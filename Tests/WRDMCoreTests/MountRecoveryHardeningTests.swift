import Darwin
import Foundation
import XCTest
@testable import WRDMCore

// MountRecoveryHardeningTests verifies the approved recovery matrix without touching real volumes.
final class MountRecoveryHardeningTests: XCTestCase {
    // testMissingMountRecoversAndClosesOneIncident covers the safe automatic mount path.
    func testMissingMountRecoversAndClosesOneIncident() async throws {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let result = await coordinator.reconcile(settings: settings(mount), mode: .automatic)

        XCTAssertEqual(result.states.first?.availability, .healthy)
        XCTAssertEqual(result.states.first?.recoveryPhase, .idle)
        XCTAssertEqual(system.mountRequestCount, 1)
        let incidents = await coordinator.recentIncidents()
        XCTAssertEqual(incidents.count, 1)
        XCTAssertNotNil(incidents.first?.closedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(incidents.first?.evidencePath)))
        let incidentID = try XCTUnwrap(incidents.first?.id)
        let evidenceEventID = UUID()
        await coordinator.attachEvidence(incidentID: incidentID, eventID: evidenceEventID, path: "/tmp/fixture.log")
        let linkedIncidents = await coordinator.recentIncidents()
        let linkedIncident = try XCTUnwrap(linkedIncidents.first)
        XCTAssertEqual(linkedIncident.evidenceEventIDs, [evidenceEventID])
        XCTAssertEqual(linkedIncident.diagnosticEvidencePaths, ["/tmp/fixture.log"])
        let recoveryRecords = await MountRecoveryStateStore(paths: paths).load()
        XCTAssertTrue(recoveryRecords.isEmpty)
    }

    // testAutomaticRecoveryOpensCircuitAtConfiguredLimit covers bounded retries without an endless loop.
    func testAutomaticRecoveryOpensCircuitAtConfiguredLimit() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.enqueueMountResults([.failure, .failure, .success])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        var configuration = settings(mount)
        configuration.general.maximumAutomaticRecoveryAttempts = 2
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = await coordinator.reconcile(settings: configuration, mode: .automatic, now: start)
        let second = await coordinator.reconcile(settings: configuration, mode: .automatic, now: start.addingTimeInterval(100))
        let third = await coordinator.reconcile(settings: configuration, mode: .automatic, now: start.addingTimeInterval(1_000))

        XCTAssertEqual(first.states.first?.recoveryPhase, .scheduled)
        XCTAssertEqual(second.states.first?.recoveryPhase, .circuitOpen)
        XCTAssertEqual(third.states.first?.recoveryPhase, .circuitOpen)
        XCTAssertEqual(third.states.first?.failureCode, .automaticAttemptLimitReached)
        XCTAssertEqual(system.mountRequestCount, 2)
    }

    // testMissingMountWaitsForReachableSMBWithoutConsumingRetry covers the network-unavailable matrix row.
    func testMissingMountWaitsForReachableSMBWithoutConsumingRetry() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.endpointReachable = false
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)
        let start = Date(timeIntervalSince1970: 1_500)

        let waiting = await coordinator.reconcile(settings: settings(mount), mode: .automatic, now: start)
        let stillWaiting = await coordinator.reconcile(settings: settings(mount), mode: .automatic, now: start.addingTimeInterval(1))
        system.endpointReachable = true
        let recovered = await coordinator.reconcile(settings: settings(mount), mode: .automatic, now: start.addingTimeInterval(600))

        XCTAssertEqual(waiting.states.first?.recoveryPhase, .waitingForNetwork)
        XCTAssertEqual(stillWaiting.states.first?.recoveryPhase, .waitingForNetwork)
        XCTAssertEqual(stillWaiting.states.first?.consecutiveFailures, 0)
        XCTAssertEqual(recovered.states.first?.availability, .healthy)
        XCTAssertEqual(system.mountRequestCount, 1)
    }

    // testStaleMountNeedsForceConfirmationAndNeverRemountsWhilePresent covers detach verification.
    func testStaleMountNeedsForceConfirmationAndNeverRemountsWhilePresent() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        system.normalDetachSucceeds = false
        system.enqueueNormalUnmountResults([.failure])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let first = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        let second = await coordinator.reconcile(settings: settings(mount), mode: .automatic, now: Date().addingTimeInterval(600))

        XCTAssertEqual(first.states.first?.availability, .staleMounted)
        XCTAssertEqual(first.states.first?.recoveryPhase, .manualConfirmationRequired)
        XCTAssertEqual(second.states.first?.recoveryPhase, .manualConfirmationRequired)
        XCTAssertEqual(system.normalUnmountRequestCount, 1)
        XCTAssertEqual(system.mountRequestCount, 0)
    }

    // testConfirmedForceRecoveryDetachesBeforeMount covers the separate destructive command path.
    func testConfirmedForceRecoveryDetachesBeforeMount() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        system.normalDetachSucceeds = false
        system.enqueueNormalUnmountResults([.failure])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)
        _ = await coordinator.reconcile(settings: settings(mount), mode: .automatic)

        let forced = await coordinator.reconcile(
            settings: settings(mount),
            mode: .confirmedForce,
            now: Date().addingTimeInterval(600)
        )

        XCTAssertEqual(forced.states.first?.availability, .healthy)
        XCTAssertEqual(system.forceUnmountRequestCount, 1)
        XCTAssertEqual(system.mountRequestCount, 1)
        XCTAssertEqual(Array(system.operationOrder.suffix(2)), ["force-unmount", "mount"])
    }

    // testActiveTransferBlocksNormalAndForceUnmount covers the transfer safety invariant.
    func testActiveTransferBlocksNormalAndForceUnmount() async throws {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        try await runtime.upsertTransferJob(TransferJob(
            operation: .copy,
            direction: .nasToMac,
            resumePolicy: .manual,
            sources: ["/Volumes/archive/large-file"],
            destination: "/tmp/destination",
            state: .running,
            maximumAutoRetries: 0,
            verifyAfterCopy: true,
            createIncidentOnFailure: true
        ))
        let system = FakeMountSystem()
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system, runtimeStore: runtime)

        let automatic = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        let forced = await coordinator.reconcile(settings: settings(mount), mode: .confirmedForce)

        XCTAssertEqual(automatic.states.first?.recoveryPhase, .deferredActiveTransfer)
        XCTAssertEqual(forced.states.first?.recoveryPhase, .deferredActiveTransfer)
        XCTAssertEqual(system.normalUnmountRequestCount, 0)
        XCTAssertEqual(system.forceUnmountRequestCount, 0)
    }

    // testKernelWaitBlocksEveryMutationUntilBootChanges covers the reboot-required terminal state.
    func testKernelWaitBlocksEveryMutationUntilBootChanges() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        system.enqueueNormalUnmountResults([.uninterruptible])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let trapped = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        let blocked = await coordinator.reconcile(settings: settings(mount), mode: .confirmedForce)
        system.currentBootIdentity = "boot-B"
        let afterReboot = await coordinator.reconcile(settings: settings(mount), mode: .automatic, now: Date().addingTimeInterval(600))

        XCTAssertEqual(trapped.states.first?.recoveryPhase, .restartRequired)
        XCTAssertEqual(trapped.states.first?.failureCode, .uninterruptibleKernelWait)
        XCTAssertEqual(blocked.states.first?.recoveryPhase, .restartRequired)
        XCTAssertNil(blocked.states.first?.nextAttemptAt)
        XCTAssertEqual(system.forceUnmountRequestCount, 0)
        XCTAssertEqual(afterReboot.states.first?.availability, .healthy)
        XCTAssertEqual(system.normalUnmountRequestCount, 2)
    }

    // testUnknownBootIdentityCannotClearRestartRequirement fails closed when no reboot can be proven.
    func testUnknownBootIdentityCannotClearRestartRequirement() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.currentBootIdentity = ""
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        system.enqueueNormalUnmountResults([.uninterruptible])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let trapped = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        system.currentBootIdentity = "boot-observed-later"
        let blocked = await coordinator.reconcile(settings: settings(mount), mode: .confirmedForce)

        XCTAssertEqual(trapped.states.first?.recoveryPhase, .restartRequired)
        XCTAssertEqual(blocked.states.first?.recoveryPhase, .restartRequired)
        XCTAssertEqual(system.forceUnmountRequestCount, 0)
    }

    // testSurvivingNonKernelProcessBlocksDuplicateMutation covers a living child without overstating kernel wait.
    func testSurvivingNonKernelProcessBlocksDuplicateMutation() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.configureStale(url: "smb://nas/archive", mountPoint: "/Volumes/archive")
        system.enqueueNormalUnmountResults([.running(processIdentifier: getpid())])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let first = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        let second = await coordinator.reconcile(settings: settings(mount), mode: .confirmedForce)

        XCTAssertEqual(first.states.first?.failureCode, .processStillRunning)
        XCTAssertEqual(second.states.first?.recoveryPhase, .manualConfirmationRequired)
        XCTAssertEqual(system.normalUnmountRequestCount, 1)
        XCTAssertEqual(system.forceUnmountRequestCount, 0)
    }

    // testServerLockPreventsConcurrentMutation covers agent, CLI, UI, and MCP serialization.
    func testServerLockPreventsConcurrentMutation() async throws {
        let paths = temporaryPaths()
        let token = try XCTUnwrap(MountOperationLock.acquire(server: "nas", paths: paths))
        let system = FakeMountSystem()
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        let result = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        withExtendedLifetime(token) {}

        XCTAssertEqual(result.states.first?.failureCode, .operationLocked)
        XCTAssertEqual(system.mountRequestCount, 0)
    }

    // testOneOutageReusesOneIncidentAndOneManifest covers incident and evidence deduplication.
    func testOneOutageReusesOneIncidentAndOneManifest() async {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let system = FakeMountSystem()
        system.enqueueMountResults([.failure, .failure])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system, runtimeStore: runtime)
        let start = Date(timeIntervalSince1970: 2_000)
        var configuration = settings(mount)
        configuration.diagnostics.enabled = true

        _ = await coordinator.reconcile(settings: configuration, mode: .automatic, now: start)
        _ = await coordinator.reconcile(settings: configuration, mode: .automatic, now: start.addingTimeInterval(600))

        let incidents = await coordinator.recentIncidents()
        let openedEvents = await runtime.recentEvents(limit: 100).filter { $0.type == .mountIncidentOpened }
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(openedEvents.count, 1)
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(at: paths.mountIncidents, includingPropertiesForKeys: nil).count, 1)
    }

    // testDiagnosticsDisabledKeepsOperationalIncidentWithoutDiagnosticEvents respects the global privacy switch.
    func testDiagnosticsDisabledKeepsOperationalIncidentWithoutDiagnosticEvents() async {
        let paths = temporaryPaths()
        let runtime = RuntimeFileStore(paths: paths)
        let system = FakeMountSystem()
        system.enqueueMountResults([.failure])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system, runtimeStore: runtime)

        _ = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        let incidents = await coordinator.recentIncidents()
        let events = await runtime.recentEvents(limit: 100)

        XCTAssertEqual(incidents.count, 1)
        XCTAssertTrue(events.isEmpty)
    }

    // testHealthyObservationClosesIncidentAfterCheckpointLoss covers a crash between incident and retry-state writes.
    func testHealthyObservationClosesIncidentAfterCheckpointLoss() async {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.enqueueMountResults([.failure])
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        let coordinator = MountRecoveryCoordinator(paths: paths, system: system)

        _ = await coordinator.reconcile(settings: settings(mount), mode: .automatic)
        try? FileManager.default.removeItem(at: paths.mountRecoveryFile)
        _ = system.requestMount(url: mount.url, timeout: 1)
        _ = await coordinator.reconcile(settings: settings(mount), mode: .automatic)

        let incidents = await coordinator.recentIncidents()
        XCTAssertEqual(incidents.count, 1)
        XCTAssertNotNil(incidents.first?.closedAt)
    }

    // testReadOnlyCheckAndForceConfirmationDoNotMutate covers truthful command boundaries.
    func testReadOnlyCheckAndForceConfirmationDoNotMutate() async throws {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        try await ConfigurationStore(paths: paths).save(settings(mount))
        let service = CommandService(paths: paths, mountSystem: system)

        let check = await service.execute(CommandRequest(command: "check"), actor: "test")
        let force = await service.execute(CommandRequest(command: "mounts.force-recover"), actor: "test")

        XCTAssertEqual(check.code, "MOUNTS_DEGRADED")
        XCTAssertEqual(force.code, "CONFIRMATION_REQUIRED")
        XCTAssertEqual(system.mountRequestCount, 0)
        XCTAssertEqual(system.forceUnmountRequestCount, 0)
        XCTAssertEqual(service.riskForCommand("check"), .readOnly)
    }

    // testUnknownMountTableResultIsNotReportedAsScheduled keeps command output truthful when observation fails.
    func testUnknownMountTableResultIsNotReportedAsScheduled() async throws {
        let paths = temporaryPaths()
        let system = FakeMountSystem()
        system.mountTableFailure = .mountTableUnavailable
        let mount = MountDefinition(name: "Archive", url: "smb://nas/archive")
        try await ConfigurationStore(paths: paths).save(settings(mount))
        let service = CommandService(paths: paths, mountSystem: system)

        let result = await service.execute(
            CommandRequest(command: "mounts.recover", confirmed: true),
            actor: "test"
        )

        XCTAssertEqual(result.code, "MOUNT_STATE_UNKNOWN")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(system.mountRequestCount, 0)
    }

    // testProcessClassificationAndPowerParserRequireRealEvidence covers both incident regressions.
    func testProcessClassificationAndPowerParserRequireRealEvidence() throws {
        let processState = ProcessRunner.classify(
            stillRunning: true,
            snapshots: [ProcessSnapshot(processIdentifier: 42, parentProcessIdentifier: 1, state: "U")]
        )
        XCTAssertEqual(processState, .uninterruptibleKernelWait)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let since = try XCTUnwrap(formatter.date(from: "2026-08-14 02:00:00 +0200"))
        let until = try XCTUnwrap(formatter.date(from: "2026-08-14 03:00:00 +0200"))
        let events = MacOSPowerEventSource.parse(
            "2026-08-14 02:11:00 +0200 Assertions PreventUserIdleSystemSleep active\n2026-08-14 02:12:00 +0200 Sleep Entering Sleep state\n2026-08-14 02:13:00 +0200 Wake Wake from Normal Sleep\n",
            since: since,
            until: until
        )
        XCTAssertEqual(events.map(\.type), [.sleep, .wake])
        XCTAssertTrue(events.allSatisfy { $0.source == "macOS-pmset" && $0.details["inferred"] == "false" })
    }

    // testAggregateAgentPhaseNeverCallsAnUnhealthyMountIdle keeps the menu-bar headline truthful.
    func testAggregateAgentPhaseNeverCallsAnUnhealthyMountIdle() {
        let mountID = UUID()
        let missing = MountRuntimeState(
            mountID: mountID,
            timestamp: Date(),
            availability: .missing,
            recoveryPhase: .scheduled,
            consecutiveFailures: 1,
            message: "Retry scheduled"
        )
        var terminal = missing
        terminal.recoveryPhase = .restartRequired

        XCTAssertEqual(AgentRuntime.statusPhase(for: [missing]), "degraded")
        XCTAssertEqual(AgentRuntime.statusPhase(for: [terminal]), "restartRequired")
    }

    // testProcessRunnerCorrelatesReparentedChildAfterTimeout covers helpers that outlive a killed parent.
    func testProcessRunnerCorrelatesReparentedChildAfterTimeout() {
        let previous = [
            ProcessSnapshot(processIdentifier: 40, parentProcessIdentifier: 1, state: "S"),
            ProcessSnapshot(processIdentifier: 41, parentProcessIdentifier: 40, state: "S"),
        ]
        let current = [
            ProcessSnapshot(processIdentifier: 41, parentProcessIdentifier: 1, state: "S"),
            ProcessSnapshot(processIdentifier: 99, parentProcessIdentifier: 1, state: "S"),
        ]
        let correlated = ProcessRunner.correlatedProcessTree(
            rootProcessIdentifier: 40,
            previouslyObserved: previous,
            current: current
        )
        XCTAssertEqual(correlated.map(\.processIdentifier), [41])
    }

    // testSchemaFiveRenamesRecoveryLimitOneWay covers configuration migration without a legacy output key.
    func testSchemaFiveRenamesRecoveryLimitOneWay() async throws {
        let paths = temporaryPaths()
        try paths.ensureDirectories()
        var legacy = AppSettings.defaults
        legacy.schemaVersion = 5
        var format = PropertyListSerialization.PropertyListFormat.xml
        var dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: PropertyListEncoder().encode(legacy),
            options: [],
            format: &format
        ) as? [String: Any])
        var general = try XCTUnwrap(dictionary["general"] as? [String: Any])
        general["failuresBeforeReset"] = 7
        general.removeValue(forKey: "maximumAutomaticRecoveryAttempts")
        dictionary["general"] = general
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: paths.configFile)

        let migrated = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.general.maximumAutomaticRecoveryAttempts, 7)
        let persisted = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.configFile),
            options: [],
            format: &format
        ) as? [String: Any])
        let persistedGeneral = try XCTUnwrap(persisted["general"] as? [String: Any])
        XCTAssertNil(persistedGeneral["failuresBeforeReset"])
        XCTAssertEqual(persistedGeneral["maximumAutomaticRecoveryAttempts"] as? Int, 7)
    }

    // settings creates one deterministic configuration for a fake SMB share.
    private func settings(_ mount: MountDefinition) -> AppSettings {
        var value = AppSettings.defaults
        value.mounts = [mount]
        value.diagnostics.enabled = false
        value.network.enabled = false
        value.network.trafficEnabled = false
        return value
    }

    // temporaryPaths isolates recovery state, locks, incidents, and transfer fixtures.
    private func temporaryPaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-recovery-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppPaths(homeDirectory: root)
    }
}

// FakeMountSystem simulates mount-table transitions and records every attempted mutation.
private final class FakeMountSystem: MountSystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [MountedShare] = []
    private var healthyMountPoints: Set<String> = []
    private var queuedMountResults: [ProcessResult] = []
    private var queuedNormalUnmountResults: [ProcessResult] = []
    private var queuedForceUnmountResults: [ProcessResult] = []
    private var mountRequests = 0
    private var normalUnmountRequests = 0
    private var forceUnmountRequests = 0
    private var operations: [String] = []
    var endpointReachable = true
    var normalDetachSucceeds = true
    var forceDetachSucceeds = true
    var currentBootIdentity = "boot-A"
    var mountTableFailure: MountFailureCode?

    // configureStale adds one present mount whose SMB health check fails.
    func configureStale(url: String, mountPoint: String) {
        locked {
            shares = [MountedShare(normalizedURL: SMBMountTableParser.normalize(url), mountPoint: mountPoint)]
            healthyMountPoints.remove(mountPoint)
        }
    }

    // enqueueMountResults controls successive fake mount outcomes.
    func enqueueMountResults(_ values: [ProcessResult]) {
        locked { queuedMountResults.append(contentsOf: values) }
    }

    // enqueueNormalUnmountResults controls successive normal-unmount outcomes.
    func enqueueNormalUnmountResults(_ values: [ProcessResult]) {
        locked { queuedNormalUnmountResults.append(contentsOf: values) }
    }

    // mountRequestCount returns the number of fake mount mutations.
    var mountRequestCount: Int { locked { mountRequests } }

    // normalUnmountRequestCount returns the number of normal fake unmount mutations.
    var normalUnmountRequestCount: Int { locked { normalUnmountRequests } }

    // forceUnmountRequestCount returns the number of force fake unmount mutations.
    var forceUnmountRequestCount: Int { locked { forceUnmountRequests } }

    // operationOrder returns a stable copy of the mutation sequence.
    var operationOrder: [String] { locked { operations } }

    // mountTable returns the current deterministic fake mount table.
    func mountTable() -> MountTableObservation {
        locked {
            MountTableObservation(
                shares: shares,
                failureCode: mountTableFailure,
                message: mountTableFailure == nil ? nil : "Fixture mount table unavailable"
            )
        }
    }

    // sessionHealth reports health only for mount points explicitly marked after a successful mount.
    func sessionHealth(mountPoint: String, timeout: TimeInterval) -> MountHealthObservation {
        locked {
            healthyMountPoints.contains(mountPoint)
                ? MountHealthObservation(healthy: true, message: "Connected")
                : MountHealthObservation(healthy: false, timedOut: true, message: "SMB health check timed out")
        }
    }

    // endpointIsReachable returns the configured fake port-445 state.
    func endpointIsReachable(host: String) -> Bool {
        locked { endpointReachable }
    }

    // requestMount records one mount request and adds a healthy table entry after success.
    func requestMount(url: String, timeout: TimeInterval) -> ProcessResult {
        locked {
            mountRequests += 1
            operations.append("mount")
            let result = queuedMountResults.isEmpty ? .success : queuedMountResults.removeFirst()
            if result.exitCode == 0 {
                let shareName = URLComponents(string: url)?.path.split(separator: "/").last.map(String.init) ?? "share"
                let mountPoint = "/Volumes/\(shareName)"
                shares.removeAll { $0.normalizedURL == SMBMountTableParser.normalize(url) }
                shares.append(MountedShare(normalizedURL: SMBMountTableParser.normalize(url), mountPoint: mountPoint))
                healthyMountPoints.insert(mountPoint)
            }
            return result
        }
    }

    // requestUnmount records the requested mode and removes the matching table entry only when configured.
    func requestUnmount(mountPoint: String, force: Bool, timeout: TimeInterval) -> ProcessResult {
        locked {
            let result: ProcessResult
            if force {
                forceUnmountRequests += 1
                operations.append("force-unmount")
                result = queuedForceUnmountResults.isEmpty ? .success : queuedForceUnmountResults.removeFirst()
            } else {
                normalUnmountRequests += 1
                operations.append("normal-unmount")
                result = queuedNormalUnmountResults.isEmpty ? .success : queuedNormalUnmountResults.removeFirst()
            }
            if result.exitCode == 0, force ? forceDetachSucceeds : normalDetachSucceeds {
                shares.removeAll { $0.mountPoint == mountPoint }
                healthyMountPoints.remove(mountPoint)
            }
            return result
        }
    }

    // bootIdentity returns the configurable fake kernel-boot identity.
    func bootIdentity() -> String {
        locked { currentBootIdentity }
    }

    // locked serializes fake state so task-group health checks remain deterministic.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// ProcessResult fixtures keep the fake adapter call sites concise and explicit.
private extension ProcessResult {
    static let success = ProcessResult(exitCode: 0, stdout: "OK", stderr: "", timedOut: false)
    static let failure = ProcessResult(exitCode: 1, stdout: "", stderr: "fixture failure", timedOut: false)
    static let uninterruptible = ProcessResult(
        exitCode: 124,
        stdout: "",
        stderr: "fixture timeout",
        timedOut: true,
        processIdentifier: 42,
        sentSignals: [15, 9],
        stillRunning: true,
        executionState: .uninterruptibleKernelWait,
        descendants: [ProcessSnapshot(processIdentifier: 42, parentProcessIdentifier: 1, state: "U")]
    )

    // running creates one timeout fixture whose surviving PID can be safely probed but is never signalled.
    static func running(processIdentifier: Int32) -> ProcessResult {
        ProcessResult(
            exitCode: 124,
            stdout: "",
            stderr: "fixture timeout",
            timedOut: true,
            processIdentifier: processIdentifier,
            sentSignals: [15, 9],
            stillRunning: true,
            executionState: .running,
            descendants: [ProcessSnapshot(processIdentifier: processIdentifier, parentProcessIdentifier: 1, state: "S")]
        )
    }
}
