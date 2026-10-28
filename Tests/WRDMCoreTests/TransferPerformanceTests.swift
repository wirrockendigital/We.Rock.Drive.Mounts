import Foundation
import XCTest
@testable import WRDMCore

// Performance changes must preserve content, resumability, and independently requested controls.
final class TransferPerformanceTests: XCTestCase {
    // Copy many tiny files plus a resumed prefix, then verify every byte and exact final counters.
    func testBatchedProgressCopiesAndResumesEveryByte() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("target")
        let copied = destination.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        let payload = Data(repeating: 31, count: 88)
        for index in 0..<512 {
            try payload.write(to: source.appendingPathComponent("file-\(index)"))
        }
        try payload.prefix(17).write(to: copied.appendingPathComponent("file-0"))
        try payload.write(to: copied.appendingPathComponent("file-99"))
        let runtime = RuntimeFileStore(paths: paths)
        let job = TransferJob(operation: .copy, direction: .macToNAS, resumePolicy: .manual,
            sources: [source.path], destination: destination.path, state: .running,
            maximumAutoRetries: 0, verifyAfterCopy: true, createIncidentOnFailure: false)
        try await runtime.upsertTransferJob(job)
        let code = await TransferService.runWorker(jobID: job.id, paths: paths)
        XCTAssertEqual(code, 0)
        for index in 0..<512 {
            XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("file-\(index)")), payload)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("file-\(index)")), payload)
        }
        let final = await runtime.readTransferJob(id: job.id)
        XCTAssertEqual(final?.progress.completedBytes, UInt64(512 * 88))
        XCTAssertEqual(final?.progress.completedFiles, 512)
    }

    // Separate store instances represent agent and worker processes sharing one locked state file.
    func testProgressMutationPreservesControlAndConcurrentCounters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let worker = RuntimeFileStore(paths: paths)
        let agent = RuntimeFileStore(paths: paths)
        let job = TransferJob(operation: .copy, direction: .macToNAS, resumePolicy: .manual,
            sources: [root.appendingPathComponent("source").path], destination: root.appendingPathComponent("target").path,
            state: .running, maximumAutoRetries: 0, verifyAfterCopy: true, createIncidentOnFailure: false)
        try await worker.upsertTransferJob(job)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await worker.mutateTransferJob(id: job.id) { $0.progress.completedFiles = ($0.progress.completedFiles ?? 0) + 1 }
                }
            }
            group.addTask {
                try await agent.mutateTransferJob(id: job.id) { $0.requestedControl = .pause }
            }
            try await group.waitForAll()
        }
        let final = await worker.readTransferJob(id: job.id)
        XCTAssertEqual(final?.requestedControl, .pause)
        XCTAssertEqual(final?.progress.completedFiles, 20)
    }
    // A persisted stop must be honored before any source bytes are written.
    func testWorkerHonorsPendingStopBeforeCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("target")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let runtime = RuntimeFileStore(paths: paths)
        var job = TransferJob(operation: .copy, direction: .macToNAS, resumePolicy: .manual,
            sources: [source.path], destination: destination.path, state: .running,
            maximumAutoRetries: 0, verifyAfterCopy: true, createIncidentOnFailure: false)
        job.requestedControl = .stop
        try await runtime.upsertTransferJob(job)
        let result = await TransferService.runWorker(jobID: job.id, paths: paths)
        XCTAssertNotEqual(result, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.bin").path))
        let stopped = await runtime.readTransferJob(id: job.id)
        XCTAssertEqual(stopped?.requestedControl, .stop)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

}
