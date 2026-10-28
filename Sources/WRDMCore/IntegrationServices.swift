import Darwin
import Foundation
import Network

// PiCompanionHealth is the versioned capability handshake returned by the remote helper.
public struct PiCompanionHealth: Codable, Equatable, Sendable {
    public var ok: Bool
    public var version: String
    public var hostname: String
    public var architecture: String
    public var addresses: [String]?
    public var dumpcapAvailable: Bool
    public var tsharkAvailable: Bool
    public var syslogReceiverActive: Bool
    public var wakeAvailable: Bool

    // init creates a complete versioned companion capability response.
    public init(
        ok: Bool,
        version: String,
        hostname: String,
        architecture: String,
        addresses: [String]?,
        dumpcapAvailable: Bool,
        tsharkAvailable: Bool,
        syslogReceiverActive: Bool,
        wakeAvailable: Bool
    ) {
        self.ok = ok
        self.version = version
        self.hostname = hostname
        self.architecture = architecture
        self.addresses = addresses
        self.dumpcapAvailable = dumpcapAvailable
        self.tsharkAvailable = tsharkAvailable
        self.syslogReceiverActive = syslogReceiverActive
        self.wakeAvailable = wakeAvailable
    }
}

// CaptureSessionMetadata preserves packet evidence provenance without loading payloads into memory.
public struct CaptureSessionMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startedAt: Date
    public var host: String
    public var interface: String
    public var filter: String
    public var remotePath: String
    public var localPath: String?
    public var sizeBytes: Int?
}

// CaptureAnalysis stores payload-free tshark evidence that AI providers can cite safely.
public struct CaptureAnalysis: Codable, Equatable, Sendable {
    public var ok: Bool
    public var packetCount: Int
    public var durationSeconds: Double
    public var protocolCounts: [String: Int]
    public var tcpRetransmissions: Int
    public var tcpResetPackets: Int
    public var icmpErrors: Int
    public var conversationCount: Int
    public var mirrorDuplicationPossible: Bool

    // diagnosticEvent binds the derived metrics to their capture session and local evidence file.
    public func diagnosticEvent(metadata: CaptureSessionMetadata, localFile: URL) -> DiagnosticEvent {
        let protocols = protocolCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return DiagnosticEvent(
            timestamp: metadata.startedAt,
            type: .packetCapture,
            source: "raspberry-pi:tshark",
            summary: "Packet capture analyzed: \(packetCount) packets, \(tcpRetransmissions) retransmissions, \(tcpResetPackets) TCP resets, \(icmpErrors) ICMP errors",
            details: [
                "session": metadata.id,
                "interface": metadata.interface,
                "filter": metadata.filter,
                "packets": String(packetCount),
                "durationSeconds": String(format: "%.3f", durationSeconds),
                "protocolCounts": protocols,
                "tcpRetransmissions": String(tcpRetransmissions),
                "tcpResetPackets": String(tcpResetPackets),
                "icmpErrors": String(icmpErrors),
                "conversationCount": String(conversationCount),
                "mirrorDuplicationPossible": String(mirrorDuplicationPossible),
            ],
            evidencePath: localFile.path
        )
    }
}

// LiveCaptureLifecycleState is the shared GUI, CLI, and MCP vocabulary for live capture.
public enum LiveCaptureLifecycleState: String, Codable, Equatable, Sendable {
    case disabled
    case degraded
    case ready
    case running
    case stopped
    case error
}

// LiveCaptureStatus reports capability and lifecycle state before any process is started.
public struct LiveCaptureStatus: Codable, Equatable, Sendable {
    public var state: LiveCaptureLifecycleState
    public var wiresharkAvailable: Bool
    public var packetCaptureEnabled: Bool
    public var activeSessionCount: Int
    public var reason: String

    // init creates one complete status envelope for all presentation adapters.
    public init(
        state: LiveCaptureLifecycleState,
        wiresharkAvailable: Bool,
        packetCaptureEnabled: Bool,
        activeSessionCount: Int,
        reason: String
    ) {
        self.state = state
        self.wiresharkAvailable = wiresharkAvailable
        self.packetCaptureEnabled = packetCaptureEnabled
        self.activeSessionCount = activeSessionCount
        self.reason = reason
    }

    // canStart keeps presentation adapters from duplicating capability policy.
    public var canStart: Bool {
        packetCaptureEnabled && wiresharkAvailable && state != .running
    }
}

// LiveCaptureService owns paired SSH and Wireshark processes for explicit live sessions.
public actor LiveCaptureService {
    private struct Session {
        var ssh: Process
        var wireshark: Process
    }

    // OpenCommand keeps file-opening testable without invoking Launch Services in unit tests.
    struct OpenCommand: Equatable {
        var executable: String
        var arguments: [String]
        var returnsImmediately: Bool
    }

    private var sessions: [String: Session] = [:]
    private let wiresharkPaths: [String]
    private let sshExecutable: String
    private var terminalState: LiveCaptureLifecycleState?
    private var terminalReason: String?

    public init(
        wiresharkPaths: [String] = LiveCaptureService.defaultWiresharkPaths,
        sshExecutable: String = "/usr/bin/ssh"
    ) {
        self.wiresharkPaths = wiresharkPaths
        self.sshExecutable = sshExecutable
    }

    // status performs a side-effect-free capability check shared by every product surface.
    public func status(packetCaptureEnabled: Bool) -> LiveCaptureStatus {
        guard packetCaptureEnabled else {
            return LiveCaptureStatus(
                state: .disabled,
                wiresharkAvailable: executablePath() != nil,
                packetCaptureEnabled: false,
                activeSessionCount: sessions.count,
                reason: "Raspberry Pi packet capture is disabled."
            )
        }
        guard executablePath() != nil else {
            return LiveCaptureStatus(
                state: .degraded,
                wiresharkAvailable: false,
                packetCaptureEnabled: true,
                activeSessionCount: sessions.count,
                reason: "Wireshark is not installed on this Mac. Install it manually to use live capture."
            )
        }
        if !sessions.isEmpty {
            return LiveCaptureStatus(
                state: .running,
                wiresharkAvailable: true,
                packetCaptureEnabled: true,
                activeSessionCount: sessions.count,
                reason: "A live Wireshark stream is running."
            )
        }
        if let terminalState, let terminalReason {
            return LiveCaptureStatus(
                state: terminalState,
                wiresharkAvailable: true,
                packetCaptureEnabled: true,
                activeSessionCount: 0,
                reason: terminalReason
            )
        }
        return LiveCaptureStatus(
            state: .ready,
            wiresharkAvailable: true,
            packetCaptureEnabled: true,
            activeSessionCount: 0,
            reason: "Wireshark is available for a bounded live stream."
        )
    }

    // start connects one validated Pi stream directly to the locally installed Wireshark binary.
    public func start(settings: PacketCaptureSettings, hostFilter: String?) throws -> String {
        guard settings.enabled else {
            terminalState = .error
            terminalReason = "Raspberry Pi packet capture is disabled."
            throw IntegrationError.remoteFailure("Raspberry Pi packet capture is disabled")
        }
        guard let wiresharkPath = executablePath() else {
            terminalState = nil
            terminalReason = nil
            throw IntegrationError.missingWireshark
        }
        if let hostFilter,
           hostFilter.range(of: "^[A-Za-z0-9_.:-]{1,253}$", options: .regularExpression) == nil {
            throw IntegrationError.remoteFailure("The live capture host filter is invalid")
        }
        let remoteArguments = [
            "/opt/we-rock-drive-mounts-companion/wrdm-companion",
            "stream",
            "--interface",
            settings.interface,
        ] + (hostFilter.map { ["--host", $0] } ?? [])
        let remote = remoteArguments.map(Self.shellQuote).joined(separator: " ")
        let pipe = Pipe()
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: sshExecutable)
        ssh.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
            "\(settings.user)@\(settings.host)", remote,
        ]
        ssh.environment = ProcessRunner.minimalEnvironment()
        ssh.standardOutput = pipe
        ssh.standardError = FileHandle.nullDevice

        let wireshark = Process()
        wireshark.executableURL = URL(fileURLWithPath: wiresharkPath)
        wireshark.arguments = ["-k", "-i", "-"]
        wireshark.environment = ProcessRunner.minimalEnvironment()
        wireshark.standardInput = pipe
        wireshark.standardOutput = FileHandle.nullDevice
        wireshark.standardError = FileHandle.nullDevice
        do {
            try wireshark.run()
        } catch {
            terminalState = .error
            terminalReason = "Wireshark could not be started."
            throw error
        }
        do {
            try ssh.run()
        } catch {
            terminate(wireshark)
            terminalState = .error
            terminalReason = "The Raspberry Pi stream could not be started."
            throw error
        }
        let identifier = UUID().uuidString
        sessions[identifier] = Session(ssh: ssh, wireshark: wireshark)
        ssh.terminationHandler = { [weak self] _ in
            Task { await self?.finishAfterProcessExit(identifier: identifier) }
        }
        wireshark.terminationHandler = { [weak self] _ in
            Task { await self?.finishAfterProcessExit(identifier: identifier) }
        }
        terminalState = nil
        terminalReason = nil
        Task { await monitor(identifier: identifier) }
        return identifier
    }

    // stop terminates both sides of one live stream without touching saved captures.
    public func stop(identifier: String) -> Bool {
        guard let session = sessions.removeValue(forKey: identifier) else { return false }
        terminate(session.ssh)
        terminate(session.wireshark)
        terminalState = .stopped
        terminalReason = "The live Wireshark stream stopped cleanly."
        return true
    }

    // wait suspends a caller until either side of the paired live stream exits.
    public func wait(identifier: String) async -> Bool {
        guard sessions[identifier] != nil else { return false }
        while sessions[identifier] != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    // stopAll terminates every stream owned by the current app, CLI, or MCP process.
    public func stopAll() {
        for identifier in Array(sessions.keys) {
            _ = stop(identifier: identifier)
        }
    }

    // ownedProcessIdentifiers exposes only app-owned child PIDs for deterministic lifecycle tests.
    func ownedProcessIdentifiers(identifier: String) -> [Int32]? {
        guard let session = sessions[identifier] else { return nil }
        return [session.ssh.processIdentifier, session.wireshark.processIdentifier]
    }

    // monitor closes the counterpart when SSH or Wireshark terminates first.
    private func monitor(identifier: String) async {
        while let session = sessions[identifier], session.ssh.isRunning, session.wireshark.isRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        finishAfterProcessExit(identifier: identifier)
    }

    // finishAfterProcessExit closes the paired child as soon as either process terminates.
    private func finishAfterProcessExit(identifier: String) {
        guard let session = sessions.removeValue(forKey: identifier) else { return }
        let sshExit = session.ssh.isRunning ? nil : session.ssh.terminationStatus
        let wiresharkExit = session.wireshark.isRunning ? nil : session.wireshark.terminationStatus
        terminate(session.ssh)
        terminate(session.wireshark)
        if let sshExit, sshExit != 0 {
            terminalState = .error
            terminalReason = "The Raspberry Pi live stream ended unexpectedly."
        } else if let wiresharkExit, wiresharkExit != 0 {
            terminalState = .error
            terminalReason = "Wireshark ended unexpectedly during live capture."
        } else {
            terminalState = .stopped
            terminalReason = "The live Wireshark stream stopped cleanly."
        }
    }

    // open reveals one completed capture in Wireshark after validating the local file.
    public func open(file: URL) throws {
        let command = try openCommand(file: file)
        if command.returnsImmediately {
            let result = try ProcessRunner.run(command.executable, arguments: command.arguments, timeout: 10)
            guard result.exitCode == 0 else { throw IntegrationError.remoteFailure("Wireshark could not open the capture") }
        } else {
            try launchDetached(executable: command.executable, arguments: command.arguments)
        }
    }

    // defaultWiresharkPaths lists explicit supported locations without installing anything.
    public static let defaultWiresharkPaths = [
            "/Applications/Wireshark.app/Contents/MacOS/Wireshark",
            "/opt/homebrew/bin/wireshark",
            "/usr/local/bin/wireshark",
    ]

    // executablePath checks the injected or default capability locations.
    private func executablePath() -> String? {
        wiresharkPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // openCommand targets the discovered Wireshark location instead of a name-based app lookup.
    func openCommand(file: URL) throws -> OpenCommand {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw IntegrationError.remoteFailure("The capture file does not exist")
        }
        guard let wiresharkPath = executablePath() else { throw IntegrationError.missingWireshark }
        if let bundlePath = appBundlePath(forExecutable: wiresharkPath) {
            return OpenCommand(
                executable: "/usr/bin/open",
                arguments: ["-a", bundlePath, file.path],
                returnsImmediately: true
            )
        }
        return OpenCommand(
            executable: wiresharkPath,
            arguments: [file.path],
            returnsImmediately: false
        )
    }

    // appBundlePath finds the owning .app bundle for a macOS application executable.
    private func appBundlePath(forExecutable executablePath: String) -> String? {
        var current = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current.path
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    // launchDetached hands a non-bundle Wireshark executable to the user without blocking command completion.
    private func launchDetached(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessRunner.minimalEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // terminate cleans up only child processes owned by this service and waits for exit.
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    // shellQuote protects each fixed remote argument from shell interpretation by SSH.
    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// PiCompanionClient uses SSH as the authenticated local-network transport.
public struct PiCompanionClient: Sendable {
    public static let protocolVersion = "0.2.0"

    public init() {}

    // health verifies the installed companion and its external capture tools.
    public func health(settings: PacketCaptureSettings) throws -> PiCompanionHealth {
        let result = try ssh(
            host: settings.host,
            user: settings.user,
            arguments: ["/opt/we-rock-drive-mounts-companion/wrdm-companion", "health"],
            timeout: 10
        )
        guard result.exitCode == 0 else {
            throw IntegrationError.remoteFailure(bounded(result.stderr))
        }
        let health = try JSONDecoder().decode(PiCompanionHealth.self, from: Data(result.stdout.utf8))
        try Self.validateHealth(health)
        return health
    }

    // validateHealth rejects incompatible companion versions and missing capture capability.
    public static func validateHealth(_ health: PiCompanionHealth) throws {
        guard health.version == protocolVersion else {
            throw IntegrationError.versionMismatch(expected: protocolVersion, actual: health.version)
        }
        guard health.dumpcapAvailable || health.tsharkAvailable else {
            throw IntegrationError.remoteFailure("The Pi has neither dumpcap nor tshark available")
        }
    }

    // install uploads the managed installer and executes it idempotently with sudo.
    public func install(
        localInstaller: URL,
        settings: PacketCaptureSettings,
        syslogPort: Int = 5514
    ) throws -> ProcessResult {
        let companionDirectory = localInstaller.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Companion")
        let companion = companionDirectory.appendingPathComponent("wrdm_companion.py")
        let service = companionDirectory.appendingPathComponent("wrdm-syslog.service")
        guard FileManager.default.fileExists(atPath: companion.path),
              FileManager.default.fileExists(atPath: service.path) else {
            throw IntegrationError.remoteFailure("Pi companion source files were not found next to the installer")
        }
        let remoteDirectory = "/tmp/wrdm-companion-install"
        _ = try ssh(
            host: settings.host,
            user: settings.user,
            arguments: ["mkdir", "-p", remoteDirectory],
            timeout: 10
        )
        let destination = "\(settings.user)@\(settings.host):\(remoteDirectory)/"
        let copy = try ProcessRunner.run(
            "/usr/bin/scp",
            arguments: sshOptions() + [localInstaller.path, companion.path, service.path, destination],
            timeout: 30
        )
        guard copy.exitCode == 0 else {
            throw IntegrationError.remoteFailure(bounded(copy.stderr))
        }
        let installer = "\(remoteDirectory)/\(localInstaller.lastPathComponent)"
        let password = CredentialStore().read(account: "raspberry-pi-sudo-password")
        // Prefer non-interactive sudo, but support a Keychain-backed first installation without exposing the password in arguments.
        let sudo = password == nil ? "sudo -n" : "sudo -S -p ''"
        let command = "\(sudo) /bin/bash \(shellQuote(installer)) --syslog-port \(max(1, min(syslogPort, 65535))); rc=$?; /bin/rm -rf \(shellQuote(remoteDirectory)); exit $rc"
        return try ssh(
            host: settings.host,
            user: settings.user,
            arguments: [command],
            timeout: 60,
            shellCommand: true,
            input: password.map { Data(($0 + "\n").utf8) }
        )
    }

    // startCapture creates one bounded PCAPNG file through the companion.
    public func startCapture(settings: PacketCaptureSettings, hostFilter: String?) throws -> CaptureSessionMetadata {
        var arguments = [
            "/opt/we-rock-drive-mounts-companion/wrdm-companion", "capture",
            "--interface", settings.interface,
            "--seconds", String(settings.durationSeconds),
            "--max-files", String(settings.maximumFiles),
            "--max-bytes", String(settings.maximumFileBytes),
            "--directory", settings.remoteDirectory,
        ]
        if let hostFilter, !hostFilter.isEmpty {
            arguments += ["--host", hostFilter]
        }
        let result = try ssh(host: settings.host, user: settings.user, arguments: arguments, timeout: TimeInterval(settings.durationSeconds + 20))
        guard result.exitCode == 0 else {
            throw IntegrationError.remoteFailure(bounded(result.stderr))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(CaptureSessionMetadata.self, from: Data(result.stdout.utf8))
        guard settings.containsRemotePath(metadata.remotePath) else {
            throw IntegrationError.remoteFailure("The companion returned a capture outside the configured directory")
        }
        return metadata
    }

    // downloadCapture copies exactly one previously returned remote path.
    public func downloadCapture(
        metadata: CaptureSessionMetadata,
        settings: PacketCaptureSettings,
        destinationDirectory: URL
    ) throws -> URL {
        try SecureFileAccess.ensureDirectory(destinationDirectory)
        guard settings.containsRemotePath(metadata.remotePath),
              metadata.sizeBytes.map({ $0 > 0 && $0 <= settings.maximumFileBytes }) ?? true else {
            throw IntegrationError.remoteFailure("The companion returned invalid or oversized capture metadata")
        }
        let destination = destinationDirectory.appendingPathComponent(URL(fileURLWithPath: metadata.remotePath).lastPathComponent)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        let source = "\(settings.user)@\(settings.host):\(metadata.remotePath)"
        let result = try ProcessRunner.run(
            "/usr/bin/scp",
            arguments: sshOptions() + [source, partial.path],
            timeout: 60
        )
        guard result.exitCode == 0,
              FileManager.default.fileExists(atPath: partial.path) else {
            throw IntegrationError.remoteFailure(bounded(result.stderr))
        }
        try SecureFileAccess.hardenFile(partial)
        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        let size = attributes[.size] as? Int ?? 0
        guard size > 0,
              size <= settings.maximumFileBytes,
              metadata.sizeBytes.map({ $0 == size }) ?? true else {
            throw IntegrationError.remoteFailure("The downloaded capture size does not match its metadata")
        }
        let header = try Data(contentsOf: partial, options: .mappedIfSafe).prefix(4)
        guard header == Data([0x0A, 0x0D, 0x0D, 0x0A]) else {
            throw IntegrationError.remoteFailure("The downloaded file is not a valid PCAPNG capture")
        }
        guard rename(partial.path, destination.path) == 0 else {
            throw IntegrationError.remoteFailure("The validated capture could not replace its destination")
        }
        try SecureFileAccess.hardenFile(destination)
        return destination
    }

    // analyzeCapture asks the Pi's tshark installation for a bounded payload-free summary.
    public func analyzeCapture(metadata: CaptureSessionMetadata, settings: PacketCaptureSettings) throws -> CaptureAnalysis {
        guard settings.containsRemotePath(metadata.remotePath) else {
            throw IntegrationError.remoteFailure("The capture analysis path is outside the configured directory")
        }
        let result = try ssh(
            host: settings.host,
            user: settings.user,
            arguments: [
                "/opt/we-rock-drive-mounts-companion/wrdm-companion",
                "capture-summary", "--file", metadata.remotePath,
            ],
            timeout: 40
        )
        guard result.exitCode == 0 else {
            throw IntegrationError.remoteFailure(bounded(result.stderr))
        }
        return try JSONDecoder().decode(CaptureAnalysis.self, from: Data(result.stdout.utf8))
    }

    // readSyslog retrieves a bounded tail from the Pi receiver.
    public func readSyslog(settings: PacketCaptureSettings, limit: Int = 500) throws -> String {
        let result = try ssh(
            host: settings.host,
            user: settings.user,
            arguments: [
                "/opt/we-rock-drive-mounts-companion/wrdm-companion",
                "syslog-tail", "--lines", String(max(1, min(limit, 5_000))),
            ],
            timeout: 15
        )
        guard result.exitCode == 0 else {
            throw IntegrationError.remoteFailure(bounded(result.stderr))
        }
        return result.stdout
    }

    // wake sends a magic packet from the verified LAN-side Pi route.
    public func wake(macAddress: String, settings: PacketCaptureSettings) throws -> ProcessResult {
        try ssh(
            host: settings.host,
            user: settings.user,
            arguments: [
                "/opt/we-rock-drive-mounts-companion/wrdm-companion",
                "wake", "--mac", macAddress,
            ],
            timeout: 10
        )
    }

    private func ssh(
        host: String,
        user: String,
        arguments: [String],
        timeout: TimeInterval,
        shellCommand: Bool = false,
        input: Data? = nil
    ) throws -> ProcessResult {
        let target = "\(user)@\(host)"
        let remote: [String]
        if shellCommand {
            remote = [arguments.joined(separator: " ")]
        } else {
            remote = [arguments.map(shellQuote).joined(separator: " ")]
        }
        return try ProcessRunner.run(
            "/usr/bin/ssh",
            arguments: sshOptions() + [target] + remote,
            input: input,
            timeout: timeout
        )
    }

    private func sshOptions() -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new"]
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }
}

// SynologyEvent keeps source and raw-line provenance for incident correlation.
public struct SynologyEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var receivedAt: Date
    public var host: String
    public var facility: String
    public var severity: String
    public var message: String
    public var rawReference: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        receivedAt: Date = Date(),
        host: String,
        facility: String,
        severity: String,
        message: String,
        rawReference: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.host = host
        self.facility = facility
        self.severity = severity
        self.message = message
        self.rawReference = rawReference
    }
}

// SynologySourceHealth reports one independently switchable evidence source.
public struct SynologySourceHealth: Codable, Equatable, Identifiable, Sendable {
    public var source: String
    public var enabled: Bool
    public var healthy: Bool
    public var message: String
    public var checkedAt: Date

    public var id: String { source }

    // init creates one source-specific health result without affecting other collectors.
    public init(source: String, enabled: Bool, healthy: Bool, message: String, checkedAt: Date = Date()) {
        self.source = source
        self.enabled = enabled
        self.healthy = healthy
        self.message = message
        self.checkedAt = checkedAt
    }
}

// SynologyService normalizes Pi syslog, CSV, and bounded read-only SSH evidence.
public struct SynologyService: Sendable {
    public init() {}

    // parseSyslog accepts RFC 3164 or RFC 5424-like lines and preserves unmatched content.
    public func parseSyslog(_ text: String, receivedAt: Date = Date()) -> [SynologyEvent] {
        text.split(separator: "\n").map { line in
            let raw = String(line)
            let envelope = receiverEnvelope(raw, fallbackReceivedAt: receivedAt)
            let parts = envelope.payload.split(separator: " ", maxSplits: 7).map(String.init)
            let rfc5424 = parts.first?.range(of: "^<[0-9]{1,3}>[0-9]+$", options: .regularExpression) != nil
            let host = rfc5424 && parts.count > 2 ? parts[2] : "synology"
            let messageStart = parts.count > 6 && parts[6] == "-" ? 7 : 6
            let message = rfc5424 && parts.count > messageStart
                ? parts.dropFirst(messageStart).joined(separator: " ")
                : envelope.payload
            return SynologyEvent(
                timestamp: rfc5424 && parts.count > 1 ? parsedISODate(parts[1]) ?? envelope.receivedAt : envelope.receivedAt,
                receivedAt: envelope.receivedAt,
                host: host,
                facility: "synology",
                severity: severity(from: envelope.payload),
                message: message,
                rawReference: stableReference(for: raw)
            )
        }
    }

    // readOnlySSH runs one fixed diagnostic command and does not accept arbitrary user shell text.
    public func readOnlySSH(settings: SynologySettings) throws -> String {
        guard settings.readOnlySSHEnabled, !settings.sshUser.isEmpty else {
            throw IntegrationError.disabled("Synology read-only SSH is disabled or incomplete")
        }
        let result = try ProcessRunner.run(
            "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
                "\(settings.sshUser)@\(settings.sshHost)",
                "uname -a; uptime; df -h; /usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion 2>/dev/null || true",
            ],
            timeout: 15
        )
        guard result.exitCode == 0 else {
            throw IntegrationError.remoteFailure(String(result.stderr.prefix(500)))
        }
        return result.stdout
    }

    // importCSV accepts exported Log Center rows with timestamp, host, severity, and message columns.
    public func importCSV(_ text: String) -> [SynologyEvent] {
        text.split(separator: "\n").dropFirst().enumerated().compactMap { index, line in
            let fields = parseCSVLine(String(line))
            guard fields.count >= 4 else { return nil }
            return SynologyEvent(
                timestamp: ISO8601DateFormatter().date(from: fields[0]) ?? Date(),
                host: fields[1],
                facility: "csv",
                severity: fields[2],
                message: fields.dropFirst(3).joined(separator: ","),
                rawReference: "csv-row-\(index + 2)"
            )
        }
    }

    // importDSMResponse normalizes supported Log Center response shapes with raw references.
    public func importDSMResponse(_ data: Data, receivedAt: Date = Date()) throws -> [SynologyEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw IntegrationError.remoteFailure("DSM returned an unsupported log response")
        }
        let rows = (payload["logs"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? (payload["data"] as? [[String: Any]])
            ?? []
        return rows.enumerated().map { index, row in
            let timestamp = dsmDate(row["timestamp"] ?? row["time"] ?? row["date"]) ?? receivedAt
            let reference = String(describing: row["id"] ?? "dsm-row-\(index + 1)")
            return SynologyEvent(
                timestamp: timestamp,
                receivedAt: receivedAt,
                host: stringValue(row["host"] ?? row["hostname"], fallback: "synology"),
                facility: stringValue(row["facility"] ?? row["category"], fallback: "dsm-api"),
                severity: stringValue(row["severity"] ?? row["level"], fallback: "info"),
                message: stringValue(row["message"] ?? row["msg"] ?? row["event"], fallback: "DSM event"),
                rawReference: reference
            )
        }
    }

    // diagnosticEvent converts a NAS event while retaining source, raw reference, and clock skew.
    public func diagnosticEvent(_ event: SynologyEvent) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: event.timestamp,
            type: .synology,
            source: "synology:\(event.host)",
            summary: String(event.message.prefix(1_000)),
            details: [
                "facility": event.facility,
                "severity": event.severity,
                "rawReference": event.rawReference,
                "receivedAt": ISO8601DateFormatter().string(from: event.receivedAt),
                "clockSkewSeconds": String(Int(event.receivedAt.timeIntervalSince(event.timestamp))),
            ]
        )
    }

    // receiverEnvelope separates the Pi arrival metadata from the original syslog payload.
    private func receiverEnvelope(_ line: String, fallbackReceivedAt: Date) -> (receivedAt: Date, payload: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              parts[1].hasPrefix("receiver="),
              let timestamp = parsedISODate(parts[0]) else {
            return (fallbackReceivedAt, line)
        }
        return (timestamp, parts[2])
    }

    private func parsedISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // stableReference deduplicates the same Pi record even when its tail position changes.
    private func stableReference(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "syslog-%016llx", hash)
    }

    private func severity(from line: String) -> String {
        guard line.hasPrefix("<"), let end = line.firstIndex(of: ">"),
              let priority = Int(line[line.index(after: line.startIndex)..<end]) else {
            return "info"
        }
        return ["emergency", "alert", "critical", "error", "warning", "notice", "info", "debug"][priority % 8]
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    // dsmDate accepts ISO 8601 strings and Unix timestamps from provider variants.
    private func dsmDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let string = value as? String {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
        }
        return nil
    }

    // stringValue bounds loosely typed DSM fields before canonical storage.
    private func stringValue(_ value: Any?, fallback: String) -> String {
        String(String(describing: value ?? fallback).prefix(2_000))
    }
}

// SynologyDSMAPIClient provides discovery and read-only Log Center retrieval through Keychain credentials.
public struct SynologyDSMAPIClient: Sendable {
    private let credentials = CredentialStore()

    public init() {}

    // health verifies API discovery without requiring a DSM mutation.
    public func health(settings: SynologySettings) async -> SynologySourceHealth {
        guard settings.dsmAPIEnabled else {
            return SynologySourceHealth(source: "dsm-api", enabled: false, healthy: false, message: "Disabled")
        }
        do {
            let info = try await discover(settings: settings)
            let available = info["SYNO.Core.SyslogClient.Log"] != nil
            return SynologySourceHealth(
                source: "dsm-api",
                enabled: true,
                healthy: available,
                message: available ? "Read-only Log Center API discovered" : "Log Center API is unavailable"
            )
        } catch {
            return SynologySourceHealth(source: "dsm-api", enabled: true, healthy: false, message: bounded(error.localizedDescription))
        }
    }

    // fetchLogs authenticates a temporary read-only session and returns its raw Log Center payload.
    public func fetchLogs(settings: SynologySettings, limit: Int = 200) async throws -> Data {
        guard settings.dsmAPIEnabled else { throw IntegrationError.disabled("DSM API source is disabled") }
        guard let account = credentials.read(account: "synology-dsm-account"),
              let password = credentials.read(account: "synology-dsm-password") else {
            throw IntegrationError.disabled("DSM API credentials are missing from Keychain")
        }
        let info = try await discover(settings: settings)
        guard let descriptor = info["SYNO.Core.SyslogClient.Log"] as? [String: Any] else {
            throw IntegrationError.remoteFailure("DSM Log Center API was not discovered")
        }
        let sid = try await login(baseURL: settings.dsmBaseURL, account: account, password: password)
        defer { Task { try? await logout(baseURL: settings.dsmBaseURL, sid: sid) } }
        let path = descriptor["path"] as? String ?? "entry.cgi"
        let version = min(3, (descriptor["maxVersion"] as? NSNumber)?.intValue ?? 1)
        return try await request(
            baseURL: settings.dsmBaseURL,
            path: path,
            query: [
                "api": "SYNO.Core.SyslogClient.Log",
                "version": String(version),
                "method": "list",
                "offset": "0",
                "limit": String(max(1, min(limit, 1_000))),
                "_sid": sid,
            ]
        )
    }

    // discover reads only public API capability metadata.
    private func discover(settings: SynologySettings) async throws -> [String: Any] {
        let data = try await request(
            baseURL: settings.dsmBaseURL,
            path: "query.cgi",
            query: [
                "api": "SYNO.API.Info",
                "version": "1",
                "method": "query",
                "query": "SYNO.API.Auth,SYNO.Core.SyslogClient.Log",
            ]
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true,
              let payload = object["data"] as? [String: Any] else {
            throw IntegrationError.remoteFailure("DSM API discovery failed")
        }
        return payload
    }

    // login creates a temporary application session without persisting credentials outside Keychain.
    private func login(baseURL: String, account: String, password: String) async throws -> String {
        let data = try await request(
            baseURL: baseURL,
            path: "auth.cgi",
            query: [
                "api": "SYNO.API.Auth",
                "version": "7",
                "method": "login",
                "account": account,
                "passwd": password,
                "session": "WeRockDriveMounts",
                "format": "sid",
            ],
            method: "POST"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true,
              let payload = object["data"] as? [String: Any],
              let sid = payload["sid"] as? String else {
            throw IntegrationError.remoteFailure("DSM authentication failed")
        }
        return sid
    }

    // logout invalidates the temporary DSM session.
    private func logout(baseURL: String, sid: String) async throws {
        _ = try await request(
            baseURL: baseURL,
            path: "auth.cgi",
            query: [
                "api": "SYNO.API.Auth",
                "version": "7",
                "method": "logout",
                "session": "WeRockDriveMounts",
                "_sid": sid,
            ],
            method: "POST"
        )
    }

    // request performs one bounded DSM Web API call and rejects credential-bearing base URLs.
    private func request(
        baseURL: String,
        path: String,
        query: [String: String],
        method: String = "GET"
    ) async throws -> Data {
        guard var base = URLComponents(string: baseURL),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host?.isEmpty == false,
              base.user == nil,
              base.password == nil else {
            throw IntegrationError.remoteFailure("DSM base address is invalid")
        }
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        base.path = "/" + (prefix.isEmpty ? "" : "\(prefix)/") + "webapi/\(path)"
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if method == "GET" { base.queryItems = items }
        guard let url = base.url else { throw IntegrationError.remoteFailure("DSM request URL is invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if method == "POST" {
            var body = URLComponents()
            body.queryItems = items
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 10_485_760 else {
            throw IntegrationError.remoteFailure("DSM request failed")
        }
        return data
    }

    // bounded prevents transport internals from filling health surfaces.
    private func bounded(_ value: String) -> String {
        String(value.prefix(300))
    }
}

// WakeService coordinates independently configurable routes and post-send verification.
public struct WakeService: Sendable {
    private let piClient = PiCompanionClient()

    public init() {}

    // validateMAC rejects malformed or broadcast-like targets before a route runs.
    public func validateMAC(_ value: String) -> Bool {
        value.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
            && value.lowercased() != "ff:ff:ff:ff:ff:ff"
    }

    // wake invokes the selected adapter and reports transport success separately from reachability.
    public func wake(
        route: WakeRouteKind,
        wakeSettings: WakeSettings,
        packetSettings: PacketCaptureSettings,
        requireVerified: Bool = true
    ) throws -> CommandResult {
        guard validateMAC(wakeSettings.targetMACAddress) else {
            return CommandResult(ok: false, code: "INVALID_MAC", message: "The configured Mac address is invalid.")
        }
        guard let configuration = wakeSettings.routes.first(where: { $0.kind == route }), configuration.enabled else {
            return CommandResult(ok: false, code: "ROUTE_DISABLED", message: "The selected wake route is disabled.")
        }
        guard configuration.verified || !requireVerified else {
            return CommandResult(ok: false, code: "ROUTE_UNVERIFIED", message: "The selected wake route has not been verified.")
        }

        let result: ProcessResult
        switch route {
        case .raspberryPiLAN:
            result = try piClient.wake(macAddress: wakeSettings.targetMACAddress, settings: packetSettings)
        case .tailscale:
            guard configuration.command.range(of: "^[A-Za-z0-9_.:-]{1,253}$", options: .regularExpression) != nil else {
                return CommandResult(ok: false, code: "ROUTE_INCOMPLETE", message: "The Tailscale Pi address is missing or invalid.")
            }
            var tailscaleSettings = packetSettings
            tailscaleSettings.host = configuration.command
            result = try piClient.wake(macAddress: wakeSettings.targetMACAddress, settings: tailscaleSettings)
        case .synologyTask:
            let fields = configuration.command.split(separator: "|", maxSplits: 1).map(String.init)
            guard fields.count == 2,
                  fields[0].range(of: "^[A-Za-z0-9._-]+@[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil,
                  fields[1].range(of: "^[0-9]{1,12}$", options: .regularExpression) != nil else {
                return CommandResult(ok: false, code: "ROUTE_INCOMPLETE", message: "Use a Synology target and numeric task ID in the documented format.")
            }
            result = try ProcessRunner.run(
                "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
                    fields[0],
                    "/usr/syno/bin/synoschedtask --run id=\(fields[1])",
                ],
                timeout: 15
            )
        case .iosShortcut:
            return CommandResult(ok: false, code: "EXTERNAL_TRIGGER_REQUIRED", message: "Run the configured iPhone Shortcut externally; this Mac cannot verify that trigger route by itself.")
        case .cli:
            result = try sendLocalMagicPacket(macAddress: wakeSettings.targetMACAddress)
        }
        guard result.exitCode == 0 else {
            return CommandResult(ok: false, code: "WAKE_TRANSPORT_FAILED", message: String(result.stderr.prefix(300)))
        }
        let reachable = verifyHost(wakeSettings.targetHost, timeout: 30)
        return CommandResult(
            ok: reachable,
            code: reachable ? "WAKE_VERIFIED" : "WAKE_SENT_UNVERIFIED",
            message: reachable ? "The Mac became reachable." : "The wake packet was sent, but reachability was not confirmed."
        )
    }

    // sendLocalMagicPacket implements the CLI route without a third-party dependency.
    private func sendLocalMagicPacket(macAddress: String) throws -> ProcessResult {
        let bytes = macAddress.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else {
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Invalid MAC address", timedOut: false)
        }
        let packet = Data(repeating: 0xFF, count: 6) + Data(Array(repeating: bytes, count: 16).flatMap { $0 })
        let script = "import socket,sys,time;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);p=sys.stdin.buffer.read();[(s.sendto(p,('255.255.255.255',9)),time.sleep(.2)) for _ in range(3)]"
        return try ProcessRunner.run("/usr/bin/python3", arguments: ["-c", script], input: packet, timeout: 5)
    }

    private func verifyHost(_ host: String, timeout: TimeInterval) -> Bool {
        guard !host.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let result = try? ProcessRunner.run("/sbin/ping", arguments: ["-c", "1", "-W", "1000", host], timeout: 3)
            if result?.exitCode == 0 { return true }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        return false
    }
}

// WakeAttemptStore suppresses duplicate triggers across app, CLI, and MCP processes.
public actor WakeAttemptStore {
    private let file: URL

    public init(paths: AppPaths = AppPaths()) {
        file = paths.wakeAttemptsFile
    }

    // reserve atomically records a route attempt unless it is inside the duplicate window.
    public func reserve(route: WakeRouteKind, now: Date = Date(), minimumInterval: TimeInterval = 10) -> Bool {
        (try? SecureFileAccess.withLock(for: file) {
            var values = loadUnlocked()
            if let previous = values[route.rawValue], now.timeIntervalSince(previous) < minimumInterval {
                return false
            }
            values[route.rawValue] = now
            try saveUnlocked(values)
            return true
        }) ?? false
    }

    // loadUnlocked tolerates interrupted state writes while its caller owns the cross-process lock.
    private func loadUnlocked() -> [String: Date] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    // saveUnlocked publishes one private attempt map while its caller owns the lock.
    private func saveUnlocked(_ values: [String: Date]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SecureFileAccess.writeAtomically(try encoder.encode(values), to: file)
    }
}

// IntegrationError keeps remote failures explicit and bounded.
public enum IntegrationError: LocalizedError {
    case disabled(String)
    case remoteFailure(String)
    case versionMismatch(expected: String, actual: String)
    case missingWireshark

    public var errorDescription: String? {
        switch self {
        case .disabled(let message), .remoteFailure(let message): message
        case .versionMismatch(let expected, let actual):
            "Pi companion version \(actual) is incompatible; expected \(expected)."
        case .missingWireshark:
            "Wireshark is not installed on this Mac. Install Wireshark to use live capture or open PCAPNG files."
        }
    }
}
