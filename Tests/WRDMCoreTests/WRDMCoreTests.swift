import Foundation
import Darwin
import XCTest
@testable import WRDMCore

// WRDMCoreTests verifies the shared contracts used by app, agent, CLI, AI, and MCP.
final class WRDMCoreTests: XCTestCase {
    // Verify unsupported architectures report their limitation and retain deterministic evidence analysis.
    func testLocalModelPlatformAvailability() async throws {
        let provider = LocalFoundationModelProvider()
        #if arch(x86_64)
        XCTAssertEqual(provider.unavailableReason, "Local AI requires Apple Silicon and macOS 26 or later.")
        let event = DiagnosticEvent(type: .mountLost, source: "test", summary: "Mount disconnected")
        let finding = try await provider.analyze(question: "What happened?", evidence: [event])
        XCTAssertEqual(finding.title, "Evidence-based fallback analysis")
        #else
        if #unavailable(macOS 26.0) {
            XCTAssertEqual(provider.unavailableReason, "Local AI requires macOS 26 or later.")
        }
        #endif
        // Empty evidence must never invoke an on-device model regardless of platform capability.
        let emptyFinding = try await provider.analyze(question: "What happened?", evidence: [])
        XCTAssertEqual(emptyFinding.title, "Not enough evidence")
        XCTAssertTrue(emptyFinding.evidenceIDs.isEmpty)
    }

    // testDefaultConfigurationPersists proves first-run creation and round-trip decoding.
    func testDefaultConfigurationPersists() async throws {
        let paths = temporaryPaths()
        let store = ConfigurationStore(paths: paths)
        let created = try await store.load()
        XCTAssertEqual(created.network.wifiGraceMinutes, 15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))

        var updated = created
        updated.network.wifiGraceMinutes = 23
        try await store.save(updated)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, updated)
    }

    // testSchemaOneMigratesIndependentCollectorAndTransferDefaults proves existing native configs keep prior behavior.
    func testSchemaOneMigratesIndependentCollectorAndTransferDefaults() async throws {
        let paths = temporaryPaths()
        try paths.ensureDirectories()
        var legacy = AppSettings.defaults
        legacy.schemaVersion = 1
        let encoded = try PropertyListEncoder().encode(legacy)
        var format = PropertyListSerialization.PropertyListFormat.xml
        var dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, options: [], format: &format) as? [String: Any])
        var diagnostics = try XCTUnwrap(dictionary["diagnostics"] as? [String: Any])
        diagnostics.removeValue(forKey: "networkEventsEnabled")
        diagnostics.removeValue(forKey: "sleepWakeEventsEnabled")
        dictionary["diagnostics"] = diagnostics
        var transfer = try XCTUnwrap(dictionary["transfer"] as? [String: Any])
        transfer.removeValue(forKey: "keepMacAwakeByDefault")
        transfer.removeValue(forKey: "unlimitedAutoRetries")
        dictionary["transfer"] = transfer
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: paths.configFile)

        let migrated = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(migrated.diagnostics.networkEventsEnabled)
        XCTAssertTrue(migrated.diagnostics.sleepWakeEventsEnabled)
        XCTAssertFalse(migrated.general.openAppAtLogin)
        XCTAssertEqual(migrated.transfer.defaultResumePolicy, .ask)
        XCTAssertTrue(migrated.transfer.incidentBundleOnFailure)
        XCTAssertFalse(try XCTUnwrap(migrated.transfer.keepMacAwakeByDefault))
        XCTAssertFalse(migrated.transfer.unlimitedAutoRetries)
        let persisted = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: paths.configFile), options: [], format: &format) as? [String: Any])
        XCTAssertEqual(persisted["schemaVersion"] as? Int, AppSettings.currentSchemaVersion)
    }

    // testDamagedNativeConfigurationIsPreserved prevents silent fallback and overwrite of user settings.
    func testDamagedNativeConfigurationIsPreserved() async throws {
        let paths = temporaryPaths()
        try paths.ensureDirectories()
        let malformed: [String: Any] = ["schemaVersion": 1, "general": "invalid"]
        let data = try PropertyListSerialization.data(fromPropertyList: malformed, format: .xml, options: 0)
        try data.write(to: paths.configFile)

        for _ in 0..<2 {
            do {
                _ = try await ConfigurationStore(paths: paths).load()
                XCTFail("Damaged native configuration must be reported")
            } catch let error as ConfigurationError {
                guard case .corruptedNativeConfiguration = error else {
                    return XCTFail("Unexpected configuration error: \(error)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.configFile), data)
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.applicationSupport.path)
        XCTAssertEqual(backups.filter { $0.hasPrefix("config.corrupt-") }.count, 1)
    }

    // testConfigurationCompareAndSwapRejectsStaleSnapshots protects UI changes from CLI races.
    func testConfigurationCompareAndSwapRejectsStaleSnapshots() async throws {
        let paths = temporaryPaths()
        let first = ConfigurationStore(paths: paths)
        let second = ConfigurationStore(paths: paths)
        let original = try await first.load()
        var externallyUpdated = original
        externallyUpdated.general.checkIntervalSeconds = 35
        try await second.save(externallyUpdated)
        var stale = original
        stale.general.checkIntervalSeconds = 55

        do {
            try await first.replace(stale, ifUnchanged: original)
            XCTFail("A stale settings snapshot must not overwrite newer data")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .concurrentModification)
        }
        let reloaded = try await first.load()
        XCTAssertEqual(reloaded, externallyUpdated)
    }

    // testApplicationFilesUsePrivatePermissions verifies repaired data ownership for runtime artifacts.
    func testApplicationFilesUsePrivatePermissions() async throws {
        let paths = temporaryPaths()
        _ = try await ConfigurationStore(paths: paths).load()
        try await RuntimeFileStore(paths: paths).writeStatus(.unavailable)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: paths.applicationSupport.path)[.posixPermissions] as? NSNumber)?.intValue
        let configMode = (try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? NSNumber)?.intValue
        let statusMode = (try FileManager.default.attributesOfItem(atPath: paths.statusFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(configMode, 0o600)
        XCTAssertEqual(statusMode, 0o600)
    }

    // testLegacyMigrationPreservesSettings validates the existing shell plist import boundary.
    func testLegacyMigrationPreservesSettings() async throws {
        let paths = temporaryPaths()
        try paths.ensureDirectories()
        let legacy: [String: Any] = [
            "checkIntervalSeconds": 30,
            "networkPolicy": [
                "enabled": true,
                "lanInterface": "en7",
                "wifiInterface": "en8",
                "wifiGraceMinutes": 15,
            ],
            "shares": (1...14).map { index in
                ["url": "smb://nas/Share%20\(index)", "enabled": index != 14] as [String: Any]
            },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        try data.write(to: paths.configFile)

        let settings = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(settings.general.checkIntervalSeconds, 30)
        XCTAssertTrue(settings.network.enabled)
        XCTAssertEqual(settings.network.lanInterface, "en7")
        XCTAssertEqual(settings.mounts.count, 14)
        XCTAssertEqual(settings.mounts.first?.name, "Share 1")
        XCTAssertEqual(settings.mounts.last?.name, "Share 14")
        XCTAssertEqual(settings.mounts.filter(\.enabled).count, 13)
        XCTAssertEqual(settings.network.wifiGraceMinutes, 15)
    }

    // testAllSurfacesShareOneConfigurationRevision proves stores observe the same atomic snapshot.
    func testAllSurfacesShareOneConfigurationRevision() async throws {
        let paths = temporaryPaths()
        let writer = ConfigurationStore(paths: paths)
        var settings = AppSettings.defaults
        settings.general.checkIntervalSeconds = 45
        settings.mounts = [MountDefinition(name: "Shared", url: "smb://nas/shared")]
        try await writer.save(settings)
        let appReader = try await ConfigurationStore(paths: paths).load()
        let agentReader = try await ConfigurationStore(paths: paths).load()
        let cliReader = try await ConfigurationStore(paths: paths).load()
        let mcpReader = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(appReader, settings)
        XCTAssertEqual(agentReader, settings)
        XCTAssertEqual(cliReader, settings)
        XCTAssertEqual(mcpReader, settings)
    }

    // testConfigurationExportImportRoundTripMovesNonSecretSettings proves the transfer file preserves all settings.
    func testConfigurationExportImportRoundTripMovesNonSecretSettings() async throws {
        let sourcePaths = temporaryPaths()
        let targetPaths = temporaryPaths()
        let source = ConfigurationStore(paths: sourcePaths)
        let target = ConfigurationStore(paths: targetPaths)
        var settings = AppSettings.defaults
        settings.mounts = [MountDefinition(name: "Team", url: "smb://nas.local/team")]
        settings.network.enabled = true
        settings.network.gatewayHost = "192.0.2.1"
        settings.diagnostics.networkEventsEnabled = false
        settings.packetCapture.enabled = true
        settings.packetCapture.host = "capture-node.example"
        settings.synology.syslogEnabled = true
        settings.ai.enabled = true
        settings.wake.targetName = "Studio Mac"
        settings.wake.targetMACAddress = "00:11:22:33:44:55"
        settings.wake.targetHost = "192.0.2.10"
        settings.transfer.monitoringEnabled = true
        settings.transfer.defaultResumePolicy = .autoRetry
        settings.transfer.maximumAutoRetries = 7
        settings.transfer.unlimitedAutoRetries = true
        try await source.save(settings)

        let exported = try await source.exportConfigurationData()
        let imported = try await target.importConfigurationData(exported)

        XCTAssertEqual(imported, settings)
        let reloaded = try await target.load()
        XCTAssertEqual(reloaded, settings)
        let exportedText = String(decoding: exported, as: UTF8.self)
        XCTAssertTrue(exportedText.contains(ConfigurationExportDocument.currentFormatIdentifier))
        XCTAssertFalse(exportedText.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(exportedText.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(exportedText.contains("sk-live-test-secret"))
    }

    // testConfigurationImportRejectsInvalidDataWithoutChangingCurrentSettings keeps bad transfers transactional.
    func testConfigurationImportRejectsInvalidDataWithoutChangingCurrentSettings() async throws {
        let paths = temporaryPaths()
        let store = ConfigurationStore(paths: paths)
        var original = AppSettings.defaults
        original.general.checkIntervalSeconds = 35
        original.mounts = [MountDefinition(name: "Stable", url: "smb://nas.local/stable")]
        try await store.save(original)

        do {
            _ = try await store.importConfigurationData(Data("not a plist".utf8), replacing: original)
            XCTFail("Unreadable transfer data must be rejected")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.localizedDescription.contains("property list"))
        }

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, original)
    }

    // testConfigurationImportValidatesBeforeReplace prevents invalid imported SMB targets from replacing live config.
    func testConfigurationImportValidatesBeforeReplace() async throws {
        let paths = temporaryPaths()
        let store = ConfigurationStore(paths: paths)
        var original = AppSettings.defaults
        original.mounts = [MountDefinition(name: "Stable", url: "smb://nas.local/stable")]
        try await store.save(original)
        var invalid = AppSettings.defaults
        invalid.mounts = [MountDefinition(name: "Broken", url: "http://nas.local/broken")]
        let exported = try ConfigurationStore.encodeExportDocument(settings: invalid)

        do {
            _ = try await store.importConfigurationData(exported, replacing: original)
            XCTFail("Imported settings must pass the same validation as saved settings")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.localizedDescription.contains("invalid SMB URL"))
        }

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, original)
    }

    // testCommandConfigurationExportImportUsesConfirmationAndSharedStore covers CLI and MCP command wiring.
    func testCommandConfigurationExportImportUsesConfirmationAndSharedStore() async throws {
        let paths = temporaryPaths()
        let service = CommandService(paths: paths)
        let exportFile = paths.applicationSupport.appendingPathComponent("transfer.wrdmconfig")
        let exported = await service.execute(CommandRequest(command: "config.export", arguments: [exportFile.path], confirmed: true), actor: "test")
        XCTAssertEqual(exported.code, "CONFIG_EXPORTED")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportFile.path))
        let mode = (try FileManager.default.attributesOfItem(atPath: exportFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)

        var imported = AppSettings.defaults
        imported.general.checkIntervalSeconds = 40
        imported.mounts = [MountDefinition(name: "Imported", url: "smb://nas.local/imported")]
        try ConfigurationStore.encodeExportDocument(settings: imported).write(to: exportFile)
        let unconfirmed = await service.execute(CommandRequest(command: "config.import", arguments: [exportFile.path]), actor: "test")
        XCTAssertEqual(unconfirmed.code, "CONFIRMATION_REQUIRED")
        let confirmed = await service.execute(CommandRequest(command: "config.import", arguments: [exportFile.path], confirmed: true), actor: "test")
        XCTAssertEqual(confirmed.code, "CONFIG_IMPORTED")
        let reloaded = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(reloaded, imported)
    }

    // testLoginItemServiceWritesOnlyVisibleAppLaunchAgent proves the app login item is separate from the helper.
    func testLoginItemServiceWritesOnlyVisibleAppLaunchAgent() throws {
        let paths = temporaryPaths()
        let appBundle = try fakeAppBundle(paths: paths)
        let service = LoginItemService(paths: paths, appBundle: appBundle, executeLaunchctl: false)

        let disabled = service.status()
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(disabled.loaded)

        let enabled = try service.apply(enabled: true)
        XCTAssertTrue(enabled.enabled)
        XCTAssertTrue(enabled.loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.plistFile.path))

        let data = try Data(contentsOf: service.plistFile)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, LoginItemService.label)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [LoginItemService.bundleIdentifier])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [appBundle.appendingPathComponent("Contents/MacOS/WeRockDriveMounts").path, "--background"])
        let plistText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(plistText.contains("We Rock Drive Mount Agent"))

        // Reconciliation must preserve the existing file instead of replacing the login job.
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: service.plistFile.path)
        _ = try service.apply(enabled: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: service.plistFile.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)

        // An outdated foreground launch definition must be replaced during reconciliation.
        try Data("outdated".utf8).write(to: service.plistFile)
        _ = try service.apply(enabled: true)
        XCTAssertEqual(try Data(contentsOf: service.plistFile), data)

        let removed = try service.apply(enabled: false)
        XCTAssertFalse(removed.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.plistFile.path))
    }

    // testCommandServiceReconcilesPersistedLoginPreference proves app startup can repair launchd drift after an install.
    func testCommandServiceReconcilesPersistedLoginPreference() async throws {
        let paths = temporaryPaths()
        let appBundle = try fakeAppBundle(paths: paths)
        var settings = AppSettings.defaults
        settings.general.openAppAtLogin = true
        try await ConfigurationStore(paths: paths).save(settings)
        let loginItem = LoginItemService(paths: paths, appBundle: appBundle, executeLaunchctl: false)
        let service = CommandService(paths: paths, loginItem: loginItem)

        let result = await service.execute(
            CommandRequest(command: "app.login.reconcile", confirmed: true),
            actor: "test"
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.code, "LOGIN_ITEM_RECONCILED")
        XCTAssertTrue(loginItem.status().enabled)
        XCTAssertTrue(loginItem.status().loaded)
    }

    // testConfigurationRejectsCredentialsInSMBURL enforces the Keychain-only secret boundary.
    func testConfigurationRejectsCredentialsInSMBURL() async throws {
        var settings = AppSettings.defaults
        settings.mounts = [MountDefinition(name: "Unsafe", url: "smb://user:password@nas/share")]
        let store = ConfigurationStore(paths: temporaryPaths())
        do {
            try await store.save(settings)
            XCTFail("Expected credential-bearing SMB URL to fail")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .secretInURL("Unsafe"))
        }
    }

    // testConfigurationRejectsDuplicateMounts prevents duplicate recovery loops for one SMB share.
    func testConfigurationRejectsDuplicateMounts() async throws {
        let paths = temporaryPaths()
        let store = ConfigurationStore(paths: paths)
        var settings = AppSettings.defaults
        settings.mounts = [
            MountDefinition(name: "Data", url: "smb://nas.local/Data/"),
            MountDefinition(name: "Duplicate", url: "SMB://NAS.LOCAL/data"),
        ]

        do {
            try await store.save(settings)
            XCTFail("Duplicate SMB endpoints must be rejected")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.localizedDescription.contains("duplicate SMB URL"))
        }
    }

    // testConfigurationRejectsUnmanagedPiCaptureDirectory prevents arbitrary remote file writes.
    func testConfigurationRejectsUnmanagedPiCaptureDirectory() async throws {
        let store = ConfigurationStore(paths: temporaryPaths())
        var settings = AppSettings.defaults
        settings.packetCapture.remoteDirectory = "/tmp/captures"
        do {
            try await store.save(settings)
            XCTFail("Unmanaged Pi capture directories must be rejected")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.localizedDescription.contains("packet capture directory"))
        }
        settings.packetCapture.remoteDirectory = "/var/lib/we-rock-drive-mounts/captures/../../outside"
        do {
            try await store.save(settings)
            XCTFail("Traversing Pi capture directories must be rejected")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.localizedDescription.contains("packet capture directory"))
        }
    }

    // testCaptureMetadataPathValidationRejectsTraversalAndSiblingPrefixes protects the Pi trust boundary.
    func testCaptureMetadataPathValidationRejectsTraversalAndSiblingPrefixes() {
        let settings = PacketCaptureSettings.defaults
        XCTAssertTrue(settings.containsRemotePath("/var/lib/we-rock-drive-mounts/captures/session.pcapng"))
        XCTAssertFalse(settings.containsRemotePath("/var/lib/we-rock-drive-mounts/captures/../../private/session.pcapng"))
        XCTAssertFalse(settings.containsRemotePath("/var/lib/we-rock-drive-mounts/captures-other/session.pcapng"))
    }

    // testCaptureOpenRejectsTraversalAndSymlinkEscape protects the local Wireshark boundary.
    func testCaptureOpenRejectsTraversalAndSymlinkEscape() async throws {
        let paths = temporaryPaths()
        try paths.ensureDirectories()
        let outside = paths.logs.appendingPathComponent("outside.pcapng")
        try SecureFileAccess.writeAtomically(Data([0x0A, 0x0D, 0x0D, 0x0A]), to: outside)
        let link = paths.captures.appendingPathComponent("escape.pcapng")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let service = CommandService(paths: paths)
        let traversal = await service.execute(CommandRequest(command: "capture.open", arguments: [paths.captures.appendingPathComponent("../outside.pcapng").path]), actor: "test")
        let symlink = await service.execute(CommandRequest(command: "capture.open", arguments: [link.path]), actor: "test")
        XCTAssertEqual(traversal.code, "INVALID_ARGUMENT")
        XCTAssertEqual(symlink.code, "INVALID_ARGUMENT")
    }

    // testCaptureOpenTargetsExactWiresharkBundlePath prevents ambiguous Launch Services app selection.
    func testCaptureOpenTargetsExactWiresharkBundlePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-open-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Wireshark.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Wireshark")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try executableScript(at: executable, body: "#!/bin/sh\nexit 0\n")
        let capture = root.appendingPathComponent("sample.pcapng")
        try SecureFileAccess.writeAtomically(Data([0x0A, 0x0D, 0x0D, 0x0A]), to: capture)
        let service = LiveCaptureService(wiresharkPaths: [executable.path])

        let command = try await service.openCommand(file: capture)

        XCTAssertEqual(command.executable, "/usr/bin/open")
        XCTAssertEqual(command.arguments, ["-a", bundle.path, capture.path])
        XCTAssertTrue(command.returnsImmediately)
    }

    // testLiveCapturePreflightReportsMissingDisabledAndAvailableStates verifies side-effect-free discovery.
    func testLiveCapturePreflightReportsMissingDisabledAndAvailableStates() async {
        let missing = LiveCaptureService(wiresharkPaths: [])
        let degraded = await missing.status(packetCaptureEnabled: true)
        XCTAssertEqual(degraded.state, .degraded)
        XCTAssertFalse(degraded.wiresharkAvailable)
        XCTAssertFalse(degraded.canStart)

        let disabled = await missing.status(packetCaptureEnabled: false)
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertFalse(disabled.canStart)

        let available = LiveCaptureService(wiresharkPaths: ["/usr/bin/true"])
        let ready = await available.status(packetCaptureEnabled: true)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertTrue(ready.wiresharkAvailable)
        XCTAssertTrue(ready.canStart)
    }

    // testLiveCaptureStopAndShutdownRemoveOwnedProcesses proves paired-process cleanup.
    func testLiveCaptureStopAndShutdownRemoveOwnedProcesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-live-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sleeper = try executableScript(at: root.appendingPathComponent("sleep.sh"), body: "#!/bin/sh\n/bin/sleep 30\n")
        var settings = PacketCaptureSettings.defaults
        settings.enabled = true
        let service = LiveCaptureService(wiresharkPaths: [sleeper.path], sshExecutable: sleeper.path)

        let first = try await service.start(settings: settings, hostFilter: nil)
        let firstProcessIDs = await service.ownedProcessIdentifiers(identifier: first)
        let firstPIDs = try XCTUnwrap(firstProcessIDs)
        XCTAssertTrue(firstPIDs.allSatisfy(processIsAlive))
        let running = await service.status(packetCaptureEnabled: true)
        XCTAssertEqual(running.state, .running)
        let stoppedFirst = await service.stop(identifier: first)
        XCTAssertTrue(stoppedFirst)
        XCTAssertTrue(firstPIDs.allSatisfy { !processIsAlive($0) })
        let stopped = await service.status(packetCaptureEnabled: true)
        XCTAssertEqual(stopped.state, .stopped)

        let second = try await service.start(settings: settings, hostFilter: nil)
        let secondProcessIDs = await service.ownedProcessIdentifiers(identifier: second)
        let secondPIDs = try XCTUnwrap(secondProcessIDs)
        await service.stopAll()
        XCTAssertTrue(secondPIDs.allSatisfy { !processIsAlive($0) })
    }

    // testLiveCaptureStartAndStreamFailuresDoNotLeaveChildren verifies both error cleanup paths.
    func testLiveCaptureStartAndStreamFailuresDoNotLeaveChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-live-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("wireshark.pid")
        let sleeper = try executableScript(
            at: root.appendingPathComponent("wireshark.sh"),
            body: "#!/bin/sh\necho $$ > '\(pidFile.path)'\n/bin/sleep 30\n"
        )
        var settings = PacketCaptureSettings.defaults
        settings.enabled = true
        let startFailure = LiveCaptureService(
            wiresharkPaths: [sleeper.path],
            sshExecutable: root.appendingPathComponent("missing-ssh").path
        )
        do {
            _ = try await startFailure.start(settings: settings, hostFilter: nil)
            XCTFail("A missing SSH executable must fail")
        } catch {
            if FileManager.default.fileExists(atPath: pidFile.path) {
                let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
                XCTAssertNotNil(pid)
                XCTAssertFalse(pid.map(processIsAlive) ?? true)
            }
            let status = await startFailure.status(packetCaptureEnabled: true)
            XCTAssertEqual(status.state, .error)
        }

        let streamSleeper = try executableScript(
            at: root.appendingPathComponent("stream-wireshark.sh"),
            body: "#!/bin/sh\n/bin/sleep 30\n"
        )
        let exits = try executableScript(at: root.appendingPathComponent("exit.sh"), body: "#!/bin/sh\nexit 0\n")
        let streamFailure = LiveCaptureService(wiresharkPaths: [streamSleeper.path], sshExecutable: exits.path)
        let streamID = try await streamFailure.start(settings: settings, hostFilter: nil)
        let streamPIDs = await streamFailure.ownedProcessIdentifiers(identifier: streamID)
        for _ in 0..<40 {
            if await streamFailure.status(packetCaptureEnabled: true).state != .running { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(streamPIDs?.allSatisfy { !processIsAlive($0) } ?? true)
        let streamStatus = await streamFailure.status(packetCaptureEnabled: true)
        XCTAssertEqual(streamStatus.state, .stopped)
        XCTAssertEqual(streamStatus.activeSessionCount, 0)
    }

    // testLiveCaptureStopWithoutActiveSessionIsIdempotent keeps stale GUI state from surfacing as an error.
    func testLiveCaptureStopWithoutActiveSessionIsIdempotent() async throws {
        let paths = temporaryPaths()
        var settings = AppSettings.defaults
        settings.packetCapture.enabled = true
        try await ConfigurationStore(paths: paths).save(settings)
        let service = CommandService(paths: paths)

        let result = await service.execute(
            CommandRequest(command: "capture.live.stop", arguments: ["already-ended"], confirmed: true),
            actor: "test"
        )

        XCTAssertTrue(result.ok)
        XCTAssertNotEqual(result.code, "SESSION_NOT_FOUND")
        // A stale stop may report any non-running terminal/capability state, but never an active stream.
        let state = result.data["state"].flatMap(LiveCaptureLifecycleState.init(rawValue:))
        XCTAssertNotEqual(state, .running)
    }

    // testNetworkFallbackDebouncesFailureAndRecovery covers the connectivity safety state machine.
    // A disabled automatic shutdown must win even after the LAN recovery threshold is reached.
    func testDisabledAutomaticWiFiShutdownKeepsRadioOn() {
        var policy = NetworkPolicy.defaults
        policy.enabled = true
        policy.disableWifiWhenLanActive = false
        var state = NetworkPolicyState.empty
        state.fallbackActive = true
        let healthy = snapshot(lanHealthy: true, route: "en0", wifi: true)
        for _ in 0..<4 {
            XCTAssertEqual(NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: healthy, state: &state),
                           .none("LAN is healthy and no Wi-Fi action is needed"))
        }
    }

    func testNetworkFallbackDebouncesFailureAndRecovery() {
        var policy = NetworkPolicy.defaults
        policy.enabled = true
        policy.lanFailureThreshold = 2
        policy.lanRecoveryStableChecks = 2
        var state = NetworkPolicyState.empty
        let now = Date(timeIntervalSince1970: 10_000)
        let unhealthy = snapshot(lanHealthy: false, route: "en1", wifi: false)

        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: unhealthy, state: &state, now: now),
            .none("Waiting for LAN failure threshold")
        )
        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: unhealthy, state: &state, now: now),
            .enableWiFi("LAN is unhealthy; enabling Wi-Fi fallback")
        )
        XCTAssertFalse(state.fallbackActive)

        let enabled = NetworkPolicyEvaluator.reconcile(
            action: .enableWiFi("LAN is unhealthy; enabling Wi-Fi fallback"),
            snapshot: unhealthy,
            mutationSucceeded: true,
            observedWiFiEnabled: true,
            state: &state,
            now: now
        )
        XCTAssertTrue(enabled.fallbackActive)
        XCTAssertNil(enabled.error)

        let recovered = snapshot(lanHealthy: true, route: "en0", wifi: true)
        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: recovered, state: &state, now: now),
            .none("Waiting for stable LAN recovery")
        )
        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: recovered, state: &state, now: now),
            .none("Waiting for stable LAN recovery")
        )
        XCTAssertEqual(NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: recovered, state: &state, now: now),
                       .disableWiFi("LAN recovered after three stable checks"))
        XCTAssertTrue(state.fallbackActive)
        XCTAssertNil(state.wifiGraceUntil)
    }

    // testFailedWiFiMutationDoesNotClaimFallback verifies command truth against observed hardware state.
    func testFailedWiFiMutationDoesNotClaimFallback() {
        var state = NetworkPolicyState.empty
        let unhealthy = snapshot(lanHealthy: false, route: "en1", wifi: false)
        let execution = NetworkPolicyEvaluator.reconcile(
            action: .enableWiFi("Enable fallback"),
            snapshot: unhealthy,
            mutationSucceeded: false,
            observedWiFiEnabled: false,
            state: &state,
            now: Date(timeIntervalSince1970: 10_000)
        )
        XCTAssertFalse(state.fallbackActive)
        XCTAssertFalse(execution.fallbackActive)
        XCTAssertNotNil(execution.error)
    }

    // testManualWiFiGetsConfiguredGracePeriod prevents immediate shutdown after AirDrop activation.
    func testManualWiFiGetsConfiguredGracePeriod() {
        var policy = NetworkPolicy.defaults
        policy.enabled = true
        policy.wifiGraceMinutes = 15
        var state = NetworkPolicyState.empty
        let now = Date(timeIntervalSince1970: 20_000)
        let healthy = snapshot(lanHealthy: true, route: "en1", wifi: true)

        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: healthy, state: &state, now: now),
            .none("Wi-Fi was enabled manually; temporary window started")
        )
        XCTAssertEqual(state.wifiGraceUntil, now.addingTimeInterval(900))
        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: healthy, state: &state, now: now.addingTimeInterval(899)),
            .none("Temporary Wi-Fi window is active")
        )
        XCTAssertEqual(
            NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: healthy, state: &state, now: now.addingTimeInterval(900)),
            .disableWiFi("LAN is stable and the Wi-Fi window expired")
        )
    }

    // testMountRecoveryBackoffPersistsFiveFailures verifies deterministic exponential retry timing.
    func testMountRecoveryBackoffPersistsFiveFailures() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        var record: MountRecoveryRecord?
        let expectedDelays = [20, 40, 80, 160, 300]
        for delay in expectedDelays {
            record = MountRecoveryPlanner.failed(
                previous: record,
                message: "server-unavailable",
                now: now,
                baseSeconds: 20
            )
            XCTAssertEqual(record?.nextAttemptAt, now.addingTimeInterval(Double(delay)))
        }
        XCTAssertEqual(record?.failureCount, 5)
        XCTAssertFalse(MountRecoveryPlanner.isDue(record, now: now.addingTimeInterval(299)))
        XCTAssertTrue(MountRecoveryPlanner.isDue(record, now: now.addingTimeInterval(300)))

        let store = MountRecoveryStateStore(paths: temporaryPaths())
        let mountID = UUID()
        try await store.save([mountID: record!])
        let reloaded = await store.load()
        XCTAssertEqual(reloaded[mountID], record)
    }

    // testMountServiceKeepsDisabledSharesSideEffectFree covers the disabled adapter path directly.
    func testMountServiceKeepsDisabledSharesSideEffectFree() async {
        var settings = AppSettings.defaults
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive", enabled: false)
        settings.mounts = [mount]
        let states = await MountService().runtimeStates(settings: settings)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].mountID, mount.id)
        XCTAssertEqual(states[0].availability, .disabled)
    }

    // testMountServiceDiscoversImportableVisibleSMBMounts verifies first-run import candidates without live mounts.
    func testMountServiceDiscoversImportableVisibleSMBMounts() {
        let configured = MountDefinition(name: "Existing", url: "smb://nas.local/Existing Share")
        let output = """
        //testuser@nas.local/Existing%20Share on /Volumes/Existing Share (smbfs, nodev, nosuid, mounted by testuser)
        //testuser@nas.local/New%20Share on /Volumes/New Share (smbfs, nodev, nosuid, mounted by testuser)
        //testuser@nas.local/New%20Share on /Volumes/New Share-1 (smbfs, nodev, nosuid, mounted by testuser)
        //testuser@backup.local/TimeMachine on /Volumes/.timemachine/TimeMachine (smbfs, nobrowse, mounted by testuser)
        /dev/disk3s1 on /Volumes/USB (apfs, local, nodev, nosuid)
        """

        let discovered = MountService.discoveredMounts(from: output, configuredMounts: [configured])

        XCTAssertEqual(discovered, [
            DiscoveredSMBMount(name: "New Share", url: "smb://nas.local/New Share", localPath: "/Volumes/New Share"),
        ])
    }

    // testAgentRuntimePublishesDisabledStatus covers the bounded cycle without network mutations.
    func testAgentRuntimePublishesDisabledStatus() async throws {
        let paths = temporaryPaths()
        var settings = AppSettings.defaults
        settings.general.enabled = false
        settings.general.checkIntervalSeconds = 25
        settings.mounts = [MountDefinition(name: "Archive", url: "smb://nas/archive", enabled: false)]
        try await ConfigurationStore(paths: paths).save(settings)
        let interval = await AgentRuntime(paths: paths).runOneCycle()
        let status = await RuntimeFileStore(paths: paths).readStatus()
        XCTAssertEqual(interval, 25)
        XCTAssertEqual(status.phase, "disabled")
        XCTAssertEqual(status.enabledMounts, 0)
        XCTAssertEqual(status.collectorStates, CollectorRuntimeState.states(settings: settings))
    }

    // testCollectorStatesRemainIndependent verifies explicit enabled and disabled reasons on every shared surface.
    func testCollectorStatesRemainIndependent() async throws {
        let paths = temporaryPaths()
        var settings = AppSettings.defaults
        settings.general.enabled = false
        settings.diagnostics.networkEventsEnabled = false
        settings.diagnostics.sleepWakeEventsEnabled = true
        settings.diagnostics.macLogsEnabled = false
        settings.network.trafficEnabled = false
        try await ConfigurationStore(paths: paths).save(settings)
        _ = await AgentRuntime(paths: paths).runOneCycle()

        let states = CollectorRuntimeState.states(settings: settings)
        XCTAssertFalse(try XCTUnwrap(states.first { $0.kind == .networkEvents }).enabled)
        XCTAssertTrue(try XCTUnwrap(states.first { $0.kind == .sleepWakeEvents }).enabled)
        XCTAssertFalse(try XCTUnwrap(states.first { $0.kind == .macOSLogs }).enabled)
        XCTAssertFalse(try XCTUnwrap(states.first { $0.kind == .interfaceTraffic }).enabled)
        XCTAssertFalse(try XCTUnwrap(states.first { $0.kind == .networkEvents }).reason.isEmpty)

        let result = await CommandService(paths: paths).execute(CommandRequest(command: "diagnostics.status"), actor: "test")
        XCTAssertTrue(result.ok)
        let data = try XCTUnwrap(result.data["json"]?.data(using: .utf8))
        let decoded = try JSONDecoder().decode([CollectorRuntimeState].self, from: data)
        XCTAssertEqual(decoded, states)
        XCTAssertEqual(result.data["runtimeMatchesConfig"], "true")
    }

    // testAgentRuntimeCompletesEnabledEmptyCycle covers normal status publication without remote mutations.
    func testAgentRuntimeCompletesEnabledEmptyCycle() async throws {
        let paths = temporaryPaths()
        var settings = AppSettings.defaults
        settings.general.enabled = true
        settings.general.checkIntervalSeconds = 25
        settings.network.enabled = false
        settings.network.gatewayHost = "127.0.0.1"
        settings.network.remoteReachabilityHosts = []
        settings.network.trafficEnabled = false
        settings.diagnostics.enabled = false
        settings.mounts = []
        try await ConfigurationStore(paths: paths).save(settings)
        let interval = await AgentRuntime(paths: paths).runOneCycle()
        let status = await RuntimeFileStore(paths: paths).readStatus()
        XCTAssertEqual(interval, 25)
        XCTAssertEqual(status.phase, "idle")
        XCTAssertEqual(status.mountStates, [])
        XCTAssertNotNil(status.networkExecution)
    }

    // testMountServiceRejectsCredentialBearingRecoveryURL covers the observation adapter's defense in depth.
    func testMountServiceRejectsCredentialBearingRecoveryURL() {
        let mount = MountDefinition(name: "Unsafe", url: "smb://user:secret@nas/archive")
        let state = MountService().runtimeState(for: mount, healthTimeout: 1)
        XCTAssertEqual(state.availability, .unknown)
        XCTAssertEqual(state.failureCode, .invalidSMBURL)
        XCTAssertEqual(state.message, "Credentials in SMB URL are not allowed")
    }

    // testTrafficSamplerCalculatesRatesAndCounterReset verifies per-interface accounting.
    func testTrafficSamplerCalculatesRatesAndCounterReset() {
        let start = Date(timeIntervalSince1970: 40_000)
        let previous = TrafficCounter(receivedBytes: 1_000, sentBytes: 500, timestamp: start)
        let sample = NetworkService.makeTrafficSample(
            interface: "en0",
            received: 3_000,
            sent: 1_500,
            previous: previous,
            timestamp: start.addingTimeInterval(10)
        )
        XCTAssertEqual(sample.receivedDelta, 2_000)
        XCTAssertEqual(sample.sentDelta, 1_000)
        XCTAssertEqual(sample.receivedBytesPerSecond, 200)
        XCTAssertEqual(sample.sentBytesPerSecond, 100)

        let reset = NetworkService.makeTrafficSample(
            interface: "en0",
            received: 10,
            sent: 20,
            previous: previous,
            timestamp: start.addingTimeInterval(20)
        )
        XCTAssertEqual(reset.receivedDelta, 0)
        XCTAssertEqual(reset.sentDelta, 0)
    }

    // testActionPolicyMatrix proves all authority modes for representative risks.
    func testActionPolicyMatrix() {
        XCTAssertEqual(ActionPolicy.decision(mode: .confirmAll, risk: .readOnly), .allow)
        XCTAssertEqual(ActionPolicy.decision(mode: .confirmAll, risk: .safeMutation), .requireConfirmation)
        XCTAssertEqual(ActionPolicy.decision(mode: .guarded, risk: .safeMutation), .allow)
        XCTAssertEqual(ActionPolicy.decision(mode: .guarded, risk: .connectivityCritical), .requireConfirmation)
        XCTAssertEqual(ActionPolicy.decision(mode: .autonomous, risk: .remoteMutation), .allow)
    }

    // testDiagnosticsCorrelatesAndRedacts verifies evidence references without false certainty.
    func testDiagnosticsCorrelatesAndRedacts() {
        let service = DiagnosticsService(paths: temporaryPaths())
        let first = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            type: .networkChanged,
            source: "network",
            summary: "authorization=very-secret-token"
        )
        let second = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_030),
            type: .mountLost,
            source: "share",
            summary: "ghp_abcdefghijklmnopqrstuvwxyz123456"
        )
        let incidents = service.correlate(events: [first, second])
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents[0].confidence, 0.7)
        XCTAssertEqual(Set(incidents[0].evidenceIDs), Set([first.id, second.id]))
        XCTAssertFalse(service.redact(first.summary).contains("very-secret-token"))
        XCTAssertFalse(service.redact(second.summary).contains("ghp_"))
    }

    // testFiveSourceIncidentTimelinePreservesEveryReference verifies the required correlation fixture.
    func testFiveSourceIncidentTimelinePreservesEveryReference() {
        let start = Date(timeIntervalSince1970: 60_000)
        let events = [
            DiagnosticEvent(timestamp: start, type: .sleep, source: "power", summary: "Sleep"),
            DiagnosticEvent(timestamp: start.addingTimeInterval(5), type: .wake, source: "power", summary: "Wake"),
            DiagnosticEvent(timestamp: start.addingTimeInterval(10), type: .networkChanged, source: "ethernet", summary: "Link lost"),
            DiagnosticEvent(timestamp: start.addingTimeInterval(15), type: .mountLost, source: "smb", summary: "Mount failed"),
            DiagnosticEvent(timestamp: start.addingTimeInterval(20), type: .agentStarted, source: "agent", summary: "Restarted"),
        ]
        let incidents = DiagnosticsService().correlate(events: events)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents[0].evidenceIDs, events.map(\.id))
        XCTAssertEqual(incidents[0].startedAt, start)
        XCTAssertEqual(incidents[0].endedAt, start.addingTimeInterval(20))
    }

    // testSupportBundleRedactsPrivateSettings performs a bundle-wide negative search across every exported surface.
    func testSupportBundleRedactsPrivateSettings() throws {
        let paths = temporaryPaths()
        let service = DiagnosticsService(paths: paths)
        var settings = AppSettings.defaults
        settings.mounts = [MountDefinition(name: "Private Team", url: "smb://nas.private/team-secret")]
        settings.network.gatewayHost = "192.168.44.1"
        settings.network.remoteReachabilityHosts = ["fd00::1234"]
        settings.packetCapture.host = "capture.local"
        settings.synology.sshUser = "wrdm-private-ssh-user"
        settings.synology.sshHost = "synology.internal"
        settings.synology.dsmBaseURL = "https://synology.internal:5001"
        settings.packetCapture.user = "private-pi-user"
        settings.packetCapture.remoteDirectory = "/home/private-pi-user/captures"
        settings.wake.targetName = "Private Mac"
        settings.wake.targetMACAddress = "00:11:22:33:44:55"
        settings.wake.targetHost = "10.44.0.9"
        settings.wake.routes[0].command = "wake-host.private"
        try paths.ensureDirectories()
        let evidenceFile = paths.diagnostics.appendingPathComponent("privacy-fixture.log")
        let evidenceText = "smb://nas.private/team-secret host 192.168.44.1 fd00::1234 wake target Private Mac /Users/private-user/Library token=secret-value apiKey=sk-abcdefghijklmnop"
        try SecureFileAccess.writeAtomically(Data(evidenceText.utf8), to: evidenceFile)
        let event = DiagnosticEvent(
            type: .warning,
            source: "Private Team",
            summary: evidenceText,
            details: ["probeHost": "10.44.0.9", "captureFilter": "host 192.168.44.1", "credential": "private-credential"],
            evidencePath: evidenceFile.path
        )
        let status = AgentStatus(
            timestamp: Date(),
            phase: "idle",
            enabledMounts: 1,
            healthyMounts: 1,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: "synology.internal returned token=secret-value",
            mountStates: [MountRuntimeState(mountID: settings.mounts[0].id, timestamp: Date(), availability: .healthy, consecutiveFailures: 0, message: "smb://nas.private/team-secret", localPath: "/Volumes/Private Team")]
        )
        let incident = MountIncident(
            mountID: settings.mounts[0].id,
            mountName: "Private Team",
            bootIdentity: "fixture-boot",
            startedAt: Date(),
            availability: .staleMounted,
            recoveryPhase: .manualConfirmationRequired,
            failureCode: .detachNotVerified,
            message: "smb://nas.private/team-secret remained at /Volumes/Private Team",
            evidencePath: "/Users/private-user/Library/Application Support/we-rock-drive-mounts/mount-incidents/private.json"
        )
        let incidentEncoder = JSONEncoder()
        incidentEncoder.dateEncodingStrategy = .iso8601
        try SecureFileAccess.writeAtomically(try incidentEncoder.encode([incident]), to: paths.mountIncidentsFile)
        let bundle = try service.exportSupportBundle(settings: settings, status: status, events: [event], traffic: [])
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil))
        var bundleText = ""
        for case let file as URL in enumerator {
            if let data = try? Data(contentsOf: file) { bundleText += String(decoding: data, as: UTF8.self) }
        }
        let forbidden = [
            "Private Team", "nas.private", "team-secret", "192.168.44.1", "fd00::1234",
            "capture.local", "wrdm-private-ssh-user", "synology.internal", "private-pi-user",
            "/home/private-pi-user", "Private Mac", "00:11:22:33:44:55", "10.44.0.9",
            "wake-host.private", "/Users/private-user", "secret-value", "sk-abcdefghijklmnop",
            "private-credential",
        ]
        for rawValue in forbidden {
            XCTAssertFalse(bundleText.contains(rawValue), "Bundle leaked fixture value: \(rawValue)")
        }
        let settingsData = try Data(contentsOf: bundle.appendingPathComponent("settings.json"))
        let settingsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let mounts = try XCTUnwrap(settingsObject["mounts"] as? [[String: Any]])
        let pseudonymousURL = try XCTUnwrap(mounts.first?["url"] as? String)
        let hostPseudonym = try XCTUnwrap(pseudonymousURL.split(separator: "/").dropFirst(2).first.map(String.init))
        XCTAssertGreaterThanOrEqual(bundleText.components(separatedBy: hostPseudonym).count - 1, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("evidence-manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("mount-incidents.json").path))
    }

    // testSupportBundlePrivacyCannotBeDisabled enforces the non-optional export boundary.
    func testSupportBundlePrivacyCannotBeDisabled() async {
        var settings = AppSettings.defaults
        settings.diagnostics.redactPathsInExports = false
        do {
            try await ConfigurationStore(paths: temporaryPaths()).save(settings)
            XCTFail("Privacy-disabled support exports must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot be disabled"))
        }
    }

    // testRetentionRunsOnScheduleAndPrunesAllArtifacts covers structured stores and macOS evidence files.
    func testRetentionRunsOnScheduleAndPrunesAllArtifacts() async throws {
        let paths = temporaryPaths()
        let store = RuntimeFileStore(paths: paths)
        let now = Date(timeIntervalSince1970: 500_000)
        try await store.appendEvent(DiagnosticEvent(timestamp: now.addingTimeInterval(-172_800), type: .warning, source: "old", summary: "old"))
        try await store.appendEvent(DiagnosticEvent(timestamp: now, type: .warning, source: "new", summary: "new"))
        let oldLog = paths.diagnostics.appendingPathComponent("mac-old.log")
        try SecureFileAccess.writeAtomically(Data("old evidence".utf8), to: oldLog)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-172_800)], ofItemAtPath: oldLog.path)
        var policy = DiagnosticsPolicy.defaults
        policy.retentionDays = 1
        policy.retentionIntervalMinutes = 30

        let firstRun = try await store.enforceRetentionIfNeeded(policy: policy, trafficMaxBytes: 10_000, now: now)
        let secondRun = try await store.enforceRetentionIfNeeded(policy: policy, trafficMaxBytes: 10_000, now: now.addingTimeInterval(60))
        let retainedSources = await store.recentEvents(limit: 10).map(\.source)
        XCTAssertTrue(firstRun)
        XCTAssertFalse(secondRun)
        XCTAssertEqual(retainedSources, ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLog.path))
    }

    // testSynologyDeduplicationPersistsInEventStore prevents duplicates after agent restarts.
    func testSynologyDeduplicationPersistsInEventStore() async throws {
        let paths = temporaryPaths()
        let event = DiagnosticEvent(
            type: .synology,
            source: "synology:nas",
            summary: "SMB session closed",
            details: ["rawReference": "nas-log-42"]
        )
        let firstStore = RuntimeFileStore(paths: paths)
        let secondStore = RuntimeFileStore(paths: paths)
        let firstInsert = try await firstStore.appendSynologyEventIfNew(event)
        let secondInsert = try await secondStore.appendSynologyEventIfNew(event)
        let count = await secondStore.recentEvents(limit: 10).count
        XCTAssertTrue(firstInsert)
        XCTAssertFalse(secondInsert)
        XCTAssertEqual(count, 1)
    }

    // testSynologyParsersPreserveProvenance covers syslog and exported CSV inputs.
    func testSynologyParsersPreserveProvenance() {
        let service = SynologyService()
        let syslog = service.parseSyslog("2026-08-03T10:00:02Z receiver=192.0.2.10 <14>1 2026-08-03T10:00:00Z nas smbd 1 ID47 - SMB session closed")
        XCTAssertEqual(syslog.count, 1)
        XCTAssertEqual(syslog[0].host, "nas")
        XCTAssertEqual(syslog[0].severity, "info")
        XCTAssertEqual(syslog[0].message, "SMB session closed")
        XCTAssertEqual(Int(syslog[0].receivedAt.timeIntervalSince(syslog[0].timestamp)), 2)
        XCTAssertTrue(syslog[0].rawReference.hasPrefix("syslog-"))

        let csv = service.importCSV("timestamp,host,severity,message\n2026-08-03T10:00:00Z,nas,error,Connection lost")
        XCTAssertEqual(csv.count, 1)
        XCTAssertEqual(csv[0].host, "nas")
        XCTAssertEqual(csv[0].message, "Connection lost")
    }

    // testDSMParserPreservesClockSkewAndRawReference covers canonical DSM API import.
    func testDSMParserPreservesClockSkewAndRawReference() throws {
        let payload: [String: Any] = [
            "success": true,
            "data": [
                "logs": [
                    [
                        "id": "nas-log-42",
                        "timestamp": "2026-08-03T10:00:00Z",
                        "host": "nas",
                        "facility": "smb",
                        "severity": "warning",
                        "message": "SMB session closed",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let received = ISO8601DateFormatter().date(from: "2026-08-03T10:00:05Z")!
        let event = try XCTUnwrap(SynologyService().importDSMResponse(data, receivedAt: received).first)
        XCTAssertEqual(event.rawReference, "nas-log-42")
        let diagnostic = SynologyService().diagnosticEvent(event)
        XCTAssertEqual(diagnostic.details["clockSkewSeconds"], "5")
        XCTAssertEqual(diagnostic.details["rawReference"], "nas-log-42")
    }

    // testWakeValidationRejectsUnsafeTargets validates accepted and broadcast MAC addresses.
    func testWakeValidationRejectsUnsafeTargets() {
        let service = WakeService()
        XCTAssertTrue(service.validateMAC("02:11:22:33:44:55"))
        XCTAssertFalse(service.validateMAC("ff:ff:ff:ff:ff:ff"))
        XCTAssertFalse(service.validateMAC("not-a-mac"))
    }

    // testWakeAttemptStoreSuppressesDuplicateTrigger verifies cross-interface idempotency state.
    func testWakeAttemptStoreSuppressesDuplicateTrigger() async {
        let store = WakeAttemptStore(paths: temporaryPaths())
        let now = Date(timeIntervalSince1970: 50_000)
        let first = await store.reserve(route: .raspberryPiLAN, now: now)
        let duplicate = await store.reserve(route: .raspberryPiLAN, now: now.addingTimeInterval(5))
        let later = await store.reserve(route: .raspberryPiLAN, now: now.addingTimeInterval(10))
        let separateRoute = await store.reserve(route: .tailscale, now: now.addingTimeInterval(5))
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(later)
        XCTAssertTrue(separateRoute)
    }

    // testIOSShortcutRouteReportsExternalTrigger prevents a no-op from being marked successful.
    func testIOSShortcutRouteReportsExternalTrigger() throws {
        var settings = WakeSettings.defaults
        settings.targetMACAddress = "00:11:22:33:44:55"
        let index = try XCTUnwrap(settings.routes.firstIndex(where: { $0.kind == .iosShortcut }))
        settings.routes[index].enabled = true
        let result = try WakeService().wake(
            route: .iosShortcut,
            wakeSettings: settings,
            packetSettings: .defaults,
            requireVerified: false
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "EXTERNAL_TRIGGER_REQUIRED")
    }

    // testPiHealthContractRejectsVersionAndCapabilityMismatch covers protocol blockers.
    func testPiHealthContractRejectsVersionAndCapabilityMismatch() throws {
        let healthy = PiCompanionHealth(
            ok: true,
            version: PiCompanionClient.protocolVersion,
            hostname: "capture-node",
            architecture: "aarch64",
            addresses: ["192.168.131.7"],
            dumpcapAvailable: true,
            tsharkAvailable: true,
            syslogReceiverActive: true,
            wakeAvailable: true
        )
        XCTAssertNoThrow(try PiCompanionClient.validateHealth(healthy))
        var wrong = healthy
        wrong.version = "9.0.0"
        XCTAssertThrowsError(try PiCompanionClient.validateHealth(wrong))
        var missing = healthy
        missing.dumpcapAvailable = false
        missing.tsharkAvailable = false
        XCTAssertThrowsError(try PiCompanionClient.validateHealth(missing))
    }

    // testProcessRunnerUsesMinimalEnvironment prevents inherited secret variables reaching children.
    func testProcessRunnerUsesMinimalEnvironment() throws {
        setenv("WRDM_TEST_SECRET", "must-not-leak", 1)
        defer { unsetenv("WRDM_TEST_SECRET") }
        let result = try ProcessRunner.run("/usr/bin/env", timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains("WRDM_TEST_SECRET"))
        XCTAssertFalse(result.stdout.contains("must-not-leak"))
    }

    // testSensitiveEnvironmentNameMatching covers inherited launch and shell credential classes.
    func testSensitiveEnvironmentNameMatching() {
        XCTAssertTrue(ProcessRunner.isSensitiveEnvironmentVariable("PRD_MCP_BEARER_TOKEN"))
        XCTAssertTrue(ProcessRunner.isSensitiveEnvironmentVariable("BW_CLIENT_SECRET"))
        XCTAssertTrue(ProcessRunner.isSensitiveEnvironmentVariable("DATABASE_PASSWORD"))
        XCTAssertTrue(ProcessRunner.isSensitiveEnvironmentVariable("OPENAI_API_KEY"))
        XCTAssertFalse(ProcessRunner.isSensitiveEnvironmentVariable("HOME"))
        XCTAssertFalse(ProcessRunner.isSensitiveEnvironmentVariable("LANG"))
        XCTAssertFalse(ProcessRunner.isSensitiveEnvironmentVariable("BW_CLIENT_ID"))
    }

    // testProcessRunnerTimesOutBoundedCommands verifies hung adapters cannot block the agent.
    func testProcessRunnerTimesOutBoundedCommands() throws {
        let result = try ProcessRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 124)
    }

    // testCloudEvidenceReductionStripsDetails enforces the default outbound privacy scope.
    func testCloudEvidenceReductionStripsDetails() {
        let event = DiagnosticEvent(
            type: .error,
            source: "test",
            summary: "Connection failed",
            details: ["raw": "private"],
            evidencePath: "/private/path"
        )
        let selected = OpenAIProvider(model: "test", dataMode: .reducedFindings).selectedEvidence([event])
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].details.isEmpty)
        XCTAssertNil(selected[0].evidencePath)
    }

    // testSelectedCloudEvidenceContainsOnlyConfirmedIDs enforces preview-backed raw-log scope.
    func testSelectedCloudEvidenceContainsOnlyConfirmedIDs() {
        let selected = DiagnosticEvent(type: .warning, source: "selected", summary: "selected")
        let excluded = DiagnosticEvent(type: .warning, source: "excluded", summary: "excluded")
        let provider = OpenAIProvider(
            model: "test",
            dataMode: .selectedRawLogs,
            selectedEvidenceIDs: [selected.id]
        )
        XCTAssertEqual(provider.selectedEvidence([selected, excluded]).map(\.id), [selected.id])
    }

    // testAIEvidenceIncludesTrafficAndBoundedMacExcerpt verifies multi-source payload construction.
    func testAIEvidenceIncludesTrafficAndBoundedMacExcerpt() throws {
        let paths = temporaryPaths()
        let log = paths.diagnostics.appendingPathComponent("mac-test.log")
        try SecureFileAccess.writeAtomically(Data("password=private\nnetwork resumed".utf8), to: log)
        let event = DiagnosticEvent(type: .wake, source: "macOS", summary: "Wake", evidencePath: log.path)
        let sample = InterfaceTrafficSample(
            timestamp: Date(timeIntervalSince1970: 80_000),
            interface: "en0",
            receivedBytes: 100,
            sentBytes: 50,
            receivedDelta: 100,
            sentDelta: 50,
            intervalSeconds: 10,
            receivedBytesPerSecond: 10,
            sentBytesPerSecond: 5
        )
        let evidence = AIEvidenceBuilder(paths: paths).build(events: [event], traffic: [sample])
        let safeMac = try XCTUnwrap(evidence.first(where: { $0.id == event.id }))
        XCTAssertNil(safeMac.evidencePath)
        XCTAssertTrue(safeMac.details["evidenceExcerpt"]?.contains("network resumed") == true)
        XCTAssertFalse(safeMac.details["evidenceExcerpt"]?.contains("private") == true)
        let trafficEvidence = evidence.first(where: { $0.type == .traffic })
        XCTAssertEqual(trafficEvidence?.source, "interface:en0")
        XCTAssertEqual(trafficEvidence?.id, sample.id)
    }

    // testEvidenceCitationParserRejectsHallucinatedIDs keeps finding references truthful.
    func testEvidenceCitationParserRejectsHallucinatedIDs() {
        let allowed = UUID()
        let hallucinated = UUID()
        let text = "Supported \(allowed.uuidString), unsupported \(hallucinated.uuidString), repeated \(allowed.uuidString)."
        XCTAssertEqual(EvidenceCitationParser.referencedIDs(in: text, allowed: [allowed]), [allowed])
    }

    // testLocalAIPromptHasGlobalBudget prevents cumulative evidence from exceeding the model context.
    func testLocalAIPromptHasGlobalBudget() {
        let events = (0..<100).map { index in
            DiagnosticEvent(
                type: .warning,
                source: "source-\(index)",
                summary: String(repeating: "summary ", count: 200),
                details: ["excerpt": String(repeating: "detail ", count: 500)]
            )
        }
        let prompt = LocalFoundationModelProvider.boundedPromptEvidence(events, maximumCharacters: 8_000)
        XCTAssertLessThanOrEqual(prompt.text.count, 8_000)
        XCTAssertLessThanOrEqual(prompt.events.count, 40)
        XCTAssertTrue(prompt.events.allSatisfy { prompt.text.contains($0.id.uuidString) })
        XCTAssertEqual(prompt.events.last?.id, events.last?.id)

        let defaultPrompt = LocalFoundationModelProvider.boundedPromptEvidence(events)
        XCTAssertLessThanOrEqual(defaultPrompt.text.count, 3_000)
        XCTAssertLessThanOrEqual(defaultPrompt.events.count, 20)
    }

    // testUncitedProviderFindingFallsBackToCitableEvidence rejects unsupported model prose.
    func testUncitedProviderFindingFallsBackToCitableEvidence() {
        let event = DiagnosticEvent(type: .mountLost, source: "share", summary: "Mount lost")
        let uncited = VerifiedFindingFactory.providerFinding(
            title: "Provider",
            text: "The network definitely failed.",
            confidence: 0.9,
            question: "Why?",
            evidence: [event],
            nextSteps: []
        )
        let cited = VerifiedFindingFactory.providerFinding(
            title: "Provider",
            text: "Observed \(event.id.uuidString).",
            confidence: 0.6,
            question: "Why?",
            evidence: [event],
            nextSteps: []
        )
        XCTAssertEqual(uncited.title, "Evidence-based fallback analysis")
        XCTAssertEqual(uncited.evidenceIDs, [event.id])
        XCTAssertEqual(cited.title, "Provider")
        XCTAssertEqual(cited.evidenceIDs, [event.id])
    }

    // testAgentTimelinePlannerReportsDelayWithoutInventingPowerEvents covers neutral scheduler evidence.
    func testAgentTimelinePlannerReportsDelayWithoutInventingPowerEvents() {
        let previous = Date(timeIntervalSince1970: 90_000)
        XCTAssertTrue(AgentTimelinePlanner.transitionEvents(lastCycleAt: previous, now: previous.addingTimeInterval(20), checkIntervalSeconds: 20).isEmpty)
        let events = AgentTimelinePlanner.transitionEvents(lastCycleAt: previous, now: previous.addingTimeInterval(120), checkIntervalSeconds: 20)
        XCTAssertEqual(events.map(\.type), [.monitoringDelayed])
        XCTAssertEqual(events.first?.timestamp, previous.addingTimeInterval(120))
        XCTAssertEqual(events.first?.details["powerStateInferred"], "false")
    }

    // testStatusAvailabilityRejectsMissingAndStaleSnapshots prevents false-green UI state.
    func testStatusAvailabilityRejectsMissingAndStaleSnapshots() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(AgentStatus.unavailable.availability(now: now, maximumAge: 60), .unavailable)
        let status = AgentStatus(
            timestamp: now.addingTimeInterval(-120),
            phase: "idle",
            enabledMounts: 0,
            healthyMounts: 0,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: nil
        )
        XCTAssertEqual(status.availability(now: now, maximumAge: 60), .stale)
    }

    // testReadOnlyCommandsDoNotFloodAudit verifies periodic GUI refreshes remain audit-free.
    func testReadOnlyCommandsDoNotFloodAudit() async {
        let paths = temporaryPaths()
        let service = CommandService(paths: paths)
        _ = await service.execute(CommandRequest(command: "status"), actor: "app")
        _ = await service.execute(CommandRequest(command: "diagnostics.events"), actor: "app")
        let audit = await RuntimeFileStore(paths: paths).recentAudit()
        XCTAssertTrue(audit.isEmpty)
    }

    // testCaptureAnalysisCreatesCitablePayloadFreeEvidence verifies the Wireshark-to-AI boundary.
    func testCaptureAnalysisCreatesCitablePayloadFreeEvidence() {
        let metadata = CaptureSessionMetadata(
            id: "capture-1",
            startedAt: Date(timeIntervalSince1970: 70_000),
            host: "192.0.2.10",
            interface: "eth0",
            filter: "tcp port 445",
            remotePath: "/var/lib/we-rock-drive-mounts/captures/test.pcapng",
            localPath: nil,
            sizeBytes: 1024
        )
        let analysis = CaptureAnalysis(
            ok: true,
            packetCount: 30,
            durationSeconds: 5,
            protocolCounts: ["smb2": 12, "tcp": 25],
            tcpRetransmissions: 2,
            tcpResetPackets: 1,
            icmpErrors: 0,
            conversationCount: 3,
            mirrorDuplicationPossible: true
        )
        let event = analysis.diagnosticEvent(metadata: metadata, localFile: URL(fileURLWithPath: "/tmp/test.pcapng"))
        XCTAssertEqual(event.type, .packetCapture)
        XCTAssertEqual(event.details["tcpRetransmissions"], "2")
        XCTAssertEqual(event.details["protocolCounts"], "smb2:12,tcp:25")
        XCTAssertEqual(event.details["mirrorDuplicationPossible"], "true")
        XCTAssertFalse(event.details.values.joined().contains("192.0.2.10"))
        XCTAssertEqual(event.evidencePath, "/tmp/test.pcapng")
    }

    // testCommandMountCRUDUsesValidatedSharedConfiguration covers the AI-operable mount lifecycle.
    func testCommandMountCRUDUsesValidatedSharedConfiguration() async throws {
        let paths = temporaryPaths()
        let service = CommandService(paths: paths)
        let added = await service.execute(CommandRequest(command: "mounts.add", arguments: ["Team Files", "smb://nas/team"]), actor: "test")
        XCTAssertEqual(added.code, "MOUNT_ADDED")
        let id = try XCTUnwrap(added.data["id"])

        let updated = await service.execute(CommandRequest(command: "mounts.update", arguments: [id, "Team Archive", "smb://nas/archive", "false"]), actor: "test")
        XCTAssertEqual(updated.code, "MOUNT_UPDATED")
        var settings = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(settings.mounts.first?.name, "Team Archive")
        XCTAssertFalse(try XCTUnwrap(settings.mounts.first?.enabled))

        let unconfirmed = await service.execute(CommandRequest(command: "mounts.remove", arguments: [id]), actor: "test")
        XCTAssertEqual(unconfirmed.code, "CONFIRMATION_REQUIRED")
        let removed = await service.execute(CommandRequest(command: "mounts.remove", arguments: [id], confirmed: true), actor: "test")
        XCTAssertEqual(removed.code, "MOUNT_REMOVED")
        settings = try await ConfigurationStore(paths: paths).load()
        XCTAssertTrue(settings.mounts.isEmpty)
    }

    // testEveryNonSecretGUISettingHasACommandKey verifies complete CLI and MCP configuration coverage.
    func testEveryNonSecretGUISettingHasACommandKey() async throws {
        let paths = temporaryPaths()
        let service = CommandService(
            paths: paths,
            loginItem: LoginItemService(paths: paths, appBundle: try fakeAppBundle(paths: paths), executeLaunchctl: false)
        )
        let evidenceID = UUID()
        let values: [(String, String)] = [
            ("general.enabled", "false"),
            ("general.openAppAtLogin", "true"),
            ("general.checkIntervalSeconds", "25"),
            ("general.bootDelaySeconds", "10"),
            ("general.maximumAutomaticRecoveryAttempts", "4"),
            ("general.mountTimeoutSeconds", "30"),
            ("general.smbHealthTimeoutSeconds", "6"),
            ("general.language", "german"),
            ("general.onboardingCompleted", "true"),
            ("network.preferredPortID", "automatic"),
            ("network.automaticTraffic", "true"),
            ("network.enabled", "true"),
            ("network.lanInterface", "en7"),
            ("network.wifiInterface", "en8"),
            ("network.wifiGraceMinutes", "18"),
            ("network.disableWifiWhenLanActive", "true"),
            ("network.enableWifiWhenLanUnhealthy", "true"),
            ("network.lanFailureThreshold", "2"),
            ("network.lanRecoveryStableChecks", "3"),
            ("network.gatewayHost", "192.0.2.1"),
            ("network.remoteReachabilityHosts", "192.0.2.2, 192.0.2.3"),
            ("network.trafficEnabled", "true"),
            ("network.trafficInterfaces", "en7,en8"),
            ("network.trafficMaxBytes", "2048"),
            ("diagnostics.enabled", "true"),
            ("diagnostics.networkEventsEnabled", "true"),
            ("diagnostics.sleepWakeEventsEnabled", "true"),
            ("diagnostics.macLogsEnabled", "true"),
            ("diagnostics.macLogLookbackMinutes", "45"),
            ("diagnostics.retentionDays", "20"),
            ("diagnostics.retentionIntervalMinutes", "45"),
            ("diagnostics.maximumStoreBytes", "4096"),
            ("diagnostics.redactPathsInExports", "true"),
            ("transfer.monitoringEnabled", "true"),
            ("transfer.highTrafficBytesPerSecond", "123456"),
            ("transfer.sustainedSeconds", "15"),
            ("transfer.rollingPiCaptureEnabled", "false"),
            ("transfer.incidentBundleOnFailure", "true"),
            ("transfer.defaultResumePolicy", "manual"),
            ("transfer.maximumAutoRetries", "2"),
            ("transfer.unlimitedAutoRetries", "true"),
            ("transfer.verifyAfterCopy", "true"),
            ("transfer.keepMacAwakeByDefault", "true"),
            ("packetCapture.enabled", "false"),
            ("packetCapture.host", "pi.example"),
            ("packetCapture.user", "capture"),
            ("packetCapture.interface", "eth1"),
            ("packetCapture.durationSeconds", "25"),
            ("packetCapture.remoteDirectory", "/var/lib/we-rock-drive-mounts/custom"),
            ("packetCapture.maximumFiles", "12"),
            ("packetCapture.maximumFileBytes", "8192"),
            ("synology.syslogEnabled", "true"),
            ("synology.syslogPort", "5515"),
            ("synology.readOnlySSHEnabled", "false"),
            ("synology.sshHost", "nas.example"),
            ("synology.sshUser", "observer"),
            ("synology.dsmAPIEnabled", "false"),
            ("synology.dsmBaseURL", "https://nas.example:5001"),
            ("synology.csvImportEnabled", "true"),
            ("ai.enabled", "true"),
            ("ai.provider", "local"),
            ("ai.actionMode", "guarded"),
            ("ai.cloudDataMode", "selectedRawLogs"),
            ("ai.openAIModel", "gpt-test"),
            ("ai.selectedEvidenceIDs", evidenceID.uuidString),
            ("wake.targetName", "Studio Mac"),
            ("wake.targetMACAddress", "00:11:22:33:44:55"),
            ("wake.targetHost", "192.0.2.10"),
            ("wake.route.raspberryPiLAN.command", "pi.example"),
            ("wake.route.raspberryPiLAN.enabled", "true"),
        ]

        for (key, value) in values {
            let result = await service.execute(CommandRequest(command: "config.set", arguments: [key, value], confirmed: true), actor: "test")
            XCTAssertTrue(result.ok, "Failed key \(key): \(result.message)")
        }
        let settings = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(settings.general.language, .german)
        XCTAssertTrue(settings.general.openAppAtLogin)
        XCTAssertEqual(settings.network.remoteReachabilityHosts, ["192.0.2.2", "192.0.2.3"])
        XCTAssertEqual(settings.packetCapture.remoteDirectory, "/var/lib/we-rock-drive-mounts/custom")
        XCTAssertEqual(settings.ai.selectedEvidenceIDs, [evidenceID])
        XCTAssertEqual(settings.wake.routes.first(where: { $0.kind == .raspberryPiLAN })?.command, "pi.example")
        XCTAssertTrue(settings.transfer.monitoringEnabled)
        XCTAssertEqual(settings.transfer.defaultResumePolicy, .manual)
        XCTAssertTrue(settings.transfer.unlimitedAutoRetries)
        XCTAssertTrue(try XCTUnwrap(settings.transfer.keepMacAwakeByDefault))
    }

    // testTransferSourceSelectionAndFinderHandoffStayGeneric covers file, folder, duplicate, and invalid inputs.
    func testTransferSourceSelectionAndFinderHandoffStayGeneric() throws {
        let paths = temporaryPaths()
        let sourceDirectory = paths.applicationSupport.appendingPathComponent("drop-folder", isDirectory: true)
        let sourceFile = paths.applicationSupport.appendingPathComponent("drop-file.bin")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sourceFile)

        let selected = try TransferSourceSelection.validatedPaths(from: [sourceFile, sourceDirectory, sourceFile])
        XCTAssertEqual(selected, [sourceFile.standardizedFileURL.path, sourceDirectory.standardizedFileURL.path])
        let handoff = try XCTUnwrap(TransferHandoff.makeURL(sourcePaths: selected))
        XCTAssertEqual(try TransferHandoff.sourceURLs(from: handoff).map(\.path), selected)
        XCTAssertThrowsError(try TransferHandoff.sourceURLs(from: URL(string: "https://example.invalid")!))
        XCTAssertThrowsError(try TransferSourceSelection.validatedPaths(from: [paths.applicationSupport.appendingPathComponent("missing")]))
    }

    // testTransferStatusSummaryUsesWeightedProgress proves the menu-bar percentage shares persisted job evidence.
    func testTransferStatusSummaryUsesWeightedProgress() {
        let first = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: ["/tmp/a"],
            destination: "/Volumes/NAS",
            state: .running,
            progress: TransferProgress(percent: 50, totalBytes: 100, completedBytes: 50),
            maximumAutoRetries: 1,
            verifyAfterCopy: true,
            createIncidentOnFailure: true
        )
        let second = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: ["/tmp/b"],
            destination: "/Volumes/NAS",
            state: .running,
            progress: TransferProgress(percent: 25, totalBytes: 300, completedBytes: 75),
            maximumAutoRetries: 1,
            verifyAfterCopy: true,
            createIncidentOnFailure: true
        )
        XCTAssertEqual(TransferStatusSummary.current(jobs: [first, second]), TransferStatusSummary(activeJobCount: 2, percent: 31))
        var completed = first
        completed.state = .completed
        XCTAssertEqual(TransferStatusSummary.current(jobs: [completed]), TransferStatusSummary(activeJobCount: 0, percent: nil))
    }

    // testTransferJobStorePersistsJobsAndIncidents proves transfer state is runtime data, not exported configuration.
    func testTransferJobStorePersistsJobsAndIncidents() async throws {
        let paths = temporaryPaths()
        let store = RuntimeFileStore(paths: paths)
        let job = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: ["/tmp/source"],
            destination: "/Volumes/NAS",
            maximumAutoRetries: 1,
            verifyAfterCopy: true,
            createIncidentOnFailure: true,
            keepMacAwake: true
        )
        try await store.upsertTransferJob(job)
        let storedJob = await store.readTransferJob(id: job.id)
        XCTAssertEqual(storedJob?.id, job.id)
        XCTAssertEqual(storedJob?.state, .queued)
        XCTAssertEqual(storedJob?.sources, ["/tmp/source"])
        XCTAssertEqual(storedJob?.destination, "/Volumes/NAS")
        XCTAssertTrue(try XCTUnwrap(storedJob?.keepMacAwake))

        let incident = TransferIncidentManifest(
            jobID: job.id,
            title: "Test incident",
            eventIDs: [],
            trafficSampleCount: 0,
            statusPhase: "idle"
        )
        try await store.appendTransferIncident(incident)
        let incidents = await store.recentTransferIncidents(limit: 10)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.id, incident.id)
        XCTAssertEqual(incidents.first?.jobID, job.id)

        let exported = try await ConfigurationStore(paths: paths).exportConfigurationData()
        let exportedText = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(exportedText.contains(job.id.uuidString))
    }

    // testUnlimitedRetryPolicyPreservesFiniteCountAndRejectsPermanentErrors proves the shared retry decision contract.
    func testUnlimitedRetryPolicyPreservesFiniteCountAndRejectsPermanentErrors() {
        var job = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .autoRetry,
            sources: ["/tmp/source"],
            destination: "/Volumes/NAS",
            state: .failed,
            attempts: 2,
            maximumAutoRetries: 1,
            verifyAfterCopy: true,
            createIncidentOnFailure: false,
            unlimitedAutoRetries: false,
            errorCode: "NATIVE_COPY_FAILED"
        )
        XCTAssertFalse(TransferService.shouldScheduleAutomaticRetry(job))
        job.unlimitedAutoRetries = true
        XCTAssertTrue(TransferService.shouldScheduleAutomaticRetry(job))
        job.errorCode = "PERMISSION_DENIED"
        XCTAssertFalse(TransferService.shouldScheduleAutomaticRetry(job))

        var settings = AppSettings.defaults.transfer
        settings.defaultResumePolicy = .autoRetry
        settings.maximumAutoRetries = 7
        settings.unlimitedAutoRetries = true
        XCTAssertFalse(settings.automaticRetryCountEditable)
        XCTAssertEqual(settings.maximumAutoRetries, 7)
        XCTAssertEqual(settings.automaticRetryMode, "unlimited")

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(TransferService.nextRetryDate(afterAttempt: 1, now: start), start.addingTimeInterval(5))
        XCTAssertEqual(TransferService.nextRetryDate(afterAttempt: 100, now: start), start.addingTimeInterval(300))
    }

    // testUnlimitedRetrySchedulerRunsBeyondFiniteLimitWithPersistentBackoff proves the agent-owned runtime path.
    func testUnlimitedRetrySchedulerRunsBeyondFiniteLimitWithPersistentBackoff() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let source = paths.applicationSupport.appendingPathComponent("retry-source.bin")
        let nasRoot = paths.applicationSupport.appendingPathComponent("Volumes/RetryNAS", isDirectory: true)
        let destination = nasRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source)
        let mount = MountDefinition(name: "RetryNAS", url: "smb://nas.local/RetryNAS")
        var settings = AppSettings.defaults
        settings.mounts = [mount]
        settings.transfer.defaultResumePolicy = .autoRetry
        settings.transfer.maximumAutoRetries = 0
        settings.transfer.unlimitedAutoRetries = true
        settings.transfer.incidentBundleOnFailure = false
        let status = AgentStatus(
            timestamp: Date(),
            phase: "idle",
            enabledMounts: 1,
            healthyMounts: 1,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: nil,
            mountStates: [MountRuntimeState(
                mountID: mount.id,
                timestamp: Date(),
                availability: .healthy,
                consecutiveFailures: 0,
                message: "Connected",
                localPath: nasRoot.path
            )]
        )
        let failingWorker = try executableScript(
            at: paths.applicationSupport.appendingPathComponent("failing-transfer-worker"),
            body: "#!/bin/sh\nexit 1\n"
        )
        let transfer = TransferService(paths: paths, runtimeStore: runtime, workerExecutablePath: failingWorker.path)
        let queued = try await transfer.start(
            request: TransferStartRequest(
                operation: .copy,
                direction: .macToNAS,
                resumePolicy: .autoRetry,
                unlimitedAutoRetries: true,
                sources: [source.path],
                destination: destination.path,
                keepMacAwake: false
            ),
            settings: settings,
            status: status
        )

        for expectedAttempt in 1...2 {
            if expectedAttempt == 2 {
                let persistedValue = await runtime.readTransferJob(id: queued.id)
                var persisted = try XCTUnwrap(persistedValue)
                persisted.nextRetryAt = Date.distantPast
                try await runtime.upsertTransferJob(persisted)
            }
            await transfer.reconcile(settings: settings, status: status)
            for _ in 0..<80 {
                let current = await runtime.readTransferJob(id: queued.id)
                if current?.state == .queued, current?.attempts == expectedAttempt, current?.nextRetryAt != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let scheduledValue = await runtime.readTransferJob(id: queued.id)
            let scheduled = try XCTUnwrap(scheduledValue)
            XCTAssertEqual(scheduled.state, .queued)
            XCTAssertEqual(scheduled.attempts, expectedAttempt)
            XCTAssertTrue(scheduled.unlimitedAutoRetries == true)
            XCTAssertGreaterThan(try XCTUnwrap(scheduled.nextRetryAt), Date())
        }

        let paused = try await transfer.pause(id: queued.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.maximumAutoRetries, 0)
        await transfer.stopAll()
    }

    // testCommandTransferCopiesThroughConfiguredMount proves transfer jobs are queued by commands and owned by the agent.
    func testCommandTransferCopiesThroughConfiguredMount() async throws {
        let paths = temporaryPaths()
        let sourceRoot = paths.applicationSupport.appendingPathComponent("source", isDirectory: true)
        let nasRoot = paths.applicationSupport.appendingPathComponent("Volumes/TestNAS", isDirectory: true)
        let destination = nasRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = sourceRoot.appendingPathComponent("payload.txt")
        try Data("transfer-payload".utf8).write(to: sourceFile)

        var settings = AppSettings.defaults
        let mount = MountDefinition(name: "TestNAS", url: "smb://nas.local/TestNAS")
        settings.mounts = [mount]
        settings.ai.actionMode = .autonomous
        try await ConfigurationStore(paths: paths).save(settings)
        try await RuntimeFileStore(paths: paths).writeStatus(AgentStatus(
            timestamp: Date(),
            phase: "idle",
            enabledMounts: 1,
            healthyMounts: 1,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: nil,
            mountStates: [
                MountRuntimeState(
                    mountID: mount.id,
                    timestamp: Date(),
                    availability: .healthy,
                    consecutiveFailures: 0,
                    message: "Connected",
                    localPath: nasRoot.path
                ),
            ]
        ))
        let status = await RuntimeFileStore(paths: paths).readStatus()

        let service = CommandService(paths: paths)
        let started = await service.execute(CommandRequest(
            command: "transfer.start",
            arguments: ["copy", "macToNAS", "ask", "true", "false", destination.path, sourceFile.path],
            confirmed: true
        ), actor: "test")
        XCTAssertEqual(started.code, "TRANSFER_QUEUED", started.message)
        let id = try XCTUnwrap(started.data["id"])
        let jobID = try XCTUnwrap(UUID(uuidString: id))
        let queuedJobValue = await RuntimeFileStore(paths: paths).readTransferJob(id: jobID)
        let queuedJob = try XCTUnwrap(queuedJobValue)
        XCTAssertEqual(queuedJob.state, .queued)
        XCTAssertEqual(queuedJob.ownedByAgent, true)
        XCTAssertTrue(queuedJob.keepMacAwake == true)
        XCTAssertFalse(queuedJob.unlimitedAutoRetries == true)

        let fakeWorker = try executableScript(
            at: paths.applicationSupport.appendingPathComponent("fake-transfer-worker"),
            body: "#!/bin/sh\n/bin/cp '\(sourceFile.path)' '\(destination.appendingPathComponent("payload.txt").path)'\n"
        )
        let transfer = TransferService(paths: paths, runtimeStore: RuntimeFileStore(paths: paths), workerExecutablePath: fakeWorker.path)
        for _ in 0..<80 {
            await transfer.reconcile(settings: settings, status: status)
            let current = await RuntimeFileStore(paths: paths).readTransferJob(id: jobID)
            if let state = current?.state, [.completed, .verified, .failed].contains(state) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let jobs = await RuntimeFileStore(paths: paths).readTransferJobs()
        let job = try XCTUnwrap(jobs.first { $0.id.uuidString == id })
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.ownedByAgent, true)
        XCTAssertGreaterThanOrEqual(job.progress.completedBytes ?? 0, UInt64("transfer-payload".utf8.count))
        XCTAssertNotNil(job.stdoutPath)
        XCTAssertNotNil(job.stderrPath)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload.txt"), encoding: .utf8), "transfer-payload")
    }

    // testCommandTransferStoresPerJobUnlimitedRetryChoice proves unlimited retry is chosen per transfer start.
    func testCommandTransferStoresPerJobUnlimitedRetryChoice() async throws {
        let paths = temporaryPaths()
        let source = paths.applicationSupport.appendingPathComponent("source.bin")
        let nasRoot = paths.applicationSupport.appendingPathComponent("Volumes/RetryChoiceNAS", isDirectory: true)
        let destination = nasRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: source)

        var settings = AppSettings.defaults
        let mount = MountDefinition(name: "RetryChoiceNAS", url: "smb://nas.local/RetryChoiceNAS")
        settings.mounts = [mount]
        settings.transfer.defaultResumePolicy = .ask
        settings.transfer.unlimitedAutoRetries = false
        settings.ai.actionMode = .autonomous
        try await ConfigurationStore(paths: paths).save(settings)
        try await RuntimeFileStore(paths: paths).writeStatus(AgentStatus(
            timestamp: Date(),
            phase: "idle",
            enabledMounts: 1,
            healthyMounts: 1,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: nil,
            mountStates: [MountRuntimeState(
                mountID: mount.id,
                timestamp: Date(),
                availability: .healthy,
                consecutiveFailures: 0,
                message: "Connected",
                localPath: nasRoot.path
            )]
        ))

        let result = await CommandService(paths: paths).execute(CommandRequest(
            command: "transfer.start",
            arguments: ["copy", "macToNAS", "autoRetry", "false", "true", destination.path, source.path],
            confirmed: true
        ), actor: "test")

        XCTAssertEqual(result.code, "TRANSFER_QUEUED", result.message)
        let id = try XCTUnwrap(result.data["id"])
        let jobID = try XCTUnwrap(UUID(uuidString: id))
        let jobValue = await RuntimeFileStore(paths: paths).readTransferJob(id: jobID)
        let job = try XCTUnwrap(jobValue)
        XCTAssertEqual(job.resumePolicy, .autoRetry)
        XCTAssertTrue(job.unlimitedAutoRetries == true)
        let reloadedSettings = try await ConfigurationStore(paths: paths).load()
        XCTAssertFalse(reloadedSettings.transfer.unlimitedAutoRetries)
    }

    // testNativeTransferWorkerCopiesPersistedJob proves the signed helper worker can copy and report progress itself.
    func testNativeTransferWorkerCopiesPersistedJob() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let sourceRoot = paths.applicationSupport.appendingPathComponent("native-source", isDirectory: true)
        let destination = paths.applicationSupport.appendingPathComponent("native-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = sourceRoot.appendingPathComponent("payload.txt")
        let emptyFile = sourceRoot.appendingPathComponent("empty.dat")
        let emptyDirectory = sourceRoot.appendingPathComponent("empty-directory", isDirectory: true)
        try Data("native-transfer-payload".utf8).write(to: sourceFile)
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyFile.path, contents: Data()))
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        var job = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: [sourceRoot.path],
            destination: destination.path,
            state: .running,
            maximumAutoRetries: 0,
            verifyAfterCopy: true,
            createIncidentOnFailure: false,
            ownedByAgent: true
        )
        job.runnerPID = 12345
        try await runtime.upsertTransferJob(job)

        let exitCode = await TransferService.runWorker(jobID: job.id, paths: paths)

        XCTAssertEqual(exitCode, 0)
        let updatedValue = await runtime.readTransferJob(id: job.id)
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.progress.completedBytes, UInt64("native-transfer-payload".utf8.count))
        XCTAssertEqual(updated.progress.completedFiles, 2)
        let copiedRoot = destination.appendingPathComponent("native-source", isDirectory: true)
        XCTAssertEqual(try String(contentsOf: copiedRoot.appendingPathComponent("payload.txt"), encoding: .utf8), "native-transfer-payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedRoot.appendingPathComponent("empty.dat").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedRoot.appendingPathComponent("empty-directory").path))
    }

    // testNativeTransferWorkerTracksZeroByteFiles proves file progress remains meaningful without byte progress.
    func testNativeTransferWorkerTracksZeroByteFiles() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let sourceRoot = paths.applicationSupport.appendingPathComponent("zero-byte-source", isDirectory: true)
        let destination = paths.applicationSupport.appendingPathComponent("zero-byte-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["first.dat", "second.dat", "third.dat"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: sourceRoot.appendingPathComponent(name).path, contents: Data()))
        }
        var job = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: [sourceRoot.path],
            destination: destination.path,
            state: .running,
            maximumAutoRetries: 0,
            verifyAfterCopy: true,
            createIncidentOnFailure: false,
            ownedByAgent: true
        )
        job.runnerPID = 12345
        try await runtime.upsertTransferJob(job)

        let exitCode = await TransferService.runWorker(jobID: job.id, paths: paths)

        XCTAssertEqual(exitCode, 0)
        let updatedValue = await runtime.readTransferJob(id: job.id)
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.progress.completedBytes, 0)
        XCTAssertEqual(updated.progress.completedFiles, 3)
        XCTAssertEqual(updated.progress.totalFiles, 3)
        XCTAssertEqual(updated.progress.percent, 100)
        let copiedRoot = destination.appendingPathComponent("zero-byte-source", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copiedRoot.path).count, 3)
    }

    // testTransferReconcileFailsOrphanedLegacyRunningJob proves stale pre-agent jobs become safe to resume.
    func testTransferReconcileFailsOrphanedLegacyRunningJob() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        var legacy = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .manual,
            sources: [paths.applicationSupport.appendingPathComponent("source.txt").path],
            destination: paths.applicationSupport.path,
            state: .running,
            maximumAutoRetries: 0,
            verifyAfterCopy: true,
            createIncidentOnFailure: false,
            ownedByAgent: false
        )
        legacy.runnerPID = nil
        try await runtime.upsertTransferJob(legacy)

        let transfer = TransferService(paths: paths, runtimeStore: runtime)
        await transfer.reconcile(settings: .defaults, status: .unavailable)

        let recoveredValue = await runtime.readTransferJob(id: legacy.id)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertEqual(recovered.errorCode, "RUNNER_UNKNOWN")
        XCTAssertEqual(recovered.runnerPID, nil)
    }

    // testTransferMonitoringRecordsSustainedHighTraffic proves the configured threshold affects runtime evidence.
    func testTransferMonitoringRecordsSustainedHighTraffic() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let sourceRoot = paths.applicationSupport.appendingPathComponent("high-source", isDirectory: true)
        let destination = paths.applicationSupport.appendingPathComponent("high-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("large.bin")
        let target = destination.appendingPathComponent("large.bin")
        let payload = Data(repeating: 7, count: 4096)
        try payload.write(to: source)
        try payload.write(to: target)
        let runner = paths.applicationSupport.appendingPathComponent("fake-transfer-runner", isDirectory: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        let fakeWorker = try executableScript(at: runner.appendingPathComponent("transfer-worker"), body: "#!/bin/sh\n/bin/sleep 30\n")
        let process = Process()
        process.executableURL = fakeWorker
        process.arguments = ["--transfer-worker", UUID().uuidString]
        try process.run()
        addTeardownBlock {
            if process.isRunning {
                process.terminate()
            }
        }

        var job = TransferJob(
            operation: .copy,
            direction: .macToNAS,
            resumePolicy: .ask,
            sources: [source.path],
            destination: destination.path,
            state: .running,
            progress: TransferProgress(
                totalBytes: UInt64(payload.count),
                completedBytes: UInt64(payload.count),
                bytesPerSecond: 2048,
                smoothedBytesPerSecond: 2048,
                lastProgressAt: Date().addingTimeInterval(-2),
                highTrafficSince: Date().addingTimeInterval(-2),
                snapshotAt: Date().addingTimeInterval(-2)
            ),
            maximumAutoRetries: 0,
            verifyAfterCopy: true,
            createIncidentOnFailure: false,
            ownedByAgent: true
        )
        job.runnerPID = process.processIdentifier
        try await runtime.upsertTransferJob(job)

        var settings = AppSettings.defaults
        settings.transfer.monitoringEnabled = true
        settings.transfer.highTrafficBytesPerSecond = 1
        settings.transfer.sustainedSeconds = 1
        settings.transfer.rollingPiCaptureEnabled = false

        let transfer = TransferService(paths: paths, runtimeStore: runtime)
        await transfer.reconcile(settings: settings, status: .unavailable)

        let monitoredValue = await runtime.readTransferJob(id: job.id)
        let monitored: TransferJob = try XCTUnwrap(monitoredValue)
        XCTAssertNotNil(monitored.progress.smoothedBytesPerSecond)
        XCTAssertGreaterThanOrEqual(monitored.progress.highTrafficSeconds ?? 0, 1)
        XCTAssertFalse(monitored.evidenceIDs.isEmpty)
        let events = await runtime.recentEvents(limit: 10)
        XCTAssertTrue(events.contains { event in
            event.summary == "Transfer high-traffic monitoring active"
                && event.details["jobID"] == job.id.uuidString
        })
    }

    // testTransferKeepAwakeAssertionFollowsWorkerLifecycle proves the agent acquires and releases idle-sleep prevention.
    func testTransferKeepAwakeAssertionFollowsWorkerLifecycle() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let source = paths.applicationSupport.appendingPathComponent("awake-source.bin")
        let nasRoot = paths.applicationSupport.appendingPathComponent("Volumes/AwakeNAS", isDirectory: true)
        let destination = nasRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 1024).write(to: source)
        let mount = MountDefinition(name: "AwakeNAS", url: "smb://nas.local/AwakeNAS")
        var settings = AppSettings.defaults
        settings.mounts = [mount]
        let status = AgentStatus(
            timestamp: Date(),
            phase: "idle",
            enabledMounts: 1,
            healthyMounts: 1,
            lanHealthy: true,
            wifiEnabled: false,
            fallbackActive: false,
            lastError: nil,
            mountStates: [MountRuntimeState(mountID: mount.id, timestamp: Date(), availability: .healthy, consecutiveFailures: 0, message: "Connected", localPath: nasRoot.path)]
        )
        let worker = try executableScript(
            at: paths.applicationSupport.appendingPathComponent("awake-worker"),
            body: "#!/bin/sh\n/bin/sleep 30\n"
        )
        let transfer = TransferService(paths: paths, runtimeStore: runtime, workerExecutablePath: worker.path)
        let queued = try await transfer.start(
            request: TransferStartRequest(
                operation: .copy,
                direction: .macToNAS,
                resumePolicy: .manual,
                unlimitedAutoRetries: false,
                sources: [source.path],
                destination: destination.path,
                keepMacAwake: true
            ),
            settings: settings,
            status: status
        )
        await transfer.reconcile(settings: settings, status: status)
        let runningValue = await runtime.readTransferJob(id: queued.id)
        let running = try XCTUnwrap(runningValue)
        XCTAssertEqual(running.state, .running)
        XCTAssertTrue(running.powerAssertionActive == true)
        let assertionPID = try XCTUnwrap(running.powerAssertionPID)
        XCTAssertTrue(processIsAlive(assertionPID))

        _ = try await transfer.stop(id: queued.id)
        for _ in 0..<40 {
            await transfer.reconcile(settings: settings, status: status)
            if let state = await runtime.readTransferJob(id: queued.id)?.state, state == .stopped { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let stoppedValue = await runtime.readTransferJob(id: queued.id)
        let stopped = try XCTUnwrap(stoppedValue)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.powerAssertionActive == true)
        XCTAssertNil(stopped.powerAssertionPID)
        for _ in 0..<40 where processIsAlive(assertionPID) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(processIsAlive(assertionPID))
        await transfer.stopAll()
    }

    // testUnknownCommandIsConfirmationRequired ensures new actions start conservatively.
    func testUnknownCommandIsConfirmationRequired() async {
        let service = CommandService(paths: temporaryPaths())
        XCTAssertEqual(service.riskForCommand("future.unknown"), .remoteMutation)
        let result = await service.execute(CommandRequest(command: "future.unknown"), actor: "test")
        XCTAssertEqual(result.code, "CONFIRMATION_REQUIRED")
    }

    // temporaryPaths isolates filesystem tests from the user's live configuration.
    private func temporaryPaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppPaths(homeDirectory: root)
    }

    // fakeAppBundle creates the minimum installed-app fixture required by login item validation.
    private func fakeAppBundle(paths: AppPaths) throws -> URL {
        let app = paths.homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("We Rock Drive Mounts.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    // executableScript creates one isolated process fixture for lifecycle tests.
    private func executableScript(at url: URL, body: String) throws -> URL {
        try Data(body.utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return url
    }

    // processIsAlive checks only a PID created by the current test fixture.
    private func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    // snapshot creates deterministic network evaluator evidence.
    private func snapshot(lanHealthy: Bool, route: String, wifi: Bool) -> NetworkSnapshot {
        NetworkSnapshot(
            lanHasAddress: lanHealthy,
            defaultRouteInterface: route,
            gatewayReachable: lanHealthy,
            remoteHostsReachable: lanHealthy,
            wifiEnabled: wifi
        )
    }
}
