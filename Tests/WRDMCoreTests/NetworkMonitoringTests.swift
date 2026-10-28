import Foundation
import XCTest
@testable import WRDMCore

// NetworkMonitoringTests exercise synthetic adapters; no test changes the host's network configuration.
final class NetworkMonitoringTests: XCTestCase {
    private func port(_ id: String = "sonnet", interface: String = "en6", kind: String = "ethernet", rank: Int = 0) -> NetworkPort {
        NetworkPort(id: id, serviceID: "service-" + id, name: "Thunderbolt Ethernet Slot 0", interface: interface, kind: kind,
                    present: true, enabled: true, link: true, addresses: ["192.0.2.6"], networkID: "network-a", hardwareID: "hardware-" + id,
                    configuredMedia: MediaSetting(subtype: "10Gbase-T", options: ["full-duplex", "flow-control"]),
                    activeMedia: MediaSetting(subtype: "10Gbase-T", options: ["full-duplex", "flow-control"]),
                    availableMedia: [MediaSetting(subtype: "10Gbase-T", options: ["full-duplex", "flow-control"]), MediaSetting(subtype: "autoselect")],
                    hardwareMode: "manual", configuredMTU: 9000, mtu: 9000, minimumMTU: 1280, maximumMTU: 9000, avb: true,
                    rank: rank, observedAt: Date(), errors: [])
    }
    private func inventory() -> NetworkInventory {
        var value = NetworkInventory()
        value.ports = [port(), port("wifi", interface: "en0", kind: "wifi", rank: 1)]
        value.serviceOrder = value.ports.map(\.serviceID)
        value.defaultIPv4 = "en6"
        return value
    }
    private func observation(_ value: NetworkInventory) -> NetworkObservation {
        NetworkObservation(inventory: value, selectedPortID: value.ports[0].id, probes: [], safeToDisableWiFi: true, reasons: [], revision: "fixture", timestamp: Date())
    }
    private func snapshot(_ value: NetworkInventory) -> NetworkSnapshot {
        var valueSnapshot = NetworkSnapshot(lanHasAddress: true, defaultRouteInterface: "en6", gatewayReachable: false, remoteHostsReachable: true, wifiEnabled: true)
        valueSnapshot.observation = observation(value); valueSnapshot.periodic = true
        return valueSnapshot
    }

    // The supplied incident had healthy LAN and mounts while Wi-Fi recovery was pending, not absent Ethernet.
    func testSupportIncidentEn6IsUsableDespiteBlockedPing() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "network-support-redacted", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(fixture["ethernetInterface"] as? String, "en6")
        XCTAssertEqual(fixture["healthyMounts"] as? Int, 8)
        XCTAssertEqual(fixture["enabledMounts"] as? Int, 8)
        XCTAssertEqual(fixture["lanHealthy"] as? Bool, true)
        let value = inventory()
        XCTAssertEqual(value.selected(options: NetworkOptions())?.interface, "en6")
        XCTAssertEqual(value.ports.first?.speedMbps, 10000)
        XCTAssertTrue(snapshot(value).lanHealthy)
        var policy = NetworkPolicy.defaults; policy.enabled = true
        var state = NetworkPolicyState.empty; state.fallbackActive = true
        for index in 1...3 {
            let action = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot(value), state: &state)
            XCTAssertEqual(state.lanRecoveryCount, index)
            if index < 3 { XCTAssertEqual(action, .none("Waiting for stable LAN recovery")) }
            else { XCTAssertEqual(action, .disableWiFi("LAN recovered after three stable checks")) }
            XCTAssertNil(state.wifiGraceUntil)
        }
    }
    func testEventsDoNotCountAndNetworkChangeResetsStability() {
        var policy = NetworkPolicy.defaults; policy.enabled = true
        var state = NetworkPolicyState.empty; state.fallbackActive = true
        var value = inventory()
        _ = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot(value), state: &state)
        var event = snapshot(value); event.periodic = false
        _ = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: event, state: &state)
        XCTAssertEqual(state.lanRecoveryCount, 1)
        value.ports[0].networkID = "network-b"
        _ = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot(value), state: &state)
        XCTAssertEqual(state.lanRecoveryCount, 1)
        var unknown = snapshot(value); unknown.observation?.safeToDisableWiFi = false
        _ = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: unknown, state: &state)
        XCTAssertEqual(state.lanRecoveryCount, 0)
    }
    func testExplicitWindowSurvivesRecoveryAndStateRoundTrip() throws {
        var state = NetworkPolicyState.empty; state.fallbackActive = true; state.explicitGrace = true
        let now = Date(timeIntervalSince1970: 10000); state.wifiGraceUntil = now.addingTimeInterval(900)
        var policy = NetworkPolicy.defaults; policy.enabled = true
        for _ in 0..<3 { _ = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot(inventory()), state: &state, now: now) }
        state = try NetworkFiles.decode(NetworkPolicyState.self, from: NetworkFiles.encode(state))
        XCTAssertEqual(NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot(inventory()), state: &state, now: now.addingTimeInterval(899)), .none("Temporary Wi-Fi window is active"))
        XCTAssertEqual(state.wifiGraceUntil, now.addingTimeInterval(900))
    }
    func testMissingIPPhoneAndBridgeNeverBecomeEthernet() {
        var value = inventory()
        value.ports[0].addresses = []
        value.ports.append(port("phone", interface: "en7", kind: "tethering"))
        value.ports.append(port("bridge", interface: "bridge0", kind: "bridge"))
        XCTAssertNil(value.selected(options: NetworkOptions()))
        value.ports[0].addresses = ["2001:db8::6"]
        XCTAssertNotNil(value.selected(options: NetworkOptions()))
    }
    func testMigrationPreservesCustomTrafficAndStableIdentityAcrossBSDChanges() {
        var value = inventory(); var policy = NetworkPolicy.defaults; policy.lanInterface = "en6"
        XCTAssertTrue(value.migratedOptions(policy: policy).automaticTraffic)
        policy.trafficInterfaces = ["en6"]
        let options = value.migratedOptions(policy: policy)
        XCTAssertFalse(options.automaticTraffic)
        value.ports[0].interface = "en9"
        XCTAssertEqual(value.selected(options: options)?.interface, "en9")
        XCTAssertEqual(value.migratedOptions(policy: policy).unresolvedLegacyInterface, "en6")
    }
    func testPriorityRetainsOtherServicesAndDisconnectedEthernet() {
        var value = inventory()
        var display = port("display", interface: "en5", rank: 4); display.link = false
        value.ports.append(display)
        value.serviceOrder = ["vpn", "service-wifi", "service-display", "bridge", "service-sonnet"]
        let order = NetworkChanges.priority(value, preferred: "sonnet")
        XCTAssertEqual(order, ["vpn", "service-sonnet", "service-display", "bridge", "service-wifi"])
        XCTAssertEqual(Set(order), Set(value.serviceOrder))
    }
    func testProfileDriftNeedsTwoPeriodicSamplesAndStopsOutsideNetwork() {
        var value = inventory(); var profile = PortProfile(port: value.ports[0], networkID: "network-a"); profile.enabled = true
        value.ports[0].mtu = 1500; value.ports[0].hardwareMode = "automatic"
        value.ports[0].activeMedia = MediaSetting(subtype: "1000baseT", options: ["full-duplex"])
        var warnings = PortMonitor.evaluate(profiles: [profile], inventory: value, previous: [], periodic: true)
        XCTAssertEqual(warnings[0].state, "pending")
        warnings = PortMonitor.evaluate(profiles: [profile], inventory: value, previous: warnings, periodic: false)
        XCTAssertEqual(warnings[0].state, "pending")
        warnings = PortMonitor.evaluate(profiles: [profile], inventory: value, previous: warnings, periodic: true)
        XCTAssertEqual(warnings[0].state, "deviation")
        XCTAssertEqual(warnings[0].differences.count, 3)
        let first = warnings[0].firstObserved
        warnings = PortMonitor.evaluate(profiles: [profile], inventory: value, previous: warnings, periodic: true)
        XCTAssertEqual(warnings[0].firstObserved, first)
        value.ports[0].networkID = "network-b"
        XCTAssertEqual(PortMonitor.evaluate(profiles: [profile], inventory: value, previous: warnings, periodic: true)[0].state, "inactive")
        value.ports[0].present = false
        XCTAssertEqual(PortMonitor.evaluate(profiles: [profile], inventory: value, previous: warnings, periodic: true)[0].state, "disconnected")
    }
    func testUnknownAndDisabledProfilesDoNotClaimDrift() {
        var value = inventory(); var profile = PortProfile(port: value.ports[0], networkID: "network-a")
        XCTAssertTrue(PortMonitor.evaluate(profiles: [profile], inventory: value, previous: [], periodic: true).isEmpty)
        profile.enabled = true; value.ports[0].mtu = nil
        XCTAssertEqual(PortMonitor.evaluate(profiles: [profile], inventory: value, previous: [], periodic: true)[0].state, "unknown")
    }
    func testUnsupportedMTUAndUnknownIdentityRejectRestoration() {
        var port = port(); var profile = PortProfile(port: port, networkID: "network-a"); profile.enabled = true
        profile.mtu = 10000
        XCTAssertThrowsError(try NetworkChanges.validate(profile: profile, port: port))
        profile.mtu = 9000; port.networkID = nil
        XCTAssertThrowsError(try NetworkChanges.validate(profile: profile, port: port))
    }
    func testExternalApplyNeverPromptsOrMutates() throws {
        let paths = AppPaths(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try NetworkChanges(paths: paths).apply(id: UUID(), interactive: false, transfersActive: false, settings: .defaults)) {
            XCTAssertTrue($0.localizedDescription.contains("INTERACTIVE_AUTHORIZATION_REQUIRED"))
        }
        XCTAssertThrowsError(try NetworkChanges(paths: paths).apply(id: UUID(), interactive: true, transfersActive: true, settings: .defaults)) {
            XCTAssertTrue($0.localizedDescription.contains("ACTIVE_TRANSFERS"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.homeDirectory.path))
    }
    func testDestinationProbeFailureProtectsWiFiRegardlessOfPing() {
        var settings = AppSettings.defaults; settings.network.remoteReachabilityHosts = ["nas.invalid:445"]
        let good = NetworkObservation.collect(settings: settings, inventory: inventory()) { host, port, interface, _ in
            NetworkProbe(host: host, interface: interface, port: port, reachable: true, error: nil)
        }
        XCTAssertTrue(good.safeToDisableWiFi)
        let bad = NetworkObservation.collect(settings: settings, inventory: inventory()) { host, port, interface, _ in
            NetworkProbe(host: host, interface: interface, port: port, reachable: false, error: "DNS_UNAVAILABLE")
        }
        XCTAssertFalse(bad.safeToDisableWiFi)
        XCTAssertTrue(bad.reasons.contains("REQUIRED_TARGET_UNREACHABLE"))
        var vpn = inventory(); vpn.defaultIPv6 = "utun4"
        let uncertain = NetworkObservation.collect(settings: settings, inventory: vpn) { host, port, interface, _ in
            NetworkProbe(host: host, interface: interface, port: port, reachable: true, error: nil)
        }
        XCTAssertTrue(uncertain.reasons.contains("DEFAULT_ROUTE_NOT_ETHERNET"))
    }
    // Archive publication is collision-safe, redacts new fields, and never changes network policy state.
    func testZIPRoundTripRedactionAndReadOnlyExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root); try paths.ensureDirectories()
        let destination = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = NetworkFiles(paths: paths)
        try files.saveState(.empty)
        let before = try Data(contentsOf: paths.networkPolicyFile)
        let report = NetworkReport(observation: observation(inventory()), policyState: .empty,
            execution: NetworkPolicyExecution(timestamp: Date(), requestedAction: .none, reason: "Waiting for stable LAN recovery", mutationAttempted: false, mutationSucceeded: nil, observedWiFiEnabled: true, fallbackActive: true, error: nil),
            warnings: [], trigger: "fixture", agentVersion: "0.3.2")
        try SecureFileAccess.writeAtomically(NetworkFiles.encode(report), to: files.reportURL)
        let service = DiagnosticsService(paths: paths)
        var settings = AppSettings.defaults; settings.mounts = []; settings.network.remoteReachabilityHosts = []
        let first = try service.exportSupportArchive(settings: settings, status: .unavailable, events: [], traffic: [], destination: destination)
        let second = try service.exportSupportArchive(settings: settings, status: .unavailable, events: [], traffic: [], destination: destination)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "zip")
        XCTAssertEqual(try ProcessRunner.run("/usr/bin/unzip", arguments: ["-t", first.path]).exitCode, 0)
        let network = try ProcessRunner.run("/usr/bin/unzip", arguments: ["-p", first.path, "*/network.json"]).stdout
        XCTAssertTrue(network.contains("lastAgentDecision"))
        XCTAssertTrue(network.contains("exportObservation"))
        XCTAssertFalse(network.contains("192.0.2.6"))
        XCTAssertFalse(network.contains("hardware-sonnet"))
        XCTAssertFalse(network.contains("Thunderbolt Ethernet Slot 0"))
        XCTAssertEqual(try Data(contentsOf: paths.networkPolicyFile), before)
        XCTAssertThrowsError(try service.exportSupportArchive(settings: settings, status: .unavailable, events: [], traffic: [], destination: root.appendingPathComponent("absent")))
    }

    func testCorruptArchiveIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an archive".utf8).write(to: file)
        XCTAssertThrowsError(try DiagnosticsService.validateArchive(file))
    }
    func testMTUOnlyRestorationPreservesMediaAndAutoselect9000IsSupported() throws {
        let port = port(); var profile = PortProfile(port: port, networkID: "network-a"); profile.enabled = true
        profile.mode = nil; profile.media = nil; profile.speedMbps = nil; profile.duplex = nil; profile.flowControl = nil
        XCTAssertNil(try NetworkChanges.desiredMedia(profile: profile, port: port))
        profile.mode = "manual"; profile.media = MediaSetting(subtype: "autoselect")
        XCTAssertEqual(try NetworkChanges.desiredMedia(profile: profile, port: port)?.subtype, "autoselect")
        XCTAssertNoThrow(try NetworkChanges.validate(profile: profile, port: port))
        XCTAssertEqual(profile.mtu, 9000)
    }
    func testConflictingDesiredMediaIsRejectedBeforeAuthorization() {
        let port = port(); var profile = PortProfile(port: port, networkID: "network-a"); profile.enabled = true
        profile.mode = "automatic"
        XCTAssertThrowsError(try NetworkChanges.validate(profile: profile, port: port))
    }
    func testFreshUserWindowCannotBeOverwrittenByAnEarlierObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = NetworkFiles(paths: AppPaths(homeDirectory: root))
        let capturedBeforeUserAction = snapshot(inventory())
        var state = NetworkPolicyState.empty; state.fallbackActive = true; state.lanRecoveryCount = 3
        let now = Date(timeIntervalSince1970: 10000)
        try SecureFileAccess.withLock(for: files.operationLock) {
            state.wifiGraceUntil = now.addingTimeInterval(900); state.explicitGrace = true
            try files.saveState(state)
        }
        var policy = NetworkPolicy.defaults; policy.enabled = true
        let result = try SecureFileAccess.withLock(for: files.operationLock) {
            var fresh = files.state()
            let action = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: capturedBeforeUserAction, state: &fresh, now: now)
            try files.saveState(fresh)
            return action
        }
        XCTAssertEqual(result, .none("Temporary Wi-Fi window is active"))
        XCTAssertEqual(files.state().wifiGraceUntil, now.addingTimeInterval(900))
    }

    // Partial apply failure permits one rollback only while the original device and network are still proven.
    func testRestorationVerificationRejectsForeignIdentityAndDistinguishesUnknown() {
        let before = inventory(); var profile = PortProfile(port: before.ports[0], networkID: "network-a"); profile.enabled = true
        let proposal = NetworkChangePreview(kind: "hardware", before: before, order: before.serviceOrder, profile: profile, summary: [])
        let baseline = observation(before)
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: before, baseline: baseline, post: baseline, applied: true), .verified)
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: before, baseline: baseline, post: baseline, applied: false), .rollback)
        var changed = before; changed.ports[0].networkID = "different-network"
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: changed, baseline: baseline, post: baseline, applied: false), .unknown)
        changed = before; changed.ports[0].mtu = nil
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: changed, baseline: baseline, post: baseline, applied: true), .pending)
        changed = before; changed.ports[0].mtu = 1500
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: changed, baseline: baseline, post: baseline, applied: true), .rollback)
        var protected = baseline
        protected.probes = [NetworkProbe(host: "nas.invalid", interface: "en6", port: 445, reachable: true, error: nil)]
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: before, baseline: protected, post: baseline, applied: true), .pending)
        var lost = protected; lost.probes[0].reachable = false; lost.probes[0].error = "TCP_UNAVAILABLE"
        XCTAssertEqual(NetworkChanges.verify(proposal: proposal, after: before, baseline: protected, post: lost, applied: true), .rollback)
    }

}
