import CryptoKit
import Foundation

// ConfigurationStore owns atomic plist persistence and one-time legacy normalization.
public actor ConfigurationStore {
    public let paths: AppPaths

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    // load decodes the current schema or imports a positively identified shell plist.
    public func load() throws -> AppSettings {
        try SecureFileAccess.withLock(for: paths.configFile) {
            try loadUnlocked()
        }
    }

    // save writes through a temporary file so readers never observe a partial configuration.
    public func save(_ settings: AppSettings) throws {
        try SecureFileAccess.withLock(for: paths.configFile) {
            try saveUnlocked(settings)
        }
    }

    // replace performs an optimistic cross-process save and rejects a stale UI snapshot.
    public func replace(_ settings: AppSettings, ifUnchanged expected: AppSettings) throws {
        try SecureFileAccess.withLock(for: paths.configFile) {
            let current = try loadUnlocked()
            guard current == expected else { throw ConfigurationError.concurrentModification }
            try saveUnlocked(settings)
        }
    }

    // update serializes read-modify-write operations across UI, CLI, agent, and MCP processes.
    public func update(_ mutation: @Sendable (inout AppSettings) throws -> Void) throws -> AppSettings {
        try SecureFileAccess.withLock(for: paths.configFile) {
            var settings = try loadUnlocked()
            try mutation(&settings)
            try saveUnlocked(settings)
            return settings
        }
    }

    // exportConfigurationData encodes the currently persisted settings without reading Keychain secrets.
    public func exportConfigurationData() throws -> Data {
        try SecureFileAccess.withLock(for: paths.configFile) {
            try Self.encodeExportDocument(settings: loadUnlocked())
        }
    }

    // importConfigurationData validates a transfer file before replacing the active configuration.
    public func importConfigurationData(_ data: Data, replacing expected: AppSettings? = nil) throws -> AppSettings {
        try SecureFileAccess.withLock(for: paths.configFile) {
            let current = try loadUnlocked()
            if let expected, current != expected {
                throw ConfigurationError.concurrentModification
            }
            let imported = try normalizeSchema(Self.decodeExportedSettings(from: data))
            try validate(imported)
            try saveUnlocked(imported)
            return imported
        }
    }

    // encodeExportDocument creates the user-transferable plist payload.
    public nonisolated static func encodeExportDocument(settings: AppSettings, exportedAt: Date = Date()) throws -> Data {
        let document = ConfigurationExportDocument(exportedAt: exportedAt, settings: settings)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(document)
    }

    // decodeExportedSettings accepts the versioned transfer format plus native AppSettings plists.
    public nonisolated static func decodeExportedSettings(from data: Data) throws -> AppSettings {
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ConfigurationError.invalidValue("configuration file is not a readable property list")
        }
        guard let dictionary = raw as? [String: Any] else {
            throw ConfigurationError.invalidValue("configuration file is not a dictionary")
        }

        let decoder = PropertyListDecoder()
        if dictionary["formatIdentifier"] as? String == ConfigurationExportDocument.currentFormatIdentifier {
            let document = try decoder.decode(ConfigurationExportDocument.self, from: data)
            guard document.formatVersion == ConfigurationExportDocument.currentFormatVersion else {
                throw ConfigurationError.invalidValue("unsupported configuration export format version \(document.formatVersion)")
            }
            return document.settings
        }
        if dictionary["schemaVersion"] != nil {
            return try decoder.decode(AppSettings.self, from: data)
        }
        throw ConfigurationError.invalidValue("configuration file is not a We Rock Drive Mounts export")
    }

    // loadUnlocked performs format detection while its caller owns the cross-process lock.
    private func loadUnlocked() throws -> AppSettings {
        try paths.ensureDirectories()
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
            let settings = AppSettings.defaults
            try saveUnlocked(settings)
            return settings
        }

        let data = try Data(contentsOf: paths.configFile)
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            let backup = try backupCorruptedConfiguration(data)
            throw ConfigurationError.corruptedNativeConfiguration(backup.lastPathComponent)
        }
        guard let dictionary = raw as? [String: Any] else {
            let backup = try backupCorruptedConfiguration(data)
            throw ConfigurationError.corruptedNativeConfiguration(backup.lastPathComponent)
        }
        let decoder = PropertyListDecoder()
        if let rawVersion = dictionary["schemaVersion"] {
            // A future schema can be valid but unreadable by this app; never call it corrupt.
            if let version = rawVersion as? Int,
               version < 1 || version > AppSettings.currentSchemaVersion {
                throw ConfigurationError.unsupportedSchema(version)
            }
            do {
                var settings = try decoder.decode(AppSettings.self, from: data)
                if settings.schemaVersion < AppSettings.currentSchemaVersion {
                    // Schema migrations normalize newly introduced native settings before validation.
                    settings = try normalizeSchema(settings)
                    try saveUnlocked(settings)
                } else {
                    try validate(settings)
                }
                return settings
            } catch let error as ConfigurationError {
                throw error
            } catch {
                let backup = try backupCorruptedConfiguration(data)
                throw ConfigurationError.corruptedNativeConfiguration(backup.lastPathComponent)
            }
        }

        let imported = try LegacyConfigurationImporter.importSettings(from: data, paths: paths)
        let normalized = try normalizeSchema(imported)
        try saveUnlocked(normalized)
        return normalized
    }

    // saveUnlocked validates and atomically replaces the configuration under the caller's lock.
    private func saveUnlocked(_ settings: AppSettings) throws {
        try validate(settings)
        try paths.ensureDirectories()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try SecureFileAccess.writeAtomically(try encoder.encode(settings), to: paths.configFile)
    }

    // backupCorruptedConfiguration preserves each distinct damaged payload exactly once.
    private func backupCorruptedConfiguration(_ data: Data) throws -> URL {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let backup = paths.applicationSupport.appendingPathComponent("config.corrupt-\(digest).plist")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try SecureFileAccess.writeAtomically(data, to: backup)
        } else {
            try SecureFileAccess.hardenFile(backup)
        }
        return backup
    }

    // validate rejects unsafe or unusable values before adapters receive them.
    public func validate(_ settings: AppSettings) throws {
        guard settings.schemaVersion == AppSettings.currentSchemaVersion else {
            throw ConfigurationError.unsupportedSchema(settings.schemaVersion)
        }
        guard settings.general.checkIntervalSeconds >= 5 else {
            throw ConfigurationError.invalidValue("checkIntervalSeconds must be at least 5")
        }
        guard settings.general.bootDelaySeconds >= 0,
              settings.general.maximumAutomaticRecoveryAttempts > 0,
              settings.general.mountTimeoutSeconds > 0,
              settings.general.smbHealthTimeoutSeconds > 0 else {
            throw ConfigurationError.invalidValue("general timing values are outside their supported range")
        }
        if let discovery = settings.network.discovery {
            guard Set(discovery.profiles.map(\.id)).count == discovery.profiles.count else {
                throw ConfigurationError.invalidValue("Duplicate network profile identifiers")
            }
            for profile in discovery.profiles {
                let hasFields = profile.mode != nil || profile.media != nil || profile.speedMbps != nil || profile.duplex != nil || profile.mtu != nil || profile.flowControl != nil
                guard !profile.enabled || hasFields else { throw ConfigurationError.invalidValue("Select at least one monitored field") }
                guard !profile.portID.isEmpty, !profile.networkID.isEmpty,
                      profile.mode == nil || ["manual", "automatic"].contains(profile.mode!),
                      profile.mtu == nil || (1280...65535).contains(profile.mtu!),
                      profile.speedMbps == nil || profile.speedMbps! > 0 else {
                    throw ConfigurationError.invalidValue("Invalid network monitoring profile")
                }
            }
        }
        guard settings.network.wifiGraceMinutes >= 0 else {
            throw ConfigurationError.invalidValue("wifiGraceMinutes must be non-negative")
        }
        guard settings.network.lanFailureThreshold > 0,
              settings.network.lanRecoveryStableChecks > 0 else {
            throw ConfigurationError.invalidValue("network thresholds must be positive")
        }
        guard settings.network.trafficMaxBytes > 0,
              !settings.network.lanInterface.isEmpty,
              !settings.network.wifiInterface.isEmpty else {
            throw ConfigurationError.invalidValue("network interfaces and traffic limit must be valid")
        }
        guard settings.diagnostics.macLogLookbackMinutes > 0,
              settings.diagnostics.retentionDays > 0,
              settings.diagnostics.retentionIntervalMinutes > 0,
              settings.diagnostics.maximumStoreBytes > 0 else {
            throw ConfigurationError.invalidValue("diagnostic limits must be positive")
        }
        guard settings.diagnostics.redactPathsInExports else {
            throw ConfigurationError.invalidValue("Support bundle privacy protection cannot be disabled")
        }
        guard settings.packetCapture.durationSeconds > 0,
              settings.packetCapture.maximumFiles > 0,
              settings.packetCapture.maximumFileBytes > 0 else {
            throw ConfigurationError.invalidValue("packet capture limits must be positive")
        }
        guard PacketCaptureSettings.normalizedManagedDirectory(settings.packetCapture.remoteDirectory) != nil else {
            throw ConfigurationError.invalidValue("packet capture directory must be inside /var/lib/we-rock-drive-mounts")
        }
        guard (1...65_535).contains(settings.synology.syslogPort) else {
            throw ConfigurationError.invalidValue("syslogPort must be between 1 and 65535")
        }
        guard settings.transfer.highTrafficBytesPerSecond > 0,
              settings.transfer.sustainedSeconds > 0,
              settings.transfer.maximumAutoRetries >= 0 else {
            throw ConfigurationError.invalidValue("transfer monitoring and retry values must be valid")
        }
        var mountIDs = Set<UUID>()
        var mountEndpoints = Set<String>()
        for mount in settings.mounts {
            guard !mount.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.invalidValue("mount names must not be empty")
            }
            guard let components = URLComponents(string: mount.url),
                  components.scheme?.lowercased() == "smb",
                  components.host?.isEmpty == false else {
                throw ConfigurationError.invalidValue("invalid SMB URL for \(mount.name)")
            }
            guard components.user == nil, components.password == nil else {
                throw ConfigurationError.secretInURL(mount.name)
            }
            guard mountIDs.insert(mount.id).inserted else {
                throw ConfigurationError.invalidValue("duplicate mount identifier for \(mount.name)")
            }
            // Normalize host case and trailing separators so one share cannot be mounted twice.
            let endpoint = mount.url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard mountEndpoints.insert(endpoint).inserted else {
                throw ConfigurationError.invalidValue("duplicate SMB URL for \(mount.name)")
            }
        }
    }

    // normalizeSchema applies one-way native beta migrations before validation and persistence.
    private func normalizeSchema(_ settings: AppSettings) throws -> AppSettings {
        guard settings.schemaVersion > 0,
              settings.schemaVersion <= AppSettings.currentSchemaVersion else {
            throw ConfigurationError.unsupportedSchema(settings.schemaVersion)
        }
        var copy = settings
        if copy.schemaVersion < 4 {
            // Schema 4 adds a persisted default for per-transfer idle-sleep prevention.
            copy.transfer.keepMacAwakeByDefault = false
        }
        if copy.schemaVersion < 5 {
            // Schema 5 keeps all existing installations on the finite retry policy until explicitly enabled.
            copy.transfer.unlimitedAutoRetries = false
        }
        if copy.schemaVersion < 6 {
            // Schema 6 renames the retry threshold and removes the helper-reset behavior it previously implied.
            copy.general.maximumAutomaticRecoveryAttempts = max(1, copy.general.maximumAutomaticRecoveryAttempts)
        }
        if copy.schemaVersion < 7 {
            // Preserve custom traffic lists and resolve legacy interface choices only against real devices.
            copy.network.discovery = NativeNetworkInventory.read().migratedOptions(policy: copy.network)
        }
        copy.schemaVersion = AppSettings.currentSchemaVersion
        return copy
    }
}

// ConfigurationError provides actionable validation messages to every interface.
public enum ConfigurationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidValue(String)
    case secretInURL(String)
    case corruptedNativeConfiguration(String)
    case concurrentModification

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            String(format: NSLocalizedString("This configuration requires a different app version (format %lld). Install a compatible version. Your settings have not been changed.", comment: "Unsupported settings schema"), version)
        case .invalidValue(let message):
            message
        case .secretInURL(let name):
            "Mount \(name) contains credentials in its URL. Remove them so macOS can store the login in Keychain."
        case .corruptedNativeConfiguration(let backup):
            "The native configuration is damaged. It was preserved as \(backup) and was not overwritten."
        case .concurrentModification:
            "The configuration changed in another process. Reload it before saving again."
        }
    }
}

// LegacyConfigurationImporter maps the current shell plist into the native schema.
public enum LegacyConfigurationImporter {
    public static func importSettings(from data: Data, paths: AppPaths = AppPaths()) throws -> AppSettings {
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = raw as? [String: Any] else {
            throw ConfigurationError.invalidValue("legacy configuration is not a dictionary")
        }

        var settings = AppSettings.defaults
        settings.general.checkIntervalSeconds = integer(dictionary["checkIntervalSeconds"], fallback: 20)
        settings.general.bootDelaySeconds = integer(dictionary["bootDelaySeconds"], fallback: 15)
        settings.general.maximumAutomaticRecoveryAttempts = integer(dictionary["failuresBeforeReset"], fallback: 3)
        settings.general.mountTimeoutSeconds = integer(dictionary["mountTimeoutSeconds"], fallback: 20)
        settings.general.smbHealthTimeoutSeconds = integer(dictionary["smbHealthTimeoutSeconds"], fallback: 5)

        if let macLogs = dictionary["macLogCapture"] as? [String: Any] {
            settings.diagnostics.macLogsEnabled = boolean(macLogs["enabled"], fallback: true)
            settings.diagnostics.macLogLookbackMinutes = integer(macLogs["lookbackMinutes"], fallback: 30)
        }
        if let traffic = dictionary["networkTraffic"] as? [String: Any] {
            settings.network.trafficEnabled = boolean(traffic["enabled"], fallback: true)
            settings.network.trafficInterfaces = string(traffic["interfaces"], fallback: "en0,en1,en10")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            settings.network.trafficMaxBytes = integer(traffic["maxBytes"], fallback: 10_485_760)
            settings.diagnostics.retentionDays = integer(traffic["retentionDays"], fallback: 30)
        }
        if let policy = dictionary["networkPolicy"] as? [String: Any] {
            settings.network.enabled = boolean(policy["enabled"], fallback: false)
            settings.network.lanInterface = string(policy["lanInterface"], fallback: "en0")
            settings.network.wifiInterface = string(policy["wifiInterface"], fallback: "en1")
            settings.network.wifiGraceMinutes = integer(policy["wifiGraceMinutes"], fallback: 15)
            settings.network.disableWifiWhenLanActive = boolean(policy["disableWifiWhenLanActive"], fallback: true)
            settings.network.enableWifiWhenLanUnhealthy = boolean(policy["enableWifiWhenLanUnhealthy"], fallback: true)
            settings.network.lanFailureThreshold = integer(policy["lanFailureThreshold"], fallback: 1)
            settings.network.lanRecoveryStableChecks = integer(policy["lanRecoveryStableChecks"], fallback: 3)
            settings.network.gatewayHost = string(policy["gatewayHost"], fallback: "")
        }
        if let packet = dictionary["packetCapture"] as? [String: Any] {
            settings.packetCapture.enabled = boolean(packet["enabled"], fallback: false)
            settings.packetCapture.host = string(packet["host"], fallback: "")
            settings.packetCapture.user = string(packet["user"], fallback: "")
            settings.packetCapture.interface = string(packet["interface"], fallback: "eth0")
            settings.packetCapture.durationSeconds = integer(packet["seconds"], fallback: 20)
            // The native companion accepts capture paths only inside its managed state directory.
            settings.packetCapture.remoteDirectory = PacketCaptureSettings.defaults.remoteDirectory
        }
        if let shares = dictionary["shares"] as? [[String: Any]] {
            settings.mounts = shares.compactMap { share in
                guard let url = share["url"] as? String, url.lowercased().hasPrefix("smb://") else {
                    return nil
                }
                return MountDefinition(
                    name: displayName(for: url),
                    url: url,
                    enabled: boolean(share["enabled"], fallback: true)
                )
            }
        }

        settings.wake.targetMACAddress = ethernetMACAddress(interface: settings.network.lanInterface) ?? ""
        settings.wake.targetHost = localIPAddress(interface: settings.network.lanInterface) ?? ""
        return settings
    }

    // displayName derives a friendly label while preserving the exact SMB URL.
    private static func displayName(for url: String) -> String {
        guard let components = URLComponents(string: url),
              let last = components.path.split(separator: "/").last else {
            return url
        }
        return String(last).removingPercentEncoding ?? String(last)
    }

    private static func integer(_ value: Any?, fallback: Int) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private static func boolean(_ value: Any?, fallback: Bool) -> Bool {
        (value as? NSNumber)?.boolValue ?? fallback
    }

    private static func string(_ value: Any?, fallback: String) -> String {
        value as? String ?? fallback
    }

    // ethernetMACAddress reads the hardware address without invoking a shell.
    private static func ethernetMACAddress(interface: String) -> String? {
        let result = try? ProcessRunner.run("/sbin/ifconfig", arguments: [interface], timeout: 3)
        return result?.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ether ") })?
            .split(separator: " ")
            .last
            .map(String.init)
    }

    // localIPAddress captures the current wake verification target at migration time.
    private static func localIPAddress(interface: String) -> String? {
        let result = try? ProcessRunner.run("/usr/sbin/ipconfig", arguments: ["getifaddr", interface], timeout: 3)
        let value = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
