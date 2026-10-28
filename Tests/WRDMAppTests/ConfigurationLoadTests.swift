import Foundation
import XCTest
@testable import WRDMCore
@testable import WRDMApp

// A failed upgrade must expose an unavailable form and must not save default toggle values.
final class ConfigurationLoadTests: XCTestCase {
    // Immediate switches persist their own value while preserving unrelated form drafts.
    @MainActor
    func testImmediateWiFiSwitchDoesNotSaveOtherDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        var initial = AppSettings.defaults
        initial.general.onboardingCompleted = true
        try await ConfigurationStore(paths: paths).save(initial)
        let model = AppModel(paths: paths)
        try await model.loadConfiguration()
        XCTAssertTrue(model.configurationLoaded)
        let originalInterval = model.settings.general.checkIntervalSeconds
        model.settings.general.checkIntervalSeconds = originalInterval + 5
        model.immediateToggle(\.network.disableWifiWhenLanActive, key: "network.disableWifiWhenLanActive").wrappedValue = false
        for _ in 0..<100 {
            if try await ConfigurationStore(paths: paths).load().network.disableWifiWhenLanActive == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let persisted = try await ConfigurationStore(paths: paths).load()
        XCTAssertFalse(persisted.network.disableWifiWhenLanActive)
        XCTAssertEqual(persisted.general.checkIntervalSeconds, originalInterval)
        XCTAssertTrue(model.hasUnsavedSettings)
    }

    @MainActor
    func testUnreadableSettingsBlockTogglesAndActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let data = try PropertyListSerialization.data(fromPropertyList: ["schemaVersion": 99], format: .xml, options: 0)
        try data.write(to: paths.configFile)
        let model = AppModel(paths: paths)
        XCTAssertFalse(model.configurationLoaded)
        await model.reloadAll()
        XCTAssertFalse(model.configurationLoaded)
        XCTAssertFalse(model.showOnboarding)
        XCTAssertNotNil(model.lastError)
        let defaults = model.settings
        model.setOpenAppAtLogin(true)
        model.mutate { $0.general.enabled.toggle() }
        XCTAssertEqual(model.settings, defaults)
        let action = await model.run("app.login.reconcile", confirmed: true)
        XCTAssertEqual(action.code, "CONFIG_UNAVAILABLE")
        XCTAssertEqual(try Data(contentsOf: paths.configFile), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgents.appendingPathComponent(LoginItemService.label + ".plist").path))
    }
    // A slow mount cycle must not hide fresh Ethernet observations in the overview.
    @MainActor
    func testNetworkFreshnessIsIndependentOfMountRecovery() {
        let model = AppModel(paths: AppPaths(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var inventory = NetworkInventory()
        inventory.ports = [NetworkPort(id: "adapter", serviceID: "service", name: "Thunderbolt Ethernet", interface: "en6", kind: "ethernet",
            present: true, enabled: true, link: true, addresses: ["192.0.2.6"], networkID: "network", hardwareID: "hardware",
            configuredMedia: nil, activeMedia: nil, availableMedia: [], hardwareMode: nil, configuredMTU: 9000, mtu: 9000,
            minimumMTU: 1280, maximumMTU: 9000, avb: nil, rank: 0, observedAt: Date(), errors: [])]
        let observation = NetworkObservation(inventory: inventory, selectedPortID: "adapter", probes: [], safeToDisableWiFi: true, reasons: [], revision: "fixture", timestamp: Date())
        let execution = NetworkPolicyExecution(timestamp: Date(), requestedAction: .none, reason: "Waiting for stable LAN recovery", mutationAttempted: false, mutationSucceeded: nil, observedWiFiEnabled: true, fallbackActive: true, error: nil)
        model.networkReport = NetworkReport(observation: observation, policyState: .empty, execution: execution, warnings: [], trigger: "fixture")
        model.status = .unavailable
        XCTAssertFalse(model.statusOperational)
        XCTAssertTrue(model.ethernetConnected)
        model.networkReport?.observation.timestamp = Date().addingTimeInterval(-3600)
        XCTAssertFalse(model.ethernetConnected)
    }

    // Generic command localization must retain the actual failure reason.
    @MainActor
    func testCommandFailurePreservesActionableCause() {
        let model = AppModel(paths: AppPaths(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let message = "Destination permission denied: fixture"
        XCTAssertEqual(model.localizedCommandMessage(CommandResult(ok: false, code: "COMMAND_FAILED", message: message)), message)
    }

}
