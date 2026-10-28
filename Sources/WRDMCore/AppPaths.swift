import Foundation

// AppPaths centralizes runtime locations so production and tests use the same ownership model.
public struct AppPaths: Sendable {
    public let homeDirectory: URL
    public let applicationSupport: URL
    public let launchAgents: URL
    public let logs: URL
    public let diagnostics: URL
    public let captures: URL
    public let transferIncidents: URL
    public let mountIncidents: URL
    public let mountOperationLocks: URL
    public let state: URL
    public let configFile: URL
    public let statusFile: URL
    public let updateStatusFile: URL
    public let eventsFile: URL
    public let trafficFile: URL
    public let auditFile: URL
    public let networkPolicyFile: URL
    public let mountRecoveryFile: URL
    public let wakeAttemptsFile: URL
    public let retentionStateFile: URL
    public let transferJobsFile: URL
    public let transferIncidentsFile: URL
    public let mountIncidentsFile: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support/we-rock-drive-mounts", isDirectory: true)
        launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        logs = homeDirectory
            .appendingPathComponent("Library/Logs/we-rock-drive-mounts", isDirectory: true)
        diagnostics = logs.appendingPathComponent("diagnostics", isDirectory: true)
        captures = diagnostics.appendingPathComponent("pcap", isDirectory: true)
        transferIncidents = diagnostics.appendingPathComponent("transfer-incidents", isDirectory: true)
        mountIncidents = applicationSupport.appendingPathComponent("mount-incidents", isDirectory: true)
        mountOperationLocks = applicationSupport.appendingPathComponent("mount-operation-locks", isDirectory: true)
        state = applicationSupport.appendingPathComponent("state", isDirectory: true)
        configFile = applicationSupport.appendingPathComponent("config.plist")
        statusFile = state.appendingPathComponent("agent-status.json")
        updateStatusFile = state.appendingPathComponent("update-status.json")
        eventsFile = diagnostics.appendingPathComponent("events.jsonl")
        trafficFile = logs.appendingPathComponent("network-traffic.jsonl")
        auditFile = logs.appendingPathComponent("action-audit.jsonl")
        networkPolicyFile = state.appendingPathComponent("network-policy.json")
        mountRecoveryFile = state.appendingPathComponent("mount-recovery.json")
        wakeAttemptsFile = state.appendingPathComponent("wake-attempts.json")
        retentionStateFile = state.appendingPathComponent("retention-state.json")
        transferJobsFile = state.appendingPathComponent("transfer-jobs.json")
        transferIncidentsFile = diagnostics.appendingPathComponent("transfer-incidents.jsonl")
        mountIncidentsFile = state.appendingPathComponent("mount-incidents.json")
    }

    // ensureDirectories creates only application-owned directories with private access.
    public func ensureDirectories() throws {
        for directory in [applicationSupport, logs, diagnostics, captures, transferIncidents, mountIncidents, mountOperationLocks, state] {
            try SecureFileAccess.ensureDirectory(directory)
        }
        // Repair files created by older builds without touching external evidence sources.
        for file in [configFile, statusFile, updateStatusFile, eventsFile, trafficFile, auditFile, networkPolicyFile, mountRecoveryFile, wakeAttemptsFile, retentionStateFile, transferJobsFile, transferIncidentsFile, mountIncidentsFile] {
            try SecureFileAccess.hardenFile(file)
        }
    }
}
