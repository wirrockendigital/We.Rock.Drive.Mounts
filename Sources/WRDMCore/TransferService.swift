import Darwin
import Foundation

// TransferStartRequest is the command-level input for one agent-owned transfer job.
public struct TransferStartRequest: Equatable, Sendable {
    public var operation: TransferOperation
    // A nil direction asks the shared validator to infer it from the selected paths.
    public var direction: TransferDirection?
    public var resumePolicy: TransferResumePolicy
    public var unlimitedAutoRetries: Bool
    public var sources: [String]
    public var destination: String
    public var keepMacAwake: Bool

    public init(
        operation: TransferOperation,
        direction: TransferDirection?,
        resumePolicy: TransferResumePolicy,
        unlimitedAutoRetries: Bool,
        sources: [String],
        destination: String,
        keepMacAwake: Bool
    ) {
        self.operation = operation
        self.direction = direction
        self.resumePolicy = resumePolicy
        self.unlimitedAutoRetries = unlimitedAutoRetries
        self.sources = sources
        self.destination = destination
        self.keepMacAwake = keepMacAwake
    }
}

// TransferServiceError keeps transfer failures actionable across GUI, CLI, MCP, and tests.
public enum TransferServiceError: LocalizedError, Equatable {
    case invalidRequest(String)
    case workerUnavailable
    case jobNotFound(UUID)
    case jobNotResumable(TransferJobState)
    case jobNotActive(UUID)
    case verificationFailed
    case finalizeRequiresVerifiedMove
    case sourceDeletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            message
        case .workerUnavailable:
            "The We Rock Drive Mount transfer worker is not available."
        case .jobNotFound(let id):
            "Transfer job \(id.uuidString) was not found."
        case .jobNotResumable(let state):
            "Transfer job cannot be resumed from state \(state.rawValue)."
        case .jobNotActive(let id):
            "Transfer job \(id.uuidString) is not active in the background agent."
        case .verificationFailed:
            "Copied files could not be verified against the source."
        case .finalizeRequiresVerifiedMove:
            "Move finalization requires a verified move job."
        case .sourceDeletionFailed(let path):
            "Source deletion failed for \(path)."
        }
    }
}

// ActiveTransfer owns a process that was launched by the current agent instance.
private final class ActiveTransfer: @unchecked Sendable {
    let process: Process
    let stdout: FileHandle
    let stderr: FileHandle
    let stdoutURL: URL
    let stderrURL: URL

    init(process: Process, stdout: FileHandle, stderr: FileHandle, stdoutURL: URL, stderrURL: URL) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
    }

    // terminate stops the child worker while keeping the background agent responsive.
    func terminate() {
        process.terminate()
    }
}

// NativeTransferError carries a stable error code for persisted transfer failures.
private struct NativeTransferError: LocalizedError, Sendable {
    var code: String
    var message: String

    var errorDescription: String? { message }
}

// TransferTreeStats stores one bounded recursive filesystem snapshot.
private struct TransferTreeStats: Equatable {
    var bytes: UInt64
    var files: Int
}

// ParsedTransferProgress preserves the newest current-file signal found in worker output.
private struct ParsedTransferProgress: Equatable {
    var percent: Double?
    var transferredBytes: UInt64?
    var currentPath: String?
}

// NativeCopyItem describes one regular file copy preserving its source-relative path.
private struct NativeCopyItem: Sendable {
    var source: URL
    var target: URL
    var relativePath: String
    var size: UInt64
}

// TransferService coordinates agent-owned transfer worker jobs and cross-process status updates.
public actor TransferService {
    public let paths: AppPaths
    private let runtimeStore: RuntimeFileStore
    private let mounts = MountService()
    // Inject mount observations so tests never need production SMB volumes.
    private let observedSMBRoots: @Sendable () -> [URL]
    private let pi = PiCompanionClient()
    private let workerExecutablePathOverride: String?
    private var active: [UUID: ActiveTransfer] = [:]
    private var powerAssertions: [UUID: Process] = [:]
    private var captureInFlight: Set<UUID> = []

    public init(paths: AppPaths = AppPaths(), runtimeStore: RuntimeFileStore? = nil, workerExecutablePath: String? = nil,
                observedSMBRoots: @escaping @Sendable () -> [URL] = {
                    MountService().importableMountedSMBMounts(configuredMounts: []).map { URL(fileURLWithPath: $0.localPath) }
                }) {
        self.paths = paths
        self.runtimeStore = runtimeStore ?? RuntimeFileStore(paths: paths)
        workerExecutablePathOverride = workerExecutablePath
        self.observedSMBRoots = observedSMBRoots
    }

    // start persists a queued job; the background agent owns the actual worker process.
    @discardableResult
    public func start(request: TransferStartRequest, settings: AppSettings, status: AgentStatus) async throws -> TransferJob {
        let direction = try validate(request: request, settings: settings, status: status)
        let normalizedSources = request.sources.map { normalizedPath($0) }
        let initialStats = totalStats(for: normalizedSources.map(URL.init(fileURLWithPath:)))
        let progress = TransferProgress(
            totalBytes: initialStats.bytes,
            completedBytes: 0,
            totalFiles: initialStats.files,
            completedFiles: 0,
            lastProgressAt: Date(),
            snapshotAt: Date()
        )
        let job = TransferJob(
            operation: request.operation,
            direction: direction,
            resumePolicy: request.resumePolicy,
            sources: normalizedSources,
            destination: normalizedPath(request.destination),
            state: .queued,
            progress: progress,
            maximumAutoRetries: settings.transfer.maximumAutoRetries,
            verifyAfterCopy: settings.transfer.verifyAfterCopy,
            createIncidentOnFailure: settings.transfer.incidentBundleOnFailure,
            unlimitedAutoRetries: request.unlimitedAutoRetries,
            ownedByAgent: true,
            keepMacAwake: request.keepMacAwake
        )
        try await runtimeStore.upsertTransferJob(job)
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: .transferStarted,
            source: "transfer",
            summary: "Transfer queued for the background agent",
            details: ["jobID": job.id.uuidString, "operation": job.operation.rawValue, "direction": job.direction.rawValue]
        ))
        return job
    }

    // resume returns a terminal or interrupted job to the agent queue with its partial target data intact.
    @discardableResult
    public func resume(id: UUID, settings: AppSettings, status: AgentStatus) async throws -> TransferJob {
        guard var job = await runtimeStore.readTransferJob(id: id) else {
            throw TransferServiceError.jobNotFound(id)
        }
        guard [.paused, .stopped, .failed].contains(job.state) else {
            throw TransferServiceError.jobNotResumable(job.state)
        }
        try validate(job: job, settings: settings, status: status)
        job.state = .queued
        job.requestedControl = nil
        job.errorCode = nil
        job.errorMessage = nil
        job.endedAt = nil
        job.nextRetryAt = nil
        job.runnerPID = nil
        job.updatedAt = Date()
        job.ownedByAgent = true
        try await runtimeStore.upsertTransferJob(job)
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: .transferResumed,
            source: "transfer",
            summary: "Transfer queued for resume by the background agent",
            details: ["jobID": id.uuidString]
        ))
        return job
    }

    // pause requests an orderly agent-side worker termination that can later be resumed.
    @discardableResult
    public func pause(id: UUID) async throws -> TransferJob {
        try await requestControl(id: id, control: .pause, terminalState: .paused)
    }

    // stop requests an agent-side worker termination while keeping persisted resume metadata.
    @discardableResult
    public func stop(id: UUID) async throws -> TransferJob {
        try await requestControl(id: id, control: .stop, terminalState: .stopped)
    }

    // finalizeMove deletes sources only after a move job has completed copy verification.
    @discardableResult
    public func finalizeMove(id: UUID) async throws -> TransferJob {
        guard var job = await runtimeStore.readTransferJob(id: id) else {
            throw TransferServiceError.jobNotFound(id)
        }
        guard job.operation == .move, job.verificationSucceeded, job.state == .verified else {
            throw TransferServiceError.finalizeRequiresVerifiedMove
        }
        for source in job.sources {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: source))
            } catch {
                throw TransferServiceError.sourceDeletionFailed(source)
            }
        }
        job.state = .finalized
        job.finalizedAt = Date()
        job.updatedAt = Date()
        try await runtimeStore.upsertTransferJob(job)
        let event = DiagnosticEvent(
            type: .transferMoveFinalized,
            source: "transfer",
            summary: "Move source files deleted after verification",
            details: ["jobID": job.id.uuidString]
        )
        try? await runtimeStore.appendEvent(event)
        return job
    }

    // createIncident persists one local blackbox manifest around a transfer failure or long-running stall.
    @discardableResult
    public func createIncident(jobID: UUID?) async throws -> TransferIncidentManifest {
        let events = await runtimeStore.recentEvents(limit: 200)
        let traffic = await runtimeStore.recentTraffic(limit: 1_000)
        let status = await runtimeStore.readStatus()
        var manifest = TransferIncidentManifest(
            jobID: jobID,
            title: "Transfer interruption evidence",
            eventIDs: events.map(\.id),
            trafficSampleCount: traffic.count,
            statusPhase: status.phase,
            unavailableSources: [
                "dangerousManipulations": "No Ethernet, NAS, sleep, or wake manipulation was performed.",
            ]
        )
        let directory = paths.transferIncidents.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try SecureFileAccess.ensureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let job = jobID == nil ? nil : await runtimeStore.readTransferJob(id: jobID!)
        let payload = TransferIncidentPayload(
            manifest: manifest,
            job: job,
            status: status,
            events: events,
            traffic: traffic
        )
        let file = directory.appendingPathComponent("incident.json")
        try SecureFileAccess.writeAtomically(try encoder.encode(payload), to: file)
        manifest.bundlePath = directory.path
        try await runtimeStore.appendTransferIncident(manifest)
        let event = DiagnosticEvent(
            type: .transferIncidentCreated,
            source: "transfer",
            summary: "Transfer incident bundle saved",
            details: ["jobID": jobID?.uuidString ?? ""],
            evidencePath: file.path
        )
        try? await runtimeStore.appendEvent(event)
        return manifest
    }

    // wait polls persistent state so CLI owners can exit without owning the worker process.
    public func wait(id: UUID) async -> Bool {
        while true {
            guard let job = await runtimeStore.readTransferJob(id: id) else { return false }
            if Self.isTerminal(job.state) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // stopAll only terminates runners owned by this service instance; persisted jobs remain resumable.
    public func stopAll() {
        for (id, transfer) in active {
            transfer.terminate()
            active[id] = transfer
        }
        for process in powerAssertions.values where process.isRunning {
            process.terminate()
        }
        powerAssertions.removeAll()
    }

    // reconcile is called by AgentRuntime to start queued jobs, monitor progress, and apply controls.
    public func reconcile(settings: AppSettings, status: AgentStatus) async {
        let jobs = await runtimeStore.readTransferJobs()
        for job in jobs {
            switch job.state {
            case .queued:
                // A persisted retry deadline prevents rapid retry loops across agent cycles and restarts.
                if let nextRetryAt = job.nextRetryAt, nextRetryAt > Date() {
                    continue
                }
                do {
                    try validate(job: job, settings: settings, status: status)
                    _ = try await launch(job: job, settings: settings, status: status, eventType: .transferStarted)
                } catch {
                    await failQueued(job: job, code: "VALIDATION_FAILED", message: error.localizedDescription)
                }
            case .running:
                await maintainPowerAssertion(for: job)
                await monitor(job: job, settings: settings, status: status)
            default:
                continue
            }
        }
    }

    // requestControl stores cross-process intent; the agent applies it on its next reconcile pass.
    private func requestControl(id: UUID, control: TransferControlRequest, terminalState: TransferJobState) async throws -> TransferJob {
        guard var job = await runtimeStore.readTransferJob(id: id) else {
            throw TransferServiceError.jobNotFound(id)
        }
        if job.state == .queued {
            job.state = terminalState
            job.requestedControl = nil
            job.endedAt = Date()
            job.updatedAt = Date()
            try await runtimeStore.upsertTransferJob(job)
            return job
        }
        guard job.state == .running else {
            throw TransferServiceError.jobNotActive(id)
        }
        job.requestedControl = control
        job.updatedAt = Date()
        try await runtimeStore.upsertTransferJob(job)
        return job
    }

    // launch starts the signed WRDM helper in worker mode and records enough data for restart-time adoption.
    private func launch(job original: TransferJob, settings: AppSettings, status: AgentStatus, eventType: DiagnosticEventType) async throws -> TransferJob {
        var job = original
        job.state = .running
        job.attempts += 1
        job.startedAt = Date()
        job.updatedAt = Date()
        job.ownedByAgent = true
        job.requestedControl = nil
        job.errorCode = nil
        job.errorMessage = nil
        job.nextRetryAt = nil

        let processDirectory = paths.state.appendingPathComponent("transfer-processes/\(job.id.uuidString)", isDirectory: true)
        try SecureFileAccess.ensureDirectory(processDirectory)
        let stdoutURL = processDirectory.appendingPathComponent("stdout-\(job.attempts).log")
        let stderrURL = processDirectory.appendingPathComponent("stderr-\(job.attempts).log")
        try SecureFileAccess.writeAtomically(Data(), to: stdoutURL)
        try SecureFileAccess.writeAtomically(Data(), to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)

        let jobID = job.id
        job.runnerPID = nil
        job.stdoutPath = stdoutURL.path
        job.stderrPath = stderrURL.path
        job.progress = progressSnapshot(job: job, previous: job.progress)
        try await runtimeStore.upsertTransferJob(job)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try workerExecutable())
        process.arguments = ["--transfer-worker", job.id.uuidString, "--home", paths.homeDirectory.path]
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessRunner.minimalEnvironment()
        environment["HOME"] = paths.homeDirectory.path
        process.environment = environment
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            var failed = job
            failed.state = .failed
            failed.errorCode = "WORKER_START_FAILED"
            failed.errorMessage = bounded(error.localizedDescription)
            failed.endedAt = Date()
            failed.updatedAt = Date()
            try? await runtimeStore.upsertTransferJob(failed)
            throw error
        }

        if var persisted = await runtimeStore.readTransferJob(id: jobID) {
            persisted.runnerPID = process.processIdentifier
            persisted.stdoutPath = stdoutURL.path
            persisted.stderrPath = stderrURL.path
            persisted.startedAt = job.startedAt
            persisted.updatedAt = Date()
            persisted.ownedByAgent = true
            job = persisted
        } else {
            job.runnerPID = process.processIdentifier
        }
        try await runtimeStore.upsertTransferJob(job)

        await maintainPowerAssertion(for: job)

        let activeTransfer = ActiveTransfer(process: process, stdout: stdout, stderr: stderr, stdoutURL: stdoutURL, stderrURL: stderrURL)
        active[jobID] = activeTransfer
        process.terminationHandler = { finished in
            let pid = finished.processIdentifier
            let exitCode = finished.terminationStatus
            Task {
                await self.finish(jobID: jobID, runnerPID: pid, exitCode: exitCode)
            }
        }
        let event = DiagnosticEvent(
            type: eventType,
            source: "transfer",
            summary: eventType == .transferResumed ? "Transfer resumed by the background agent" : "Transfer started by the background agent",
            details: ["jobID": job.id.uuidString, "operation": job.operation.rawValue, "direction": job.direction.rawValue, "runner": "agent-worker", "pid": String(process.processIdentifier)]
        )
        try? await runtimeStore.appendEvent(event)
        if !process.isRunning {
            await finish(jobID: jobID, runnerPID: process.processIdentifier, exitCode: process.terminationStatus)
        }
        return job
    }

    // runWorker performs the copy in a child WRDM helper process so the main agent remains interruptible.
    public static func runWorker(jobID: UUID, paths: AppPaths = AppPaths()) async -> Int32 {
        let runtimeStore = RuntimeFileStore(paths: paths)
        var nativeError: NativeTransferError?
        do {
            try await performNativeCopy(jobID: jobID, runtimeStore: runtimeStore)
        } catch is CancellationError {
            nativeError = NativeTransferError(code: "TRANSFER_CANCELLED", message: "The transfer runner was cancelled.")
        } catch let error as NativeTransferError {
            nativeError = error
        } catch {
            nativeError = classifiedNativeError(error)
        }
        if let nativeError, var job = await runtimeStore.readTransferJob(id: jobID), job.errorCode == nil {
            job.errorCode = nativeError.code
            job.errorMessage = nativeError.message
            job.updatedAt = Date()
            try? await runtimeStore.upsertTransferJob(job)
        }
        return nativeError == nil ? 0 : 1
    }

    // performNativeCopy copies every selected source in bounded chunks and persists progress.
    private static func performNativeCopy(jobID: UUID, runtimeStore: RuntimeFileStore) async throws {
        guard let job = await runtimeStore.readTransferJob(id: jobID) else {
            throw NativeTransferError(code: "TRANSFER_NOT_FOUND", message: "The queued transfer job was not found.")
        }
        let items = try nativeCopyItems(for: job)
        let totalBytes = items.reduce(UInt64(0)) { $0 + $1.size }
        let totalFiles = items.count
        var completedBytes: UInt64 = try existingCompletedBytes(for: items)
        var completedFiles: Int = try existingCompletedFiles(for: items)
        var lastSnapshotAt = Date()
        var lastSnapshotBytes: UInt64 = completedBytes
        try await updateNativeProgress(
            jobID: jobID,
            runtimeStore: runtimeStore,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            currentPath: nil,
            bytesPerSecond: nil
        )

        for item in items {
            try Task.checkCancellation()
            _ = try await currentRunningJob(jobID: jobID, runtimeStore: runtimeStore)
            let existing = try fileSizeIfPresent(item.target)
            if existing == item.size {
                continue
            }
            if let existing, existing > item.size {
                completedBytes -= min(completedBytes, item.size)
                try FileManager.default.removeItem(at: item.target)
            }
            try FileManager.default.createDirectory(at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: item.target.path) {
                FileManager.default.createFile(atPath: item.target.path, contents: nil)
            }
            let input = try FileHandle(forReadingFrom: item.source)
            let output = try FileHandle(forWritingTo: item.target)
            defer {
                try? input.close()
                try? output.close()
            }
            let resumedBytes = min(try fileSizeIfPresent(item.target) ?? 0, item.size)
            if resumedBytes > 0 {
                try input.seek(toOffset: resumedBytes)
                try output.seekToEnd()
            }
            var fileOffset = resumedBytes
            while fileOffset < item.size {
                try Task.checkCancellation()
                _ = try await currentRunningJob(jobID: jobID, runtimeStore: runtimeStore)
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                fileOffset += UInt64(data.count)
                completedBytes += UInt64(data.count)
                let now = Date()
                if now.timeIntervalSince(lastSnapshotAt) >= 0.5 && fileOffset < item.size {
                    let elapsed = max(0.1, now.timeIntervalSince(lastSnapshotAt))
                    let byteDelta: UInt64 = completedBytes >= lastSnapshotBytes ? completedBytes - lastSnapshotBytes : 0
                    let bytesPerSecond = Double(byteDelta) / elapsed
                    try await updateNativeProgress(
                        jobID: jobID,
                        runtimeStore: runtimeStore,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        completedFiles: completedFiles,
                        totalFiles: totalFiles,
                        currentPath: item.relativePath,
                        bytesPerSecond: bytesPerSecond
                    )
                    lastSnapshotAt = now
                    lastSnapshotBytes = completedBytes
                }
            }
            // Keep per-file durability; only UI bookkeeping is coalesced across small files.
            try output.synchronize()
            completedFiles += 1
            let now = Date()
            if now.timeIntervalSince(lastSnapshotAt) >= 0.5 || completedFiles == totalFiles {
                let elapsed = max(0.1, now.timeIntervalSince(lastSnapshotAt))
                try await updateNativeProgress(
                    jobID: jobID, runtimeStore: runtimeStore,
                    completedBytes: completedBytes, totalBytes: totalBytes,
                    completedFiles: completedFiles, totalFiles: totalFiles,
                    currentPath: item.relativePath,
                    bytesPerSecond: Double(completedBytes - lastSnapshotBytes) / elapsed
                )
                lastSnapshotAt = now
                lastSnapshotBytes = completedBytes
            }
        }
        // Publish exact final counters even when trailing files were already complete on resume.
        try await updateNativeProgress(
            jobID: jobID, runtimeStore: runtimeStore,
            completedBytes: completedBytes, totalBytes: totalBytes,
            completedFiles: completedFiles, totalFiles: totalFiles,
            currentPath: items.last?.relativePath, bytesPerSecond: nil
        )
    }

    // currentRunningJob returns the newest job state and turns pause or stop requests into cancellation.
    private static func currentRunningJob(jobID: UUID, runtimeStore: RuntimeFileStore) async throws -> TransferJob {
        guard let job = await runtimeStore.readTransferJob(id: jobID) else {
            throw NativeTransferError(code: "TRANSFER_NOT_FOUND", message: "The transfer job disappeared while running.")
        }
        if job.requestedControl != nil || job.state != .running {
            throw CancellationError()
        }
        return job
    }

    // nativeCopyItems expands files and folders into deterministic destination file targets.
    private static func nativeCopyItems(for job: TransferJob) throws -> [NativeCopyItem] {
        let destination = URL(fileURLWithPath: job.destination).standardizedFileURL
        var items: [NativeCopyItem] = []
        for sourcePath in job.sources {
            let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw NativeTransferError(code: "SOURCE_MISSING", message: "Source does not exist: \(source.path)")
            }
            if isDirectory.boolValue {
                let rootTarget = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                try FileManager.default.createDirectory(at: rootTarget, withIntermediateDirectories: true)
                guard let enumerator = FileManager.default.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: []
                ) else { continue }
                for case let child as URL in enumerator {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                    let relative = relativePath(child: child, root: source)
                    let target = rootTarget.appendingPathComponent(relative)
                    if values.isDirectory == true {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    } else if values.isRegularFile == true {
                        items.append(NativeCopyItem(
                            source: child,
                            target: target,
                            relativePath: "\(source.lastPathComponent)/\(relative)",
                            size: UInt64(values.fileSize ?? 0)
                        ))
                    }
                }
            } else {
                let values = try source.resourceValues(forKeys: [.fileSizeKey])
                items.append(NativeCopyItem(
                    source: source,
                    target: destination.appendingPathComponent(source.lastPathComponent),
                    relativePath: source.lastPathComponent,
                    size: UInt64(values.fileSize ?? 0)
                ))
            }
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    // relativePath keeps nested directory layout stable below the selected folder.
    private static func relativePath(child: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else { return child.lastPathComponent }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    // existingCompletedBytes counts resumable target bytes without trusting oversized partial files.
    private static func existingCompletedBytes(for items: [NativeCopyItem]) throws -> UInt64 {
        try items.reduce(UInt64(0)) { partial, item in
            partial + min(try fileSizeIfPresent(item.target) ?? 0, item.size)
        }
    }

    // existingCompletedFiles counts already complete target files for resumed jobs.
    private static func existingCompletedFiles(for items: [NativeCopyItem]) throws -> Int {
        try items.reduce(0) { partial, item in
            partial + (try fileSizeIfPresent(item.target) == item.size ? 1 : 0)
        }
    }

    // fileSizeIfPresent distinguishes a missing target from a valid zero-byte file during resume.
    private static func fileSizeIfPresent(_ url: URL) throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        return UInt64(values.fileSize ?? 0)
    }

    // updateNativeProgress stores bounded live counters from the child copy worker.
    private static func updateNativeProgress(
        jobID: UUID,
        runtimeStore: RuntimeFileStore,
        completedBytes: UInt64,
        totalBytes: UInt64,
        completedFiles: Int,
        totalFiles: Int,
        currentPath: String?,
        bytesPerSecond: Double?
    ) async throws {
        // Read-modify-write is one transaction so a concurrent Pause/Stop cannot be overwritten.
        try await runtimeStore.mutateTransferJob(id: jobID) { job in
            guard job.state == .running, job.requestedControl == nil else { throw CancellationError() }
            let now = Date()
            let movedForward = completedBytes > (job.progress.completedBytes ?? 0)
                || completedFiles > (job.progress.completedFiles ?? 0)
            let percent: Double
            if totalBytes > 0 {
                percent = min(100, max(0, Double(completedBytes) / Double(totalBytes) * 100))
            } else if totalFiles > 0 {
                percent = min(100, max(0, Double(completedFiles) / Double(totalFiles) * 100))
            } else {
                percent = 100
            }
            job.progress = TransferProgress(
                updatedAt: now,
                percent: percent,
                transferredBytes: completedBytes,
                currentPath: currentPath ?? job.progress.currentPath,
                totalBytes: totalBytes,
                completedBytes: completedBytes,
                totalFiles: totalFiles,
                completedFiles: completedFiles,
                bytesPerSecond: bytesPerSecond,
                smoothedBytesPerSecond: smoothedBytesPerSecond(current: bytesPerSecond, previous: job.progress.smoothedBytesPerSecond),
                lastProgressAt: movedForward ? now : job.progress.lastProgressAt ?? now,
                stallSeconds: movedForward ? 0 : Int(now.timeIntervalSince(job.progress.lastProgressAt ?? now)),
                highTrafficSince: job.progress.highTrafficSince,
                highTrafficSeconds: job.progress.highTrafficSeconds,
                snapshotAt: now
            )
            job.updatedAt = now
        }
    }

    // monitor updates progress, detects stalls, and finishes adopted jobs whose process ended.
    private func monitor(job: TransferJob, settings: AppSettings, status: AgentStatus) async {
        if let control = job.requestedControl {
            await apply(control: control, to: job)
            return
        }
        if let transfer = active[job.id], !transfer.process.isRunning {
            await finish(jobID: job.id, runnerPID: transfer.process.processIdentifier, exitCode: transfer.process.terminationStatus)
            return
        }
        guard active[job.id] != nil || job.runnerPID != nil else {
            await failOrphanedLegacyRun(job: job)
            return
        }
        if active[job.id] == nil,
           let pid = job.runnerPID,
           Self.processIsAlive(pid),
           !Self.processLooksLikeTransferRunner(pid) {
            await failRunning(job: job, code: "RUNNER_UNKNOWN", message: "The persisted native transfer runner is not owned by this background-agent instance. Resume the job to continue safely.")
            return
        }
        if active[job.id] == nil,
           let pid = job.runnerPID,
           !Self.processIsAlive(pid) {
            await finishAdopted(jobID: job.id)
            return
        }
        let now = Date()
        let stallThreshold = max(30, settings.transfer.sustainedSeconds)
        let highTrafficThreshold = max(1, settings.transfer.highTrafficBytesPerSecond)
        // Native workers own byte/file counters; monitoring must not scan the SMB tree or overwrite them.
        guard var updated = try? await runtimeStore.mutateTransferJob(id: job.id, { latest in
            guard latest.state == .running, latest.requestedControl == nil else { return }
            let lastProgress = latest.progress.lastProgressAt ?? latest.startedAt ?? now
            latest.progress.stallSeconds = max(0, Int(now.timeIntervalSince(lastProgress)))
            let fresh = now.timeIntervalSince(latest.progress.updatedAt) < Double(stallThreshold)
            let isHighTraffic = settings.transfer.monitoringEnabled && fresh
                && (latest.progress.bytesPerSecond ?? 0) >= Double(highTrafficThreshold)
            if isHighTraffic {
                let since = latest.progress.highTrafficSince ?? now
                latest.progress.highTrafficSince = since
                latest.progress.highTrafficSeconds = Int(now.timeIntervalSince(since))
            } else {
                latest.progress.highTrafficSince = nil
                latest.progress.highTrafficSeconds = nil
            }
            if (latest.progress.stallSeconds ?? 0) >= stallThreshold {
                latest.errorCode = "TRANSFER_STALLED"
                latest.errorMessage = "No transfer progress for \(latest.progress.stallSeconds ?? stallThreshold) seconds. The background agent terminated the runner so the job can be resumed or retried."
            }
            latest.updatedAt = now
        }), updated.state == .running, updated.requestedControl == nil else { return }
        let isStalled = (updated.progress.stallSeconds ?? 0) >= stallThreshold
        let highTrafficSustained = (updated.progress.highTrafficSeconds ?? 0) >= max(1, settings.transfer.sustainedSeconds)
        if settings.transfer.monitoringEnabled || isStalled {
            let event = DiagnosticEvent(
                type: .transferProgress, source: "transfer",
                summary: isStalled ? "Transfer appears stalled" : highTrafficSustained ? "Transfer high-traffic monitoring active" : "Transfer progress updated",
                details: progressDetails(job: updated)
            )
            try? await runtimeStore.appendEvent(event)
            // Append evidence without writing an old copy of the worker's progress or controls.
            if let current = try? await runtimeStore.mutateTransferJob(id: job.id, { $0.evidenceIDs.append(event.id) }) {
                updated = current
            }
        }
        if isStalled {
            scheduleTransferCaptureIfNeeded(job: updated, settings: settings, status: status, reason: "stall")
            // Recheck fresh worker progress before terminating a runner that just resumed making progress.
            let lastProgress = updated.progress.lastProgressAt ?? now
            if Date().timeIntervalSince(lastProgress) >= Double(stallThreshold) {
                await terminateStalledRunner(job: updated)
            }
        } else if highTrafficSustained {
            scheduleTransferCaptureIfNeeded(job: updated, settings: settings, status: status, reason: "high-traffic")
        }
    }

    // terminateStalledRunner exits a stuck runner so the normal failure or retry path can take over.
    private func terminateStalledRunner(job: TransferJob) async {
        if let transfer = active[job.id] {
            transfer.terminate()
            return
        }
        guard let pid = job.runnerPID, Self.processIsAlive(pid) else { return }
        guard Self.processLooksLikeTransferRunner(pid) else {
            await failRunning(job: job, code: "RUNNER_UNTRUSTED", message: "The stalled runner PID is alive, but it no longer looks like the worker process owned by this transfer. The job was not signalled.")
            return
        }
        kill(pid, SIGTERM)
    }

    // apply converts persistent control requests into process termination and durable state.
    private func apply(control: TransferControlRequest, to job: TransferJob) async {
        let terminalState: TransferJobState = control == .pause ? .paused : .stopped
        if let transfer = active[job.id] {
            transfer.terminate()
            return
        }
        if let pid = job.runnerPID, Self.processIsAlive(pid) {
            guard Self.processLooksLikeTransferRunner(pid) else {
                await failRunning(job: job, code: "RUNNER_UNTRUSTED", message: "The recorded runner PID is alive, but it no longer looks like the worker process owned by this transfer. The job was not signalled.")
                return
            }
            kill(pid, SIGTERM)
            return
        }
        var updated = job
        updated.state = terminalState
        updated.requestedControl = nil
        updated.endedAt = Date()
        updated.updatedAt = Date()
        try? await runtimeStore.upsertTransferJob(updated)
    }

    // finish converts a current-process termination into terminal state and optional incident evidence.
    private func finish(jobID: UUID, runnerPID: Int32, exitCode: Int32) async {
        guard let transfer = active.removeValue(forKey: jobID) else { return }
        try? transfer.stdout.synchronize()
        try? transfer.stderr.synchronize()
        try? transfer.stdout.close()
        try? transfer.stderr.close()
        guard var job = await runtimeStore.readTransferJob(id: jobID),
              job.runnerPID == runnerPID || job.runnerPID == nil else { return }
        job.progress = progressSnapshot(job: job, previous: job.progress)
        await finish(job: &job, exitCode: exitCode)
    }

    // finishAdopted completes a process recovered from persisted PID data after an agent restart.
    private func finishAdopted(jobID: UUID) async {
        guard var job = await runtimeStore.readTransferJob(id: jobID) else { return }
        job.progress = progressSnapshot(job: job, previous: job.progress)
        await finish(job: &job, exitCode: nil)
    }

    // finish applies final verification, retry, and incident behavior.
    private func finish(job: inout TransferJob, exitCode: Int32?) async {
        await releasePowerAssertion(jobID: job.id)
        let requestedControl = job.requestedControl
        job.endedAt = Date()
        job.runnerPID = nil
        job.requestedControl = nil
        job.powerAssertionActive = false
        job.powerAssertionPID = nil
        job.updatedAt = Date()

        if exitCode == nil {
            if verify(job: job) {
                job.verificationSucceeded = true
                job.state = job.operation == .move ? .verified : .completed
            } else {
                job.state = .failed
                job.errorCode = "RUNNER_EXIT_UNKNOWN"
                job.errorMessage = "The background agent recovered a transfer whose runner already exited; copied bytes could not be verified."
            }
        } else if exitCode == 0 {
            if job.verifyAfterCopy || job.operation == .move {
                job.verificationSucceeded = verify(job: job)
                job.state = job.verificationSucceeded && job.operation == .move ? .verified : job.verificationSucceeded ? .completed : .failed
                if !job.verificationSucceeded {
                    job.errorCode = "VERIFY_FAILED"
                    job.errorMessage = TransferServiceError.verificationFailed.localizedDescription
                }
            } else {
                job.state = .completed
                job.verificationSucceeded = false
            }
        } else if let requested = requestedControl {
            job.state = requested == .pause ? .paused : .stopped
        } else {
            job.state = .failed
            if job.errorCode == nil {
                job.errorCode = "TRANSFER_WORKER_FAILED"
                job.errorMessage = bounded(output(for: job))
            }
        }

        try? await runtimeStore.upsertTransferJob(job)
        let eventType: DiagnosticEventType
        switch job.state {
        case .verified: eventType = .transferVerified
        case .completed: eventType = .transferCompleted
        case .paused: eventType = .transferPaused
        case .stopped: eventType = .transferStopped
        default: eventType = .transferFailed
        }
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: eventType,
            source: "transfer",
            summary: eventType == .transferFailed ? "Transfer failed" : "Transfer finished",
            details: ["jobID": job.id.uuidString, "state": job.state.rawValue, "attempts": String(job.attempts)]
        ))
        if Self.shouldScheduleAutomaticRetry(job) {
            var retry = job
            retry.state = .queued
            retry.endedAt = nil
            let now = Date()
            retry.nextRetryAt = Self.nextRetryDate(afterAttempt: job.attempts, now: now)
            retry.updatedAt = now
            try? await runtimeStore.upsertTransferJob(retry)
            try? await runtimeStore.appendEvent(DiagnosticEvent(
                type: .transferProgress,
                source: "transfer",
                summary: "Transfer retry scheduled",
                details: [
                    "jobID": job.id.uuidString,
                    "attempts": String(job.attempts),
                    "retryMode": job.unlimitedAutoRetries == true ? "unlimited" : "finite",
                    "nextRetryAt": ISO8601DateFormatter().string(from: retry.nextRetryAt ?? now),
                ]
            ))
        } else if job.state == .failed, job.createIncidentOnFailure {
            _ = try? await createIncident(jobID: job.id)
        }
    }

    // shouldScheduleAutomaticRetry applies the snapshotted job policy and rejects permanent failures.
    nonisolated static func shouldScheduleAutomaticRetry(_ job: TransferJob) -> Bool {
        guard job.state == .failed,
              job.resumePolicy == .autoRetry,
              !terminalRetryErrorCodes.contains(job.errorCode ?? "") else {
            return false
        }
        return job.unlimitedAutoRetries == true || job.attempts <= job.maximumAutoRetries
    }

    // nextRetryDate returns a capped exponential deadline so unlimited count never means a tight loop.
    nonisolated static func nextRetryDate(afterAttempt attempt: Int, now: Date) -> Date {
        let exponent = min(6, max(0, attempt - 1))
        let delay = min(300.0, 5.0 * pow(2.0, Double(exponent)))
        return now.addingTimeInterval(delay)
    }

    // terminalRetryErrorCodes identifies failures that cannot become healthy without user correction.
    private nonisolated static let terminalRetryErrorCodes: Set<String> = [
        "VALIDATION_FAILED",
        "SOURCE_MISSING",
        "TRANSFER_NOT_FOUND",
        "PERMISSION_DENIED",
        "SECURITY_SCOPE_DENIED",
        "RUNNER_UNKNOWN",
        "RUNNER_UNTRUSTED",
    ]

    // classifiedNativeError separates permanent permission failures from transient I/O failures.
    private nonisolated static func classifiedNativeError(_ error: Error) -> NativeTransferError {
        let value = error as NSError
        let cocoaPermissionCodes: Set<Int> = [
            CocoaError.Code.fileReadNoPermission.rawValue,
            CocoaError.Code.fileWriteNoPermission.rawValue,
            CocoaError.Code.fileWriteVolumeReadOnly.rawValue,
        ]
        let permissionDenied = value.domain == NSCocoaErrorDomain && cocoaPermissionCodes.contains(value.code)
            || value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code)
        if permissionDenied {
            return NativeTransferError(code: "PERMISSION_DENIED", message: error.localizedDescription)
        }
        return NativeTransferError(code: "NATIVE_COPY_FAILED", message: error.localizedDescription)
    }

    // failQueued records a validation or environment failure before a runner starts.
    private func failQueued(job: TransferJob, code: String, message: String) async {
        var failed = job
        await releasePowerAssertion(jobID: job.id)
        failed.state = .failed
        failed.errorCode = code
        failed.errorMessage = bounded(message)
        failed.endedAt = Date()
        failed.updatedAt = Date()
        failed.powerAssertionActive = false
        failed.powerAssertionPID = nil
        try? await runtimeStore.upsertTransferJob(failed)
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: .transferFailed,
            source: "transfer",
            summary: "Transfer could not be started",
            details: ["jobID": job.id.uuidString, "code": code]
        ))
        if failed.createIncidentOnFailure {
            _ = try? await createIncident(jobID: failed.id)
        }
    }

    // failOrphanedLegacyRun makes pre-agent-owned jobs safe to resume instead of pretending they are still monitored.
    private func failOrphanedLegacyRun(job: TransferJob) async {
        var failed = job
        await releasePowerAssertion(jobID: job.id)
        failed.state = .failed
        failed.errorCode = "RUNNER_UNKNOWN"
        failed.errorMessage = "This transfer was marked as running, but no background-agent runner PID was recorded. Resume the job to continue safely."
        failed.endedAt = Date()
        failed.updatedAt = Date()
        failed.powerAssertionActive = false
        failed.powerAssertionPID = nil
        try? await runtimeStore.upsertTransferJob(failed)
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: .transferFailed,
            source: "transfer",
            summary: "Transfer monitoring recovered an orphaned legacy job",
            details: ["jobID": job.id.uuidString, "code": "RUNNER_UNKNOWN"]
        ))
        if failed.createIncidentOnFailure {
            _ = try? await createIncident(jobID: failed.id)
        }
    }

    // failRunning marks a monitored job failed without touching an untrusted or missing external process.
    private func failRunning(job: TransferJob, code: String, message: String) async {
        var failed = job
        await releasePowerAssertion(jobID: job.id)
        failed.state = .failed
        failed.errorCode = code
        failed.errorMessage = bounded(message)
        failed.runnerPID = nil
        failed.requestedControl = nil
        failed.endedAt = Date()
        failed.updatedAt = Date()
        failed.powerAssertionActive = false
        failed.powerAssertionPID = nil
        try? await runtimeStore.upsertTransferJob(failed)
        try? await runtimeStore.appendEvent(DiagnosticEvent(
            type: .transferFailed,
            source: "transfer",
            summary: "Transfer monitoring stopped an unsafe runner association",
            details: ["jobID": job.id.uuidString, "code": code]
        ))
        if failed.createIncidentOnFailure {
            _ = try? await createIncident(jobID: failed.id)
        }
    }

    // validate resolves one job back into a start request for resume-time checks.
    private func validate(job: TransferJob, settings: AppSettings, status: AgentStatus) throws {
        try validate(
            request: TransferStartRequest(
                operation: job.operation,
                direction: job.direction,
                resumePolicy: job.resumePolicy,
                unlimitedAutoRetries: job.unlimitedAutoRetries == true,
                sources: job.sources,
                destination: job.destination,
                keepMacAwake: job.keepMacAwake == true
            ),
            settings: settings,
            status: status
        )
    }

    // maintainPowerAssertion ties a caffeinate idle-sleep assertion to the signed transfer worker PID.
    private func maintainPowerAssertion(for job: TransferJob) async {
        guard job.keepMacAwake == true,
              let runnerPID = job.runnerPID,
              Self.processIsAlive(runnerPID) else {
            await releasePowerAssertion(jobID: job.id)
            return
        }
        if let current = powerAssertions[job.id], current.isRunning {
            if job.powerAssertionActive != true || job.powerAssertionPID != current.processIdentifier {
                var updated = job
                updated.powerAssertionActive = true
                updated.powerAssertionPID = current.processIdentifier
                updated.powerAssertionError = nil
                updated.updatedAt = Date()
                try? await runtimeStore.upsertTransferJob(updated)
            }
            return
        }
        if let assertionPID = job.powerAssertionPID,
           Self.processIsAlive(assertionPID),
           Self.processLooksLikePowerAssertion(assertionPID, runnerPID: runnerPID) {
            return
        }

        powerAssertions[job.id]?.terminate()
        powerAssertions[job.id] = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", String(runnerPID)]
        process.environment = ProcessRunner.minimalEnvironment()
        do {
            try process.run()
            powerAssertions[job.id] = process
            var updated = job
            updated.powerAssertionActive = true
            updated.powerAssertionPID = process.processIdentifier
            updated.powerAssertionError = nil
            updated.updatedAt = Date()
            try? await runtimeStore.upsertTransferJob(updated)
            try? await runtimeStore.appendEvent(DiagnosticEvent(
                type: .transferProgress,
                source: "transfer",
                summary: "Transfer keep-awake assertion acquired",
                details: ["jobID": job.id.uuidString, "assertionPID": String(process.processIdentifier)]
            ))
        } catch {
            var updated = job
            updated.powerAssertionActive = false
            updated.powerAssertionPID = nil
            updated.powerAssertionError = bounded(error.localizedDescription)
            updated.updatedAt = Date()
            try? await runtimeStore.upsertTransferJob(updated)
            try? await runtimeStore.appendEvent(DiagnosticEvent(
                type: .transferProgress,
                source: "transfer",
                summary: "Transfer keep-awake assertion failed",
                details: ["jobID": job.id.uuidString, "error": bounded(error.localizedDescription)]
            ))
        }
    }

    // releasePowerAssertion ends only the assertion owned by one transfer and clears persisted evidence.
    private func releasePowerAssertion(jobID: UUID) async {
        if let process = powerAssertions.removeValue(forKey: jobID), process.isRunning {
            process.terminate()
        }
        guard var job = await runtimeStore.readTransferJob(id: jobID),
              job.powerAssertionActive == true || job.powerAssertionPID != nil else { return }
        if let assertionPID = job.powerAssertionPID,
           let runnerPID = job.runnerPID,
           Self.processIsAlive(assertionPID),
           Self.processLooksLikePowerAssertion(assertionPID, runnerPID: runnerPID) {
            kill(assertionPID, SIGTERM)
        }
        job.powerAssertionActive = false
        job.powerAssertionPID = nil
        job.updatedAt = Date()
        try? await runtimeStore.upsertTransferJob(job)
    }

    // validate accepts connected SMB shares without requiring recovery-management enrollment.
    @discardableResult
    private func validate(request: TransferStartRequest, settings: AppSettings, status: AgentStatus) throws -> TransferDirection {
        guard !request.sources.isEmpty else {
            throw TransferServiceError.invalidRequest("At least one source file or folder is required.")
        }
        guard !request.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransferServiceError.invalidRequest("A destination folder is required.")
        }
        for source in request.sources {
            guard FileManager.default.fileExists(atPath: source) else {
                throw TransferServiceError.invalidRequest("Source does not exist: \(source)")
            }
        }
        let roots = mountRoots(settings: settings, status: status) + observedSMBRoots()
        let direction = try TransferPathSelection.direction(sources: request.sources, destination: request.destination, smbRoots: roots)
        if let requested = request.direction, requested != direction {
            throw TransferServiceError.invalidRequest("The transfer direction does not match the selected source and destination.")
        }
        return direction
    }

    // mountRoots combines agent-published local paths with live mount observations and safe conventional guesses.
    private func mountRoots(settings: AppSettings, status: AgentStatus) -> [URL] {
        mountRootPairs(settings: settings, status: status).map(\.root)
    }

    // mountRootPairs keeps root-to-definition metadata for capture host selection.
    private func mountRootPairs(settings: AppSettings, status: AgentStatus) -> [(mount: MountDefinition, root: URL)] {
        var roots: [(mount: MountDefinition, root: URL)] = []
        let enabled = settings.mounts.filter(\.enabled)
        for mount in enabled {
            if let state = status.mountStates?.first(where: { $0.mountID == mount.id }),
               let localPath = state.localPath {
                roots.append((mount, URL(fileURLWithPath: localPath).standardizedFileURL.resolvingSymlinksInPath()))
            }
        }
        let liveStates = mounts.runtimeStatesSynchronously(settings: settings)
        for mount in enabled {
            if let state = liveStates.first(where: { $0.mountID == mount.id }),
               let localPath = state.localPath {
                roots.append((mount, URL(fileURLWithPath: localPath).standardizedFileURL.resolvingSymlinksInPath()))
            }
        }
        for mount in enabled {
            guard let guessed = guessedVolumeRoot(for: mount),
                  FileManager.default.fileExists(atPath: guessed.path) else { continue }
            roots.append((mount, guessed))
        }
        var seen: Set<String> = []
        return roots.filter { pair in
            let key = "\(pair.mount.id.uuidString):\(pair.root.path)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }.sorted { (lhs: (mount: MountDefinition, root: URL), rhs: (mount: MountDefinition, root: URL)) in
            lhs.root.path < rhs.root.path
        }
    }

    // guessedVolumeRoot mirrors macOS' default SMB share mount naming when no status is fresh yet.
    private func guessedVolumeRoot(for mount: MountDefinition) -> URL? {
        guard let components = URLComponents(string: mount.url) else { return nil }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let name = decodedPath.split(separator: "/").last.map(String.init) ?? mount.name
        guard !name.isEmpty else { return nil }
        return URL(fileURLWithPath: "/Volumes").appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
    }

    // verify compares byte and file totals so missing zero-byte files cannot pass completion.
    private func verify(job: TransferJob) -> Bool {
        let destination = URL(fileURLWithPath: job.destination).standardizedFileURL
        for sourcePath in job.sources {
            let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
            let target = destination.appendingPathComponent(source.lastPathComponent)
            let sourceStats = totalStats(for: [source])
            let targetStats = totalStats(for: [target])
            guard FileManager.default.fileExists(atPath: target.path),
                  sourceStats.bytes == targetStats.bytes,
                  sourceStats.files == targetStats.files else {
                return false
            }
        }
        return true
    }

    // progressSnapshot combines worker output with filesystem totals for cross-process live status.
    private func progressSnapshot(job: TransferJob, previous: TransferProgress) -> TransferProgress {
        let now = Date()
        let stdout = job.stdoutPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let stderr = job.stderrPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let parsed = Self.parseProgress(stdout + "\n" + stderr)
        let sourceStats = totalStats(for: job.sources.map(URL.init(fileURLWithPath:)))
        let destinationStats = destinationStats(for: job)
        let previousCompleted = previous.completedBytes ?? 0
        let previousSnapshot = previous.snapshotAt ?? previous.updatedAt
        let elapsed = max(0.1, now.timeIntervalSince(previousSnapshot))
        let bytesPerSecond = destinationStats.bytes >= previousCompleted
            ? Double(destinationStats.bytes - previousCompleted) / elapsed
            : nil
        // Smooth ETA input so transient filesystem sampling spikes do not make the UI jump.
        let smoothedBytesPerSecond = Self.smoothedBytesPerSecond(
            current: bytesPerSecond,
            previous: previous.smoothedBytesPerSecond
        )
        let movedForward = destinationStats.bytes > previousCompleted
            || destinationStats.files > (previous.completedFiles ?? 0)
            || (parsed.transferredBytes ?? 0) > (previous.transferredBytes ?? 0)
        let lastProgressAt = movedForward ? now : previous.lastProgressAt ?? now
        let stallSeconds = Int(now.timeIntervalSince(lastProgressAt))
        let total = sourceStats.bytes == 0 ? (previous.totalBytes ?? 0) : sourceStats.bytes
        let overallPercent: Double?
        if total > 0 {
            overallPercent = min(100, max(0, Double(destinationStats.bytes) / Double(total) * 100))
        } else if sourceStats.files > 0 {
            overallPercent = min(100, max(0, Double(destinationStats.files) / Double(sourceStats.files) * 100))
        } else {
            overallPercent = 100
        }
        return TransferProgress(
            updatedAt: now,
            percent: overallPercent,
            transferredBytes: parsed.transferredBytes ?? previous.transferredBytes,
            currentPath: parsed.currentPath ?? previous.currentPath,
            totalBytes: total,
            completedBytes: destinationStats.bytes,
            totalFiles: sourceStats.files == 0 ? previous.totalFiles : sourceStats.files,
            completedFiles: destinationStats.files,
            bytesPerSecond: bytesPerSecond,
            smoothedBytesPerSecond: smoothedBytesPerSecond,
            lastProgressAt: lastProgressAt,
            stallSeconds: stallSeconds,
            highTrafficSince: previous.highTrafficSince,
            highTrafficSeconds: previous.highTrafficSeconds,
            snapshotAt: now
        )
    }

    // progressDetails serializes non-secret progress metrics for events and AI evidence.
    private func progressDetails(job: TransferJob) -> [String: String] {
        var details = [
            "jobID": job.id.uuidString,
            "state": job.state.rawValue,
            "attempts": String(job.attempts),
        ]
        if let total = job.progress.totalBytes { details["totalBytes"] = String(total) }
        if let completed = job.progress.completedBytes { details["completedBytes"] = String(completed) }
        if let totalFiles = job.progress.totalFiles { details["totalFiles"] = String(totalFiles) }
        if let completedFiles = job.progress.completedFiles { details["completedFiles"] = String(completedFiles) }
        if let bps = job.progress.bytesPerSecond { details["bytesPerSecond"] = String(Int(bps)) }
        if let bps = job.progress.smoothedBytesPerSecond { details["smoothedBytesPerSecond"] = String(Int(bps)) }
        if let stall = job.progress.stallSeconds { details["stallSeconds"] = String(stall) }
        if let highTraffic = job.progress.highTrafficSeconds { details["highTrafficSeconds"] = String(highTraffic) }
        if let current = job.progress.currentPath { details["currentPath"] = current }
        return details
    }

    // smoothedBytesPerSecond applies a bounded exponential moving average for user-facing ETA.
    private nonisolated static func smoothedBytesPerSecond(current: Double?, previous: Double?) -> Double? {
        guard let current, current.isFinite, current > 0 else { return previous }
        guard let previous, previous.isFinite, previous > 0 else { return current }
        let smoothingFactor = 0.2
        return previous + (current - previous) * smoothingFactor
    }

    // destinationStats sums only the target counterparts of the selected sources.
    private func destinationStats(for job: TransferJob) -> TransferTreeStats {
        let destination = URL(fileURLWithPath: job.destination).standardizedFileURL
        let targets = job.sources.map {
            destination.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent)
        }
        return totalStats(for: targets)
    }

    // totalStats recursively sums regular files and tolerates partially changing directories.
    private func totalStats(for urls: [URL]) -> TransferTreeStats {
        urls.reduce(into: TransferTreeStats(bytes: 0, files: 0)) { result, url in
            let stats = fileStats(url)
            result.bytes += stats.bytes
            result.files += stats.files
        }
    }

    // fileStats counts a file tree without following unrelated external paths.
    private func fileStats(_ url: URL) -> TransferTreeStats {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return TransferTreeStats(bytes: 0, files: 0) }
        if values.isRegularFile == true {
            return TransferTreeStats(bytes: UInt64(values.fileSize ?? 0), files: 1)
        }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return TransferTreeStats(bytes: 0, files: 0)
        }
        var stats = TransferTreeStats(bytes: 0, files: 0)
        for case let file as URL in enumerator {
            guard let fileValues = try? file.resourceValues(forKeys: keys),
                  fileValues.isRegularFile == true else { continue }
            stats.bytes += UInt64(fileValues.fileSize ?? 0)
            stats.files += 1
        }
        return stats
    }

    // totalBytes recursively sums regular-file sizes and treats unreadable paths as verification failures.
    private func totalBytes(_ url: URL) -> UInt64? {
        let stats = fileStats(url)
        return stats.files == 0 && !FileManager.default.fileExists(atPath: url.path) ? nil : stats.bytes
    }

    // isInsideConfiguredMount compares standardized paths with directory-boundary awareness.
    private func isInsideConfiguredMount(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    // normalizedPath makes stored paths deterministic while preserving user-selected targets.
    private func normalizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    // bounded prevents enormous worker output from becoming UI text.
    private func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }

    // output returns the terminal stderr/stdout text for user-visible failures.
    private func output(for job: TransferJob) -> String {
        let stdout = job.stdoutPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let stderr = job.stderrPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        return stderr.isEmpty ? stdout : stderr
    }

    // scheduleTransferCaptureIfNeeded records Pi evidence at transfer start or stall without blocking the agent cycle.
    private func scheduleTransferCaptureIfNeeded(job: TransferJob, settings: AppSettings, status: AgentStatus, reason: String) {
        guard settings.transfer.rollingPiCaptureEnabled,
              settings.packetCapture.enabled,
              !captureInFlight.contains(job.id) else { return }
        captureInFlight.insert(job.id)
        let pi = pi
        let runtimeStore = runtimeStore
        let captures = paths.captures
        let captureSettings = settings.packetCapture
        let host = captureHost(for: job, settings: settings, status: status)
        Task.detached {
            do {
                let metadata = try pi.startCapture(settings: captureSettings, hostFilter: host)
                let file = try pi.downloadCapture(metadata: metadata, settings: captureSettings, destinationDirectory: captures)
                let analysis = try? pi.analyzeCapture(metadata: metadata, settings: captureSettings)
                var event = analysis?.diagnosticEvent(metadata: metadata, localFile: file) ?? DiagnosticEvent(
                    timestamp: metadata.startedAt,
                    type: .packetCapture,
                    source: "raspberry-pi",
                    summary: "Transfer packet capture saved; protocol summary is unavailable",
                    details: ["session": metadata.id, "jobID": job.id.uuidString, "reason": reason],
                    evidencePath: file.path
                )
                event.details["jobID"] = job.id.uuidString
                event.details["reason"] = reason
                try? await runtimeStore.appendEvent(event)
                await self.recordCaptureFinished(jobID: job.id, eventID: event.id)
            } catch {
                try? await runtimeStore.appendEvent(DiagnosticEvent(
                    type: .warning,
                    source: "raspberry-pi",
                    summary: "Transfer packet capture failed",
                    details: ["jobID": job.id.uuidString, "reason": reason, "error": String(error.localizedDescription.prefix(500))]
                ))
                await self.recordCaptureFinished(jobID: job.id, eventID: nil)
            }
        }
    }

    // recordCaptureFinished releases the single-flight guard and links successful evidence to the job.
    private func recordCaptureFinished(jobID: UUID, eventID: UUID?) async {
        captureInFlight.remove(jobID)
        guard let eventID, var job = await runtimeStore.readTransferJob(id: jobID) else { return }
        if !job.evidenceIDs.contains(eventID) {
            job.evidenceIDs.append(eventID)
            job.updatedAt = Date()
            try? await runtimeStore.upsertTransferJob(job)
        }
    }

    // captureHost chooses the NAS host for a mounted transfer side when available.
    private func captureHost(for job: TransferJob, settings: AppSettings, status: AgentStatus) -> String? {
        let transferPath = URL(fileURLWithPath: job.direction == .macToNAS ? job.destination : (job.sources.first ?? "")).standardizedFileURL
        let pair = mountRootPairs(settings: settings, status: status).first { pair in
            isInsideConfiguredMount(transferPath, roots: [pair.root])
        }
        return pair.flatMap { URLComponents(string: $0.mount.url)?.host }
    }

    // parseProgress extracts the newest current-file progress line and its preceding path.
    private static func parseProgress(_ text: String) -> ParsedTransferProgress {
        var currentPath: String?
        var parsed = ParsedTransferProgress(percent: nil, transferredBytes: nil, currentPath: nil)
        for rawLine in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if let percentToken = parts.first(where: { $0.hasSuffix("%") }),
               let percent = Double(percentToken.dropLast()),
               let first = parts.first {
                parsed.percent = percent
                parsed.transferredBytes = UInt64(first.replacingOccurrences(of: ",", with: ""))
                parsed.currentPath = currentPath
            } else if !line.hasSuffix("/") {
                currentPath = line
            }
        }
        return parsed
    }

    // processIsAlive safely checks only a persisted runner PID.
    private static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    // workerExecutable resolves the installed or test-injected helper that can run transfer worker mode.
    private func workerExecutable() throws -> String {
        if let override = workerExecutablePathOverride,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let bundleExecutable = Bundle.main.executableURL?.path
        let installedHelper = "/Applications/We Rock Drive Mounts.app/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent"
        let candidates = [bundleExecutable, installedHelper].compactMap { $0 }
        for candidate in candidates {
            let name = URL(fileURLWithPath: candidate).lastPathComponent
            guard ["We Rock Drive Mount Agent", "wrdm-agent"].contains(name),
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        throw TransferServiceError.workerUnavailable
    }

    // processLooksLikeTransferRunner avoids signalling a reused PID after an agent restart.
    private static func processLooksLikeTransferRunner(_ pid: Int32) -> Bool {
        guard let result = try? ProcessRunner.run(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "comm=", "-o", "args="],
            timeout: 2
        ), result.exitCode == 0 else {
            return false
        }
        let processText = result.stdout.lowercased()
        return processText.contains("--transfer-worker")
    }

    // processLooksLikePowerAssertion prevents signalling an unrelated process after an agent restart.
    private static func processLooksLikePowerAssertion(_ pid: Int32, runnerPID: Int32) -> Bool {
        guard let result = try? ProcessRunner.run(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "comm=", "-o", "args="],
            timeout: 2
        ), result.exitCode == 0 else {
            return false
        }
        let processText = result.stdout.lowercased()
        return processText.contains("/usr/bin/caffeinate")
            && processText.contains("-w \(runnerPID)")
    }

    // isTerminal identifies states where no agent monitoring loop is needed.
    private static func isTerminal(_ state: TransferJobState) -> Bool {
        [.paused, .stopped, .failed, .completed, .verified, .finalized].contains(state)
    }
}

// TransferIncidentPayload stores the local blackbox data referenced by the incident manifest.
private struct TransferIncidentPayload: Codable {
    var manifest: TransferIncidentManifest
    var job: TransferJob?
    var status: AgentStatus
    var events: [DiagnosticEvent]
    var traffic: [InterfaceTrafficSample]
}
