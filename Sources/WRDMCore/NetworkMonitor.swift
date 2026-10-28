import Foundation
import Network
import SystemConfiguration
import OSLog

// NetworkReport publishes the latest observation and the exact persisted decision independently of mounts.
public struct NetworkReport: Codable, Equatable, Sendable {
    public var observation: NetworkObservation
    public var policyState: NetworkPolicyState
    public var execution: NetworkPolicyExecution
    public var warnings: [PortWarning]
    public var trigger: String
    public var agentVersion: String?
    public var powerContext: [DiagnosticEvent]?
}

// NetworkFiles is the single cross-process storage boundary for monitoring and user network actions.
public struct NetworkFiles: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths = AppPaths()) { self.paths = paths }
    public var reportURL: URL { paths.state.appendingPathComponent("network-report.json") }
    public var historyURL: URL { paths.diagnostics.appendingPathComponent("network-history.json") }
    public var operationLock: URL { paths.state.appendingPathComponent("network-operation") }

    // encode/decode share ISO date rules with support exports and existing runtime files.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public func report() -> NetworkReport? { read(NetworkReport.self, at: reportURL) }
    public func state() -> NetworkPolicyState { read(NetworkPolicyState.self, at: paths.networkPolicyFile) ?? .empty }
    public func history() -> [NetworkReport] { read([NetworkReport].self, at: historyURL) ?? [] }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decode(type, from: data)
    }
    public func saveState(_ state: NetworkPolicyState) throws {
        try SecureFileAccess.writeAtomically(Self.encode(state), to: paths.networkPolicyFile)
    }

    // tick holds the action lock through observation, decision, mutation and verified publication.
    public func tick(settings: AppSettings, periodic: Bool, trigger: String = "periodic") throws -> NetworkReport {
        let observation = NetworkObservation.collect(settings: settings)
        return try SecureFileAccess.withLock(for: operationLock) {
            if let data = try? Data(contentsOf: paths.configFile) {
                guard let applied = try? PropertyListDecoder().decode(AppSettings.self, from: data), applied == settings else {
                    throw NetworkChangeError.rejected("CONFIGURATION_CHANGED_DURING_OBSERVATION")
                }
            }
            let old = report()
            // A preferences edit during observation invalidates this decision instead of applying stale data.
            let currentInventory = NativeNetworkInventory.read()
            let identity = observation.selected
            let currentPort = currentInventory.ports.first { $0.id == identity?.id }
            guard currentPort?.networkID == identity?.networkID, currentPort?.configuredMedia == identity?.configuredMedia,
                  currentPort?.configuredMTU == identity?.configuredMTU else { throw NetworkChangeError.rejected("OBSERVATION_INVALIDATED") }
            var state = state()
            if let old, observation.timestamp.timeIntervalSince(old.observation.timestamp) > Double(max(5, settings.general.checkIntervalSeconds) * 2) {
                state.lanRecoveryCount = 0
            }
            var policy = settings.network
            policy.enabled = settings.general.enabled && policy.enabled
            policy.wifiInterface = observation.inventory.wifi?.interface ?? "unavailable"
            policy.lanInterface = observation.selected?.interface ?? "unavailable"
            let network = NetworkService()
            let wifi = network.readWiFiEnabled(interface: policy.wifiInterface)
            var snapshot = NetworkSnapshot(lanHasAddress: observation.selected?.usable == true,
                defaultRouteInterface: observation.inventory.defaultIPv4 ?? observation.inventory.defaultIPv6 ?? "",
                gatewayReachable: observation.safeToDisableWiFi, remoteHostsReachable: observation.safeToDisableWiFi,
                wifiEnabled: wifi ?? true)
            snapshot.observation = observation; snapshot.periodic = periodic
            // Unknown Wi-Fi state must not cause a speculative radio mutation.
            if wifi == nil { policy.enabled = false }
            var transferProtected = false
            // Preserve active transfers even when the target is reachable on an alternate interface.
            if snapshot.wifiEnabled, let data = try? Data(contentsOf: paths.transferJobsFile) {
                let jobs = try Self.decode([TransferJob].self, from: data)
                if jobs.contains(where: { [.running, .queued].contains($0.state) }) { policy.disableWifiWhenLanActive = false; transferProtected = true }
            }
            var execution = network.apply(policy: policy, snapshot: snapshot, state: &state)
            if wifi == nil { execution.error = "WIFI_STATUS_UNKNOWN" }
            if transferProtected { execution.reason = "ACTIVE_TRANSFERS" }
            if execution.requestedAction == .disableWiFi && execution.mutationSucceeded == true {
                let post = NetworkObservation.collect(settings: settings)
                if !post.safeToDisableWiFi {
                    let restored = network.setWiFi(interface: policy.wifiInterface, enabled: true)
                    execution.observedWiFiEnabled = network.readWiFiEnabled(interface: policy.wifiInterface) ?? false
                    execution.mutationSucceeded = false
                    execution.error = restored && execution.observedWiFiEnabled ? "POSTCHECK_FAILED_WIFI_RESTORED" : "POSTCHECK_FAILED_OUTCOME_UNKNOWN"
                    state.fallbackActive = execution.observedWiFiEnabled
                    state.lanRecoveryCount = 0
                }
            }
            state.lastWiFiEnabled = execution.observedWiFiEnabled
            let warnings = PortMonitor.evaluate(profiles: settings.network.discovery?.profiles ?? [], inventory: observation.inventory,
                                               previous: old?.warnings ?? [], periodic: periodic)
            if settings.network.trafficEnabled && periodic {
                let interfaces = settings.network.discovery?.automaticTraffic != false
                    ? observation.inventory.ports.filter { ["ethernet", "wifi"].contains($0.kind) && $0.present }.map(\.interface)
                    : settings.network.trafficInterfaces
                for interface in Set(interfaces) {
                    if let (sample, counter) = network.trafficSample(interface: interface, previous: state.trafficCounters[interface]) {
                        state.trafficCounters[interface] = counter
                        // Traffic samples retain the existing bounded JSONL store and retention policy.
                        let file = paths.trafficFile
                        try SecureFileAccess.withLock(for: file) {
                            var data = (try? Data(contentsOf: file)) ?? Data()
                            data.append(try Self.encode(sample)); data.append(0x0a)
                            if data.count > settings.network.trafficMaxBytes {
                                data = Data(data.suffix(settings.network.trafficMaxBytes))
                                if let newline = data.firstIndex(of: 0x0a) { data = Data(data.suffix(from: data.index(after: newline))) }
                            }
                            try SecureFileAccess.writeAtomically(data, to: file)
                        }
                    }
                }
            }
            var report = NetworkReport(observation: observation, policyState: state, execution: execution, warnings: warnings, trigger: trigger, agentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
            if settings.diagnostics.enabled && settings.diagnostics.sleepWakeEventsEnabled,
               let events = try? Data(contentsOf: paths.eventsFile) {
                report.powerContext = events.split(separator: 0x0a).suffix(200).compactMap {
                    try? Self.decode(DiagnosticEvent.self, from: Data($0))
                }.filter { [.wake, .sleep].contains($0.type) && $0.timestamp > Date().addingTimeInterval(-300) }
            }
            try saveState(state)
            try SecureFileAccess.writeAtomically(Self.encode(report), to: reportURL)
            if settings.diagnostics.enabled && settings.diagnostics.networkEventsEnabled {
                let cutoff = Date().addingTimeInterval(-Double(settings.diagnostics.retentionDays) * 86400)
                var entries = history().filter { $0.observation.timestamp >= cutoff }
                let changed = trigger == "startup" || old?.agentVersion != report.agentVersion || old?.execution.reason != execution.reason || old?.observation.reasons != observation.reasons
                    || old?.observation.selectedPortID != observation.selectedPortID || old?.warnings.map { $0.state + $0.differences.joined() } != warnings.map { $0.state + $0.differences.joined() }
                    || execution.mutationAttempted || old?.policyState.wifiGraceUntil != state.wifiGraceUntil
                if changed { entries.append(report) }
                entries = Array(entries.suffix(200))
                while try Self.encode(entries).count > min(settings.diagnostics.maximumStoreBytes, 2_000_000), !entries.isEmpty { entries.removeFirst() }
                try SecureFileAccess.writeAtomically(Self.encode(entries), to: historyURL)
            } else {
                // Disabling the collector stops historical retention; operational status remains available.
                try? FileManager.default.removeItem(at: historyURL)
            }
            return report
        }
    }
}

// NetworkChangeSignal coalesces native path events without counting them as periodic stability checks.
private final class NetworkChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    func consume() -> Bool { lock.lock(); defer { lock.unlock() }; let result = changed; changed = false; return result }
}

// NetworkMonitor runs outside the mount actor so slow SMB recovery never suspends network observation.
public enum NetworkMonitor {
    public static func run(paths: AppPaths) async {
        let signal = NetworkChangeSignal()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in signal.mark() }
        monitor.start(queue: DispatchQueue(label: "com.we-rock.network-events"))
        defer { monitor.cancel() }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(signal).toOpaque(), retain: { info in
            _ = Unmanaged<NetworkChangeSignal>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        }, release: { info in
            Unmanaged<NetworkChangeSignal>.fromOpaque(info).release()
        }, copyDescription: nil)
        let store = SCDynamicStoreCreate(nil, "WRDM network events" as CFString, { _, _, info in
            if let info { Unmanaged<NetworkChangeSignal>.fromOpaque(info).takeUnretainedValue().mark() }
        }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, nil, ["State:/Network/.*", "Setup:/Network/.*"] as CFArray)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue(label: "com.we-rock.network-configuration"))
        }
        defer { if let store { SCDynamicStoreSetDispatchQueue(store, nil) } }
        let configuration = ConfigurationStore(paths: paths)
        let files = NetworkFiles(paths: paths)
        var next = Date.distantPast
        var first = true
        while !Task.isCancelled {
            if let settings = try? await configuration.load() {
                let periodic = Date() >= next
                let changed = signal.consume()
                if periodic || changed {
                    let started = Date()
                    do { _ = try files.tick(settings: settings, periodic: periodic, trigger: first ? "startup" : periodic ? "periodic" : "network-change"); first = false }
                    catch { Logger(subsystem: "com.we-rock.drive-mounts", category: "network").error("Network observation failed: \(error.localizedDescription, privacy: .public)") }
                    if periodic { next = started.addingTimeInterval(Double(max(5, settings.general.checkIntervalSeconds))) }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
