import Foundation
import Network

// NetworkProbe records destination-specific evidence separately from physical connectivity.
public struct NetworkProbe: Codable, Equatable, Sendable {
    public var host: String
    public var interface: String
    public var port: UInt16
    public var reachable: Bool
    public var error: String?
    public var routeInterface: String?
    public var dnsStatus: String?
    public var tcpStatus: String?
    public var resolvedAddress: String?
    public var systemRouteInterface: String?
    public var routeError: String?
}

// NetworkObservation is safe to collect for status/export: it never changes Wi-Fi or preferences.
public struct NetworkObservation: Codable, Equatable, Sendable {
    public var inventory: NetworkInventory
    public var selectedPortID: String?
    public var probes: [NetworkProbe]
    public var safeToDisableWiFi: Bool
    public var reasons: [String]
    public var revision: String
    public var timestamp: Date
    public var routerDiagnostic: String?
    public var selected: NetworkPort? { inventory.ports.first { $0.id == selectedPortID } }

    // collect checks actual bound TCP paths rather than equating a missing ICMP reply with no cable.
    public static func collect(settings: AppSettings, inventory: NetworkInventory = NativeNetworkInventory.read(),
                               probe: (String, UInt16, String, Date) -> NetworkProbe = { BoundNetworkProbe.check(host: $0, port: $1, interface: $2, deadline: $3) }) -> NetworkObservation {
        let deadline = Date().addingTimeInterval(8)
        let options = settings.network.discovery ?? NetworkOptions()
        let selected = inventory.selected(options: options)
        var reasons: [String] = inventory.errors
        var probes: [NetworkProbe] = []
        if options.unresolvedLegacyInterface != nil { reasons.append("INTERFACE_SELECTION_REQUIRED") }
        if selected == nil { reasons.append("NO_USABLE_ETHERNET") }
        if let selected {
            let routes = [inventory.defaultIPv4, inventory.defaultIPv6].compactMap { $0 }
            if routes.isEmpty { reasons.append("DEFAULT_ROUTE_UNKNOWN") }
            if routes.contains(where: { $0 != selected.interface }) { reasons.append("DEFAULT_ROUTE_NOT_ETHERNET") }
            let servers = Set(settings.mounts.filter(\.enabled).compactMap { mount -> SMBProbeTarget? in
                guard let url = URL(string: mount.url), let host = url.host, let port = UInt16(exactly: url.port ?? 445) else { return nil }
                return SMBProbeTarget(host: host, port: port)
            })
            for target in servers.sorted(by: { $0.host == $1.host ? $0.port < $1.port : $0.host < $1.host }) {
                let host = target.host
                let wired = probe(host, target.port, selected.interface, deadline)
                if let error = wired.routeError { reasons.append(error) }
                if let route = wired.systemRouteInterface, route != selected.interface { reasons.append("TARGET_ROUTE_NOT_ETHERNET") }
                probes.append(wired)
                if !wired.reachable, let wifi = inventory.wifi {
                    let wireless = probe(host, target.port, wifi.interface, deadline)
                    probes.append(wireless)
                    if wireless.reachable { reasons.append("SMB_REQUIRES_WIFI") }
                    else { reasons.append("SMB_REACHABILITY_UNKNOWN") }
                } else if !wired.reachable { reasons.append("SMB_REACHABILITY_UNKNOWN") }
            }
            // Explicit additional targets are TCP services: host:port or a URL, defaulting to HTTPS.
            for raw in settings.network.remoteReachabilityHosts {
                let url = URL(string: raw.contains("://") ? raw : "https://" + raw)
                guard let host = url?.host, let port = UInt16(exactly: url?.port ?? 443) else {
                    reasons.append("INVALID_REQUIRED_TARGET"); continue
                }
                let result = probe(host, port, selected.interface, deadline)
                probes.append(result)
                if let error = result.routeError { reasons.append(error) }
                if let route = result.systemRouteInterface, route != selected.interface { reasons.append("TARGET_ROUTE_NOT_ETHERNET") }
                if !result.reachable { reasons.append("REQUIRED_TARGET_UNREACHABLE") }
            }
            // With no protected endpoint, a link and default route alone cannot prove safe shutdown.
            if probes.isEmpty { reasons.append("NO_VERIFIED_TARGET") }
        }
        // ICMP is diagnostic only and never contributes to the shutdown decision.
        var routerDiagnostic = "UNAVAILABLE"
        if let selected, let router = selected.routerIPv4,
           let source = selected.addresses.first(where: { !$0.contains(":") }), deadline > Date() {
            let echo = try? ProcessRunner.run("/sbin/ping", arguments: ["-n", "-S", source, "-c", "1", "-W", "500", router],
                                            timeout: min(1, deadline.timeIntervalSinceNow))
            routerDiagnostic = echo?.exitCode == 0 ? "REACHABLE" : "UNCONFIRMED"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let revision = NativeNetworkInventory.fingerprint(String(decoding: (try? encoder.encode(settings)) ?? Data(), as: UTF8.self))
        return NetworkObservation(inventory: inventory, selectedPortID: selected?.id, probes: probes,
                                  safeToDisableWiFi: reasons.isEmpty, reasons: Array(Set(reasons)).sorted(),
                                  revision: revision, timestamp: Date(), routerDiagnostic: routerDiagnostic)
    }
}

// ProbeResult owns callback state across Network.framework queues without racing timeout cancellation.
private final class ProbeResult: @unchecked Sendable {
    let lock = NSLock()
    var interface: NWInterface?
    var ready = false
    var finished = false
    var failure = "TCP_TIMEOUT"
    var address: String?
    let signal = DispatchSemaphore(value: 0)
    func finish(_ success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        ready = success; finished = true; signal.signal()
    }
}

// BoundNetworkProbe requires the exact interface for both hostname-based and address-based connections.
public enum BoundNetworkProbe {
    public static func check(host: String, port: UInt16, interface: String, deadline: Date = Date().addingTimeInterval(5)) -> NetworkProbe {
        guard deadline > Date() else { return NetworkProbe(host: host, interface: interface, port: port, reachable: false, error: "PROBE_DEADLINE") }
        let queue = DispatchQueue(label: "com.we-rock.bound-probe")
        let state = ProbeResult()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            state.lock.lock()
            state.interface = path.availableInterfaces.first { $0.name == interface }
            state.lock.unlock()
            state.signal.signal()
        }
        monitor.start(queue: queue)
        _ = state.signal.wait(timeout: .now() + min(2, max(0, deadline.timeIntervalSinceNow)))
        monitor.cancel()
        state.lock.lock(); let device = state.interface; state.lock.unlock()
        guard let device, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return NetworkProbe(host: host, interface: interface, port: port, reachable: false, error: "INTERFACE_UNAVAILABLE")
        }
        let result = ProbeResult()
        let parameters = NWParameters.tcp
        parameters.requiredInterface = device
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        connection.stateUpdateHandler = { status in
            switch status {
            case .ready:
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    result.lock.lock()
                    switch host {
                    case .ipv4(let address): result.address = String(describing: address)
                    case .ipv6(let address): result.address = String(describing: address)
                    default: break
                    }
                    result.lock.unlock()
                }
                result.finish(true)
            case .failed(let error):
                result.lock.lock()
                if case .dns = error { result.failure = "DNS_UNAVAILABLE" } else { result.failure = "TCP_UNAVAILABLE" }
                result.lock.unlock()
                result.finish(false)
            case .cancelled: result.finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        _ = result.signal.wait(timeout: .now() + min(3, max(0, deadline.timeIntervalSinceNow)))
        result.lock.lock(); let ready = result.ready; let failure = result.failure; let address = result.address; result.lock.unlock()
        connection.cancel()
        connection.stateUpdateHandler = nil
        var probe = NetworkProbe(host: host, interface: interface, port: port, reachable: ready, error: ready ? nil : failure,
                                 routeInterface: ready ? interface : nil, dnsStatus: ready ? "resolved" : failure == "DNS_UNAVAILABLE" ? "failed" : "unknown",
                                 tcpStatus: ready ? "connected" : "unconfirmed", resolvedAddress: address)
        // Inspect the ordinary route separately from the explicitly bound test connection.
        if let address, deadline > Date(), let route = try? ProcessRunner.run("/sbin/route",
            arguments: ["-n", "get", address.contains(":") ? "-inet6" : "-inet", address], timeout: min(1, deadline.timeIntervalSinceNow)), route.exitCode == 0 {
            probe.systemRouteInterface = route.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("interface:") }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if probe.systemRouteInterface == nil { probe.routeError = "TARGET_ROUTE_UNKNOWN" }
        return probe
    }
}

// SMBProbeTarget keeps custom ports distinct even when several shares use the same hostname.
private struct SMBProbeTarget: Hashable {
    let host: String
    let port: UInt16
}
