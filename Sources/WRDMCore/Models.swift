import Foundation

// AppSettings is the single persisted configuration consumed by every process.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var general: GeneralSettings
    public var mounts: [MountDefinition]
    public var network: NetworkPolicy
    public var diagnostics: DiagnosticsPolicy
    public var packetCapture: PacketCaptureSettings
    public var synology: SynologySettings
    public var ai: AISettings
    public var wake: WakeSettings
    public var transfer: TransferSettings

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        general: GeneralSettings = .defaults,
        mounts: [MountDefinition] = [],
        network: NetworkPolicy = .defaults,
        diagnostics: DiagnosticsPolicy = .defaults,
        packetCapture: PacketCaptureSettings = .defaults,
        synology: SynologySettings = .defaults,
        ai: AISettings = .defaults,
        wake: WakeSettings = .defaults,
        transfer: TransferSettings = .defaults
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.mounts = mounts
        self.network = network
        self.diagnostics = diagnostics
        self.packetCapture = packetCapture
        self.synology = synology
        self.ai = ai
        self.wake = wake
        self.transfer = transfer
    }

    public static var defaults: AppSettings { AppSettings() }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case general
        case mounts
        case network
        case diagnostics
        case packetCapture
        case synology
        case ai
        case wake
        case transfer
    }

    // init preserves existing beta configurations while adding transfer defaults.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        general = try values.decode(GeneralSettings.self, forKey: .general)
        mounts = try values.decode([MountDefinition].self, forKey: .mounts)
        network = try values.decode(NetworkPolicy.self, forKey: .network)
        diagnostics = try values.decode(DiagnosticsPolicy.self, forKey: .diagnostics)
        packetCapture = try values.decode(PacketCaptureSettings.self, forKey: .packetCapture)
        synology = try values.decode(SynologySettings.self, forKey: .synology)
        ai = try values.decode(AISettings.self, forKey: .ai)
        wake = try values.decode(WakeSettings.self, forKey: .wake)
        transfer = try values.decodeIfPresent(TransferSettings.self, forKey: .transfer) ?? .defaults
    }
}

// ConfigurationExportDocument wraps AppSettings with a stable transfer marker.
public struct ConfigurationExportDocument: Codable, Equatable, Sendable {
    public static let currentFormatIdentifier = "com.we-rock.drive-mounts.configuration"
    public static let currentFormatVersion = 1

    public var formatIdentifier: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var settings: AppSettings

    public init(
        formatIdentifier: String = Self.currentFormatIdentifier,
        formatVersion: Int = Self.currentFormatVersion,
        exportedAt: Date = Date(),
        settings: AppSettings
    ) {
        self.formatIdentifier = formatIdentifier
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.settings = settings
    }
}

// GeneralSettings controls the independent agent lifecycle and user language.
public struct GeneralSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var openAppAtLogin: Bool
    public var checkIntervalSeconds: Int
    public var bootDelaySeconds: Int
    public var maximumAutomaticRecoveryAttempts: Int
    public var mountTimeoutSeconds: Int
    public var smbHealthTimeoutSeconds: Int
    public var language: AppLanguage
    public var onboardingCompleted: Bool

    public static let defaults = GeneralSettings(
        enabled: true,
        openAppAtLogin: false,
        checkIntervalSeconds: 20,
        bootDelaySeconds: 15,
        maximumAutomaticRecoveryAttempts: 3,
        mountTimeoutSeconds: 20,
        smbHealthTimeoutSeconds: 5,
        language: .system,
        onboardingCompleted: false
    )

    public init(
        enabled: Bool,
        openAppAtLogin: Bool = false,
        checkIntervalSeconds: Int,
        bootDelaySeconds: Int,
        maximumAutomaticRecoveryAttempts: Int,
        mountTimeoutSeconds: Int,
        smbHealthTimeoutSeconds: Int,
        language: AppLanguage,
        onboardingCompleted: Bool
    ) {
        self.enabled = enabled
        self.openAppAtLogin = openAppAtLogin
        self.checkIntervalSeconds = checkIntervalSeconds
        self.bootDelaySeconds = bootDelaySeconds
        self.maximumAutomaticRecoveryAttempts = maximumAutomaticRecoveryAttempts
        self.mountTimeoutSeconds = mountTimeoutSeconds
        self.smbHealthTimeoutSeconds = smbHealthTimeoutSeconds
        self.language = language
        self.onboardingCompleted = onboardingCompleted
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case openAppAtLogin
        case checkIntervalSeconds
        case bootDelaySeconds
        case maximumAutomaticRecoveryAttempts
        case failuresBeforeReset
        case mountTimeoutSeconds
        case smbHealthTimeoutSeconds
        case language
        case onboardingCompleted
    }

    // init keeps older beta configuration files readable after adding the login toggle.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        openAppAtLogin = try values.decodeIfPresent(Bool.self, forKey: .openAppAtLogin) ?? false
        checkIntervalSeconds = try values.decode(Int.self, forKey: .checkIntervalSeconds)
        bootDelaySeconds = try values.decode(Int.self, forKey: .bootDelaySeconds)
        maximumAutomaticRecoveryAttempts = try values.decodeIfPresent(Int.self, forKey: .maximumAutomaticRecoveryAttempts)
            ?? values.decodeIfPresent(Int.self, forKey: .failuresBeforeReset)
            ?? Self.defaults.maximumAutomaticRecoveryAttempts
        mountTimeoutSeconds = try values.decode(Int.self, forKey: .mountTimeoutSeconds)
        smbHealthTimeoutSeconds = try values.decode(Int.self, forKey: .smbHealthTimeoutSeconds)
        language = try values.decode(AppLanguage.self, forKey: .language)
        onboardingCompleted = try values.decode(Bool.self, forKey: .onboardingCompleted)
    }

    // encode persists only the schema-six recovery limit after the one-way migration.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(openAppAtLogin, forKey: .openAppAtLogin)
        try values.encode(checkIntervalSeconds, forKey: .checkIntervalSeconds)
        try values.encode(bootDelaySeconds, forKey: .bootDelaySeconds)
        try values.encode(maximumAutomaticRecoveryAttempts, forKey: .maximumAutomaticRecoveryAttempts)
        try values.encode(mountTimeoutSeconds, forKey: .mountTimeoutSeconds)
        try values.encode(smbHealthTimeoutSeconds, forKey: .smbHealthTimeoutSeconds)
        try values.encode(language, forKey: .language)
        try values.encode(onboardingCompleted, forKey: .onboardingCompleted)
    }
}

// AppLanguage supports an automatic system choice plus explicit German and English.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case german
    case english

    public var id: String { rawValue }
}

// MountDefinition stores a stable share identity without embedding credentials.
public struct MountDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
    }
}

// NetworkPolicy keeps Ethernet preference and Wi-Fi fallback independently configurable.
public struct NetworkPolicy: Codable, Equatable, Sendable {
    // Schema 7 adds native discovery without inventing profiles for existing installations.
    public var discovery: NetworkOptions? = NetworkOptions()
    public var enabled: Bool
    public var lanInterface: String
    public var wifiInterface: String
    public var wifiGraceMinutes: Int
    public var disableWifiWhenLanActive: Bool
    public var enableWifiWhenLanUnhealthy: Bool
    public var lanFailureThreshold: Int
    public var lanRecoveryStableChecks: Int
    public var gatewayHost: String
    public var remoteReachabilityHosts: [String]
    public var trafficEnabled: Bool
    public var trafficInterfaces: [String]
    public var trafficMaxBytes: Int

    public static let defaults = NetworkPolicy(
        enabled: false,
        lanInterface: "en0",
        wifiInterface: "en1",
        wifiGraceMinutes: 15,
        disableWifiWhenLanActive: true,
        enableWifiWhenLanUnhealthy: true,
        lanFailureThreshold: 1,
        lanRecoveryStableChecks: 3,
        gatewayHost: "",
        remoteReachabilityHosts: [],
        trafficEnabled: true,
        trafficInterfaces: ["en0", "en1", "en10"],
        trafficMaxBytes: 10_485_760
    )
}

// DiagnosticsPolicy bounds local evidence collection and exported support data.
public struct DiagnosticsPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var networkEventsEnabled: Bool
    public var sleepWakeEventsEnabled: Bool
    public var macLogsEnabled: Bool
    public var macLogLookbackMinutes: Int
    public var retentionDays: Int
    public var retentionIntervalMinutes: Int
    public var maximumStoreBytes: Int
    public var redactPathsInExports: Bool

    public static let defaults = DiagnosticsPolicy(
        enabled: true,
        networkEventsEnabled: true,
        sleepWakeEventsEnabled: true,
        macLogsEnabled: true,
        macLogLookbackMinutes: 30,
        retentionDays: 30,
        retentionIntervalMinutes: 30,
        maximumStoreBytes: 52_428_800,
        redactPathsInExports: true
    )

    // init creates a complete diagnostics policy for configuration and tests.
    public init(
        enabled: Bool,
        networkEventsEnabled: Bool = true,
        sleepWakeEventsEnabled: Bool = true,
        macLogsEnabled: Bool,
        macLogLookbackMinutes: Int,
        retentionDays: Int,
        retentionIntervalMinutes: Int = 30,
        maximumStoreBytes: Int,
        redactPathsInExports: Bool
    ) {
        self.enabled = enabled
        self.networkEventsEnabled = networkEventsEnabled
        self.sleepWakeEventsEnabled = sleepWakeEventsEnabled
        self.macLogsEnabled = macLogsEnabled
        self.macLogLookbackMinutes = macLogLookbackMinutes
        self.retentionDays = retentionDays
        self.retentionIntervalMinutes = retentionIntervalMinutes
        self.maximumStoreBytes = maximumStoreBytes
        self.redactPathsInExports = redactPathsInExports
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case networkEventsEnabled
        case sleepWakeEventsEnabled
        case macLogsEnabled
        case macLogLookbackMinutes
        case retentionDays
        case retentionIntervalMinutes
        case maximumStoreBytes
        case redactPathsInExports
    }

    // init preserves older native configurations while adding the scheduled retention interval.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        networkEventsEnabled = try values.decodeIfPresent(Bool.self, forKey: .networkEventsEnabled) ?? Self.defaults.networkEventsEnabled
        sleepWakeEventsEnabled = try values.decodeIfPresent(Bool.self, forKey: .sleepWakeEventsEnabled) ?? Self.defaults.sleepWakeEventsEnabled
        macLogsEnabled = try values.decode(Bool.self, forKey: .macLogsEnabled)
        macLogLookbackMinutes = try values.decode(Int.self, forKey: .macLogLookbackMinutes)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
        retentionIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .retentionIntervalMinutes) ?? Self.defaults.retentionIntervalMinutes
        maximumStoreBytes = try values.decode(Int.self, forKey: .maximumStoreBytes)
        redactPathsInExports = try values.decode(Bool.self, forKey: .redactPathsInExports)
    }
}

// PacketCaptureSettings describes the optional, bounded Raspberry Pi capture path.
public struct PacketCaptureSettings: Codable, Equatable, Sendable {
    public static let managedRemoteRoot = "/var/lib/we-rock-drive-mounts"

    public var enabled: Bool
    public var host: String
    public var user: String
    public var interface: String
    public var durationSeconds: Int
    public var remoteDirectory: String
    public var maximumFiles: Int
    public var maximumFileBytes: Int

    public static let defaults = PacketCaptureSettings(
        enabled: false,
        host: "",
        user: "",
        interface: "eth0",
        durationSeconds: 20,
        remoteDirectory: "/var/lib/we-rock-drive-mounts/captures",
        maximumFiles: 20,
        maximumFileBytes: 104_857_600
    )

    // normalizedManagedDirectory accepts only absolute directories below the companion-owned root.
    public static func normalizedManagedDirectory(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return nil }
        let normalized = (value as NSString).standardizingPath
        guard normalized.hasPrefix(managedRemoteRoot + "/") else { return nil }
        return normalized
    }

    // containsRemotePath rejects traversal and sibling-prefix tricks in companion metadata.
    public func containsRemotePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              let root = Self.normalizedManagedDirectory(remoteDirectory) else { return false }
        let normalized = (value as NSString).standardizingPath
        return normalized.hasPrefix(root + "/")
    }
}

// SynologySettings keeps every evidence source separately switchable.
public struct SynologySettings: Codable, Equatable, Sendable {
    public var syslogEnabled: Bool
    public var syslogPort: Int
    public var readOnlySSHEnabled: Bool
    public var sshHost: String
    public var sshUser: String
    public var dsmAPIEnabled: Bool
    public var dsmBaseURL: String
    public var csvImportEnabled: Bool

    public static let defaults = SynologySettings(
        syslogEnabled: false,
        syslogPort: 5514,
        readOnlySSHEnabled: false,
        sshHost: "",
        sshUser: "",
        dsmAPIEnabled: false,
        dsmBaseURL: "",
        csvImportEnabled: true
    )
}

// AISettings separates provider, action authority, and cloud evidence scope.
public struct AISettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: AIProviderKind
    public var actionMode: AIActionMode
    public var cloudDataMode: CloudDataMode
    public var openAIModel: String
    public var selectedEvidenceIDs: [UUID]? = nil

    public static let defaults = AISettings(
        enabled: true,
        provider: .local,
        actionMode: .guarded,
        cloudDataMode: .reducedFindings,
        openAIModel: "gpt-5-mini",
        selectedEvidenceIDs: nil
    )
}

// AIProviderKind selects local Foundation Models or the optional cloud provider.
public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case openAI

    public var id: String { rawValue }
}

// AIActionMode defines when a user confirmation is required.
public enum AIActionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case confirmAll
    case guarded
    case autonomous

    public var id: String { rawValue }
}

// CloudDataMode explicitly bounds evidence sent to an optional cloud provider.
public enum CloudDataMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case reducedFindings
    case selectedRawLogs
    case fullDiagnostics

    public var id: String { rawValue }
}

// WakeSettings stores independently enabled Mac wake routes and verification state.
public struct WakeSettings: Codable, Equatable, Sendable {
    public var targetName: String
    public var targetMACAddress: String
    public var targetHost: String
    public var routes: [WakeRouteConfiguration]

    public static let defaults = WakeSettings(
        targetName: "Mac",
        targetMACAddress: "",
        targetHost: "",
        routes: WakeRouteKind.allCases.map { kind in
            WakeRouteConfiguration(kind: kind, enabled: false, verified: false, command: "")
        }
    )
}

// WakeRouteKind enumerates the supported local and remote trigger paths.
public enum WakeRouteKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case raspberryPiLAN
    case tailscale
    case synologyTask
    case iosShortcut
    case cli

    public var id: String { rawValue }
}

// WakeRouteConfiguration records opt-in and live-verification state per route.
public struct WakeRouteConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var kind: WakeRouteKind
    public var enabled: Bool
    public var verified: Bool
    public var command: String

    public var id: String { kind.rawValue }
}

// TransferSettings controls user-initiated NAS copy/move jobs and incident monitoring.
public struct TransferSettings: Codable, Equatable, Sendable {
    public var monitoringEnabled: Bool
    public var highTrafficBytesPerSecond: Int
    public var sustainedSeconds: Int
    public var rollingPiCaptureEnabled: Bool
    public var incidentBundleOnFailure: Bool
    public var defaultResumePolicy: TransferResumePolicy
    public var maximumAutoRetries: Int
    public var unlimitedAutoRetries: Bool
    public var verifyAfterCopy: Bool
    public var keepMacAwakeByDefault: Bool?

    public static let defaults = TransferSettings(
        monitoringEnabled: false,
        highTrafficBytesPerSecond: 100_000_000,
        sustainedSeconds: 30,
        rollingPiCaptureEnabled: false,
        incidentBundleOnFailure: true,
        defaultResumePolicy: .ask,
        maximumAutoRetries: 1,
        unlimitedAutoRetries: false,
        verifyAfterCopy: true,
        keepMacAwakeByDefault: false
    )

    // init exposes the complete transfer-settings contract to tests and future adapters.
    public init(
        monitoringEnabled: Bool,
        highTrafficBytesPerSecond: Int,
        sustainedSeconds: Int,
        rollingPiCaptureEnabled: Bool,
        incidentBundleOnFailure: Bool,
        defaultResumePolicy: TransferResumePolicy,
        maximumAutoRetries: Int,
        unlimitedAutoRetries: Bool,
        verifyAfterCopy: Bool,
        keepMacAwakeByDefault: Bool?
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.highTrafficBytesPerSecond = highTrafficBytesPerSecond
        self.sustainedSeconds = sustainedSeconds
        self.rollingPiCaptureEnabled = rollingPiCaptureEnabled
        self.incidentBundleOnFailure = incidentBundleOnFailure
        self.defaultResumePolicy = defaultResumePolicy
        self.maximumAutoRetries = maximumAutoRetries
        self.unlimitedAutoRetries = unlimitedAutoRetries
        self.verifyAfterCopy = verifyAfterCopy
        self.keepMacAwakeByDefault = keepMacAwakeByDefault
    }

    private enum CodingKeys: String, CodingKey {
        case monitoringEnabled
        case highTrafficBytesPerSecond
        case sustainedSeconds
        case rollingPiCaptureEnabled
        case incidentBundleOnFailure
        case defaultResumePolicy
        case maximumAutoRetries
        case unlimitedAutoRetries
        case verifyAfterCopy
        case keepMacAwakeByDefault
    }

    // init assigns the finite retry mode to schema-four configurations before schema normalization persists it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        monitoringEnabled = try values.decode(Bool.self, forKey: .monitoringEnabled)
        highTrafficBytesPerSecond = try values.decode(Int.self, forKey: .highTrafficBytesPerSecond)
        sustainedSeconds = try values.decode(Int.self, forKey: .sustainedSeconds)
        rollingPiCaptureEnabled = try values.decode(Bool.self, forKey: .rollingPiCaptureEnabled)
        incidentBundleOnFailure = try values.decode(Bool.self, forKey: .incidentBundleOnFailure)
        defaultResumePolicy = try values.decode(TransferResumePolicy.self, forKey: .defaultResumePolicy)
        maximumAutoRetries = try values.decode(Int.self, forKey: .maximumAutoRetries)
        unlimitedAutoRetries = try values.decodeIfPresent(Bool.self, forKey: .unlimitedAutoRetries) ?? false
        verifyAfterCopy = try values.decode(Bool.self, forKey: .verifyAfterCopy)
        keepMacAwakeByDefault = try values.decodeIfPresent(Bool.self, forKey: .keepMacAwakeByDefault) ?? false
    }

    // automaticRetryCountEditable keeps the GUI state derived from the persisted retry policy.
    public var automaticRetryCountEditable: Bool {
        !unlimitedAutoRetries
    }

    // automaticRetryMode exposes one shared effective value to CLI, MCP, tests, and future UI surfaces.
    public var automaticRetryMode: String {
        guard defaultResumePolicy == .autoRetry else { return "inactive" }
        return unlimitedAutoRetries ? "unlimited" : "finite"
    }
}

// TransferOperation distinguishes normal copy from verified two-phase move.
public enum TransferOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy
    case move

    public var id: String { rawValue }
}

// TransferDirection constrains which side must be a configured WRDM NAS mount.
public enum TransferDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case macToNAS
    case nasToMac

    public var id: String { rawValue }
}

// TransferResumePolicy controls what happens after a failed background transfer.
public enum TransferResumePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case autoRetry
    case manual

    public var id: String { rawValue }
}

// TransferJobState is persisted so interrupted app sessions can be resumed later.
public enum TransferJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case stopped
    case failed
    case completed
    case verified
    case finalized
}

// TransferProgress records bounded progress metadata without storing file contents.
public struct TransferProgress: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var percent: Double?
    public var transferredBytes: UInt64?
    public var currentPath: String?
    public var totalBytes: UInt64?
    public var completedBytes: UInt64?
    public var totalFiles: Int?
    public var completedFiles: Int?
    public var bytesPerSecond: Double?
    public var smoothedBytesPerSecond: Double?
    public var lastProgressAt: Date?
    public var stallSeconds: Int?
    public var highTrafficSince: Date?
    public var highTrafficSeconds: Int?
    public var snapshotAt: Date?

    public init(
        updatedAt: Date = Date(),
        percent: Double? = nil,
        transferredBytes: UInt64? = nil,
        currentPath: String? = nil,
        totalBytes: UInt64? = nil,
        completedBytes: UInt64? = nil,
        totalFiles: Int? = nil,
        completedFiles: Int? = nil,
        bytesPerSecond: Double? = nil,
        smoothedBytesPerSecond: Double? = nil,
        lastProgressAt: Date? = nil,
        stallSeconds: Int? = nil,
        highTrafficSince: Date? = nil,
        highTrafficSeconds: Int? = nil,
        snapshotAt: Date? = nil
    ) {
        self.updatedAt = updatedAt
        self.percent = percent
        self.transferredBytes = transferredBytes
        self.currentPath = currentPath
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.bytesPerSecond = bytesPerSecond
        self.smoothedBytesPerSecond = smoothedBytesPerSecond
        self.lastProgressAt = lastProgressAt
        self.stallSeconds = stallSeconds
        self.highTrafficSince = highTrafficSince
        self.highTrafficSeconds = highTrafficSeconds
        self.snapshotAt = snapshotAt
    }
}

// TransferControlRequest lets GUI, CLI, and MCP request action from the agent-owned runner.
public enum TransferControlRequest: String, Codable, CaseIterable, Identifiable, Sendable {
    case pause
    case stop

    public var id: String { rawValue }
}

// TransferJob is the durable state shared by GUI, CLI, MCP, and AI action policy.
public struct TransferJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var operation: TransferOperation
    public var direction: TransferDirection
    public var resumePolicy: TransferResumePolicy
    public var sources: [String]
    public var destination: String
    public var state: TransferJobState
    public var progress: TransferProgress
    public var attempts: Int
    public var maximumAutoRetries: Int
    public var unlimitedAutoRetries: Bool?
    public var nextRetryAt: Date?
    public var verifyAfterCopy: Bool
    public var createIncidentOnFailure: Bool
    public var errorCode: String?
    public var errorMessage: String?
    public var evidenceIDs: [UUID]
    public var verificationSucceeded: Bool
    public var finalizedAt: Date?
    public var ownedByAgent: Bool?
    public var runnerPID: Int32?
    public var stdoutPath: String?
    public var stderrPath: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var requestedControl: TransferControlRequest?
    public var keepMacAwake: Bool?
    public var powerAssertionActive: Bool?
    public var powerAssertionPID: Int32?
    public var powerAssertionError: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        operation: TransferOperation,
        direction: TransferDirection,
        resumePolicy: TransferResumePolicy,
        sources: [String],
        destination: String,
        state: TransferJobState = .queued,
        progress: TransferProgress = TransferProgress(),
        attempts: Int = 0,
        maximumAutoRetries: Int,
        verifyAfterCopy: Bool,
        createIncidentOnFailure: Bool,
        unlimitedAutoRetries: Bool? = false,
        nextRetryAt: Date? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        evidenceIDs: [UUID] = [],
        verificationSucceeded: Bool = false,
        finalizedAt: Date? = nil,
        ownedByAgent: Bool? = true,
        runnerPID: Int32? = nil,
        stdoutPath: String? = nil,
        stderrPath: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        requestedControl: TransferControlRequest? = nil,
        keepMacAwake: Bool? = false,
        powerAssertionActive: Bool? = false,
        powerAssertionPID: Int32? = nil,
        powerAssertionError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.operation = operation
        self.direction = direction
        self.resumePolicy = resumePolicy
        self.sources = sources
        self.destination = destination
        self.state = state
        self.progress = progress
        self.attempts = attempts
        self.maximumAutoRetries = maximumAutoRetries
        self.unlimitedAutoRetries = unlimitedAutoRetries
        self.nextRetryAt = nextRetryAt
        self.verifyAfterCopy = verifyAfterCopy
        self.createIncidentOnFailure = createIncidentOnFailure
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.evidenceIDs = evidenceIDs
        self.verificationSucceeded = verificationSucceeded
        self.finalizedAt = finalizedAt
        self.ownedByAgent = ownedByAgent
        self.runnerPID = runnerPID
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.requestedControl = requestedControl
        self.keepMacAwake = keepMacAwake
        self.powerAssertionActive = powerAssertionActive
        self.powerAssertionPID = powerAssertionPID
        self.powerAssertionError = powerAssertionError
    }
}

// TransferIncidentManifest creates one local blackbox record around a transfer failure.
public struct TransferIncidentManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var jobID: UUID?
    public var title: String
    public var eventIDs: [UUID]
    public var trafficSampleCount: Int
    public var statusPhase: String
    public var bundlePath: String?
    public var unavailableSources: [String: String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        jobID: UUID?,
        title: String,
        eventIDs: [UUID],
        trafficSampleCount: Int,
        statusPhase: String,
        bundlePath: String? = nil,
        unavailableSources: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.jobID = jobID
        self.title = title
        self.eventIDs = eventIDs
        self.trafficSampleCount = trafficSampleCount
        self.statusPhase = statusPhase
        self.bundlePath = bundlePath
        self.unavailableSources = unavailableSources
    }
}

// AgentStatus is the compact cross-process snapshot rendered by UI, CLI, and MCP.
public struct AgentStatus: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var phase: String
    public var enabledMounts: Int
    public var healthyMounts: Int
    public var lanHealthy: Bool
    public var wifiEnabled: Bool
    public var fallbackActive: Bool
    public var lastError: String?
    public var mountStates: [MountRuntimeState]?
    public var networkExecution: NetworkPolicyExecution?
    public var collectorStates: [CollectorRuntimeState]?

    // init creates a complete cross-process status snapshot.
    public init(
        timestamp: Date,
        phase: String,
        enabledMounts: Int,
        healthyMounts: Int,
        lanHealthy: Bool,
        wifiEnabled: Bool,
        fallbackActive: Bool,
        lastError: String?,
        mountStates: [MountRuntimeState]? = nil,
        networkExecution: NetworkPolicyExecution? = nil,
        collectorStates: [CollectorRuntimeState]? = nil
    ) {
        self.timestamp = timestamp
        self.phase = phase
        self.enabledMounts = enabledMounts
        self.healthyMounts = healthyMounts
        self.lanHealthy = lanHealthy
        self.wifiEnabled = wifiEnabled
        self.fallbackActive = fallbackActive
        self.lastError = lastError
        self.mountStates = mountStates
        self.networkExecution = networkExecution
        self.collectorStates = collectorStates
    }

    public static let unavailable = AgentStatus(
        timestamp: .distantPast,
        phase: "unavailable",
        enabledMounts: 0,
        healthyMounts: 0,
        lanHealthy: false,
        wifiEnabled: false,
        fallbackActive: false,
        lastError: nil,
        mountStates: nil,
        networkExecution: nil,
        collectorStates: nil
    )

    // availability classifies missing and stale snapshots before UI health colors are selected.
    public func availability(now: Date = Date(), maximumAge: TimeInterval) -> AgentStatusAvailability {
        guard phase != "unavailable", timestamp != .distantPast else { return .unavailable }
        return now.timeIntervalSince(timestamp) <= maximumAge ? .fresh : .stale
    }
}

// AgentStatusAvailability prevents an absent or stale snapshot from being presented as healthy.
public enum AgentStatusAvailability: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

// CollectorKind names every independently controllable diagnostic source shared by UI, CLI, agent, and MCP.
public enum CollectorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case networkEvents
    case sleepWakeEvents
    case macOSLogs
    case interfaceTraffic

    public var id: String { rawValue }
}

// CollectorRuntimeState makes disabled collection an explicit state instead of an absence of data.
public struct CollectorRuntimeState: Codable, Equatable, Identifiable, Sendable {
    public var kind: CollectorKind
    public var enabled: Bool
    public var reason: String

    public var id: CollectorKind { kind }

    public init(kind: CollectorKind, enabled: Bool, reason: String) {
        self.kind = kind
        self.enabled = enabled
        self.reason = reason
    }

    // states resolves effective collector behavior including the diagnostics master switch.
    public static func states(settings: AppSettings) -> [CollectorRuntimeState] {
        let diagnosticsDisabled = "Diagnostic collection is disabled."
        return [
            CollectorRuntimeState(
                kind: .networkEvents,
                enabled: settings.diagnostics.enabled && settings.diagnostics.networkEventsEnabled,
                reason: !settings.diagnostics.enabled ? diagnosticsDisabled : settings.diagnostics.networkEventsEnabled ? "Enabled." : "Network event collection is disabled."
            ),
            CollectorRuntimeState(
                kind: .sleepWakeEvents,
                enabled: settings.diagnostics.enabled && settings.diagnostics.sleepWakeEventsEnabled,
                reason: !settings.diagnostics.enabled ? diagnosticsDisabled : settings.diagnostics.sleepWakeEventsEnabled ? "Enabled." : "Sleep and wake event collection is disabled."
            ),
            CollectorRuntimeState(
                kind: .macOSLogs,
                enabled: settings.diagnostics.enabled && settings.diagnostics.macLogsEnabled,
                reason: !settings.diagnostics.enabled ? diagnosticsDisabled : settings.diagnostics.macLogsEnabled ? "Enabled." : "macOS log collection is disabled."
            ),
            CollectorRuntimeState(
                kind: .interfaceTraffic,
                enabled: settings.network.trafficEnabled,
                reason: settings.network.trafficEnabled ? "Enabled." : "Interface traffic tracking is disabled."
            ),
        ]
    }
}

// MountAvailability records only what macOS currently exposes about a configured share.
public enum MountAvailability: String, Codable, CaseIterable, Sendable {
    case disabled
    case healthy
    case missing
    case staleMounted
    case unknown
}

// MountRecoveryPhase records recovery progress independently from mount availability.
public enum MountRecoveryPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case waitingForNetwork
    case scheduled
    case mounting
    case unmounting
    case verifyingDetach
    case verifyingHealth
    case deferredActiveTransfer
    case manualConfirmationRequired
    case circuitOpen
    case restartRequired
}

// MountFailureCode provides stable automation values while messages remain user-readable.
public enum MountFailureCode: String, Codable, CaseIterable, Sendable {
    case invalidSMBURL
    case mountTableUnavailable
    case smbSessionUnresponsive
    case smbHealthTimedOut
    case smbServerUnavailable
    case mountRequestFailed
    case mountRequestTimedOut
    case normalUnmountFailed
    case forceUnmountFailed
    case detachNotVerified
    case activeTransfer
    case operationLocked
    case processStillRunning
    case uninterruptibleKernelWait
    case automaticAttemptLimitReached
}

// MountRuntimeState is persisted as evidence but never contains share credentials.
public struct MountRuntimeState: Codable, Equatable, Identifiable, Sendable {
    public var mountID: UUID
    public var timestamp: Date
    public var availability: MountAvailability
    public var recoveryPhase: MountRecoveryPhase
    public var consecutiveFailures: Int
    public var failureCode: MountFailureCode?
    public var message: String
    public var localPath: String?
    public var incidentID: UUID?
    public var nextAttemptAt: Date?

    public var id: UUID { mountID }

    // init creates an explicit runtime state for adapters and tests outside WRDMCore.
    public init(
        mountID: UUID,
        timestamp: Date,
        availability: MountAvailability,
        recoveryPhase: MountRecoveryPhase = .idle,
        consecutiveFailures: Int,
        failureCode: MountFailureCode? = nil,
        message: String,
        localPath: String? = nil,
        incidentID: UUID? = nil,
        nextAttemptAt: Date? = nil
    ) {
        self.mountID = mountID
        self.timestamp = timestamp
        self.availability = availability
        self.recoveryPhase = recoveryPhase
        self.consecutiveFailures = consecutiveFailures
        self.failureCode = failureCode
        self.message = message
        self.localPath = localPath
        self.incidentID = incidentID
        self.nextAttemptAt = nextAttemptAt
    }
}

// InterfaceTrafficSample records monotonic counters and interval deltas.
public struct InterfaceTrafficSample: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var interface: String
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var receivedDelta: UInt64
    public var sentDelta: UInt64
    public var intervalSeconds: Double?
    public var receivedBytesPerSecond: Double?
    public var sentBytesPerSecond: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        interface: String,
        receivedBytes: UInt64,
        sentBytes: UInt64,
        receivedDelta: UInt64,
        sentDelta: UInt64,
        intervalSeconds: Double? = nil,
        receivedBytesPerSecond: Double? = nil,
        sentBytesPerSecond: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.interface = interface
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedDelta = receivedDelta
        self.sentDelta = sentDelta
        self.intervalSeconds = intervalSeconds
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
    }
}

// DiagnosticEvent is the canonical source-preserving incident evidence record.
public struct DiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var type: DiagnosticEventType
    public var source: String
    public var summary: String
    public var details: [String: String]
    public var evidencePath: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: DiagnosticEventType,
        source: String,
        summary: String,
        details: [String: String] = [:],
        evidencePath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.source = source
        self.summary = summary
        self.details = details
        self.evidencePath = evidencePath
    }
}

// DiagnosticEventType supports correlation without inferring causality.
public enum DiagnosticEventType: String, Codable, CaseIterable, Sendable {
    case agentStarted
    case agentStopped
    case sleep
    case wake
    case monitoringDelayed
    case networkChanged
    case mountLost
    case mountRecovered
    case mountIncidentOpened
    case mountRecoveryChanged
    case mountRestartRequired
    case traffic
    case packetCapture
    case synology
    case wakeAttempt
    case transferStarted
    case transferProgress
    case transferPaused
    case transferStopped
    case transferResumed
    case transferCompleted
    case transferFailed
    case transferVerified
    case transferMoveFinalized
    case transferIncidentCreated
    case warning
    case error
}

// Incident groups evidence in a bounded time window and labels uncertainty.
public struct Incident: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var title: String
    public var hypothesis: String
    public var confidence: Double
    public var evidenceIDs: [UUID]
}

// DiagnosticFinding is the stable AI output surfaced with evidence references.
public struct DiagnosticFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var explanation: String
    public var confidence: Double
    public var evidenceIDs: [UUID]
    public var nextSteps: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        explanation: String,
        confidence: Double,
        evidenceIDs: [UUID],
        nextSteps: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.explanation = explanation
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
        self.nextSteps = nextSteps
    }
}

// CommandRisk drives the configurable action confirmation policy.
public enum CommandRisk: String, Codable, Sendable {
    case readOnly
    case safeMutation
    case connectivityCritical
    case remoteMutation
}

// ActionDecision is returned before any adapter mutation occurs.
public enum ActionDecision: String, Codable, Sendable {
    case allow
    case requireConfirmation
    case deny
}

// CommandResult is the shared result envelope for app, CLI, AI, and MCP.
public struct CommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var code: String
    public var message: String
    public var data: [String: String]

    public init(ok: Bool, code: String, message: String, data: [String: String] = [:]) {
        self.ok = ok
        self.code = code
        self.message = message
        self.data = data
    }
}
