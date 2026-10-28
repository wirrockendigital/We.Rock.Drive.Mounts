import Foundation
import XCTest
@testable import WRDMCore

// Transfer selection must recognize mounted shares independently of recovery configuration.
final class TransferSelectionTests: XCTestCase {
    // A directory with hidden files can be queued and copied to an unconfigured SMB fixture.
    func testAutomaticDirectionAndCopyOnUnconfiguredShare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let source = root.appendingPathComponent(".codex")
        let nas = root.appendingPathComponent("volume-2-folder-2")
        let local = root.appendingPathComponent("returned")
        for directory in [source, nas, local] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = Data("synthetic fixture only".utf8)
        try payload.write(to: source.appendingPathComponent(".hidden"))
        let runtime = RuntimeFileStore(paths: paths)
        let service = TransferService(paths: paths, runtimeStore: runtime, observedSMBRoots: { [nas] })
        var settings = AppSettings.defaults
        settings.mounts = []
        let request = TransferStartRequest(operation: .copy, direction: nil, resumePolicy: .manual,
            unlimitedAutoRetries: false, sources: [source.path], destination: nas.path, keepMacAwake: false)
        var job = try await service.start(request: request, settings: settings, status: .unavailable)
        XCTAssertEqual(job.direction, .macToNAS)
        job.state = .running
        try await runtime.upsertTransferJob(job)
        let result = await TransferService.runWorker(jobID: job.id, paths: paths)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(try Data(contentsOf: nas.appendingPathComponent(".codex/.hidden")), payload)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".hidden")), payload)
        var reverse = request
        reverse.sources = [nas.appendingPathComponent(".codex").path]
        reverse.destination = local.path
        let reverseJob = try await service.start(request: reverse, settings: settings, status: .unavailable)
        XCTAssertEqual(reverseJob.direction, .nasToMac)
        reverse.direction = .macToNAS
        do {
            _ = try await service.start(request: reverse, settings: settings, status: .unavailable)
            XCTFail("Explicit incorrect direction must be rejected")
        } catch let error as TransferServiceError {
            XCTAssertTrue(error.localizedDescription.contains("direction"))
        }
    }

    // The command contract accepts auto and reaches path validation without queuing invalid work.
    func testCommandAutoDirectionReachesSharedValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let commands = CommandService(paths: paths)
        let result = await commands.execute(CommandRequest(command: "transfer.start",
            arguments: ["copy", "auto", "manual", "false", "false", root.path, root.path], confirmed: true), actor: "app")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Select files on your Mac and a connected SMB destination, or SMB sources and a folder on your Mac.")
        let jobs = await commands.runtimeStore.readTransferJobs()
        XCTAssertTrue(jobs.isEmpty)
    }

    // Boundary checks reject local-only, SMB-only, mixed-source and detached-share requests.
    func testDirectionRejectsInvalidCombinations() throws {
        let nas = URL(fileURLWithPath: "/Volumes/TransferFixture")
        XCTAssertEqual(try TransferPathSelection.direction(sources: ["/tmp/input"], destination: nas.path, smbRoots: [nas]), .macToNAS)
        for (sources, destination, roots) in [
            (["/tmp/input"], "/tmp/output", [nas]),
            ([nas.path + "/input"], nas.path + "/output", [nas]),
            ([nas.path + "/input", "/tmp/input"], "/tmp/output", [nas]),
            (["/tmp/input"], nas.path + "-other", [nas]),
            (["/tmp/input"], nas.path, [])
        ] {
            XCTAssertThrowsError(try TransferPathSelection.direction(sources: sources, destination: destination, smbRoots: roots))
        }
    }

    // Symlinks must not misclassify a NAS source as a local source.
    func testDirectionResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nas = root.appendingPathComponent("nas")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nas)
        XCTAssertEqual(try TransferPathSelection.direction(sources: [alias.path], destination: root.path, smbRoots: [nas]), .nasToMac)
    }
}
