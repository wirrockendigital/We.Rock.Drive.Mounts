import Foundation

// NetworkSnapshot contains the evidence used for one policy decision.
public struct NetworkSnapshot: Codable, Equatable, Sendable {
    // Rich observation separates a connected port from permission to shut Wi-Fi down.
    public var observation: NetworkObservation?
    public var periodic: Bool?
    public var timestamp: Date
    public var lanHasAddress: Bool
    public var defaultRouteInterface: String
    public var gatewayReachable: Bool
    public var dnsReachable: Bool
    public var remoteHostsReachable: Bool
    public var wifiEnabled: Bool

    public var lanHealthy: Bool {
        observation.map { $0.selected?.usable == true } ?? (lanHasAddress && gatewayReachable && dnsReachable && remoteHostsReachable)
    }

    // init creates an evaluator input from observed or test evidence.
    public init(
        timestamp: Date = Date(),
        lanHasAddress: Bool,
        defaultRouteInterface: String,
        gatewayReachable: Bool,
        dnsReachable: Bool = true,
        remoteHostsReachable: Bool,
        wifiEnabled: Bool
    ) {
        self.timestamp = timestamp
        self.lanHasAddress = lanHasAddress
        self.defaultRouteInterface = defaultRouteInterface
        self.gatewayReachable = gatewayReachable
        self.dnsReachable = dnsReachable
        self.remoteHostsReachable = remoteHostsReachable
        self.wifiEnabled = wifiEnabled
    }
}

// NetworkPolicyState persists debounce counters and the user's temporary Wi-Fi window.
public struct NetworkPolicyState: Codable, Equatable, Sendable {
    // Optional fields decode existing state without resetting a user's outstanding grace window.
    public var contextID: String?
    public var lastWiFiEnabled: Bool?
    public var explicitGrace: Bool?
    public var lanFailureCount: Int
    public var lanRecoveryCount: Int
    public var fallbackActive: Bool
    public var wifiGraceUntil: Date?
    public var trafficCounters: [String: TrafficCounter]

    public static let empty = NetworkPolicyState(
        lanFailureCount: 0,
        lanRecoveryCount: 0,
        fallbackActive: false,
        wifiGraceUntil: nil,
        trafficCounters: [:]
    )

    // init creates explicit persisted evaluator state.
    public init(
        lanFailureCount: Int,
        lanRecoveryCount: Int,
        fallbackActive: Bool,
        wifiGraceUntil: Date?,
        trafficCounters: [String: TrafficCounter]
    ) {
        self.lanFailureCount = lanFailureCount
        self.lanRecoveryCount = lanRecoveryCount
        self.fallbackActive = fallbackActive
        self.wifiGraceUntil = wifiGraceUntil
        self.trafficCounters = trafficCounters
    }
}

// TrafficCounter stores the previous monotonic interface totals.
public struct TrafficCounter: Codable, Equatable, Sendable {
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var timestamp: Date?

    // init records one pair of monotonic interface counters.
    public init(receivedBytes: UInt64, sentBytes: UInt64, timestamp: Date? = Date()) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.timestamp = timestamp
    }
}

// NetworkPolicyAction is a pure decision that adapters can apply or suppress.
public enum NetworkPolicyAction: Equatable, Sendable {
    case none(String)
    case enableWiFi(String)
    case disableWiFi(String)
}

// NetworkPolicyActionKind is the persisted representation of an evaluator decision.
public enum NetworkPolicyActionKind: String, Codable, Equatable, Sendable {
    case none
    case enableWiFi
    case disableWiFi
}

// NetworkPolicyExecution records requested work separately from the observed adapter outcome.
public struct NetworkPolicyExecution: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var requestedAction: NetworkPolicyActionKind
    public var reason: String
    public var mutationAttempted: Bool
    public var mutationSucceeded: Bool?
    public var observedWiFiEnabled: Bool
    public var fallbackActive: Bool
    public var error: String?

    // init creates one status-safe execution result without command output or secrets.
    public init(
        timestamp: Date,
        requestedAction: NetworkPolicyActionKind,
        reason: String,
        mutationAttempted: Bool,
        mutationSucceeded: Bool?,
        observedWiFiEnabled: Bool,
        fallbackActive: Bool,
        error: String?
    ) {
        self.timestamp = timestamp
        self.requestedAction = requestedAction
        self.reason = reason
        self.mutationAttempted = mutationAttempted
        self.mutationSucceeded = mutationSucceeded
        self.observedWiFiEnabled = observedWiFiEnabled
        self.fallbackActive = fallbackActive
        self.error = error
    }
}

// NetworkPolicyEvaluator keeps safety behavior deterministic and testable.
public enum NetworkPolicyEvaluator {
    public static func evaluate(
        policy: NetworkPolicy,
        snapshot: NetworkSnapshot,
        state: inout NetworkPolicyState,
        now: Date = Date()
    ) -> NetworkPolicyAction {
        guard policy.enabled else {
            state.lanFailureCount = 0
            state.lanRecoveryCount = 0
            state.fallbackActive = false
            return .none("Network policy is disabled")
        }

        let identity = snapshot.observation.map { ($0.selectedPortID ?? "none") + ":" + ($0.selected?.networkID ?? "unknown") }
        if identity != state.contextID {
            state.lanRecoveryCount = 0
            state.contextID = identity
        }
        // An externally observed off-to-on transition is a deliberate user window, never recovery.
        if snapshot.wifiEnabled && state.lastWiFiEnabled == false && !state.fallbackActive {
            state.wifiGraceUntil = now.addingTimeInterval(Double(policy.wifiGraceMinutes) * 60)
            state.explicitGrace = true
        }
        state.lastWiFiEnabled = snapshot.wifiEnabled
        if !snapshot.lanHealthy || (snapshot.observation?.safeToDisableWiFi == false && !snapshot.wifiEnabled) {
            state.lanFailureCount += 1
            state.lanRecoveryCount = 0
            guard policy.enableWifiWhenLanUnhealthy,
                  state.lanFailureCount >= policy.lanFailureThreshold else {
                return .none("Waiting for LAN failure threshold")
            }
            if snapshot.wifiEnabled {
                state.fallbackActive = true
                return .none("Wi-Fi fallback is already active")
            }
            return .enableWiFi("LAN is unhealthy; enabling Wi-Fi fallback")
        }
        state.lanFailureCount = 0
        let safe = snapshot.observation?.safeToDisableWiFi ?? snapshot.lanHealthy
        guard safe else {
            state.lanRecoveryCount = 0
            return .none(snapshot.observation?.reasons.joined(separator: ", ") ?? "Connectivity unknown")
        }
        if snapshot.periodic != false { state.lanRecoveryCount = min(3, state.lanRecoveryCount + 1) }
        guard policy.disableWifiWhenLanActive else { return .none("LAN is healthy and no Wi-Fi action is needed") }
        guard snapshot.wifiEnabled else {
            state.wifiGraceUntil = nil
            state.explicitGrace = false
            state.fallbackActive = false
            return .none("LAN is healthy and Wi-Fi is already off")
        }
        if let until = state.wifiGraceUntil, until > now {
            return .none("Temporary Wi-Fi window is active")
        }
        if !state.fallbackActive && state.wifiGraceUntil == nil {
            state.wifiGraceUntil = now.addingTimeInterval(Double(policy.wifiGraceMinutes) * 60)
            state.explicitGrace = true
            return .none("Wi-Fi was enabled manually; temporary window started")
        }
        guard state.lanRecoveryCount >= 3 else {
            return .none("Waiting for stable LAN recovery")
        }
        return .disableWiFi(state.fallbackActive ? "LAN recovered after three stable checks" : "LAN is stable and the Wi-Fi window expired")
    }

    // reconcile records adapter truth and updates fallback state only after an observed mutation outcome.
    public static func reconcile(
        action: NetworkPolicyAction,
        snapshot: NetworkSnapshot,
        mutationSucceeded: Bool?,
        observedWiFiEnabled: Bool,
        state: inout NetworkPolicyState,
        now: Date
    ) -> NetworkPolicyExecution {
        let actionKind: NetworkPolicyActionKind
        let reason: String
        switch action {
        case .enableWiFi(let message):
            actionKind = .enableWiFi
            reason = message
        case .disableWiFi(let message):
            actionKind = .disableWiFi
            reason = message
        case .none(let message):
            actionKind = .none
            reason = message
        }
        let mutationAttempted = actionKind != .none
        let matchedRequestedState = switch actionKind {
        case .enableWiFi: observedWiFiEnabled
        case .disableWiFi: !observedWiFiEnabled
        case .none: observedWiFiEnabled == snapshot.wifiEnabled
        }
        if actionKind == .enableWiFi {
            state.fallbackActive = mutationSucceeded == true && matchedRequestedState
        } else if actionKind == .disableWiFi, mutationSucceeded == true, matchedRequestedState {
            state.fallbackActive = false
            state.wifiGraceUntil = nil
        }
        let error = mutationAttempted && (mutationSucceeded != true || !matchedRequestedState)
            ? "Wi-Fi command did not reach the requested observed state"
            : nil
        return NetworkPolicyExecution(
            timestamp: now,
            requestedAction: actionKind,
            reason: reason,
            mutationAttempted: mutationAttempted,
            mutationSucceeded: mutationSucceeded,
            observedWiFiEnabled: observedWiFiEnabled,
            fallbackActive: state.fallbackActive,
            error: error
        )
    }
}

// NetworkService gathers evidence and applies only evaluator-approved Wi-Fi actions.
public struct NetworkService: Sendable {
    public init() {}

    // apply reuses an already captured snapshot and verifies the resulting Wi-Fi power state.
    public func apply(
        policy: NetworkPolicy,
        snapshot: NetworkSnapshot,
        state: inout NetworkPolicyState,
        now: Date = Date()
    ) -> NetworkPolicyExecution {
        let action = NetworkPolicyEvaluator.evaluate(policy: policy, snapshot: snapshot, state: &state, now: now)
        let mutationSucceeded: Bool?
        switch action {
        case .enableWiFi:
            mutationSucceeded = setWiFi(interface: policy.wifiInterface, enabled: true)
        case .disableWiFi:
            mutationSucceeded = setWiFi(interface: policy.wifiInterface, enabled: false)
        case .none:
            mutationSucceeded = nil
        }
        let observedWiFiEnabled = readWiFiEnabled(interface: policy.wifiInterface) ?? snapshot.wifiEnabled
        return NetworkPolicyEvaluator.reconcile(
            action: action,
            snapshot: snapshot,
            mutationSucceeded: mutationSucceeded,
            observedWiFiEnabled: observedWiFiEnabled,
            state: &state,
            now: now
        )
    }

    // allowWiFi records an AirDrop window only after command and observed hardware state agree.
    public func allowWiFi(policy: NetworkPolicy, state: inout NetworkPolicyState, minutes: Int) -> Bool {
        let commandSucceeded = setWiFi(interface: policy.wifiInterface, enabled: true)
        let observedEnabled = readWiFiEnabled(interface: policy.wifiInterface) == true
        guard commandSucceeded, observedEnabled else { return false }
        state.wifiGraceUntil = Date().addingTimeInterval(Double(max(0, minutes)) * 60)
        state.explicitGrace = true
        return true
    }

    // setWiFi uses the hardware interface to avoid localized service-name parsing.
    public func setWiFi(interface: String, enabled: Bool) -> Bool {
        let result = try? ProcessRunner.run(
            "/usr/sbin/networksetup",
            arguments: ["-setairportpower", interface, enabled ? "on" : "off"],
            timeout: 10
        )
        return result?.exitCode == 0
    }

    // readWiFiEnabled observes the hardware state after a mutation instead of trusting exit status alone.
    public func readWiFiEnabled(interface: String) -> Bool? {
        guard let result = try? ProcessRunner.run(
            "/usr/sbin/networksetup",
            arguments: ["-getairportpower", interface],
            timeout: 3
        ), result.exitCode == 0 else {
            return nil
        }
        return result.stdout.lowercased().contains("on")
    }

    // trafficSample calculates interval deltas while tolerating counter resets.
    public func trafficSample(interface: String, previous: TrafficCounter?) -> (InterfaceTrafficSample, TrafficCounter)? {
        guard let result = try? ProcessRunner.run(
            "/usr/sbin/netstat",
            arguments: ["-ibn", "-I", interface],
            timeout: 5
        ), result.exitCode == 0 else {
            return nil
        }
        let line = result.stdout.split(separator: "\n").dropFirst().first { row in
            let fields = row.split(whereSeparator: { $0.isWhitespace })
            return fields.first.map(String.init) == interface && fields.count >= 10 && fields[2].hasPrefix("<Link#")
        }
        guard let line else { return nil }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard let received = UInt64(fields[6]), let sent = UInt64(fields[9]) else { return nil }
        let timestamp = Date()
        let sample = Self.makeTrafficSample(
            interface: interface,
            received: received,
            sent: sent,
            previous: previous,
            timestamp: timestamp
        )
        return (sample, TrafficCounter(receivedBytes: received, sentBytes: sent, timestamp: timestamp))
    }

    // makeTrafficSample calculates deltas and rates while tolerating resets and interface replacement.
    public static func makeTrafficSample(
        interface: String,
        received: UInt64,
        sent: UInt64,
        previous: TrafficCounter?,
        timestamp: Date
    ) -> InterfaceTrafficSample {
        let receivedDelta = previous.map { received >= $0.receivedBytes ? received - $0.receivedBytes : 0 } ?? 0
        let sentDelta = previous.map { sent >= $0.sentBytes ? sent - $0.sentBytes : 0 } ?? 0
        let interval = previous?.timestamp.map { max(0.001, timestamp.timeIntervalSince($0)) }
        return InterfaceTrafficSample(
            timestamp: timestamp,
            interface: interface,
            receivedBytes: received,
            sentBytes: sent,
            receivedDelta: receivedDelta,
            sentDelta: sentDelta,
            intervalSeconds: interval,
            receivedBytesPerSecond: interval.map { Double(receivedDelta) / $0 },
            sentBytesPerSecond: interval.map { Double(sentDelta) / $0 }
        )
    }


}
