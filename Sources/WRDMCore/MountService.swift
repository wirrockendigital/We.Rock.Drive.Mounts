import Darwin
import Foundation

// DiscoveredSMBMount is a visible macOS SMB mount that can become a WRDM auto-recovery entry.
public struct DiscoveredSMBMount: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var localPath: String

    public var id: String { url }

    // init keeps discovery data independent from generated MountDefinition identifiers.
    public init(name: String, url: String, localPath: String) {
        self.name = name
        self.url = url
        self.localPath = localPath
    }
}

// DiscoveryMountedShare retains display-only fields that recovery deliberately does not need.
private struct DiscoveryMountedShare: Sendable {
    var url: String
    var normalizedURL: String
    var mountPoint: String
    var options: String

    // isNormalUserMount filters hidden system SMB mounts such as Time Machine.
    var isNormalUserMount: Bool {
        mountPoint.hasPrefix("/Volumes/")
            && !mountPoint.hasPrefix("/Volumes/.")
            && !options.contains("nobrowse")
    }
}

// MountedShare binds a normalized SMB identity to its current macOS mount point.
public struct MountedShare: Codable, Equatable, Sendable {
    public var normalizedURL: String
    public var mountPoint: String

    // init creates one mount-table record without retaining a username.
    public init(normalizedURL: String, mountPoint: String) {
        self.normalizedURL = normalizedURL
        self.mountPoint = mountPoint
    }
}

// MountTableObservation preserves adapter failures instead of treating them as an empty table.
public struct MountTableObservation: Equatable, Sendable {
    public var shares: [MountedShare]
    public var failureCode: MountFailureCode?
    public var message: String?

    // init creates one complete observation from the macOS mount command.
    public init(shares: [MountedShare], failureCode: MountFailureCode? = nil, message: String? = nil) {
        self.shares = shares
        self.failureCode = failureCode
        self.message = message
    }
}

// MountHealthObservation distinguishes a timeout from a normal unhealthy SMB response.
public struct MountHealthObservation: Equatable, Sendable {
    public var healthy: Bool
    public var timedOut: Bool
    public var message: String

    // init creates one bounded session-health result.
    public init(healthy: Bool, timedOut: Bool = false, message: String) {
        self.healthy = healthy
        self.timedOut = timedOut
        self.message = message
    }
}

// MountSystemProviding isolates all read and mutation calls to the macOS SMB subsystem.
public protocol MountSystemProviding: Sendable {
    func mountTable() -> MountTableObservation
    func sessionHealth(mountPoint: String, timeout: TimeInterval) -> MountHealthObservation
    func endpointIsReachable(host: String) -> Bool
    func requestMount(url: String, timeout: TimeInterval) -> ProcessResult
    func requestUnmount(mountPoint: String, force: Bool, timeout: TimeInterval) -> ProcessResult
    func bootIdentity() -> String
}

// MacOSMountSystem is the production adapter for mount, smbutil, nc, diskutil, and osascript.
public struct MacOSMountSystem: MountSystemProviding {
    private let process: any ProcessExecuting

    public init(process: any ProcessExecuting = SystemProcessExecutor()) {
        self.process = process
    }

    // mountTable parses only smbfs records and reports command failure separately from no mounts.
    public func mountTable() -> MountTableObservation {
        do {
            let result = try process.run("/sbin/mount", arguments: [], input: nil, timeout: 5, environment: nil)
            guard result.exitCode == 0, !result.timedOut else {
                return MountTableObservation(
                    shares: [],
                    failureCode: .mountTableUnavailable,
                    message: boundedMessage(result.timedOut ? "Mount-table query timed out" : result.stderr)
                )
            }
            return MountTableObservation(shares: SMBMountTableParser.parse(result.stdout))
        } catch {
            return MountTableObservation(shares: [], failureCode: .mountTableUnavailable, message: boundedMessage(error.localizedDescription))
        }
    }

    // sessionHealth checks one existing mount point without traversing its directory tree.
    public func sessionHealth(mountPoint: String, timeout: TimeInterval) -> MountHealthObservation {
        do {
            let result = try process.run(
                "/usr/bin/smbutil",
                arguments: ["statshares", "-m", mountPoint],
                input: nil,
                timeout: timeout,
                environment: nil
            )
            if result.exitCode == 0 {
                return MountHealthObservation(healthy: true, message: "Connected")
            }
            return MountHealthObservation(
                healthy: false,
                timedOut: result.timedOut,
                message: boundedMessage(result.timedOut ? "SMB health check timed out" : result.stderr)
            )
        } catch {
            return MountHealthObservation(healthy: false, message: boundedMessage(error.localizedDescription))
        }
    }

    // endpointIsReachable avoids opening a Finder authentication flow during a server outage.
    public func endpointIsReachable(host: String) -> Bool {
        let result = try? process.run(
            "/usr/bin/nc",
            arguments: ["-z", "-G", "2", host, "445"],
            input: nil,
            timeout: 4,
            environment: nil
        )
        return result?.exitCode == 0
    }

    // requestMount asks the standard macOS mount-volume adapter to use Keychain credentials.
    public func requestMount(url: String, timeout: TimeInterval) -> ProcessResult {
        let script = [
            "on run argv",
            "try",
            "mount volume item 1 of argv",
            "return \"OK\"",
            "on error errMsg number errNum",
            "return \"ERROR \" & errNum & \": \" & errMsg",
            "end try",
            "end run",
        ]
        let arguments = script.flatMap { ["-e", $0] } + [SMBMountTableParser.encodedURL(url)]
        return commandResult(executable: "/usr/bin/osascript", arguments: arguments, timeout: timeout)
    }

    // requestUnmount keeps normal and force requests explicit for the recovery policy.
    public func requestUnmount(mountPoint: String, force: Bool, timeout: TimeInterval) -> ProcessResult {
        let arguments = force ? ["unmount", "force", mountPoint] : ["unmount", mountPoint]
        return commandResult(executable: "/usr/sbin/diskutil", arguments: arguments, timeout: timeout)
    }

    // bootIdentity returns a stable value that changes only after the macOS kernel boots again.
    public func bootIdentity() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else { return "" }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }

    // commandResult converts a launch error into a stable non-throwing adapter result.
    private func commandResult(executable: String, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        do {
            return try process.run(executable, arguments: arguments, input: nil, timeout: timeout, environment: nil)
        } catch {
            return ProcessResult(exitCode: 127, stdout: "", stderr: boundedMessage(error.localizedDescription), timedOut: false, executionState: .unknown)
        }
    }

    // boundedMessage prevents adapter output from filling shared status surfaces.
    private func boundedMessage(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}

// SMBMountTableParser provides deterministic identity handling for production and test fixtures.
public enum SMBMountTableParser {
    // parse preserves mount points containing spaces and removes usernames from remote identities.
    public static func parse(_ output: String) -> [MountedShare] {
        output.split(separator: "\n").compactMap { line in
            let value = String(line)
            guard value.hasPrefix("//"), value.contains("(smbfs"), let separator = value.range(of: " on ") else {
                return nil
            }
            let remote = String(value[..<separator.lowerBound]).dropFirst(2)
            let remainder = String(value[separator.upperBound...])
            guard let options = remainder.range(of: " (smbfs") else { return nil }
            let mountPoint = String(remainder[..<options.lowerBound])
            let withoutUser = remote.split(separator: "@", maxSplits: 1).last.map(String.init) ?? String(remote)
            return MountedShare(normalizedURL: normalize("smb://\(withoutUser)"), mountPoint: mountPoint)
        }
    }

    // normalize compares host and share case-insensitively like the Synology mount table.
    public static func normalize(_ value: String) -> String {
        guard let components = URLComponents(string: value), let host = components.host else {
            return value.lowercased()
        }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return "smb://\(host.lowercased())\(decodedPath.lowercased())"
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // encodedURL percent-encodes spaces while preserving SMB separators.
    public static func encodedURL(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "%20")
    }
}

// MountService observes SMB mounts and performs no mount-changing operation itself.
public struct MountService: Sendable {
    public let system: any MountSystemProviding

    public init(system: any MountSystemProviding = MacOSMountSystem()) {
        self.system = system
    }

    // importableMountedSMBMounts reads visible SMB mounts without entering the recovery mutation path.
    public func importableMountedSMBMounts(configuredMounts: [MountDefinition]) -> [DiscoveredSMBMount] {
        guard let result = try? ProcessRunner.run("/sbin/mount", timeout: 5),
              result.exitCode == 0,
              !result.timedOut else {
            return []
        }
        return Self.discoveredMounts(from: result.stdout, configuredMounts: configuredMounts)
    }

    // discoveredMounts parses macOS mount output without touching live system state.
    public static func discoveredMounts(
        from mountOutput: String,
        configuredMounts: [MountDefinition] = []
    ) -> [DiscoveredSMBMount] {
        let configured = Set(configuredMounts.map { SMBMountTableParser.normalize($0.url) })
        var seen: Set<String> = []
        return parseDiscoveryMountedShares(from: mountOutput).compactMap { share in
            guard share.isNormalUserMount,
                  !configured.contains(share.normalizedURL),
                  seen.insert(share.normalizedURL).inserted else {
                return nil
            }
            let localName = URL(fileURLWithPath: share.mountPoint).lastPathComponent
            let urlName = URLComponents(string: share.url)?.path.split(separator: "/").last.map(String.init)
            return DiscoveredSMBMount(
                name: localName.isEmpty ? urlName ?? share.url : localName,
                url: share.url,
                localPath: share.mountPoint
            )
        }
    }

    // runtimeStates checks independent SMB sessions concurrently after one shared mount-table read.
    public func runtimeStates(settings: AppSettings) async -> [MountRuntimeState] {
        let table = system.mountTable()
        return await withTaskGroup(of: (Int, MountRuntimeState).self, returning: [MountRuntimeState].self) { group in
            for (index, mount) in settings.mounts.enumerated() {
                group.addTask {
                    let state = runtimeState(
                        for: mount,
                        table: table,
                        healthTimeout: TimeInterval(settings.general.smbHealthTimeoutSeconds)
                    )
                    return (index, state)
                }
            }
            var indexed: [(Int, MountRuntimeState)] = []
            for await value in group { indexed.append(value) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // runtimeStatesSynchronously supports synchronous transfer validation outside the monitoring cycle.
    public func runtimeStatesSynchronously(settings: AppSettings) -> [MountRuntimeState] {
        let table = system.mountTable()
        return settings.mounts.map { mount in
            runtimeState(
                for: mount,
                table: table,
                healthTimeout: TimeInterval(settings.general.smbHealthTimeoutSeconds)
            )
        }
    }

    // runtimeState observes one mount against a caller-provided table for recovery verification.
    public func runtimeState(
        for mount: MountDefinition,
        table: MountTableObservation? = nil,
        healthTimeout: TimeInterval
    ) -> MountRuntimeState {
        guard mount.enabled else {
            return state(for: mount, availability: .disabled, message: "Disabled")
        }
        guard Self.isCredentialFreeSMBURL(mount.url) else {
            return state(for: mount, availability: .unknown, failureCode: .invalidSMBURL, message: "Credentials in SMB URL are not allowed")
        }
        let observedTable = table ?? system.mountTable()
        if let failureCode = observedTable.failureCode {
            return state(for: mount, availability: .unknown, failureCode: failureCode, message: observedTable.message ?? "Mount table is unavailable")
        }
        guard let share = observedTable.shares.first(where: { $0.normalizedURL == SMBMountTableParser.normalize(mount.url) }) else {
            return state(for: mount, availability: .missing, message: "Not mounted")
        }
        let health = system.sessionHealth(mountPoint: share.mountPoint, timeout: healthTimeout)
        guard health.healthy else {
            return state(
                for: mount,
                availability: .staleMounted,
                failureCode: health.timedOut ? .smbHealthTimedOut : .smbSessionUnresponsive,
                message: health.message.isEmpty ? "SMB session is unresponsive" : health.message,
                localPath: share.mountPoint
            )
        }
        return state(for: mount, availability: .healthy, message: "Connected", localPath: share.mountPoint)
    }

    // isCredentialFreeSMBURL enforces Keychain-based authentication before any mutation is considered.
    public static func isCredentialFreeSMBURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme?.lowercased() == "smb"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
    }

    // parseDiscoveryMountedShares preserves display URLs and mount flags only for read-only import discovery.
    private static func parseDiscoveryMountedShares(from output: String) -> [DiscoveryMountedShare] {
        output.split(separator: "\n").compactMap { line in
            let value = String(line)
            guard value.hasPrefix("//"), value.contains("(smbfs"), let separator = value.range(of: " on ") else {
                return nil
            }
            let remote = String(value[..<separator.lowerBound]).dropFirst(2)
            let remainder = String(value[separator.upperBound...])
            guard let options = remainder.range(of: " (smbfs") else { return nil }
            let mountPoint = String(remainder[..<options.lowerBound])
            let optionValue = String(remainder[options.lowerBound...])
            let withoutUser = remote.split(separator: "@", maxSplits: 1).last.map(String.init) ?? String(remote)
            let decodedRemote = (withoutUser.removingPercentEncoding ?? withoutUser)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = "smb://\(decodedRemote)"
            return DiscoveryMountedShare(
                url: url,
                normalizedURL: SMBMountTableParser.normalize(url),
                mountPoint: mountPoint,
                options: optionValue
            )
        }
    }

    // state creates one consistently timestamped observation without recovery metadata.
    private func state(
        for mount: MountDefinition,
        availability: MountAvailability,
        failureCode: MountFailureCode? = nil,
        message: String,
        localPath: String? = nil
    ) -> MountRuntimeState {
        MountRuntimeState(
            mountID: mount.id,
            timestamp: Date(),
            availability: availability,
            consecutiveFailures: 0,
            failureCode: failureCode,
            message: String(message.prefix(300)),
            localPath: localPath
        )
    }
}
