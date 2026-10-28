import Foundation
import SystemConfiguration
import CryptoKit
import Darwin

// NetworkOptions contains native discovery preferences and explicitly opted-in hardware profiles.
public struct NetworkOptions: Codable, Equatable, Sendable {
    public var preferredPortID: String?
    public var unresolvedLegacyInterface: String?
    public var automaticTraffic = true
    public var profiles: [PortProfile] = []
    public init() {}
}

// MediaSetting distinguishes requested media from the mode actually negotiated by the driver.
public struct MediaSetting: Codable, Equatable, Sendable {
    public var subtype: String
    public var options: [String]
    public init(subtype: String, options: [String] = []) {
        self.subtype = subtype
        self.options = options.sorted()
    }
}

// NetworkPort is a timestamped inventory entry; nil evidence always means unknown, not failure.
public struct NetworkPort: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var serviceID: String
    public var name: String
    public var interface: String
    public var kind: String
    public var present: Bool
    public var enabled: Bool
    public var link: Bool?
    public var addresses: [String]
    public var networkID: String?
    public var hardwareID: String?
    public var configuredMedia: MediaSetting?
    public var routerIPv4: String? = nil
    public var activeMedia: MediaSetting?
    public var availableMedia: [MediaSetting]
    public var hardwareMode: String?
    public var configuredMTU: Int?
    public var mtu: Int?
    public var minimumMTU: Int?
    public var maximumMTU: Int?
    public var avb: Bool?
    public var rank: Int
    public var observedAt: Date
    public var errors: [String]

    // speedMbps uses known Darwin media names without guessing from a device's marketing name.
    public var speedMbps: Int? {
        guard let value = activeMedia?.subtype.lowercased() else { return nil }
        for (prefix, speed) in [("100g",100000),("40g",40000),("25g",25000),("10g",10000),("5g",5000),("2500",2500),("2.5g",2500),("1000",1000),("100",100),("10",10)] {
            if value.hasPrefix(prefix) { return speed }
        }
        return nil
    }
    public var usable: Bool { enabled && present && link == true && !addresses.isEmpty }
}

// PortProfile binds each optional desired field to one positively identified adapter and network.
public struct PortProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var portID: String
    public var networkID: String
    public var enabled = false
    public var mode: String?
    public var media: MediaSetting?
    public var speedMbps: Int?
    public var duplex: String?
    public var mtu: Int?
    public var flowControl: Bool?

    // init captures a baseline only when the caller explicitly requests it.
    public init(port: NetworkPort, networkID: String) {
        portID = port.id
        self.networkID = networkID
        mode = port.hardwareMode
        media = port.configuredMedia
        speedMbps = port.speedMbps
        duplex = port.activeMedia?.options.first { $0.contains("duplex") }
        mtu = port.mtu
    }
}

// NetworkInventory records all configured services, including disconnected ones and both IP families.
public struct NetworkInventory: Codable, Equatable, Sendable {
    public var timestamp = Date()
    public var locationID: String?
    public var ports: [NetworkPort] = []
    public var serviceOrder: [String] = []
    public var defaultIPv4: String?
    public var defaultIPv6: String?
    public var errors: [String] = []
    public init() {}

    // selected prefers only eligible wired services and never treats a bridge or phone as LAN.
    public func selected(options: NetworkOptions) -> NetworkPort? {
        let eligible = ports.filter { $0.kind == "ethernet" && $0.usable }
        return eligible.first { $0.id == options.preferredPortID } ?? eligible.sorted { $0.rank < $1.rank }.first
    }
    // migratedOptions is deterministic and accepts inventory evidence from the migration boundary.
    public func migratedOptions(policy: NetworkPolicy) -> NetworkOptions {
        var options = NetworkOptions()
        options.automaticTraffic = policy.trafficInterfaces == ["en0", "en1", "en10"]
        let matches = ports.filter { $0.interface == policy.lanInterface && $0.kind == "ethernet" && $0.hardwareID != nil }
        if matches.count == 1 { options.preferredPortID = matches[0].id }
        else { options.unresolvedLegacyInterface = policy.lanInterface }
        return options
    }
    public var wifi: NetworkPort? { ports.first { $0.kind == "wifi" && $0.present } }
}

// NativeNetworkInventory reads SystemConfiguration without mutating preferences or the live network.
public enum NativeNetworkInventory {
    // fingerprint is deliberately local; exports must pseudonymize these stable identifiers again.
    public static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func read() -> NetworkInventory {
        var result = NetworkInventory()
        guard let preferences = SCPreferencesCreate(nil, "WRDM inventory" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let store = SCDynamicStoreCreate(nil, "WRDM inventory" as CFString, nil, nil) else {
            result.errors = ["SYSTEM_CONFIGURATION_UNAVAILABLE"]
            return result
        }
        result.locationID = SCNetworkSetGetSetID(set) as String?
        result.serviceOrder = SCNetworkSetGetServiceOrder(set) as? [String] ?? []
        let v4 = dictionary(store, "State:/Network/Global/IPv4")
        let v6 = dictionary(store, "State:/Network/Global/IPv6")
        result.defaultIPv4 = v4["PrimaryInterface"] as? String
        result.defaultIPv6 = v6["PrimaryInterface"] as? String
        for service in SCNetworkSetCopyServices(set) as? [SCNetworkService] ?? [] {
            guard let device = SCNetworkServiceGetInterface(service) else { continue }
            let bsd = SCNetworkInterfaceGetBSDName(device) as String? ?? ""
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(device) as String? ?? "unknown"
            let display = SCNetworkInterfaceGetLocalizedDisplayName(device) as String? ?? name
            let lower = (name + " " + display).lowercased()
            let kind: String
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = "wifi" }
            else if lower.contains("iphone") || lower.contains("ipad") { kind = "tethering" }
            else if type == (kSCNetworkInterfaceTypeEthernet as String) { kind = "ethernet" }
            else { kind = type.lowercased() }
            let mac = SCNetworkInterfaceGetHardwareAddressString(device) as String?
            let hardwareID = mac.map { fingerprint(type + ":" + $0) }
            let ipv4 = dictionary(store, "State:/Network/Service/\(serviceID)/IPv4")
            let ipv6 = dictionary(store, "State:/Network/Service/\(serviceID)/IPv6")
            let addresses = ((ipv4["Addresses"] as? [String] ?? []) + (ipv6["Addresses"] as? [String] ?? []))
                .filter { !$0.hasPrefix("169.254.") && !$0.hasPrefix("fe80:") }
            // A subnet or location name alone is not a trustworthy network identity.
            let signature = (ipv4["NetworkSignature"] as? String) ?? (ipv6["NetworkSignature"] as? String)
            let gatewayMAC = ipv4["ARPResolvedHardwareAddress"] as? String
            let router = ipv4["Router"] as? String
            let networkID = signature.map(fingerprint) ?? ((gatewayMAC != nil && router != nil) ? fingerprint(gatewayMAC! + ":" + router!) : nil)
            let config = SCNetworkInterfaceGetConfiguration(device) as? [String: Any] ?? [:]
            var current: Unmanaged<CFDictionary>?
            var active: Unmanaged<CFDictionary>?
            var available: Unmanaged<CFArray>?
            let mediaOK = SCNetworkInterfaceCopyMediaOptions(device, &current, &active, &available, true)
            let requested = current?.takeRetainedValue() as? [String: Any]
            let negotiated = active?.takeRetainedValue() as? [String: Any]
            let choices = available?.takeRetainedValue() as? [[String: Any]] ?? []
            var mtu: Int32 = 0, minimum: Int32 = 0, maximum: Int32 = 0
            let mtuOK = SCNetworkInterfaceCopyMTU(device, &mtu, &minimum, &maximum)
            let link = dictionary(store, "State:/Network/Interface/\(bsd)/Link")["Active"] as? Bool
            let present = if_nametoindex(bsd) != 0
            let configuredMTU = (config["MTU"] as? NSNumber)?.intValue
            // The Hardware panel is manual when preferences contain overrides, even with autoselect media.
            let mode = config["MediaSubType"] != nil || configuredMTU != nil ? "manual" : "automatic"
            var port = NetworkPort(
                id: fingerprint(serviceID + ":" + (hardwareID ?? "unknown")), serviceID: serviceID,
                name: name, interface: bsd, kind: kind, present: present,
                enabled: SCNetworkServiceGetEnabled(service), link: present ? link : false,
                addresses: addresses, networkID: networkID, hardwareID: hardwareID,
                configuredMedia: requested.flatMap(media), activeMedia: negotiated.flatMap(media),
                availableMedia: choices.compactMap(media), hardwareMode: mediaOK ? mode : nil,
                configuredMTU: configuredMTU, mtu: mtuOK ? Int(mtu) : nil,
                minimumMTU: mtuOK ? Int(minimum) : nil, maximumMTU: mtuOK ? Int(maximum) : nil,
                avb: config["AV"] as? Bool, rank: result.serviceOrder.firstIndex(of: serviceID) ?? Int.max,
                observedAt: result.timestamp, errors: mediaOK ? [] : ["MEDIA_UNAVAILABLE"]
            )
            port.routerIPv4 = router
            result.ports.append(port)
        }
        result.ports.sort { $0.rank < $1.rank }
        return result
    }

    // dictionary retains no CF objects beyond the read-only inventory pass.
    private static func dictionary(_ store: SCDynamicStore, _ key: String) -> [String: Any] {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
    }
    private static func media(_ value: [String: Any]) -> MediaSetting? {
        guard let subtype = value["MediaSubType"] as? String else { return nil }
        return MediaSetting(subtype: subtype, options: value["MediaOptions"] as? [String] ?? [])
    }
}
