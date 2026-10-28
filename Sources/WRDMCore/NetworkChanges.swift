import Foundation
import Security
import SystemConfiguration

// NetworkChangePreview is a short-lived, persisted proposal; it never grants authorization itself.
public struct NetworkChangePreview: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var kind: String
    public var before: NetworkInventory
    public var order: [String]
    public var profile: PortProfile?
    public var summary: [String]
}

// NetworkChangeError keeps unsafe or ambiguous operations explicit across all command surfaces.
public enum NetworkChangeError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case let .rejected(reason) = self { return reason }; return nil }
}

// NetworkChanges uses an authorized, locked native preferences session with no privileged resident helper.
public struct NetworkChanges: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }
    private var previewURL: URL { paths.state.appendingPathComponent("network-preview.json") }
    public var resultURL: URL { paths.state.appendingPathComponent("network-change-result.json") }

    // priority keeps every service exactly once and moves only Ethernet and Wi-Fi slots.
    public static func priority(_ inventory: NetworkInventory, preferred: String?) -> [String] {
        let ports = inventory.ports
        let managed = ports.filter { ["ethernet", "wifi"].contains($0.kind) && inventory.serviceOrder.contains($0.serviceID) }.sorted {
            let a = $0.id == preferred ? 0 : $0.kind == "ethernet" ? 1 : 2
            let b = $1.id == preferred ? 0 : $1.kind == "ethernet" ? 1 : 2
            return a == b ? $0.rank < $1.rank : a < b
        }.map(\.serviceID)
        var remaining = managed.makeIterator()
        return inventory.serviceOrder.map { managed.contains($0) ? remaining.next()! : $0 }
    }

    public func preview(settings: AppSettings, profileID: UUID? = nil) throws -> NetworkChangePreview {
        let inventory = NativeNetworkInventory.read()
        let profile = profileID.flatMap { id in settings.network.discovery?.profiles.first { $0.id == id } }
        if profileID != nil && profile == nil { throw NetworkChangeError.rejected("PROFILE_NOT_FOUND") }
        var summary: [String] = []
        let order: [String]
        if let profile {
            guard let port = inventory.ports.first(where: { $0.id == profile.portID }) else { throw NetworkChangeError.rejected("ADAPTER_MISSING") }
            try Self.validate(profile: profile, port: port)
            summary = PortMonitor.differences(profile: profile, port: port)
            order = inventory.serviceOrder
        } else {
            let fastest = inventory.ports.filter { $0.kind == "ethernet" }.max { ($0.speedMbps ?? 0) < ($1.speedMbps ?? 0) }?.id
            order = Self.priority(inventory, preferred: settings.network.discovery?.preferredPortID ?? fastest)
            summary = order.enumerated().map { index, id in
                "\(index + 1). \(inventory.ports.first { $0.serviceID == id }?.name ?? id)"
            }
        }
        let preview = NetworkChangePreview(kind: profile == nil ? "priority" : "hardware", before: inventory, order: order, profile: profile, summary: summary)
        try SecureFileAccess.writeAtomically(NetworkFiles.encode(preview), to: previewURL)
        return preview
    }

    // validate refuses unknown identity, unsupported values and ambiguous media-only restoration.
    public static func validate(profile: PortProfile, port: NetworkPort) throws {
        guard profile.enabled, port.present, port.kind == "ethernet", port.hardwareID != nil,
              port.id == profile.portID, port.networkID == profile.networkID else {
            throw NetworkChangeError.rejected("PROFILE_IDENTITY_OR_NETWORK_MISMATCH")
        }
        if let mtu = profile.mtu {
            guard let lower = port.minimumMTU, let upper = port.maximumMTU, (lower...upper).contains(mtu) else {
                throw NetworkChangeError.rejected("MTU_UNSUPPORTED")
            }
        }
        _ = try desiredMedia(profile: profile, port: port)

    }

    // desiredMedia changes only elected media fields and rejects combinations the driver cannot represent.
    public static func desiredMedia(profile: PortProfile, port: NetworkPort) throws -> MediaSetting? {
        guard profile.mode != nil || profile.media != nil || profile.speedMbps != nil || profile.duplex != nil || profile.flowControl != nil else { return nil }
        if let mode = profile.mode, !["manual", "automatic"].contains(mode) { throw NetworkChangeError.rejected("MODE_UNSUPPORTED") }
        let base = profile.media ?? port.configuredMedia
        guard let base else { throw NetworkChangeError.rejected("CONFIGURED_MEDIA_UNKNOWN") }
        if profile.mode == "automatic" {
            guard profile.mtu == nil || profile.mtu == 1500 else { throw NetworkChangeError.rejected("AUTOMATIC_HARDWARE_CONFLICTS_WITH_CUSTOM_MTU: Use manual hardware with autoselect media for Jumbo frames.") }
            if port.configuredMTU != nil && profile.mtu == nil { throw NetworkChangeError.rejected("SELECT_MTU_BEFORE_REMOVING_HARDWARE_OVERRIDES") }
        }
        let automatic = profile.mode == "automatic" || base.subtype == "autoselect"
        let candidates = port.availableMedia.filter { media in
            if automatic { return media.subtype == "autoselect" }
            if media.subtype == "autoselect" { return false }
            if let speed = profile.speedMbps {
                var candidate = port; candidate.activeMedia = media
                if candidate.speedMbps != speed { return false }
            } else if media.subtype != base.subtype { return false }
            var desiredOptions = base.options
            if let duplex = profile.duplex {
                desiredOptions.removeAll { $0.contains("duplex") }; desiredOptions.append(duplex)
            }
            if let flow = profile.flowControl {
                desiredOptions.removeAll { $0 == "flow-control" }
                if flow { desiredOptions.append("flow-control") }
            }
            return media.options == desiredOptions.sorted()
        }
        guard let media = candidates.first else { throw NetworkChangeError.rejected("MEDIA_COMBINATION_UNSUPPORTED") }
        if let explicit = profile.media, explicit != media { throw NetworkChangeError.rejected("CONFLICTING_DESIRED_MEDIA: Select matching configured and active media values.") }
        return media
    }

    // verify distinguishes a measured failure from missing evidence before authorizing a single rollback.
    public static func verify(proposal: NetworkChangePreview, after: NetworkInventory, baseline: NetworkObservation,
                              post: NetworkObservation, applied: Bool) -> NetworkChangeVerification {
        var failed = !applied
        var matching = false
        var identityMatches = after.locationID == proposal.before.locationID
        if let profile = proposal.profile {
            let before = proposal.before.ports.first { $0.id == profile.portID }
            if let port = after.ports.first(where: { $0.id == profile.portID }) {
                identityMatches = identityMatches && port.hardwareID == before?.hardwareID && port.networkID == before?.networkID
                let differences = PortMonitor.differences(profile: profile, port: port)
                failed = failed || differences.contains { !$0.hasPrefix("UNKNOWN:") }
                matching = differences.isEmpty && port.link == true
            } else { identityMatches = false }
        } else { matching = after.serviceOrder == proposal.order }
        let protected = baseline.probes.filter(\.reachable)
        let lost = protected.contains { before in
            post.probes.contains { $0.host == before.host && $0.port == before.port && $0.interface == before.interface && !$0.reachable && $0.error != "PROBE_DEADLINE" }
        }
        let verifiedPaths = protected.allSatisfy { before in
            post.probes.contains { $0.host == before.host && $0.port == before.port && $0.interface == before.interface && $0.reachable }
        }
        if failed || lost { return identityMatches ? .rollback : .unknown }
        guard identityMatches else { return .unknown }
        return matching && verifiedPaths ? .verified : .pending
    }

    // apply verifies the preview again under the shared action lock and retains the original config for one rollback.
    public func apply(id: UUID, interactive: Bool, transfersActive: Bool, settings: AppSettings) throws -> String {
        guard interactive else { throw NetworkChangeError.rejected("INTERACTIVE_AUTHORIZATION_REQUIRED: Open the app to confirm this change.") }
        guard !transfersActive else { throw NetworkChangeError.rejected("ACTIVE_TRANSFERS: Wait until transfers finish.") }
        return try SecureFileAccess.withLock(for: NetworkFiles(paths: paths).operationLock) {
            // Recheck transfers after acquiring the same lock used to publish running jobs.
            if let data = try? Data(contentsOf: paths.transferJobsFile) {
                let jobs = try NetworkFiles.decode([TransferJob].self, from: data)
                guard !jobs.contains(where: { [.running, .queued].contains($0.state) }) else { throw NetworkChangeError.rejected("ACTIVE_TRANSFERS") }
            }
            let proposal = try NetworkFiles.decode(NetworkChangePreview.self, from: Data(contentsOf: previewURL))
            guard proposal.id == id, Date().timeIntervalSince(proposal.createdAt) < 300 else { throw NetworkChangeError.rejected("PREVIEW_EXPIRED") }
            var fresh = NativeNetworkInventory.read()
            guard fresh.locationID == proposal.before.locationID, fresh.serviceOrder == proposal.before.serviceOrder else { throw NetworkChangeError.rejected("CONFIGURATION_CHANGED") }
            let baseline = NetworkObservation.collect(settings: settings)
            var authorization: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize], &authorization) == errAuthorizationSuccess,
                  let authorization else { throw NetworkChangeError.rejected("AUTHORIZATION_FAILED") }
            defer { AuthorizationFree(authorization, []) }
            guard let preferences = SCPreferencesCreateWithAuthorization(nil, "We Rock Drive Mounts" as CFString, nil, authorization),
                  SCPreferencesLock(preferences, false) else { throw NetworkChangeError.rejected("PREFERENCES_LOCK_OR_AUTHORIZATION_FAILED") }
            defer { SCPreferencesUnlock(preferences) }
            guard let set = SCNetworkSetCopyCurrent(preferences),
                  SCNetworkSetGetSetID(set) as String? == proposal.before.locationID,
                  SCNetworkSetGetServiceOrder(set) as? [String] == proposal.before.serviceOrder else { throw NetworkChangeError.rejected("CONFIGURATION_CHANGED") }
            // Authorization may take minutes; compare both app preferences and hardware after the system lock is held.
            if let data = try? Data(contentsOf: paths.configFile) {
                guard let currentSettings = try? PropertyListDecoder().decode(AppSettings.self, from: data), currentSettings == settings else { throw NetworkChangeError.rejected("APP_CONFIGURATION_CHANGED") }
            }
            fresh = NativeNetworkInventory.read()
            var device: SCNetworkInterface?
            var original: CFDictionary?
            if let profile = proposal.profile {
                guard settings.network.discovery?.profiles.contains(profile) == true,
                      let before = proposal.before.ports.first(where: { $0.id == profile.portID }),
                      let current = fresh.ports.first(where: { $0.id == profile.portID }),
                      before.hardwareID == current.hardwareID, before.networkID == current.networkID,
                      before.configuredMedia == current.configuredMedia, before.configuredMTU == current.configuredMTU,
                      before.hardwareMode == current.hardwareMode,
                      let service = SCNetworkServiceCopy(preferences, current.serviceID as CFString),
                      let interface = SCNetworkServiceGetInterface(service) else { throw NetworkChangeError.rejected("CONFIGURATION_CHANGED") }
                try Self.validate(profile: profile, port: current)
                device = interface
                original = SCNetworkInterfaceGetConfiguration(interface)
                if profile.mode == "automatic" {
                    guard SCNetworkInterfaceSetMediaOptions(interface, nil, nil) else { throw NetworkChangeError.rejected("MEDIA_WRITE_FAILED") }
                } else if let media = try Self.desiredMedia(profile: profile, port: current) {
                    guard SCNetworkInterfaceSetMediaOptions(interface, media.subtype as CFString, media.options as CFArray) else { throw NetworkChangeError.rejected("MEDIA_WRITE_FAILED") }
                }
                if let mtu = profile.mtu, !SCNetworkInterfaceSetMTU(interface, profile.mode == "automatic" ? 0 : Int32(mtu)) { throw NetworkChangeError.rejected("MTU_WRITE_FAILED") }
            } else {
                guard Set(proposal.order) == Set(proposal.before.serviceOrder), proposal.order.count == proposal.before.serviceOrder.count,
                      SCNetworkSetSetServiceOrder(set, proposal.order as CFArray) else { throw NetworkChangeError.rejected("SERVICE_ORDER_WRITE_FAILED") }
            }
            guard SCPreferencesCommitChanges(preferences) else { throw NetworkChangeError.rejected("COMMIT_FAILED") }
            let applied = SCPreferencesApplyChanges(preferences)
            // Read back independently; unknown convergence is not claimed as success.
            var after = NativeNetworkInventory.read()
            // Driver re-negotiation may lag behind preference commit. Wait only a bounded interval.
            for _ in 0..<3 {
                let converged = proposal.profile.map { profile in
                    after.ports.first(where: { $0.id == profile.portID }).map { PortMonitor.differences(profile: profile, port: $0).isEmpty && $0.link == true } ?? false
                } ?? (after.serviceOrder == proposal.order)
                if converged { break }
                Thread.sleep(forTimeInterval: 1)
                after = NativeNetworkInventory.read()
            }
            let post = NetworkObservation.collect(settings: settings)
            let protected = baseline.probes.filter(\.reachable)
            let decision = Self.verify(proposal: proposal, after: after, baseline: baseline, post: post, applied: applied)
            var outcome = decision == .verified ? "VERIFIED" : decision == .unknown ? "FAILED_OUTCOME_UNKNOWN" : "APPLIED_VERIFICATION_PENDING"
            if decision == .rollback {
                // The preferences lock excludes competing configuration writers during this bounded rollback.
                let restored = device.map { SCNetworkInterfaceSetConfiguration($0, original) }
                    ?? SCNetworkSetSetServiceOrder(set, proposal.before.serviceOrder as CFArray)
                let committed = restored && SCPreferencesCommitChanges(preferences) && SCPreferencesApplyChanges(preferences)
                let restoredInventory = NativeNetworkInventory.read()
                let verified = proposal.profile.map { profile in
                    let before = proposal.before.ports.first { $0.id == profile.portID }
                    let now = restoredInventory.ports.first { $0.id == profile.portID }
                    return before?.configuredMedia == now?.configuredMedia && before?.configuredMTU == now?.configuredMTU && now != nil
                } ?? (restoredInventory.serviceOrder == proposal.before.serviceOrder)
                let rollbackObservation = NetworkObservation.collect(settings: settings)
                let connectivityRestored = protected.allSatisfy { before in
                    rollbackObservation.probes.contains { $0.host == before.host && $0.port == before.port && $0.interface == before.interface && $0.reachable }
                }
                outcome = committed && verified && connectivityRestored ? "FAILED_ROLLED_BACK" : "FAILED_OUTCOME_UNKNOWN"
            }
            try SecureFileAccess.writeAtomically(NetworkFiles.encode(NetworkChangeResult(outcome: outcome, timestamp: Date(), preview: proposal, after: after, postObservation: post)), to: resultURL)
            try? FileManager.default.removeItem(at: previewURL)
            return outcome
        }
    }
}

// NetworkChangeResult retains the exact proposal and independent read-back, including unresolved outcomes.
public struct NetworkChangeResult: Codable, Equatable, Sendable {
    public var outcome: String
    public var timestamp: Date
    public var preview: NetworkChangePreview
    public var after: NetworkInventory
    public var postObservation: NetworkObservation
}

// Verification decisions never equate a missing observation with permission to mutate another device.
public enum NetworkChangeVerification: String, Codable, Sendable {
    case verified, pending, rollback, unknown
}
