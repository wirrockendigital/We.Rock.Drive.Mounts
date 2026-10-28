import Foundation
import UserNotifications

// AgentRuntime performs one bounded monitoring cycle and publishes a single status snapshot.
public actor AgentRuntime {
    public let paths: AppPaths
    private let settingsStore: ConfigurationStore
    private let runtimeStore: RuntimeFileStore
    private let recovery: MountRecoveryCoordinator
    private let powerEvents: any PowerEventProviding
    private let diagnostics: DiagnosticsService
    private let pi = PiCompanionClient()
    private let synology = SynologyService()
    private let transfer: TransferService
    private var networkLoopActive = false
    private var lastCycleAt: Date?
    private var mountEvidenceCapturesInFlight: Set<UUID> = []
    private var wakeEvidenceCaptureInFlight = false
    private var lastSynologyPoll: Date?

    public init(
        paths: AppPaths = AppPaths(),
        mountSystem: any MountSystemProviding = MacOSMountSystem(),
        powerEvents: any PowerEventProviding = MacOSPowerEventSource()
    ) {
        self.paths = paths
        settingsStore = ConfigurationStore(paths: paths)
        let sharedRuntimeStore = RuntimeFileStore(paths: paths)
        runtimeStore = sharedRuntimeStore
        recovery = MountRecoveryCoordinator(paths: paths, system: mountSystem, runtimeStore: sharedRuntimeStore)
        self.powerEvents = powerEvents
        diagnostics = DiagnosticsService(paths: paths)
        transfer = TransferService(paths: paths, runtimeStore: sharedRuntimeStore)
    }

    // run continuously reloads settings so UI and CLI changes apply without restart.
    public func run() async {
        ProcessRunner.sanitizeCurrentProcessEnvironment()
        if let settings = try? await settingsStore.load() {
            if settings.diagnostics.enabled {
                try? await runtimeStore.appendEvent(DiagnosticEvent(type: .agentStarted, source: "agent", summary: "Background agent started"))
            }
            if settings.general.bootDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(settings.general.bootDelaySeconds))
            }
        }
        // A separate task owns network state while the mount actor performs slower recovery work.
        networkLoopActive = true
        let networkTask = Task.detached { [paths] in await NetworkMonitor.run(paths: paths) }
        // Update checks remain active even when mount recovery is paused or the visible app is closed.
        let updateTask = Task.detached { [paths] in
            let updates = UpdateService(paths: paths)
            while !Task.isCancelled {
                let snapshot = await updates.checkIfDue()
                await Self.notifyUpdateIfNeeded(snapshot, updates: updates)
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
        defer { networkTask.cancel(); updateTask.cancel(); networkLoopActive = false }
        while !Task.isCancelled {
            let interval = await runOneCycle()
            try? await Task.sleep(for: .seconds(max(5, interval)))
        }
        if let settings = try? await settingsStore.load(), settings.diagnostics.enabled {
            try? await runtimeStore.appendEvent(DiagnosticEvent(type: .agentStopped, source: "agent", summary: "Background agent stopped"))
        }
    }

    // notifyUpdateIfNeeded shows one quiet system notice per version after notification consent.
    private nonisolated static func notifyUpdateIfNeeded(_ snapshot: UpdateSnapshot, updates: UpdateService) async {
        guard let version = snapshot.availableVersion, version != snapshot.lastNotifiedVersion else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "We Rock Drive Mounts \(version) verfügbar"
        content.body = "Öffne die App, um das Update anzusehen und zu installieren."
        do {
            try await center.add(UNNotificationRequest(identifier: "wrdm-update-\(version)", content: content, trigger: nil))
            await updates.markNotified(version: version)
        } catch {
            // A failed notification remains eligible for a later retry.
        }
    }

    // runOneCycle observes independent health checks before one bounded automatic recovery pass.
    @discardableResult
    public func runOneCycle() async -> Int {
        do {
            let settings = try await settingsStore.load()
            let cycleStartedAt = Date()
            let collectorStates = CollectorRuntimeState.states(settings: settings)
            if settings.diagnostics.enabled, settings.diagnostics.sleepWakeEventsEnabled {
                let confirmedPowerEvents = powerEvents.events(since: lastCycleAt, until: cycleStartedAt)
                for event in confirmedPowerEvents {
                    try? await runtimeStore.appendEvent(event)
                }
                for event in AgentTimelinePlanner.transitionEvents(
                    lastCycleAt: lastCycleAt,
                    now: cycleStartedAt,
                    checkIntervalSeconds: settings.general.checkIntervalSeconds
                ) {
                    try? await runtimeStore.appendEvent(event)
                }
                if settings.diagnostics.macLogsEnabled, confirmedPowerEvents.contains(where: { $0.type == .wake }) {
                    scheduleEvidenceCapture(settings: settings, mount: nil, incidentID: nil)
                }
            }
            guard settings.general.enabled else {
                try await runtimeStore.writeStatus(AgentStatus(
                    timestamp: Date(),
                    phase: "disabled",
                    enabledMounts: settings.mounts.filter(\.enabled).count,
                    healthyMounts: 0,
                    lanHealthy: false,
                    wifiEnabled: false,
                    fallbackActive: false,
                    lastError: nil,
                    collectorStates: collectorStates
                ))
                lastCycleAt = cycleStartedAt
                return settings.general.checkIntervalSeconds
            }

            let files = NetworkFiles(paths: paths)
            let networkReport = networkLoopActive ? files.report() : try files.tick(settings: settings, periodic: true)
            let policyState = networkReport?.policyState ?? .empty
            let snapshot = NetworkSnapshot(lanHasAddress: networkReport?.observation.selected?.usable == true,
                defaultRouteInterface: networkReport?.observation.inventory.defaultIPv4 ?? "",
                gatewayReachable: true, remoteHostsReachable: true,
                wifiEnabled: networkReport?.execution.observedWiFiEnabled ?? false)
            let networkExecution = networkReport?.execution ?? NetworkPolicyExecution(timestamp: Date(), requestedAction: .none,
                reason: "Network observation pending", mutationAttempted: false, mutationSucceeded: nil,
                observedWiFiEnabled: false, fallbackActive: false, error: nil)

            let batch = await recovery.reconcile(settings: settings, mode: .automatic)
            for mountID in batch.newlyOpenedMountIDs {
                let mount = settings.mounts.first { $0.id == mountID }
                let incidentID = batch.states.first { $0.mountID == mountID }?.incidentID
                scheduleEvidenceCapture(settings: settings, mount: mount, incidentID: incidentID)
            }
            let recovered = batch.states

            if settings.diagnostics.enabled, settings.synology.syslogEnabled {
                await collectSynologyEvents(settings: settings)
            }

            _ = try? await runtimeStore.enforceRetentionIfNeeded(
                policy: settings.diagnostics,
                trafficMaxBytes: settings.network.trafficMaxBytes
            )

            let phase = Self.statusPhase(for: recovered)
            let status = AgentStatus(
                timestamp: Date(),
                phase: phase,
                enabledMounts: settings.mounts.filter(\.enabled).count,
                healthyMounts: recovered.filter { $0.availability == .healthy }.count,
                lanHealthy: snapshot.lanHealthy,
                wifiEnabled: networkExecution.observedWiFiEnabled,
                fallbackActive: policyState.fallbackActive,
                lastError: networkExecution.error ?? recovered.first(where: { ![MountAvailability.healthy, .disabled].contains($0.availability) })?.message,
                mountStates: recovered,
                networkExecution: networkExecution,
                collectorStates: collectorStates
            )
            try await runtimeStore.writeStatus(status)
            await transfer.reconcile(settings: settings, status: status)
            lastCycleAt = cycleStartedAt
            return settings.general.checkIntervalSeconds
        } catch {
            lastCycleAt = Date()
            try? await runtimeStore.writeStatus(AgentStatus(
                timestamp: Date(),
                phase: "error",
                enabledMounts: 0,
                healthyMounts: 0,
                lanHealthy: false,
                wifiEnabled: false,
                fallbackActive: false,
                lastError: String(error.localizedDescription.prefix(500))
            ))
            return 20
        }
    }

    // statusPhase makes every unhealthy active mount visible at the aggregate agent level.
    public nonisolated static func statusPhase(for states: [MountRuntimeState]) -> String {
        if states.contains(where: { $0.recoveryPhase == .restartRequired }) { return "restartRequired" }
        if states.contains(where: { ![MountAvailability.healthy, .disabled].contains($0.availability) }) { return "degraded" }
        return "idle"
    }

    // scheduleEvidenceCapture permits one capture per mount incident and one concurrent wake capture.
    private func scheduleEvidenceCapture(settings: AppSettings, mount: MountDefinition?, incidentID: UUID?) {
        guard settings.diagnostics.enabled else { return }
        if let mount {
            guard mountEvidenceCapturesInFlight.insert(mount.id).inserted else { return }
        } else {
            guard !wakeEvidenceCaptureInFlight else { return }
            wakeEvidenceCaptureInFlight = true
        }
        let diagnostics = diagnostics
        let pi = pi
        let runtimeStore = runtimeStore
        let recovery = recovery
        let captures = paths.captures
        let host = mount.flatMap { URLComponents(string: $0.url)?.host }
        Task.detached {
            if settings.diagnostics.macLogsEnabled {
                do {
                    let file = try diagnostics.captureMacEvidence(
                        lookbackMinutes: settings.diagnostics.macLogLookbackMinutes,
                        label: mount == nil ? "wake" : "mount-incident"
                    )
                    let event = DiagnosticEvent(
                        type: .warning,
                        source: "macOS",
                        summary: "macOS diagnostic evidence saved",
                        details: ["mountID": mount?.id.uuidString ?? "", "incidentID": incidentID?.uuidString ?? ""],
                        evidencePath: file.path
                    )
                    try? await runtimeStore.appendEvent(event)
                    if let incidentID {
                        await recovery.attachEvidence(incidentID: incidentID, eventID: event.id, path: file.path)
                    }
                } catch {
                    try? await runtimeStore.appendEvent(Self.captureFailure(source: "macOS", error: error))
                }
            }
            if settings.packetCapture.enabled {
                do {
                    let metadata = try pi.startCapture(settings: settings.packetCapture, hostFilter: host)
                    let file = try pi.downloadCapture(
                        metadata: metadata,
                        settings: settings.packetCapture,
                        destinationDirectory: captures
                    )
                    let analysis = try? pi.analyzeCapture(metadata: metadata, settings: settings.packetCapture)
                    let event = analysis?.diagnosticEvent(metadata: metadata, localFile: file) ?? DiagnosticEvent(
                        timestamp: metadata.startedAt,
                        type: .packetCapture,
                        source: "raspberry-pi",
                        summary: "Network packet capture saved; protocol summary is unavailable",
                        details: ["session": metadata.id, "mountID": mount?.id.uuidString ?? "", "incidentID": incidentID?.uuidString ?? ""],
                        evidencePath: file.path
                    )
                    var linkedEvent = event
                    linkedEvent.details["mountID"] = mount?.id.uuidString ?? ""
                    linkedEvent.details["incidentID"] = incidentID?.uuidString ?? ""
                    try? await runtimeStore.appendEvent(linkedEvent)
                    if let incidentID {
                        await recovery.attachEvidence(incidentID: incidentID, eventID: linkedEvent.id, path: file.path)
                    }
                } catch {
                    try? await runtimeStore.appendEvent(Self.captureFailure(source: "raspberry-pi", error: error))
                }
            }
            await self.evidenceCaptureFinished(mountID: mount?.id)
        }
    }

    // evidenceCaptureFinished releases the incident-specific collection guard.
    private func evidenceCaptureFinished(mountID: UUID?) {
        if let mountID {
            mountEvidenceCapturesInFlight.remove(mountID)
        } else {
            wakeEvidenceCaptureInFlight = false
        }
    }

    // collectSynologyEvents polls a bounded Pi syslog tail and persists source-reference deduplication.
    private func collectSynologyEvents(settings: AppSettings) async {
        if let lastSynologyPoll, Date().timeIntervalSince(lastSynologyPoll) < 60 { return }
        lastSynologyPoll = Date()
        do {
            let text = try pi.readSyslog(settings: settings.packetCapture, limit: 200)
            for event in synology.parseSyslog(text) {
                var diagnostic = synology.diagnosticEvent(event)
                diagnostic.summary = diagnostics.redact(diagnostic.summary)
                diagnostic.details = diagnostic.details.mapValues(diagnostics.redact)
                _ = try? await runtimeStore.appendSynologyEventIfNew(diagnostic)
            }
        } catch {
            try? await runtimeStore.appendEvent(Self.captureFailure(source: "synology", error: error))
        }
    }

    // captureFailure converts a bounded collection error into visible non-secret evidence.
    private static func captureFailure(source: String, error: Error) -> DiagnosticEvent {
        DiagnosticEvent(
            type: .warning,
            source: source,
            summary: "Diagnostic evidence collection failed",
            details: ["error": String(error.localizedDescription.prefix(500))]
        )
    }
}

// AgentTimelinePlanner reports monitoring delay without inventing sleep or wake events.
public enum AgentTimelinePlanner {
    // transitionEvents returns one neutral delay event when the monitoring gap exceeds normal drift.
    public static func transitionEvents(
        lastCycleAt: Date?,
        now: Date,
        checkIntervalSeconds: Int
    ) -> [DiagnosticEvent] {
        guard let lastCycleAt else { return [] }
        let gap = now.timeIntervalSince(lastCycleAt)
        let threshold = Double(max(60, checkIntervalSeconds * 3))
        guard gap > threshold else { return [] }
        return [DiagnosticEvent(
            timestamp: now,
            type: .monitoringDelayed,
            source: "agent-scheduler",
            summary: "Monitoring resumed after an extended scheduling gap",
            details: ["gapSeconds": String(Int(gap)), "powerStateInferred": "false"]
        )]
    }
}
