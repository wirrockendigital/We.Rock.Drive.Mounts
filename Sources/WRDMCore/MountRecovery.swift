import CryptoKit
import Darwin
import Foundation

// MountRecoveryMode separates agent automation from explicit normal and force recovery.
public enum MountRecoveryMode: String, Codable, Sendable {
    case automatic
    case manual
    case confirmedForce
}

// MountRecoveryRecord persists the complete safety checkpoint for one configured mount.
public struct MountRecoveryRecord: Codable, Equatable, Sendable {
    public var failureCount: Int
    public var nextAttemptAt: Date
    public var lastFailure: String
    public var failureCode: MountFailureCode?
    public var incidentID: UUID?
    public var bootIdentity: String
    public var normalUnmountAttempted: Bool
    public var restartRequired: Bool
    public var manualActionRequired: Bool
    public var lastPhase: MountRecoveryPhase
    public var blockingProcessIdentifiers: [Int32]

    // init creates one explicit persisted recovery checkpoint.
    public init(
        failureCount: Int,
        nextAttemptAt: Date,
        lastFailure: String,
        failureCode: MountFailureCode? = nil,
        incidentID: UUID? = nil,
        bootIdentity: String = "",
        normalUnmountAttempted: Bool = false,
        restartRequired: Bool = false,
        manualActionRequired: Bool = false,
        lastPhase: MountRecoveryPhase = .scheduled,
        blockingProcessIdentifiers: [Int32] = []
    ) {
        self.failureCount = failureCount
        self.nextAttemptAt = nextAttemptAt
        self.lastFailure = lastFailure
        self.failureCode = failureCode
        self.incidentID = incidentID
        self.bootIdentity = bootIdentity
        self.normalUnmountAttempted = normalUnmountAttempted
        self.restartRequired = restartRequired
        self.manualActionRequired = manualActionRequired
        self.lastPhase = lastPhase
        self.blockingProcessIdentifiers = blockingProcessIdentifiers
    }
}

// MountRecoveryPlanner calculates deterministic bounded backoff without side effects.
public enum MountRecoveryPlanner {
    // failed advances the retry delay from the configured monitoring interval up to five minutes.
    public static func failed(
        previous: MountRecoveryRecord?,
        message: String,
        code: MountFailureCode? = nil,
        now: Date,
        baseSeconds: Int,
        bootIdentity: String = "",
        maximumSeconds: Int = 300
    ) -> MountRecoveryRecord {
        let count = (previous?.failureCount ?? 0) + 1
        let exponent = min(8, max(0, count - 1))
        let delay = min(maximumSeconds, max(5, baseSeconds) * (1 << exponent))
        return MountRecoveryRecord(
            failureCount: count,
            nextAttemptAt: now.addingTimeInterval(Double(delay)),
            lastFailure: String(message.prefix(300)),
            failureCode: code,
            incidentID: previous?.incidentID,
            bootIdentity: bootIdentity.isEmpty ? previous?.bootIdentity ?? "" : bootIdentity,
            normalUnmountAttempted: previous?.normalUnmountAttempted ?? false,
            restartRequired: previous?.restartRequired ?? false,
            manualActionRequired: previous?.manualActionRequired ?? false,
            lastPhase: previous?.lastPhase ?? .scheduled,
            blockingProcessIdentifiers: previous?.blockingProcessIdentifiers ?? []
        )
    }

    // deferred schedules a retry without consuming the automatic mutation budget.
    public static func deferred(
        previous: MountRecoveryRecord?,
        message: String,
        code: MountFailureCode?,
        phase: MountRecoveryPhase,
        now: Date,
        baseSeconds: Int,
        bootIdentity: String
    ) -> MountRecoveryRecord {
        MountRecoveryRecord(
            failureCount: previous?.failureCount ?? 0,
            nextAttemptAt: now.addingTimeInterval(Double(max(5, baseSeconds))),
            lastFailure: String(message.prefix(300)),
            failureCode: code,
            incidentID: previous?.incidentID,
            bootIdentity: bootIdentity,
            normalUnmountAttempted: previous?.normalUnmountAttempted ?? false,
            restartRequired: previous?.restartRequired ?? false,
            manualActionRequired: previous?.manualActionRequired ?? false,
            lastPhase: phase,
            blockingProcessIdentifiers: previous?.blockingProcessIdentifiers ?? []
        )
    }

    // isDue determines whether the agent may attempt another mount operation.
    public static func isDue(_ record: MountRecoveryRecord?, now: Date) -> Bool {
        guard let record else { return true }
        return record.nextAttemptAt <= now
    }
}

// MountRecoveryStateStore serializes recovery checkpoints independently from user settings.
public actor MountRecoveryStateStore {
    private let file: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: AppPaths = AppPaths()) {
        file = paths.mountRecoveryFile
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // load tolerates missing or obsolete retry state and returns an empty deterministic baseline.
    public func load() -> [UUID: MountRecoveryRecord] {
        (try? SecureFileAccess.withLock(for: file, exclusive: false) {
            guard let data = try? Data(contentsOf: file),
                  let records = try? decoder.decode([UUID: MountRecoveryRecord].self, from: data) else {
                return [:]
            }
            return records
        }) ?? [:]
    }

    // save atomically publishes the complete retry state.
    public func save(_ records: [UUID: MountRecoveryRecord]) throws {
        try SecureFileAccess.withLock(for: file) {
            try SecureFileAccess.writeAtomically(try encoder.encode(records), to: file)
        }
    }

    // set merges one checkpoint so concurrent recovery processes cannot erase unrelated mount records.
    public func set(_ record: MountRecoveryRecord?, for mountID: UUID) throws {
        try SecureFileAccess.withLock(for: file) {
            var records: [UUID: MountRecoveryRecord] = [:]
            if let data = try? Data(contentsOf: file),
               let decoded = try? decoder.decode([UUID: MountRecoveryRecord].self, from: data) {
                records = decoded
            }
            records[mountID] = record
            try SecureFileAccess.writeAtomically(try encoder.encode(records), to: file)
        }
    }
}

// MountIncident is the single durable record updated throughout one mount outage.
public struct MountIncident: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var mountID: UUID
    public var mountName: String
    public var bootIdentity: String
    public var startedAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var availability: MountAvailability
    public var recoveryPhase: MountRecoveryPhase
    public var failureCode: MountFailureCode?
    public var message: String
    public var evidencePath: String
    public var evidenceEventIDs: [UUID]
    public var diagnosticEvidencePaths: [String]

    // init opens one incident with a stable evidence-manifest path.
    public init(
        id: UUID = UUID(),
        mountID: UUID,
        mountName: String,
        bootIdentity: String,
        startedAt: Date,
        availability: MountAvailability,
        recoveryPhase: MountRecoveryPhase,
        failureCode: MountFailureCode?,
        message: String,
        evidencePath: String,
        evidenceEventIDs: [UUID] = [],
        diagnosticEvidencePaths: [String] = []
    ) {
        self.id = id
        self.mountID = mountID
        self.mountName = mountName
        self.bootIdentity = bootIdentity
        self.startedAt = startedAt
        updatedAt = startedAt
        closedAt = nil
        self.availability = availability
        self.recoveryPhase = recoveryPhase
        self.failureCode = failureCode
        self.message = message
        self.evidencePath = evidencePath
        self.evidenceEventIDs = evidenceEventIDs
        self.diagnosticEvidencePaths = diagnosticEvidencePaths
    }
}

// MountIncidentStore deduplicates an outage and rewrites one bounded evidence manifest per incident.
public actor MountIncidentStore {
    private let paths: AppPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumIncidents = 100

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // openOrReuse creates one incident for an outage and returns whether it was newly opened.
    public func openOrReuse(
        mount: MountDefinition,
        bootIdentity: String,
        state: MountRuntimeState,
        now: Date
    ) throws -> (incident: MountIncident, created: Bool) {
        try SecureFileAccess.withLock(for: paths.mountIncidentsFile) {
            var incidents = loadUnlocked()
            if let index = incidents.firstIndex(where: { $0.mountID == mount.id && $0.closedAt == nil }) {
                incidents[index] = updated(incidents[index], state: state, now: now)
                try saveUnlocked(incidents)
                return (incidents[index], false)
            }
            let identifier = UUID()
            let evidence = paths.mountIncidents.appendingPathComponent("\(identifier.uuidString).json")
            let incident = MountIncident(
                id: identifier,
                mountID: mount.id,
                mountName: mount.name,
                bootIdentity: bootIdentity,
                startedAt: now,
                availability: state.availability,
                recoveryPhase: state.recoveryPhase,
                failureCode: state.failureCode,
                message: state.message,
                evidencePath: evidence.path
            )
            incidents.append(incident)
            try saveUnlocked(incidents)
            return (incident, true)
        }
    }

    // update changes the existing manifest without creating another incident or evidence package.
    public func update(id: UUID, state: MountRuntimeState, now: Date) throws -> MountIncident? {
        try SecureFileAccess.withLock(for: paths.mountIncidentsFile) {
            var incidents = loadUnlocked()
            guard let index = incidents.firstIndex(where: { $0.id == id }) else { return nil }
            incidents[index] = updated(incidents[index], state: state, now: now)
            try saveUnlocked(incidents)
            return incidents[index]
        }
    }

    // close marks one recovered outage terminal while preserving its evidence package.
    public func close(id: UUID, state: MountRuntimeState, now: Date) throws -> MountIncident? {
        try SecureFileAccess.withLock(for: paths.mountIncidentsFile) {
            var incidents = loadUnlocked()
            guard let index = incidents.firstIndex(where: { $0.id == id }) else { return nil }
            incidents[index] = updated(incidents[index], state: state, now: now)
            incidents[index].closedAt = now
            try saveUnlocked(incidents)
            return incidents[index]
        }
    }

    // attachEvidence links one completed bounded capture to the existing incident manifest.
    public func attachEvidence(id: UUID, eventID: UUID, path: String) throws {
        try SecureFileAccess.withLock(for: paths.mountIncidentsFile) {
            var incidents = loadUnlocked()
            guard let index = incidents.firstIndex(where: { $0.id == id }) else { return }
            if !incidents[index].evidenceEventIDs.contains(eventID) {
                incidents[index].evidenceEventIDs.append(eventID)
            }
            if !incidents[index].diagnosticEvidencePaths.contains(path) {
                incidents[index].diagnosticEvidencePaths.append(path)
            }
            incidents[index].updatedAt = Date()
            try saveUnlocked(incidents)
        }
    }

    // recent returns newest incidents first for CLI, MCP, and support surfaces.
    public func recent(limit: Int = 100) -> [MountIncident] {
        (try? SecureFileAccess.withLock(for: paths.mountIncidentsFile, exclusive: false) {
            Array(loadUnlocked().sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit)))
        }) ?? []
    }

    // openIncident finds crash-surviving outage state even when its retry checkpoint was not persisted.
    public func openIncident(mountID: UUID) -> MountIncident? {
        (try? SecureFileAccess.withLock(for: paths.mountIncidentsFile, exclusive: false) {
            loadUnlocked().first { $0.mountID == mountID && $0.closedAt == nil }
        }) ?? nil
    }

    // updated applies one recovery transition to the existing durable incident.
    private func updated(_ incident: MountIncident, state: MountRuntimeState, now: Date) -> MountIncident {
        var copy = incident
        copy.updatedAt = now
        copy.availability = state.availability
        copy.recoveryPhase = state.recoveryPhase
        copy.failureCode = state.failureCode
        copy.message = String(state.message.prefix(300))
        return copy
    }

    // loadUnlocked reads a cross-process snapshot and tolerates a missing initial store.
    private func loadUnlocked() -> [MountIncident] {
        guard let data = try? Data(contentsOf: paths.mountIncidentsFile),
              let values = try? decoder.decode([MountIncident].self, from: data) else { return [] }
        return values
    }

    // saveUnlocked bounds closed history while never evicting an open incident.
    private func saveUnlocked(_ values: [MountIncident]) throws {
        try paths.ensureDirectories()
        let open = values.filter { $0.closedAt == nil }
        let closed = values.filter { $0.closedAt != nil }.sorted { $0.updatedAt > $1.updatedAt }
        let retainedClosed = Array(closed.prefix(max(0, maximumIncidents - open.count)))
        let retained = (open + retainedClosed).sorted { $0.startedAt < $1.startedAt }
        let retainedIDs = Set(retained.map(\.id))
        for removed in values where !retainedIDs.contains(removed.id) {
            try? FileManager.default.removeItem(atPath: removed.evidencePath)
        }
        try SecureFileAccess.writeAtomically(try encoder.encode(retained), to: paths.mountIncidentsFile)
        for incident in retained {
            try SecureFileAccess.writeAtomically(try encoder.encode(incident), to: URL(fileURLWithPath: incident.evidencePath))
        }
    }
}

// MountOperationLock serializes mount-changing operations across the agent, UI, CLI, and MCP processes.
public enum MountOperationLock {
    // acquire returns nil when another WRDM process already owns the server-scoped mutation lock.
    public static func acquire(server: String, paths: AppPaths) -> MountOperationLockToken? {
        try? paths.ensureDirectories()
        let digest = SHA256.hash(data: Data(server.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        let file = paths.mountOperationLocks.appendingPathComponent("\(digest).lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR, mode_t(SecureFileAccess.privateFileMode))
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return MountOperationLockToken(descriptor: descriptor)
    }
}

// MountOperationLockToken releases one acquired cross-process lock when its scope ends.
public final class MountOperationLockToken: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MountRecoveryBatch carries final states plus newly opened incidents that need one evidence capture.
public struct MountRecoveryBatch: Sendable {
    public var states: [MountRuntimeState]
    public var newlyOpenedMountIDs: Set<UUID>

    // init creates one complete coordinator result.
    public init(states: [MountRuntimeState], newlyOpenedMountIDs: Set<UUID> = []) {
        self.states = states
        self.newlyOpenedMountIDs = newlyOpenedMountIDs
    }
}

// MountRecoveryCoordinator is the sole policy boundary allowed to mutate SMB mounts.
public actor MountRecoveryCoordinator {
    public let paths: AppPaths
    private let system: any MountSystemProviding
    private let mounts: MountService
    private let recoveryStore: MountRecoveryStateStore
    private let incidentStore: MountIncidentStore
    private let runtimeStore: RuntimeFileStore

    public init(
        paths: AppPaths = AppPaths(),
        system: any MountSystemProviding = MacOSMountSystem(),
        recoveryStore: MountRecoveryStateStore? = nil,
        incidentStore: MountIncidentStore? = nil,
        runtimeStore: RuntimeFileStore? = nil
    ) {
        self.paths = paths
        self.system = system
        mounts = MountService(system: system)
        self.recoveryStore = recoveryStore ?? MountRecoveryStateStore(paths: paths)
        self.incidentStore = incidentStore ?? MountIncidentStore(paths: paths)
        self.runtimeStore = runtimeStore ?? RuntimeFileStore(paths: paths)
    }

    // observe reads current states and decorates them with persisted recovery metadata without mutation.
    public func observe(settings: AppSettings) async -> [MountRuntimeState] {
        let observed = await mounts.runtimeStates(settings: settings)
        let records = await recoveryStore.load()
        return observed.map { state in
            guard let record = records[state.mountID] else { return state }
            return decorated(state, record: record)
        }
    }

    // recentIncidents exposes bounded incident manifests without changing recovery state.
    public func recentIncidents(limit: Int = 100) async -> [MountIncident] {
        await incidentStore.recent(limit: limit)
    }

    // attachEvidence links an asynchronous diagnostic capture to its durable mount incident.
    public func attachEvidence(incidentID: UUID, eventID: UUID, path: String) async {
        try? await incidentStore.attachEvidence(id: incidentID, eventID: eventID, path: path)
    }

    // reconcile performs one bounded recovery pass for the selected mode and mount identifiers.
    public func reconcile(
        settings: AppSettings,
        mode: MountRecoveryMode,
        mountIDs: Set<UUID>? = nil,
        now: Date = Date()
    ) async -> MountRecoveryBatch {
        let observed = await mounts.runtimeStates(settings: settings)
        var records = await recoveryStore.load()
        let bootIdentity = system.bootIdentity()
        var results: [MountRuntimeState] = []
        var newlyOpened = Set<UUID>()

        for state in observed {
            if let mountIDs, !mountIDs.contains(state.mountID) { continue }
            guard let mount = settings.mounts.first(where: { $0.id == state.mountID }) else { continue }
            if let record = records[mount.id],
               !record.bootIdentity.isEmpty,
               !bootIdentity.isEmpty,
               record.bootIdentity != bootIdentity {
                records[mount.id] = nil
                try? await recoveryStore.set(nil, for: mount.id)
            }
            if state.availability == .healthy || state.availability == .disabled {
                let persistedIncident = await incidentStore.openIncident(mountID: mount.id)
                let incidentID = records[mount.id]?.incidentID ?? persistedIncident?.id
                if let incidentID {
                    var closedState = state
                    closedState.incidentID = incidentID
                    _ = try? await incidentStore.close(id: incidentID, state: closedState, now: now)
                    if settings.diagnostics.enabled {
                        try? await runtimeStore.appendEvent(DiagnosticEvent(
                            type: .mountRecovered,
                            source: mount.name,
                            summary: "Mount incident recovered",
                            details: ["incidentID": incidentID.uuidString]
                        ))
                    }
                }
                records[mount.id] = nil
                try? await recoveryStore.set(nil, for: mount.id)
                results.append(state)
                continue
            }
            if state.availability == .unknown {
                var unknown = records[mount.id].map { decorated(state, record: $0) } ?? state
                if let incident = await incidentStore.openIncident(mountID: mount.id) {
                    unknown.incidentID = incident.id
                    _ = try? await incidentStore.update(id: incident.id, state: unknown, now: now)
                }
                results.append(unknown)
                continue
            }

            var record = records[mount.id] ?? MountRecoveryRecord(
                failureCount: 0,
                nextAttemptAt: now,
                lastFailure: state.message,
                failureCode: state.failureCode,
                bootIdentity: bootIdentity,
                lastPhase: .scheduled
            )
            var incidentState = decorated(state, record: record)
            let opened = try? await incidentStore.openOrReuse(mount: mount, bootIdentity: bootIdentity, state: incidentState, now: now)
            if let opened {
                record.incidentID = opened.incident.id
                incidentState.incidentID = opened.incident.id
                if opened.created {
                    newlyOpened.insert(mount.id)
                    if settings.diagnostics.enabled {
                        try? await runtimeStore.appendEvent(DiagnosticEvent(
                            type: .mountIncidentOpened,
                            source: mount.name,
                            summary: state.message,
                            details: [
                                "incidentID": opened.incident.id.uuidString,
                                "availability": state.availability.rawValue,
                            ],
                            evidencePath: opened.incident.evidencePath
                        ))
                    }
                }
            }

            let recovered = await recover(
                mount: mount,
                observed: state,
                record: &record,
                settings: settings,
                mode: mode,
                bootIdentity: bootIdentity,
                now: now
            )
            if settings.diagnostics.enabled, recovered.recoveryPhase != incidentState.recoveryPhase {
                try? await runtimeStore.appendEvent(DiagnosticEvent(
                    type: .mountRecoveryChanged,
                    source: mount.name,
                    summary: recovered.message,
                    details: [
                        "incidentID": record.incidentID?.uuidString ?? "",
                        "availability": recovered.availability.rawValue,
                        "recoveryPhase": recovered.recoveryPhase.rawValue,
                        "failureCode": recovered.failureCode?.rawValue ?? "",
                    ]
                ))
            }
            if recovered.availability == .healthy {
                if let incidentID = record.incidentID {
                    _ = try? await incidentStore.close(id: incidentID, state: recovered, now: now)
                    if settings.diagnostics.enabled {
                        try? await runtimeStore.appendEvent(DiagnosticEvent(
                            type: .mountRecovered,
                            source: mount.name,
                            summary: "Mount incident recovered",
                            details: ["incidentID": incidentID.uuidString]
                        ))
                    }
                }
                records[mount.id] = nil
                try? await recoveryStore.set(nil, for: mount.id)
                results.append(recovered)
                continue
            }
            records[mount.id] = record
            try? await recoveryStore.set(record, for: mount.id)
            results.append(recovered)
            if let incidentID = record.incidentID {
                _ = try? await incidentStore.update(id: incidentID, state: recovered, now: now)
            }
        }
        return MountRecoveryBatch(states: results, newlyOpenedMountIDs: newlyOpened)
    }

    // recover applies the state matrix to one mount while preserving the latest checkpoint.
    private func recover(
        mount: MountDefinition,
        observed: MountRuntimeState,
        record: inout MountRecoveryRecord,
        settings: AppSettings,
        mode: MountRecoveryMode,
        bootIdentity: String,
        now: Date
    ) async -> MountRuntimeState {
        if record.restartRequired {
            return transition(
                observed,
                record: &record,
                phase: .restartRequired,
                code: .uninterruptibleKernelWait,
                message: "macOS restart required before another mount operation"
            )
        }
        if record.failureCode == .processStillRunning, record.manualActionRequired {
            if record.blockingProcessIdentifiers.contains(where: ProcessRunner.isProcessAlive) {
                return transition(
                    observed,
                    record: &record,
                    phase: .manualConfirmationRequired,
                    code: .processStillRunning,
                    message: "Previous mount operation is still running; no new mutation is safe"
                )
            }
            record.manualActionRequired = false
            record.blockingProcessIdentifiers = []
        }
        if mode == .automatic, record.manualActionRequired {
            return transition(
                observed,
                record: &record,
                phase: .manualConfirmationRequired,
                code: record.failureCode,
                message: record.lastFailure
            )
        }
        if mode == .automatic,
           record.failureCount >= settings.general.maximumAutomaticRecoveryAttempts {
            return transition(
                observed,
                record: &record,
                phase: .circuitOpen,
                code: .automaticAttemptLimitReached,
                message: "Automatic recovery attempt limit reached"
            )
        }
        if mode == .automatic, !MountRecoveryPlanner.isDue(record, now: now) {
            let waitingPhase: MountRecoveryPhase = [.waitingForNetwork, .deferredActiveTransfer].contains(record.lastPhase)
                ? record.lastPhase
                : .scheduled
            return transition(
                observed,
                record: &record,
                phase: waitingPhase,
                code: record.failureCode,
                message: "Recovery scheduled after \(record.lastFailure)"
            )
        }
        if observed.availability == .staleMounted,
           let mountPoint = observed.localPath,
           await hasActiveTransfer(at: mountPoint) {
            record = MountRecoveryPlanner.deferred(
                previous: record,
                message: "An active WRDM transfer is using this mount",
                code: .activeTransfer,
                phase: .deferredActiveTransfer,
                now: now,
                baseSeconds: settings.general.checkIntervalSeconds,
                bootIdentity: bootIdentity
            )
            return decorated(observed, record: record)
        }
        guard let host = URLComponents(string: mount.url)?.host else {
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: .invalidSMBURL, message: "Invalid SMB URL")
        }
        guard system.endpointIsReachable(host: host) else {
            record = MountRecoveryPlanner.deferred(
                previous: record,
                message: "SMB server is unavailable on port 445",
                code: .smbServerUnavailable,
                phase: .waitingForNetwork,
                now: now,
                baseSeconds: settings.general.checkIntervalSeconds,
                bootIdentity: bootIdentity
            )
            return decorated(observed, record: record)
        }
        guard let operationLock = MountOperationLock.acquire(server: host, paths: paths) else {
            record = MountRecoveryPlanner.deferred(
                previous: record,
                message: "Another WRDM process is changing mounts on this server",
                code: .operationLocked,
                phase: .scheduled,
                now: now,
                baseSeconds: settings.general.checkIntervalSeconds,
                bootIdentity: bootIdentity
            )
            return decorated(observed, record: record)
        }
        defer { withExtendedLifetime(operationLock) {} }

        let current = mounts.runtimeState(
            for: mount,
            healthTimeout: TimeInterval(settings.general.smbHealthTimeoutSeconds)
        )
        if current.availability == .healthy {
            return transition(current, record: &record, phase: .idle, code: nil, message: "Connected")
        }
        if current.availability == .unknown {
            return transition(current, record: &record, phase: .scheduled, code: current.failureCode, message: current.message)
        }
        if current.availability == .staleMounted {
            return await recoverStale(
                mount: mount,
                observed: current,
                record: &record,
                settings: settings,
                mode: mode,
                bootIdentity: bootIdentity,
                now: now
            )
        }
        return await performMount(
            mount: mount,
            observed: current,
            record: &record,
            settings: settings,
            bootIdentity: bootIdentity,
            now: now
        )
    }

    // recoverStale permits one normal unmount automatically and force only in confirmed mode.
    private func recoverStale(
        mount: MountDefinition,
        observed: MountRuntimeState,
        record: inout MountRecoveryRecord,
        settings: AppSettings,
        mode: MountRecoveryMode,
        bootIdentity: String,
        now: Date
    ) async -> MountRuntimeState {
        guard let mountPoint = observed.localPath else {
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: .detachNotVerified, message: "Stale mount point is unavailable")
        }
        if await hasActiveTransfer(at: mountPoint) {
            return transition(observed, record: &record, phase: .deferredActiveTransfer, code: .activeTransfer, message: "An active WRDM transfer is using this mount")
        }
        let force = mode == .confirmedForce
        if !force && record.normalUnmountAttempted {
            record.manualActionRequired = true
            return transition(
                observed,
                record: &record,
                phase: .manualConfirmationRequired,
                code: .detachNotVerified,
                message: "Normal unmount did not detach the stale mount; confirmed force recovery is required"
            )
        }
        record.normalUnmountAttempted = record.normalUnmountAttempted || !force
        record.lastPhase = .unmounting
        try? await recoveryStore.set(record, for: mount.id)
        let result = system.requestUnmount(mountPoint: mountPoint, force: force, timeout: 10)
        if result.requiresRestart {
            record.restartRequired = true
            record.manualActionRequired = true
            let terminal = transition(
                observed,
                record: &record,
                phase: .restartRequired,
                code: .uninterruptibleKernelWait,
                message: "Unmount is trapped in uninterruptible macOS kernel wait; restart required"
            )
            if settings.diagnostics.enabled {
                try? await runtimeStore.appendEvent(DiagnosticEvent(
                    type: .mountRestartRequired,
                    source: mount.name,
                    summary: terminal.message,
                    details: ["incidentID": record.incidentID?.uuidString ?? ""]
                ))
            }
            return terminal
        }
        if result.stillRunning {
            record.manualActionRequired = true
            record.blockingProcessIdentifiers = survivingProcessIdentifiers(result)
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: .processStillRunning, message: "Unmount process is still running after timeout and signals")
        }

        record.lastPhase = .verifyingDetach
        try? await recoveryStore.set(record, for: mount.id)
        let table = system.mountTable()
        guard table.failureCode == nil else {
            record.manualActionRequired = true
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: .mountTableUnavailable, message: table.message ?? "Cannot verify mount detach")
        }
        let stillMounted = table.shares.contains { $0.normalizedURL == SMBMountTableParser.normalize(mount.url) }
        guard !stillMounted else {
            record.manualActionRequired = true
            let code: MountFailureCode = result.exitCode == 0 ? .detachNotVerified : force ? .forceUnmountFailed : .normalUnmountFailed
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: code, message: "Unmount did not detach the stale mount")
        }
        return await performMount(
            mount: mount,
            observed: MountRuntimeState(
                mountID: mount.id,
                timestamp: now,
                availability: .missing,
                recoveryPhase: .verifyingDetach,
                consecutiveFailures: record.failureCount,
                message: "Stale mount detached",
                incidentID: record.incidentID
            ),
            record: &record,
            settings: settings,
            bootIdentity: bootIdentity,
            now: now
        )
    }

    // performMount proves the share is absent immediately before issuing one bounded mount request.
    private func performMount(
        mount: MountDefinition,
        observed: MountRuntimeState,
        record: inout MountRecoveryRecord,
        settings: AppSettings,
        bootIdentity: String,
        now: Date
    ) async -> MountRuntimeState {
        let table = system.mountTable()
        guard table.failureCode == nil else {
            return transition(observed, record: &record, phase: .scheduled, code: .mountTableUnavailable, message: table.message ?? "Cannot verify mount table")
        }
        if table.shares.contains(where: { $0.normalizedURL == SMBMountTableParser.normalize(mount.url) }) {
            let present = mounts.runtimeState(
                for: mount,
                table: table,
                healthTimeout: TimeInterval(settings.general.smbHealthTimeoutSeconds)
            )
            record.manualActionRequired = present.availability == .staleMounted
            return transition(
                present,
                record: &record,
                phase: present.availability == .healthy ? .idle : .manualConfirmationRequired,
                code: present.failureCode,
                message: present.availability == .healthy ? "Connected" : "Mount remains present; remount was not attempted"
            )
        }

        record.lastPhase = .mounting
        record.nextAttemptAt = now
        try? await recoveryStore.set(record, for: mount.id)
        let result = system.requestMount(url: mount.url, timeout: TimeInterval(settings.general.mountTimeoutSeconds))
        if result.requiresRestart {
            record.restartRequired = true
            record.manualActionRequired = true
            let terminal = transition(observed, record: &record, phase: .restartRequired, code: .uninterruptibleKernelWait, message: "Mount request is trapped in uninterruptible macOS kernel wait; restart required")
            if settings.diagnostics.enabled {
                try? await runtimeStore.appendEvent(DiagnosticEvent(
                    type: .mountRestartRequired,
                    source: mount.name,
                    summary: terminal.message,
                    details: ["incidentID": record.incidentID?.uuidString ?? ""]
                ))
            }
            return terminal
        }
        if result.stillRunning {
            record.manualActionRequired = true
            record.blockingProcessIdentifiers = survivingProcessIdentifiers(result)
            return transition(observed, record: &record, phase: .manualConfirmationRequired, code: .processStillRunning, message: "Mount process is still running after timeout and signals")
        }
        record.lastPhase = .verifyingHealth
        try? await recoveryStore.set(record, for: mount.id)
        let verified = mounts.runtimeState(
            for: mount,
            healthTimeout: TimeInterval(settings.general.smbHealthTimeoutSeconds)
        )
        if verified.availability == .healthy {
            return transition(verified, record: &record, phase: .idle, code: nil, message: "Connected")
        }
        let code: MountFailureCode = result.timedOut ? .mountRequestTimedOut : .mountRequestFailed
        record = MountRecoveryPlanner.failed(
            previous: record,
            message: result.timedOut ? "Mount request timed out" : outputMessage(result),
            code: code,
            now: now,
            baseSeconds: settings.general.checkIntervalSeconds,
            bootIdentity: bootIdentity
        )
        let phase: MountRecoveryPhase = record.failureCount >= settings.general.maximumAutomaticRecoveryAttempts ? .circuitOpen : .scheduled
        return transition(verified, record: &record, phase: phase, code: phase == .circuitOpen ? .automaticAttemptLimitReached : code, message: record.lastFailure)
    }

    // hasActiveTransfer blocks unmount while a running WRDM job references the mount root.
    private func hasActiveTransfer(at mountPoint: String) async -> Bool {
        let root = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        return await runtimeStore.readTransferJobs().contains { job in
            guard job.state == .running else { return false }
            return (job.sources + [job.destination]).contains { path in
                let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                return normalized == root || normalized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }

    // transition updates recovery metadata while keeping the observed availability unchanged.
    private func transition(
        _ state: MountRuntimeState,
        record: inout MountRecoveryRecord,
        phase: MountRecoveryPhase,
        code: MountFailureCode?,
        message: String
    ) -> MountRuntimeState {
        record.lastPhase = phase
        record.failureCode = code
        record.lastFailure = String(message.prefix(300))
        if phase == .manualConfirmationRequired { record.manualActionRequired = true }
        var copy = state
        copy.recoveryPhase = phase
        copy.consecutiveFailures = record.failureCount
        copy.failureCode = code
        copy.message = String(message.prefix(300))
        copy.incidentID = record.incidentID
        copy.nextAttemptAt = [.scheduled, .waitingForNetwork, .deferredActiveTransfer].contains(phase) ? record.nextAttemptAt : nil
        return copy
    }

    // decorated overlays persisted metadata without changing a fresh observation.
    private func decorated(_ state: MountRuntimeState, record: MountRecoveryRecord) -> MountRuntimeState {
        var copy = state
        copy.recoveryPhase = record.restartRequired ? .restartRequired : record.manualActionRequired ? .manualConfirmationRequired : record.lastPhase
        copy.consecutiveFailures = record.failureCount
        copy.failureCode = record.failureCode ?? state.failureCode
        copy.message = record.lastFailure.isEmpty ? state.message : record.lastFailure
        copy.incidentID = record.incidentID
        copy.nextAttemptAt = [.scheduled, .waitingForNetwork, .deferredActiveTransfer].contains(copy.recoveryPhase)
            ? record.nextAttemptAt
            : nil
        return copy
    }

    // outputMessage selects and bounds one non-secret adapter error for status surfaces.
    private func outputMessage(_ result: ProcessResult) -> String {
        let value = result.stdout.isEmpty ? result.stderr : result.stdout
        let bounded = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return bounded.isEmpty ? "Mount request failed" : bounded
    }

    // survivingProcessIdentifiers retains only the root and descendants reported alive after timeout handling.
    private func survivingProcessIdentifiers(_ result: ProcessResult) -> [Int32] {
        var identifiers = Set(result.descendants.map(\.processIdentifier))
        if let processIdentifier = result.processIdentifier { identifiers.insert(processIdentifier) }
        return identifiers.sorted()
    }
}
