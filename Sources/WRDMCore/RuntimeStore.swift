import Foundation

// RuntimeFileStore writes shared snapshots atomically and JSONL evidence append-only.
public actor RuntimeFileStore {
    public let paths: AppPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // writeStatus publishes one complete private snapshot for UI, CLI, and MCP readers.
    public func writeStatus(_ status: AgentStatus) throws {
        try SecureFileAccess.withLock(for: paths.statusFile) {
            try SecureFileAccess.writeAtomically(try encoder.encode(status), to: paths.statusFile)
        }
    }

    // readStatus returns an explicit unavailable state when the agent has not written yet.
    public func readStatus() -> AgentStatus {
        (try? SecureFileAccess.withLock(for: paths.statusFile, exclusive: false) {
            let data = try? Data(contentsOf: paths.statusFile)
            let status = data.flatMap { try? decoder.decode(AgentStatus.self, from: $0) } ?? .unavailable
            var merged = status
            if let report = NetworkFiles(paths: paths).report(), report.observation.timestamp > status.timestamp {
                merged.lanHealthy = report.observation.selected?.usable == true
                merged.wifiEnabled = report.execution.observedWiFiEnabled
                merged.networkExecution = report.execution
                merged.fallbackActive = report.policyState.fallbackActive
            }
            return merged
        }) ?? .unavailable
    }

    // appendEvent preserves one source event per line for recovery after partial writes.
    public func appendEvent(_ event: DiagnosticEvent) throws {
        try appendJSONLine(event, to: paths.eventsFile)
    }

    // appendSynologyEventIfNew persists source deduplication across agent restarts and processes.
    @discardableResult
    public func appendSynologyEventIfNew(_ event: DiagnosticEvent) throws -> Bool {
        guard let rawReference = event.details["rawReference"], !rawReference.isEmpty else {
            try appendEvent(event)
            return true
        }
        return try SecureFileAccess.withLock(for: paths.eventsFile) {
            let duplicate = readJSONLinesUnlocked(DiagnosticEvent.self, from: paths.eventsFile).contains { existing in
                existing.type == .synology
                    && existing.source == event.source
                    && (existing.details["rawReference"] ?? existing.details["reference"]) == rawReference
            }
            guard !duplicate else { return false }
            try appendJSONLineUnlocked(event, to: paths.eventsFile)
            return true
        }
    }

    // appendTraffic records monotonic counters without mixing them into diagnostic prose.
    public func appendTraffic(_ sample: InterfaceTrafficSample) throws {
        try appendJSONLine(sample, to: paths.trafficFile)
    }

    // appendAudit keeps mutating or AI actions independently reviewable.
    public func appendAudit(_ entry: ActionAuditEntry) throws {
        try appendJSONLine(entry, to: paths.auditFile)
    }

    // recentEvents reads a bounded suffix and tolerates a damaged final line.
    public func recentEvents(limit: Int = 200) -> [DiagnosticEvent] {
        readJSONLines(DiagnosticEvent.self, from: paths.eventsFile).suffix(max(0, limit)).map { $0 }
    }

    // recentTraffic reads a bounded suffix for status and charts.
    public func recentTraffic(limit: Int = 500) -> [InterfaceTrafficSample] {
        readJSONLines(InterfaceTrafficSample.self, from: paths.trafficFile).suffix(max(0, limit)).map { $0 }
    }

    // recentAudit reads a bounded suffix for the diagnostic action history.
    public func recentAudit(limit: Int = 200) -> [ActionAuditEntry] {
        readJSONLines(ActionAuditEntry.self, from: paths.auditFile).suffix(max(0, limit)).map { $0 }
    }

    // readTransferJobs returns the persisted transfer dashboard state.
    public func readTransferJobs() -> [TransferJob] {
        (try? SecureFileAccess.withLock(for: paths.transferJobsFile, exclusive: false) {
            guard let data = try? Data(contentsOf: paths.transferJobsFile),
                  !data.isEmpty,
                  let jobs = try? decoder.decode([TransferJob].self, from: data) else {
                return []
            }
            return jobs.sorted { $0.updatedAt > $1.updatedAt }
        }) ?? []
    }

    // readTransferJob resolves one persisted transfer job by stable identifier.
    public func readTransferJob(id: UUID) -> TransferJob? {
        readTransferJobs().first { $0.id == id }
    }

    // upsertTransferJob atomically replaces or inserts one transfer job.
    public func upsertTransferJob(_ job: TransferJob) throws {
        // Share the network-change lock so no transfer can start during a disruptive system edit.
        try SecureFileAccess.withLock(for: NetworkFiles(paths: paths).operationLock) {
            try SecureFileAccess.withLock(for: paths.transferJobsFile) {
                var jobs: [TransferJob]
                if let data = try? Data(contentsOf: paths.transferJobsFile),
                   !data.isEmpty,
                   let decoded = try? decoder.decode([TransferJob].self, from: data) {
                    jobs = decoded
                } else {
                    jobs = []
                }
                if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[index] = job
                } else {
                    jobs.append(job)
                }
                jobs.sort { $0.updatedAt > $1.updatedAt }
                try SecureFileAccess.writeAtomically(try encoder.encode(jobs), to: paths.transferJobsFile)
            }
        }
    }

    // Mutate only the latest persisted job under the cross-process lock, preserving concurrent controls.
    @discardableResult
    public func mutateTransferJob(id: UUID, _ update: @Sendable (inout TransferJob) throws -> Void) throws -> TransferJob {
        try SecureFileAccess.withLock(for: NetworkFiles(paths: paths).operationLock) {
            try SecureFileAccess.withLock(for: paths.transferJobsFile) {
                var jobs = try decoder.decode([TransferJob].self, from: Data(contentsOf: paths.transferJobsFile))
                guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                    throw TransferServiceError.jobNotFound(id)
                }
                try update(&jobs[index])
                let result = jobs[index]
                jobs.sort { $0.updatedAt > $1.updatedAt }
                try SecureFileAccess.writeAtomically(try encoder.encode(jobs), to: paths.transferJobsFile)
                return result
            }
        }
    }

    // appendTransferIncident persists one incident manifest as append-only diagnostics metadata.
    public func appendTransferIncident(_ incident: TransferIncidentManifest) throws {
        try appendJSONLine(incident, to: paths.transferIncidentsFile)
    }

    // recentTransferIncidents reads a bounded suffix for CLI, MCP, AI, and support surfaces.
    public func recentTransferIncidents(limit: Int = 100) -> [TransferIncidentManifest] {
        readJSONLines(TransferIncidentManifest.self, from: paths.transferIncidentsFile).suffix(max(0, limit)).map { $0 }
    }

    // enforceRetentionIfNeeded avoids rewriting every evidence store on each monitoring cycle.
    @discardableResult
    public func enforceRetentionIfNeeded(
        policy: DiagnosticsPolicy,
        trafficMaxBytes: Int,
        now: Date = Date()
    ) throws -> Bool {
        let due = try SecureFileAccess.withLock(for: paths.retentionStateFile) {
            let previous = loadRetentionStateUnlocked()
            let interval = Double(policy.retentionIntervalMinutes) * 60
            return previous?.lastRunAt.addingTimeInterval(interval) ?? .distantPast <= now
        }
        guard due else { return false }
        try enforceRetention(policy: policy, trafficMaxBytes: trafficMaxBytes, now: now)
        try SecureFileAccess.withLock(for: paths.retentionStateFile) {
            let state = RetentionState(lastRunAt: now)
            try SecureFileAccess.writeAtomically(try encoder.encode(state), to: paths.retentionStateFile)
        }
        return true
    }

    // enforceRetention prunes structured stores and all app-owned diagnostic artifacts.
    public func enforceRetention(
        policy: DiagnosticsPolicy,
        trafficMaxBytes: Int,
        now: Date = Date()
    ) throws {
        let cutoff = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
        let events = readJSONLines(DiagnosticEvent.self, from: paths.eventsFile)
            .filter { $0.timestamp >= cutoff }
        try rewriteJSONLines(events, to: paths.eventsFile, maximumBytes: policy.maximumStoreBytes)

        let traffic = readJSONLines(InterfaceTrafficSample.self, from: paths.trafficFile)
            .filter { $0.timestamp >= cutoff }
        try rewriteJSONLines(traffic, to: paths.trafficFile, maximumBytes: trafficMaxBytes)

        let audit = readJSONLines(ActionAuditEntry.self, from: paths.auditFile)
            .filter { $0.timestamp >= cutoff }
        try rewriteJSONLines(audit, to: paths.auditFile, maximumBytes: policy.maximumStoreBytes)

        let incidents = readJSONLines(TransferIncidentManifest.self, from: paths.transferIncidentsFile)
            .filter { $0.createdAt >= cutoff }
        try rewriteJSONLines(incidents, to: paths.transferIncidentsFile, maximumBytes: policy.maximumStoreBytes)

        let eventBytes = fileSize(paths.eventsFile)
        try pruneArtifacts(
            in: paths.diagnostics,
            cutoff: cutoff,
            maximumBytes: max(0, policy.maximumStoreBytes - eventBytes),
            excludedFiles: [paths.eventsFile]
        )
    }

    // appendJSONLine serializes an append with retention rewrites across all WRDM processes.
    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        try SecureFileAccess.withLock(for: url) {
            try appendJSONLineUnlocked(value, to: url)
        }
    }

    // appendJSONLineUnlocked writes one complete private line while the caller owns the file lock.
    private func appendJSONLineUnlocked<T: Encodable>(_ value: T, to url: URL) throws {
        try paths.ensureDirectories()
        var line = try encoder.encode(value)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try SecureFileAccess.writeAtomically(Data(), to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try SecureFileAccess.hardenFile(url)
    }

    // readJSONLines uses a shared lock so readers never race a rewrite.
    private func readJSONLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        (try? SecureFileAccess.withLock(for: url, exclusive: false) {
            readJSONLinesUnlocked(type, from: url)
        }) ?? []
    }

    // readJSONLinesUnlocked tolerates malformed lines while preserving every valid record.
    private func readJSONLinesUnlocked<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(type, from: Data(line.utf8))
        }
    }

    // rewriteJSONLines bounds a structured store while preserving its newest complete records.
    private func rewriteJSONLines<T: Encodable>(_ values: [T], to url: URL, maximumBytes: Int) throws {
        try SecureFileAccess.withLock(for: url) {
            var lines = try values.map { value -> Data in
                var line = try encoder.encode(value)
                line.append(0x0A)
                return line
            }
            var total = lines.reduce(0) { $0 + $1.count }
            while total > maximumBytes, !lines.isEmpty {
                total -= lines.removeFirst().count
            }
            try SecureFileAccess.writeAtomically(Data(lines.joined()), to: url)
        }
    }

    // pruneArtifacts removes expired and oldest app-owned evidence without touching active partial files.
    private func pruneArtifacts(
        in directory: URL,
        cutoff: Date,
        maximumBytes: Int,
        excludedFiles: Set<URL>
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var files: [(url: URL, date: Date, bytes: Int)] = []
        for case let file as URL in enumerator {
            guard !excludedFiles.contains(file), !file.lastPathComponent.hasSuffix(".partial") else { continue }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            files.append((file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        for file in files where file.date < cutoff {
            try FileManager.default.removeItem(at: file.url)
        }
        var retained = files.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        var total = retained.reduce(0) { $0 + $1.bytes }
        while total > maximumBytes, !retained.isEmpty {
            let oldest = retained.removeFirst()
            try FileManager.default.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
        removeEmptyDirectories(below: directory)
    }

    // removeEmptyDirectories cleans support-bundle shells after their retained files expire.
    private func removeEmptyDirectories(below directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let directories = enumerator.compactMap { $0 as? URL }.reversed()
        for candidate in directories where candidate != directory {
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let contents = try? FileManager.default.contentsOfDirectory(atPath: candidate.path)
            if contents?.isEmpty == true { try? FileManager.default.removeItem(at: candidate) }
        }
    }

    // loadRetentionStateUnlocked decodes the previous successful maintenance run.
    private func loadRetentionStateUnlocked() -> RetentionState? {
        guard let data = try? Data(contentsOf: paths.retentionStateFile) else { return nil }
        return try? decoder.decode(RetentionState.self, from: data)
    }

    // fileSize returns zero for a missing store while calculating the shared evidence budget.
    private func fileSize(_ file: URL) -> Int {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

// RetentionState stores only the last successful evidence maintenance timestamp.
private struct RetentionState: Codable {
    var lastRunAt: Date
}

// ActionAuditEntry records policy and outcome without storing model prompts or credentials.
public struct ActionAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var actor: String
    public var action: String
    public var risk: CommandRisk
    public var decision: ActionDecision
    public var outcome: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        actor: String,
        action: String,
        risk: CommandRisk,
        decision: ActionDecision,
        outcome: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.action = action
        self.risk = risk
        self.decision = decision
        self.outcome = outcome
    }
}
