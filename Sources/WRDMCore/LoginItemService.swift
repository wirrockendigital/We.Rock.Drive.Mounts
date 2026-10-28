import Darwin
import Foundation

// LoginItemStatus describes the user-domain LaunchAgent used to open the menu-bar app.
public struct LoginItemStatus: Codable, Equatable, Sendable {
    public var label: String
    public var plistPath: String
    public var appPath: String
    public var enabled: Bool
    public var loaded: Bool
    public var message: String
}

// LoginItemService manages only the visible app login item, never the background helper.
public struct LoginItemService: Sendable {
    public static let label = "com.we-rock.drive-mounts.app-login"
    public static let bundleIdentifier = "com.we-rock.drive-mounts"

    private let paths: AppPaths
    private let appBundle: URL
    private let executeLaunchctl: Bool

    public init(
        paths: AppPaths = AppPaths(),
        appBundle: URL = URL(fileURLWithPath: "/Applications/We Rock Drive Mounts.app", isDirectory: true),
        executeLaunchctl: Bool = true
    ) {
        self.paths = paths
        self.appBundle = appBundle.standardizedFileURL
        self.executeLaunchctl = executeLaunchctl
    }

    public var plistFile: URL {
        paths.launchAgents.appendingPathComponent("\(Self.label).plist")
    }

    // status reports durable and launchd state separately so callers can spot drift.
    public func status() -> LoginItemStatus {
        let exists = FileManager.default.fileExists(atPath: plistFile.path)
        let loaded = executeLaunchctl ? launchctlPrintSucceeded() : exists
        return LoginItemStatus(
            label: Self.label,
            plistPath: plistFile.path,
            appPath: appBundle.path,
            enabled: exists,
            loaded: loaded,
            message: exists ? (loaded ? "App login item is enabled." : "App login item file exists but is not loaded.") : "App login item is disabled."
        )
    }

    // apply converges the LaunchAgent to the requested setting.
    @discardableResult
    public func apply(enabled: Bool) throws -> LoginItemStatus {
        if enabled {
            try enable()
        } else {
            try disable()
        }
        return status()
    }

    // enable writes, validates, and bootstraps the app-login LaunchAgent.
    public func enable() throws {
        guard FileManager.default.fileExists(atPath: appBundle.path) else {
            throw LoginItemError.missingApp(appBundle.path)
        }
        try ensureLaunchAgentsDirectory()
        try SecureFileAccess.ensureDirectory(paths.logs)
        // A matching loaded job must not be bootstrapped again: RunAtLoad would reopen the app.
        let expected = try renderPlistData()
        let current = try? Data(contentsOf: plistFile)
        if current == expected && status().loaded { return }
        try writePlist()
        if executeLaunchctl {
            _ = try? ProcessRunner.run("/bin/launchctl", arguments: ["bootout", domainTarget()], timeout: 5)
            let result = try ProcessRunner.run("/bin/launchctl", arguments: ["bootstrap", domain(), plistFile.path], timeout: 10)
            guard result.exitCode == 0 else {
                throw LoginItemError.launchctlFailed("bootstrap", bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
            }
            let enable = try ProcessRunner.run("/bin/launchctl", arguments: ["enable", domainTarget()], timeout: 5)
            guard enable.exitCode == 0 else {
                throw LoginItemError.launchctlFailed("enable", bounded(enable.stderr.isEmpty ? enable.stdout : enable.stderr))
            }
        }
    }

    // disable unloads and removes only the app-login LaunchAgent.
    public func disable() throws {
        if executeLaunchctl {
            _ = try? ProcessRunner.run("/bin/launchctl", arguments: ["bootout", domainTarget()], timeout: 5)
        }
        if FileManager.default.fileExists(atPath: plistFile.path) {
            try FileManager.default.removeItem(at: plistFile)
        }
    }

    // renderPlistData is public for tests and installer parity checks.
    public func renderPlistData() throws -> Data {
        let payload: [String: Any] = [
            "Label": Self.label,
            "AssociatedBundleIdentifiers": [Self.bundleIdentifier],
            // Launch the accessory executable directly to avoid LaunchServices reopen events.
            "ProgramArguments": [appBundle.appendingPathComponent("Contents/MacOS/WeRockDriveMounts").path, "--background"],
            "RunAtLoad": true,
            "StandardOutPath": paths.logs.appendingPathComponent("app-login.out.log").path,
            "StandardErrorPath": paths.logs.appendingPathComponent("app-login.err.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    // writePlist atomically publishes a launchd-readable plist owned by the user.
    private func writePlist() throws {
        try ensureLaunchAgentsDirectory()
        let data = try renderPlistData()
        let temporary = plistFile.deletingLastPathComponent().appendingPathComponent(".\(plistFile.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try SecureFileAccess.hardenFile(temporary)
            guard rename(temporary.path, plistFile.path) == 0 else {
                throw FileAccessError.posix(operation: "replace login item plist", code: errno)
            }
            try SecureFileAccess.hardenFile(plistFile)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // ensureLaunchAgentsDirectory keeps the user-owned launchd directory readable by launchd.
    private func ensureLaunchAgentsDirectory() throws {
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        guard chmod(paths.launchAgents.path, 0o755) == 0 else {
            throw FileAccessError.posix(operation: "chmod LaunchAgents directory", code: errno)
        }
    }

    private func launchctlPrintSucceeded() -> Bool {
        guard let result = try? ProcessRunner.run("/bin/launchctl", arguments: ["print", domainTarget()], timeout: 5) else {
            return false
        }
        return result.exitCode == 0
    }

    private func domain() -> String { "gui/\(getuid())" }

    private func domainTarget() -> String { "\(domain())/\(Self.label)" }

    private func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }
}

// LoginItemError keeps launchd failures user-readable across app, CLI, and MCP.
public enum LoginItemError: LocalizedError, Equatable {
    case missingApp(String)
    case launchctlFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingApp(let path):
            "The installed app was not found at \(path)."
        case .launchctlFailed(let action, let detail):
            "Could not \(action) the app login item. \(detail)"
        }
    }
}
