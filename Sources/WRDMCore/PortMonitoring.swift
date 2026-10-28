import Foundation

// PortWarning includes stable identity and evidence while keeping absent hardware separate from drift.
public struct PortWarning: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var portID: String
    public var state: String
    public var differences: [String]
    public var firstObserved: Date
    public var lastMatching: Date?
    public var consecutive: Int
}

// PortMonitor is a pure evaluator so reconnects and debounce behavior can be tested without hardware.
public enum PortMonitor {
    public static func evaluate(profiles: [PortProfile], inventory: NetworkInventory, previous: [PortWarning], periodic: Bool) -> [PortWarning] {
        profiles.filter(\.enabled).map { profile in
            let old = previous.first { $0.id == profile.id }
            var warning = PortWarning(id: profile.id, portID: profile.portID, state: "unknown", differences: [],
                                      firstObserved: inventory.timestamp, lastMatching: old?.lastMatching, consecutive: 0)
            guard let port = inventory.ports.first(where: { $0.id == profile.portID }), port.present else {
                warning.state = "disconnected"; return warning
            }
            guard port.hardwareID != nil, let network = port.networkID else { return warning }
            guard network == profile.networkID else { warning.state = "inactive"; return warning }
            guard port.link == true else { warning.state = "disconnected"; return warning }
            let differences = differences(profile: profile, port: port)
            guard !differences.contains(where: { $0.hasPrefix("UNKNOWN:") }) else {
                warning.differences = differences; return warning
            }
            if differences.isEmpty {
                warning.state = "matching"; warning.lastMatching = inventory.timestamp; return warning
            }
            warning.differences = differences
            let same = old?.differences == differences && ["pending", "deviation"].contains(old?.state ?? "")
            warning.consecutive = (same ? old?.consecutive ?? 0 : 0) + (periodic ? 1 : 0)
            warning.firstObserved = same ? old!.firstObserved : inventory.timestamp
            warning.state = warning.consecutive >= 2 ? "deviation" : "pending"
            return warning
        }
    }

    // differences compares only fields the user elected to monitor, preserving unknown values.
    public static func differences(profile: PortProfile, port: NetworkPort) -> [String] {
        var result: [String] = []
        func compare<T: Equatable>(_ field: String, _ desired: T?, _ actual: T?) {
            guard let desired else { return }
            guard let actual else { result.append("UNKNOWN:\(field)"); return }
            if desired != actual { result.append("\(field): \(actual) → \(desired)") }
        }
        compare("mode", profile.mode, port.hardwareMode)
        compare("media", profile.media, port.configuredMedia)
        compare("speedMbps", profile.speedMbps, port.speedMbps)
        compare("duplex", profile.duplex, port.activeMedia?.options.first { $0.contains("duplex") })
        compare("mtu", profile.mtu, port.mtu)
        compare("flowControl", profile.flowControl, port.activeMedia.map { $0.options.contains("flow-control") })
        return result
    }
}
