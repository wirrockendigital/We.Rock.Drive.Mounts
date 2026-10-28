import Darwin
import Foundation

// CommandRequest is the canonical command shared by UI, CLI, AI, and MCP.
public struct CommandRequest: Codable, Equatable, Sendable {
    public var command: String
    public var arguments: [String]
    public var confirmed: Bool

    public init(command: String, arguments: [String] = [], confirmed: Bool = false) {
        self.command = command
        self.arguments = arguments
        self.confirmed = confirmed
    }
}

// CommandService routes requests through one settings, policy, audit, and adapter boundary.
public actor CommandService {
    public let paths: AppPaths
    public let settingsStore: ConfigurationStore
    public let runtimeStore: RuntimeFileStore
    private let recovery: MountRecoveryCoordinator
    private let network = NetworkService()
    private let interactiveNetworkAuthorization: Bool
    private let diagnostics: DiagnosticsService
    private let pi = PiCompanionClient()
    private let synology = SynologyService()
    private let dsm = SynologyDSMAPIClient()
    private let wake = WakeService()
    private let liveCapture = LiveCaptureService()
    private let transfer: TransferService
    private let loginItem: LoginItemService
    private let wakeAttempts: WakeAttemptStore

    public init(
        paths: AppPaths = AppPaths(),
        interactiveNetworkAuthorization: Bool = false,
        loginItem: LoginItemService? = nil,
        mountSystem: any MountSystemProviding = MacOSMountSystem()
    ) {
        self.paths = paths
        self.interactiveNetworkAuthorization = interactiveNetworkAuthorization
        settingsStore = ConfigurationStore(paths: paths)
        runtimeStore = RuntimeFileStore(paths: paths)
        recovery = MountRecoveryCoordinator(paths: paths, system: mountSystem, runtimeStore: runtimeStore)
        wakeAttempts = WakeAttemptStore(paths: paths)
        diagnostics = DiagnosticsService(paths: paths)
        transfer = TransferService(paths: paths, runtimeStore: runtimeStore)
        self.loginItem = loginItem ?? LoginItemService(paths: paths)
    }

    // waitForLiveCapture keeps a CLI owner alive until its paired processes finish.
    public func waitForLiveCapture(identifier: String) async -> Bool {
        await liveCapture.wait(identifier: identifier)
    }

    // waitForTransfer polls the agent-owned transfer state for callers that explicitly wait.
    public func waitForTransfer(identifier: String) async -> Bool {
        guard let id = UUID(uuidString: identifier) else { return false }
        return await transfer.wait(id: id)
    }

    // shutdown stops all live streams owned by this command-service process.
    public func shutdown() async {
        await liveCapture.stopAll()
        await transfer.stopAll()
    }

    // execute applies AI action policy and audits only actions with side effects or AI authority.
    public func execute(_ request: CommandRequest, actor: String = "user") async -> CommandResult {
        do {
            let settings = try await settingsStore.load()
            let risk = riskForCommand(request.command)
            if ["mounts.force-recover", "network.priority.apply", "network.hardware.apply", "network.profile.save", "network.profile.remove"].contains(request.command), !request.confirmed {
                let result = CommandResult(
                    ok: false,
                    code: "CONFIRMATION_REQUIRED",
                    message: "This action requires explicit confirmation. Network changes may interrupt connections."
                )
                try? await audit(actor: actor, request: request, risk: risk, decision: .requireConfirmation, result: result)
                return result
            }
            let decision = ActionPolicy.decision(mode: settings.ai.actionMode, risk: risk)
            if decision == .requireConfirmation && !request.confirmed {
                let result = CommandResult(
                    ok: false,
                    code: "CONFIRMATION_REQUIRED",
                    message: "This action requires confirmation in the current action mode."
                )
                if risk != .readOnly {
                    try? await audit(actor: actor, request: request, risk: risk, decision: decision, result: result)
                }
                return result
            }

            let result = try await perform(request, settings: settings)
            if risk != .readOnly {
                try? await audit(actor: actor, request: request, risk: risk, decision: decision, result: result)
            }
            return result
        } catch {
            let result = CommandResult(ok: false, code: "COMMAND_FAILED", message: bounded(error.localizedDescription))
            if riskForCommand(request.command) != .readOnly {
                try? await runtimeStore.appendAudit(ActionAuditEntry(
                    actor: actor,
                    action: request.command,
                    risk: riskForCommand(request.command),
                    decision: .deny,
                    outcome: result.code
                ))
            }
            return result
        }
    }

    private func perform(_ request: CommandRequest, settings: AppSettings) async throws -> CommandResult {
        switch request.command {
        case "status":
            let status = await runtimeStore.readStatus()
            return CommandResult(
                ok: true,
                code: "OK",
                message: "Status loaded.",
                data: statusData(status, settings: settings, maximumAge: Double(max(60, settings.general.checkIntervalSeconds * 3)))
            )
        case "check":
            let states = await recovery.observe(settings: settings)
            let healthy = states.filter { $0.availability == .healthy }.count
            return CommandResult(
                ok: states.allSatisfy { [MountAvailability.healthy, .disabled].contains($0.availability) },
                code: healthy == settings.mounts.filter(\.enabled).count ? "OK" : "MOUNTS_DEGRADED",
                message: "Read-only mount check completed.",
                data: [
                    "healthy": String(healthy),
                    "enabled": String(settings.mounts.filter(\.enabled).count),
                    "json": try encodeJSON(states),
                ]
            )
        case "config.show":
            return CommandResult(ok: true, code: "OK", message: "Configuration loaded.", data: ["json": try settingsJSON(settings)])
        case "app.login.status":
            return CommandResult(ok: true, code: "OK", message: "App login item status loaded.", data: ["json": try encodeJSON(loginItem.status())])
        case "app.login.reconcile":
            let status = try loginItem.apply(enabled: settings.general.openAppAtLogin)
            return CommandResult(ok: true, code: "LOGIN_ITEM_RECONCILED", message: "App login item reconciled.", data: ["json": try encodeJSON(status)])
        case "config.export":
            guard request.arguments.count == 1 else { return usage("config.export requires an output path") }
            let file = URL(fileURLWithPath: request.arguments[0]).standardizedFileURL
            let data = try await settingsStore.exportConfigurationData()
            try data.write(to: file, options: .atomic)
            _ = chmod(file.path, SecureFileAccess.privateFileMode)
            return CommandResult(ok: true, code: "CONFIG_EXPORTED", message: "Configuration exported.", data: ["path": file.path])
        case "config.import":
            guard request.arguments.count == 1 else { return usage("config.import requires an input path") }
            let file = URL(fileURLWithPath: request.arguments[0]).standardizedFileURL
            let data = try Data(contentsOf: file)
            var imported = try ConfigurationStore.decodeExportedSettings(from: data)
            guard imported.schemaVersion > 0,
                  imported.schemaVersion <= AppSettings.currentSchemaVersion else {
                throw ConfigurationError.unsupportedSchema(imported.schemaVersion)
            }
            try await settingsStore.validate(imported)
            let loginStatus = try loginItem.apply(enabled: imported.general.openAppAtLogin)
            do {
                imported = try await settingsStore.importConfigurationData(data, replacing: settings)
            } catch {
                _ = try? loginItem.apply(enabled: settings.general.openAppAtLogin)
                throw error
            }
            return CommandResult(ok: true, code: "CONFIG_IMPORTED", message: "Configuration imported.", data: ["json": try settingsJSON(imported), "loginItem": try encodeJSON(loginStatus)])
        case "config.set":
            guard request.arguments.count == 2 else { return usage("config.set requires key and value") }
            let key = request.arguments[0]
            let rawValue = request.arguments[1]
            var updated = settings
            try setConfiguration(key: key, rawValue: rawValue, settings: &updated)
            try await settingsStore.replace(updated, ifUnchanged: settings)
            var data = ["json": try settingsJSON(updated)]
            if key == "general.openAppAtLogin" {
                do {
                    data["loginItem"] = try encodeJSON(loginItem.apply(enabled: updated.general.openAppAtLogin))
                } catch {
                    var rollback = updated
                    rollback.general.openAppAtLogin = settings.general.openAppAtLogin
                    try? await settingsStore.replace(rollback, ifUnchanged: updated)
                    _ = try? loginItem.apply(enabled: settings.general.openAppAtLogin)
                    throw error
                }
            }
            return CommandResult(ok: true, code: "UPDATED", message: "Configuration saved.", data: data)
        case "mounts.list":
            let status = await runtimeStore.readStatus()
            let maximumAge = Double(max(60, settings.general.checkIntervalSeconds * 3))
            let states: [MountRuntimeState]
            if status.availability(maximumAge: maximumAge) == .fresh, let published = status.mountStates {
                states = published
            } else {
                states = await recovery.observe(settings: settings)
            }
            return CommandResult(ok: true, code: "OK", message: "Mount states loaded.", data: ["json": try encodeJSON(states)])
        case "mounts.add":
            guard (2...3).contains(request.arguments.count) else { return usage("mounts.add requires name, SMB URL, and optional enabled state") }
            let mount = MountDefinition(
                name: request.arguments[0],
                url: request.arguments[1],
                enabled: request.arguments.count == 3 ? try bool(request.arguments[2]) : true
            )
            _ = try await settingsStore.update { current in
                current.mounts.append(mount)
            }
            return CommandResult(ok: true, code: "MOUNT_ADDED", message: "Mount configuration added.", data: ["id": mount.id.uuidString])
        case "mounts.update":
            guard (3...4).contains(request.arguments.count), let id = UUID(uuidString: request.arguments[0]) else {
                return usage("mounts.update requires mount ID, name, SMB URL, and optional enabled state")
            }
            let name = request.arguments[1]
            let url = request.arguments[2]
            let enabled = request.arguments.count == 4 ? try bool(request.arguments[3]) : nil
            _ = try await settingsStore.update { current in
                guard let index = current.mounts.firstIndex(where: { $0.id == id }) else {
                    throw ConfigurationError.invalidValue("Mount ID was not found")
                }
                current.mounts[index].name = name
                current.mounts[index].url = url
                if let enabled { current.mounts[index].enabled = enabled }
            }
            return CommandResult(ok: true, code: "MOUNT_UPDATED", message: "Mount configuration updated.", data: ["id": id.uuidString])
        case "mounts.remove":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("mounts.remove requires one mount ID")
            }
            _ = try await settingsStore.update { current in
                guard current.mounts.contains(where: { $0.id == id }) else {
                    throw ConfigurationError.invalidValue("Mount ID was not found")
                }
                current.mounts.removeAll { $0.id == id }
            }
            return CommandResult(ok: true, code: "MOUNT_REMOVED", message: "Mount configuration removed.", data: ["id": id.uuidString])
        case "mounts.enable":
            guard request.arguments.count == 2,
                  let id = UUID(uuidString: request.arguments[0]) else {
                return usage("mounts.enable requires mount ID and enabled state")
            }
            let enabled = try bool(request.arguments[1])
            _ = try await settingsStore.update { current in
                guard let index = current.mounts.firstIndex(where: { $0.id == id }) else {
                    throw ConfigurationError.invalidValue("Mount ID was not found")
                }
                current.mounts[index].enabled = enabled
            }
            return CommandResult(ok: true, code: "MOUNT_UPDATED", message: "Mount availability updated.", data: ["id": id.uuidString])
        case "mounts.recover":
            let selected = try mountIdentifiers(request.arguments, settings: settings)
            let batch = await recovery.reconcile(settings: settings, mode: .manual, mountIDs: selected)
            let states = batch.states
            return CommandResult(
                ok: states.allSatisfy { [MountAvailability.healthy, .disabled].contains($0.availability) },
                code: recoveryResultCode(states),
                message: "Bounded normal mount recovery pass finished.",
                data: ["json": try encodeJSON(states)]
            )
        case "mounts.force-recover":
            let selected = try mountIdentifiers(request.arguments, settings: settings)
            let batch = await recovery.reconcile(settings: settings, mode: .confirmedForce, mountIDs: selected)
            let states = batch.states
            return CommandResult(
                ok: states.allSatisfy { [MountAvailability.healthy, .disabled].contains($0.availability) },
                code: recoveryResultCode(states),
                message: "Confirmed force recovery pass finished.",
                data: ["json": try encodeJSON(states)]
            )
        case "mounts.incidents":
            guard request.arguments.count <= 1 else { return usage("mounts.incidents accepts one optional limit") }
            let limit: Int
            if let rawLimit = request.arguments.first {
                guard let parsed = Int(rawLimit), (1...100).contains(parsed) else {
                    return usage("mounts.incidents limit must be between 1 and 100")
                }
                limit = parsed
            } else {
                limit = 100
            }
            let incidents = await recovery.recentIncidents(limit: limit)
            return CommandResult(ok: true, code: "OK", message: "Mount incidents loaded.", data: ["json": try encodeJSON(incidents)])
        case "network.status":
            let observation = NetworkObservation.collect(settings: settings)
            var data = ["json": try encodeJSON(observation)]
            if let report = NetworkFiles(paths: paths).report() { data["agentJSON"] = try encodeJSON(report) }
            return CommandResult(ok: true, code: "OK", message: "Read-only network observation loaded.", data: data)
        case "network.mtu.check":
            guard request.arguments.count == 2,
                  let port = NativeNetworkInventory.read().ports.first(where: { $0.id == request.arguments[0] }),
                  settings.mounts.contains(where: { URL(string: $0.url)?.host == request.arguments[1] }) else { return usage("Select an identified port and a configured NAS hostname") }
            return try NetworkPathDiagnostic.check(port: port, host: request.arguments[1])
        case "network.profile.list":
            return CommandResult(ok: true, code: "OK", message: "Profiles loaded.", data: ["json": try encodeJSON(settings.network.discovery?.profiles ?? [])])
        case "network.profile.capture":
            let inventory = NativeNetworkInventory.read()
            guard let id = request.arguments.first, let port = inventory.ports.first(where: { $0.id == id }),
                  port.kind == "ethernet", port.hardwareID != nil, let networkID = port.networkID else {
                return usage("ADAPTER_OR_NETWORK_IDENTITY_UNKNOWN")
            }
            return CommandResult(ok: true, code: "OK", message: "Current values captured; monitoring remains disabled until saved.",
                                 data: ["json": try encodeJSON(PortProfile(port: port, networkID: networkID))])
        case "network.profile.save":
            guard let raw = request.arguments.first else { return usage("Profile JSON required") }
            let profile = try NetworkFiles.decode(PortProfile.self, from: Data(raw.utf8))
            let port = NativeNetworkInventory.read().ports.first(where: { $0.id == profile.portID })
            let existing = settings.network.discovery?.profiles.first { $0.id == profile.id }
            let sameBinding = existing?.portID == profile.portID && existing?.networkID == profile.networkID
            guard sameBinding || (port?.hardwareID != nil && port?.networkID == profile.networkID) else { return usage("ADAPTER_OR_NETWORK_IDENTITY_UNKNOWN") }
            if let mtu = profile.mtu, let port, let lower = port.minimumMTU, let upper = port.maximumMTU,
               !(lower...upper).contains(mtu) { return usage("MTU_UNSUPPORTED") }
            _ = try await settingsStore.update { config in
                var options = config.network.discovery ?? NetworkOptions()
                options.profiles.removeAll { $0.id == profile.id }
                options.profiles.append(profile)
                config.network.discovery = options
            }
            return CommandResult(ok: true, code: "PROFILE_SAVED", message: "Port profile saved.")
        case "network.profile.remove":
            guard let raw = request.arguments.first, let id = UUID(uuidString: raw) else { return usage("Profile ID required") }
            _ = try await settingsStore.update { $0.network.discovery?.profiles.removeAll { $0.id == id } }
            return CommandResult(ok: true, code: "PROFILE_REMOVED", message: "Port profile removed.")
        case "network.priority.preview", "network.hardware.preview":
            let id = request.arguments.first.flatMap(UUID.init(uuidString:))
            if request.command == "network.hardware.preview" && id == nil { return usage("Profile ID required") }
            let preview = try NetworkChanges(paths: paths).preview(settings: settings, profileID: id)
            return CommandResult(ok: true, code: "PREVIEW", message: "Review before confirming.", data: ["json": try encodeJSON(preview)])
        case "network.priority.apply", "network.hardware.apply":
            guard let raw = request.arguments.first, let id = UUID(uuidString: raw) else { return usage("Preview ID required") }
            let active = await runtimeStore.readTransferJobs().contains { [.running, .queued].contains($0.state) }
            let outcome = try NetworkChanges(paths: paths).apply(id: id, interactive: interactiveNetworkAuthorization,
                                                               transfersActive: active, settings: settings)
            return CommandResult(ok: outcome == "VERIFIED", code: outcome, message: outcome)
        case "network.wifi.allow", "network.wifi.off":
            let files = NetworkFiles(paths: paths)
            return try SecureFileAccess.withLock(for: files.operationLock) {
                guard let wifi = NativeNetworkInventory.read().wifi else { return usage("WIFI_INTERFACE_UNKNOWN") }
                var policy = settings.network; policy.wifiInterface = wifi.interface
                var state = files.state()
                let allow = request.command == "network.wifi.allow"
                let minutes = request.arguments.first.flatMap(Int.init) ?? policy.wifiGraceMinutes
                guard (0...240).contains(minutes) else { return usage("Wi-Fi window must be between 0 and 240 minutes") }
                let ok: Bool
                if allow { ok = network.allowWiFi(policy: policy, state: &state, minutes: minutes) }
                else {
                    ok = network.setWiFi(interface: wifi.interface, enabled: false) && network.readWiFiEnabled(interface: wifi.interface) == false
                    if ok { state.wifiGraceUntil = nil; state.explicitGrace = false; state.fallbackActive = false }
                }
                if ok { state.lastWiFiEnabled = allow }
                try files.saveState(state)
                return CommandResult(ok: ok, code: ok ? "WIFI_UPDATED" : "WIFI_FAILED", message: ok ? "Wi-Fi state verified." : "Wi-Fi did not reach the requested state.")
            }
        case "diagnostics.events":
            let limit = request.arguments.first.flatMap(Int.init) ?? 100
            return CommandResult(ok: true, code: "OK", message: "Events loaded.", data: ["json": try encodeJSON(await runtimeStore.recentEvents(limit: limit))])
        case "diagnostics.status":
            let status = await runtimeStore.readStatus()
            let maximumAge = Double(max(60, settings.general.checkIntervalSeconds * 3))
            let configuredStates = CollectorRuntimeState.states(settings: settings)
            let runtimeStates = status.collectorStates ?? []
            return CommandResult(
                ok: true,
                code: "OK",
                message: "Diagnostic collector states loaded.",
                data: [
                    "json": try encodeJSON(configuredStates),
                    "runtimeJSON": try encodeJSON(runtimeStates),
                    "runtimeMatchesConfig": String(runtimeStates == configuredStates),
                    "runtimeAvailability": status.availability(maximumAge: maximumAge).rawValue,
                ]
            )
        case "diagnostics.capture":
            guard settings.diagnostics.enabled else { return disabled("Diagnostics are disabled") }
            guard settings.diagnostics.macLogsEnabled else { return disabled("macOS log collection is disabled") }
            let file = try diagnostics.captureMacEvidence(
                lookbackMinutes: settings.diagnostics.macLogLookbackMinutes,
                label: request.arguments.first ?? "manual"
            )
            return CommandResult(ok: true, code: "CAPTURED", message: "macOS diagnostics captured.", data: ["path": file.path])
        case "diagnostics.export":
            let bundle = try diagnostics.exportSupportArchive(
                settings: settings,
                status: await runtimeStore.readStatus(),
                events: await runtimeStore.recentEvents(limit: 2_000),
                traffic: await runtimeStore.recentTraffic(limit: 5_000),
                destination: request.arguments.first.map { URL(fileURLWithPath: $0) }
            )
            return CommandResult(ok: true, code: "EXPORTED", message: "Support bundle exported.", data: ["path": bundle.path, "size": String((try bundle.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)])
        case "transfer.monitoring.status":
            let status = await runtimeStore.readStatus()
            let jobs = await runtimeStore.readTransferJobs()
            return CommandResult(
                ok: true,
                code: settings.transfer.monitoringEnabled ? "TRANSFER_MONITORING_ENABLED" : "TRANSFER_MONITORING_DISABLED",
                message: settings.transfer.monitoringEnabled ? "Transfer monitoring is enabled." : "Transfer monitoring is disabled.",
                data: [
                    "settings": try encodeJSON(settings.transfer),
                    "activeJobs": String(jobs.filter { $0.state == .running }.count),
                    "queuedJobs": String(jobs.filter { $0.state == .queued }.count),
                    "retryMode": settings.transfer.automaticRetryMode,
                    "maximumAutoRetries": String(settings.transfer.maximumAutoRetries),
                    "owner": "background-agent",
                    "statusPhase": status.phase,
                ]
            )
        case "transfer.list":
            return CommandResult(ok: true, code: "OK", message: "Transfer jobs loaded.", data: ["json": try encodeJSON(await runtimeStore.readTransferJobs())])
        case "transfer.status":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("transfer.status requires one transfer job ID")
            }
            guard let job = await runtimeStore.readTransferJob(id: id) else {
                return CommandResult(ok: false, code: "TRANSFER_NOT_FOUND", message: "Transfer job was not found.")
            }
            return CommandResult(ok: true, code: "OK", message: "Transfer job loaded.", data: ["json": try encodeJSON(job)])
        case "transfer.start":
            let start = try transferStartRequest(arguments: request.arguments)
            let job = try await transfer.start(request: start, settings: settings, status: await runtimeStore.readStatus())
            return CommandResult(ok: true, code: "TRANSFER_QUEUED", message: "Transfer queued for the background agent.", data: ["id": job.id.uuidString, "json": try encodeJSON(job)])
        case "transfer.resume":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("transfer.resume requires one transfer job ID")
            }
            let job = try await transfer.resume(id: id, settings: settings, status: await runtimeStore.readStatus())
            return CommandResult(ok: true, code: "TRANSFER_RESUMED", message: "Transfer resumed.", data: ["id": job.id.uuidString, "json": try encodeJSON(job)])
        case "transfer.pause":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("transfer.pause requires one transfer job ID")
            }
            let job = try await transfer.pause(id: id)
            return CommandResult(ok: true, code: "TRANSFER_PAUSED", message: "Transfer paused.", data: ["id": job.id.uuidString, "json": try encodeJSON(job)])
        case "transfer.stop":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("transfer.stop requires one transfer job ID")
            }
            let job = try await transfer.stop(id: id)
            return CommandResult(ok: true, code: "TRANSFER_STOPPED", message: "Transfer stopped.", data: ["id": job.id.uuidString, "json": try encodeJSON(job)])
        case "transfer.finalizeMove":
            guard request.arguments.count == 1, let id = UUID(uuidString: request.arguments[0]) else {
                return usage("transfer.finalizeMove requires one verified move job ID")
            }
            let job = try await transfer.finalizeMove(id: id)
            return CommandResult(ok: true, code: "TRANSFER_MOVE_FINALIZED", message: "Move finalized.", data: ["id": job.id.uuidString, "json": try encodeJSON(job)])
        case "transfer.incident":
            let id = request.arguments.first.flatMap(UUID.init(uuidString:))
            let incident = try await transfer.createIncident(jobID: id)
            return CommandResult(ok: true, code: "TRANSFER_INCIDENT_CREATED", message: "Transfer incident bundle created.", data: ["id": incident.id.uuidString, "path": incident.bundlePath ?? "", "json": try encodeJSON(incident)])
        case "pi.health":
            let health = try pi.health(settings: settings.packetCapture)
            return CommandResult(ok: health.ok, code: health.ok ? "OK" : "PI_DEGRADED", message: "Pi health loaded.", data: ["json": try encodeJSON(health)])
        case "pi.install":
            guard let path = request.arguments.first else { return usage("pi.install requires an installer path") }
            let result = try pi.install(
                localInstaller: URL(fileURLWithPath: path),
                settings: settings.packetCapture,
                syslogPort: settings.synology.syslogPort
            )
            return CommandResult(ok: result.exitCode == 0, code: result.exitCode == 0 ? "PI_INSTALLED" : "PI_INSTALL_FAILED", message: bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        case "capture.start":
            guard settings.packetCapture.enabled else { return disabled("Raspberry Pi packet capture is disabled") }
            let metadata = try pi.startCapture(settings: settings.packetCapture, hostFilter: request.arguments.first)
            let local = try pi.downloadCapture(metadata: metadata, settings: settings.packetCapture, destinationDirectory: paths.captures)
            let analysis = try? pi.analyzeCapture(metadata: metadata, settings: settings.packetCapture)
            let event = analysis?.diagnosticEvent(metadata: metadata, localFile: local) ?? DiagnosticEvent(
                timestamp: metadata.startedAt,
                type: .packetCapture,
                source: "raspberry-pi",
                summary: "Packet capture saved; protocol summary is unavailable",
                details: ["session": metadata.id],
                evidencePath: local.path
            )
            try? await runtimeStore.appendEvent(event)
            // Serialize optional derived evidence once so encoding failures remain visible to callers.
            let analysisJSON = try analysis.map { try encodeJSON($0) } ?? ""
            return CommandResult(
                ok: true,
                code: "CAPTURE_SAVED",
                message: analysis == nil ? "Packet capture saved without protocol summary." : "Packet capture saved and analyzed.",
                data: ["path": local.path, "session": metadata.id, "analysis": analysisJSON]
            )
        case "capture.live.status":
            let status = await liveCapture.status(packetCaptureEnabled: settings.packetCapture.enabled)
            return CommandResult(
                ok: true,
                code: liveCaptureCode(status.state),
                message: status.reason,
                data: ["json": try encodeJSON(status), "state": status.state.rawValue]
            )
        case "capture.live.start":
            let preflight = await liveCapture.status(packetCaptureEnabled: settings.packetCapture.enabled)
            guard preflight.canStart else {
                return CommandResult(
                    ok: false,
                    code: liveCaptureCode(preflight.state),
                    message: preflight.reason,
                    data: ["json": try encodeJSON(preflight), "state": preflight.state.rawValue]
                )
            }
            let identifier = try await liveCapture.start(settings: settings.packetCapture, hostFilter: request.arguments.first)
            let status = await liveCapture.status(packetCaptureEnabled: settings.packetCapture.enabled)
            try? await runtimeStore.appendEvent(DiagnosticEvent(type: .packetCapture, source: "raspberry-pi", summary: "Live Wireshark stream started", details: ["session": identifier]))
            return CommandResult(ok: true, code: "LIVE_CAPTURE_STARTED", message: "Live Wireshark capture started.", data: ["session": identifier, "json": try encodeJSON(status), "state": status.state.rawValue])
        case "capture.live.stop":
            guard let identifier = request.arguments.first else { return usage("capture.live.stop requires a session ID") }
            let stopped = await liveCapture.stop(identifier: identifier)
            let status = await liveCapture.status(packetCaptureEnabled: settings.packetCapture.enabled)
            // Treat stale GUI stop requests as a clean terminal refresh once the actor owns no session.
            if !stopped, status.activeSessionCount == 0 {
                return CommandResult(
                    ok: true,
                    code: liveCaptureCode(status.state),
                    message: status.reason,
                    data: ["json": try encodeJSON(status), "state": status.state.rawValue]
                )
            }
            return CommandResult(
                ok: stopped,
                code: stopped ? "LIVE_CAPTURE_STOPPED" : "SESSION_NOT_FOUND",
                message: stopped ? "Live capture stopped." : "Live capture session was not found.",
                data: ["json": try encodeJSON(status), "state": status.state.rawValue]
            )
        case "capture.open":
            guard let path = request.arguments.first else { return usage("capture.open requires a local PCAPNG path") }
            let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let captureRoot = paths.captures.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard file.path.hasPrefix(captureRoot) else { return usage("capture.open accepts only app-owned capture files") }
            try await liveCapture.open(file: file)
            return CommandResult(ok: true, code: "CAPTURE_OPENED", message: "Capture opened in Wireshark.")
        case "synology.tail":
            guard settings.synology.syslogEnabled else { return disabled("Synology syslog collection is disabled") }
            let text = try pi.readSyslog(settings: settings.packetCapture, limit: request.arguments.first.flatMap(Int.init) ?? 500)
            let events = synology.parseSyslog(text)
            return CommandResult(ok: true, code: "OK", message: "Synology events loaded.", data: ["json": try encodeJSON(events)])
        case "synology.ssh.health":
            let output = try synology.readOnlySSH(settings: settings.synology)
            return CommandResult(ok: true, code: "OK", message: "Synology read-only SSH succeeded.", data: ["output": bounded(output)])
        case "synology.health":
            let values = await synologyHealth(settings: settings)
            return CommandResult(
                ok: values.filter(\.enabled).allSatisfy(\.healthy),
                code: values.filter(\.enabled).allSatisfy(\.healthy) ? "OK" : "SYNOLOGY_SOURCE_DEGRADED",
                message: "Synology source health loaded.",
                data: ["json": try encodeJSON(values)]
            )
        case "synology.csv.import":
            guard settings.synology.csvImportEnabled else { return disabled("Synology CSV import is disabled") }
            guard let path = request.arguments.first else { return usage("synology.csv.import requires a file path") }
            let file = URL(fileURLWithPath: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 20_971_520 else {
                return usage("Synology CSV import is limited to 20 MB")
            }
            let events = synology.importCSV(try String(contentsOf: file, encoding: .utf8))
            let inserted = await appendSynologyEvents(events)
            return CommandResult(ok: true, code: "IMPORTED", message: "Synology CSV imported.", data: ["events": String(inserted)])
        case "synology.dsm.fetch":
            let data = try await dsm.fetchLogs(settings: settings.synology)
            let events = try synology.importDSMResponse(data)
            let inserted = await appendSynologyEvents(events)
            return CommandResult(ok: true, code: "IMPORTED", message: "Synology DSM logs imported.", data: ["events": String(inserted)])
        case "ai.analyze":
            guard settings.ai.enabled else { return disabled("AI analysis is disabled") }
            let events = AIEvidenceBuilder(paths: paths).build(
                events: await runtimeStore.recentEvents(limit: 300),
                traffic: await runtimeStore.recentTraffic(limit: 1_000)
            )
            let provider: any AIProvider
            if settings.ai.provider == .local {
                provider = LocalFoundationModelProvider()
            } else {
                provider = OpenAIProvider(
                    model: settings.ai.openAIModel,
                    dataMode: settings.ai.cloudDataMode,
                    selectedEvidenceIDs: settings.ai.selectedEvidenceIDs ?? []
                )
            }
            let finding = try await provider.analyze(question: request.arguments.joined(separator: " "), evidence: events)
            return CommandResult(ok: true, code: "ANALYZED", message: "Analysis completed.", data: ["json": try encodeJSON(finding), "provider": provider.availabilityDescription])
        case "wake":
            let route = request.arguments.first.flatMap(WakeRouteKind.init(rawValue:)) ?? .raspberryPiLAN
            guard wake.validateMAC(settings.wake.targetMACAddress),
                  settings.wake.routes.first(where: { $0.kind == route })?.enabled == true,
                  settings.wake.routes.first(where: { $0.kind == route })?.verified == true else {
                return try wake.wake(route: route, wakeSettings: settings.wake, packetSettings: settings.packetCapture)
            }
            guard await wakeAttempts.reserve(route: route) else {
                return CommandResult(ok: false, code: "DUPLICATE_WAKE_SUPPRESSED", message: "A wake request for this route was sent moments ago.")
            }
            let result = try wake.wake(route: route, wakeSettings: settings.wake, packetSettings: settings.packetCapture)
            try? await runtimeStore.appendEvent(DiagnosticEvent(type: .wakeAttempt, source: route.rawValue, summary: result.message, details: ["code": result.code, "probeHost": settings.wake.targetHost]))
            return result
        case "wake.verify":
            let route = request.arguments.first.flatMap(WakeRouteKind.init(rawValue:)) ?? .raspberryPiLAN
            guard wake.validateMAC(settings.wake.targetMACAddress),
                  settings.wake.routes.first(where: { $0.kind == route })?.enabled == true else {
                return try wake.wake(
                    route: route,
                    wakeSettings: settings.wake,
                    packetSettings: settings.packetCapture,
                    requireVerified: false
                )
            }
            guard await wakeAttempts.reserve(route: route) else {
                return CommandResult(ok: false, code: "DUPLICATE_WAKE_SUPPRESSED", message: "A wake verification for this route was sent moments ago.")
            }
            let result = try wake.wake(
                route: route,
                wakeSettings: settings.wake,
                packetSettings: settings.packetCapture,
                requireVerified: false
            )
            if result.code == "WAKE_VERIFIED" {
                _ = try await settingsStore.update { current in
                    if let index = current.wake.routes.firstIndex(where: { $0.kind == route }) {
                        current.wake.routes[index].verified = true
                    }
                }
            }
            try? await runtimeStore.appendEvent(DiagnosticEvent(type: .wakeAttempt, source: route.rawValue, summary: result.message, details: ["code": result.code, "verification": "true", "probeHost": settings.wake.targetHost]))
            return result
        default:
            return usage("Unknown command: \(request.command)")
        }
    }

    // riskForCommand centralizes policy classification for every interface.
    public nonisolated func riskForCommand(_ command: String) -> CommandRisk {
        switch command {
        case "network.mtu.check", "network.profile.list", "network.profile.capture", "network.priority.preview", "network.hardware.preview", "status", "check", "config.show", "app.login.status", "mounts.list", "mounts.incidents", "network.status", "diagnostics.events", "diagnostics.status", "transfer.monitoring.status", "transfer.list", "transfer.status", "pi.health", "capture.live.status", "synology.tail", "synology.ssh.health", "synology.health":
            .readOnly
        case "config.export", "app.login.reconcile", "mounts.recover", "mounts.add", "mounts.update", "mounts.enable", "diagnostics.capture", "diagnostics.export", "transfer.incident", "ai.analyze", "synology.csv.import", "synology.dsm.fetch", "capture.open":
            .safeMutation
        case "mounts.force-recover", "network.wifi.allow", "network.wifi.off", "wake", "wake.verify":
            .connectivityCritical
        case "config.set", "config.import", "mounts.remove", "pi.install", "capture.start", "capture.live.start", "capture.live.stop", "transfer.start", "transfer.resume", "transfer.pause", "transfer.stop", "transfer.finalizeMove":
            .remoteMutation
        default:
            .remoteMutation
        }
    }

    // liveCaptureCode maps the typed lifecycle into a stable cross-interface command code.
    private nonisolated func liveCaptureCode(_ state: LiveCaptureLifecycleState) -> String {
        switch state {
        case .disabled: "LIVE_CAPTURE_DISABLED"
        case .degraded: "LIVE_CAPTURE_DEGRADED"
        case .ready: "LIVE_CAPTURE_READY"
        case .running: "LIVE_CAPTURE_RUNNING"
        case .stopped: "LIVE_CAPTURE_STOPPED"
        case .error: "LIVE_CAPTURE_ERROR"
        }
    }

    private func audit(
        actor: String,
        request: CommandRequest,
        risk: CommandRisk,
        decision: ActionDecision,
        result: CommandResult
    ) async throws {
        try await runtimeStore.appendAudit(ActionAuditEntry(
            actor: actor,
            action: request.command,
            risk: risk,
            decision: decision,
            outcome: result.code
        ))
    }

    // statusData includes explicit freshness so automation cannot interpret absent counters as healthy.
    private func statusData(_ status: AgentStatus, settings: AppSettings, maximumAge: TimeInterval) -> [String: String] {
        let collectors = status.collectorStates ?? CollectorRuntimeState.states(settings: settings)
        return [
            "timestamp": ISO8601DateFormatter().string(from: status.timestamp),
            "phase": status.phase,
            "enabledMounts": String(status.enabledMounts),
            "healthyMounts": String(status.healthyMounts),
            "lanHealthy": String(status.lanHealthy),
            "wifiEnabled": String(status.wifiEnabled),
            "fallbackActive": String(status.fallbackActive),
            "lastError": status.lastError ?? "",
            "availability": status.availability(maximumAge: maximumAge).rawValue,
            "collectors": (try? encodeJSON(collectors)) ?? "[]",
            "mountStates": (try? encodeJSON(status.mountStates ?? [])) ?? "[]",
        ]
    }

    // mountIdentifiers validates optional mount IDs before a recovery operation is started.
    private func mountIdentifiers(_ values: [String], settings: AppSettings) throws -> Set<UUID>? {
        guard !values.isEmpty else { return nil }
        let identifiers = try values.map { value -> UUID in
            guard let identifier = UUID(uuidString: value), settings.mounts.contains(where: { $0.id == identifier }) else {
                throw ConfigurationError.invalidValue("Mount ID was not found: \(value)")
            }
            return identifier
        }
        return Set(identifiers)
    }

    // recoveryResultCode exposes the most important terminal state consistently to every interface.
    private func recoveryResultCode(_ states: [MountRuntimeState]) -> String {
        if states.contains(where: { $0.recoveryPhase == .restartRequired }) { return "RESTART_REQUIRED" }
        if states.contains(where: { $0.recoveryPhase == .deferredActiveTransfer }) { return "RECOVERY_DEFERRED_ACTIVE_TRANSFER" }
        if states.contains(where: { $0.recoveryPhase == .manualConfirmationRequired }) { return "FORCE_RECOVERY_CONFIRMATION_REQUIRED" }
        if states.contains(where: { $0.recoveryPhase == .circuitOpen }) { return "RECOVERY_CIRCUIT_OPEN" }
        if states.contains(where: { $0.recoveryPhase == .waitingForNetwork }) { return "RECOVERY_WAITING_FOR_NETWORK" }
        if states.contains(where: { $0.availability == .unknown }) { return "MOUNT_STATE_UNKNOWN" }
        if states.contains(where: { $0.recoveryPhase == .scheduled }) { return "RECOVERY_SCHEDULED" }
        return "RECOVERY_FINISHED"
    }

    // synologyHealth evaluates every configured source independently so one failure cannot mask others.
    private func synologyHealth(settings: AppSettings) async -> [SynologySourceHealth] {
        var values: [SynologySourceHealth] = []
        if settings.synology.syslogEnabled {
            do {
                let health = try pi.health(settings: settings.packetCapture)
                values.append(SynologySourceHealth(
                    source: "pi-syslog",
                    enabled: true,
                    healthy: health.syslogReceiverActive,
                    message: health.syslogReceiverActive ? "Receiver active" : "Receiver inactive"
                ))
            } catch {
                values.append(SynologySourceHealth(source: "pi-syslog", enabled: true, healthy: false, message: bounded(error.localizedDescription)))
            }
        } else {
            values.append(SynologySourceHealth(source: "pi-syslog", enabled: false, healthy: false, message: "Disabled"))
        }
        if settings.synology.readOnlySSHEnabled {
            do {
                _ = try synology.readOnlySSH(settings: settings.synology)
                values.append(SynologySourceHealth(source: "read-only-ssh", enabled: true, healthy: true, message: "Fixed read-only query succeeded"))
            } catch {
                values.append(SynologySourceHealth(source: "read-only-ssh", enabled: true, healthy: false, message: bounded(error.localizedDescription)))
            }
        } else {
            values.append(SynologySourceHealth(source: "read-only-ssh", enabled: false, healthy: false, message: "Disabled"))
        }
        values.append(await dsm.health(settings: settings.synology))
        values.append(SynologySourceHealth(
            source: "csv",
            enabled: settings.synology.csvImportEnabled,
            healthy: settings.synology.csvImportEnabled,
            message: settings.synology.csvImportEnabled ? "Ready for manual import" : "Disabled"
        ))
        return values
    }

    // appendSynologyEvents deduplicates canonical source references before adding timeline events.
    private func appendSynologyEvents(_ values: [SynologyEvent]) async -> Int {
        var inserted = 0
        for value in values {
            if (try? await runtimeStore.appendSynologyEventIfNew(diagnostics.redactedEvent(synology.diagnosticEvent(value)))) == true {
                inserted += 1
            }
        }
        return inserted
    }

    private func setConfiguration(key: String, rawValue: String, settings: inout AppSettings) throws {
        let routeParts = key.split(separator: ".").map(String.init)
        if routeParts.count == 4,
           routeParts[0] == "wake",
           routeParts[1] == "route",
           routeParts[3] == "enabled",
           let kind = WakeRouteKind(rawValue: routeParts[2]),
           let index = settings.wake.routes.firstIndex(where: { $0.kind == kind }) {
            // Verification remains command-owned; configuration can only opt an individual route in or out.
            settings.wake.routes[index].enabled = try bool(rawValue)
            if !settings.wake.routes[index].enabled {
                settings.wake.routes[index].verified = false
            }
            return
        }
        if routeParts.count == 4,
           routeParts[0] == "wake",
           routeParts[1] == "route",
           routeParts[3] == "command",
           let kind = WakeRouteKind(rawValue: routeParts[2]),
           let index = settings.wake.routes.firstIndex(where: { $0.kind == kind }) {
            // Route commands are non-secret transport identifiers interpreted by the wake adapter.
            settings.wake.routes[index].command = rawValue
            settings.wake.routes[index].verified = false
            return
        }
        switch key {
        case "general.enabled": settings.general.enabled = try bool(rawValue)
        case "general.openAppAtLogin": settings.general.openAppAtLogin = try bool(rawValue)
        case "general.checkIntervalSeconds": settings.general.checkIntervalSeconds = try int(rawValue)
        case "general.bootDelaySeconds": settings.general.bootDelaySeconds = try int(rawValue)
        case "general.maximumAutomaticRecoveryAttempts": settings.general.maximumAutomaticRecoveryAttempts = try int(rawValue)
        case "general.mountTimeoutSeconds": settings.general.mountTimeoutSeconds = try int(rawValue)
        case "general.smbHealthTimeoutSeconds": settings.general.smbHealthTimeoutSeconds = try int(rawValue)
        case "general.language": settings.general.language = try enumValue(rawValue, type: AppLanguage.self)
        case "general.onboardingCompleted": settings.general.onboardingCompleted = try bool(rawValue)
        case "network.preferredPortID":
            var options = settings.network.discovery ?? NetworkOptions()
            guard rawValue == "automatic" || NativeNetworkInventory.read().ports.contains(where: { $0.kind == "ethernet" && $0.id == rawValue }) else { throw ConfigurationError.invalidValue("Unknown Ethernet port") }
            options.preferredPortID = rawValue == "automatic" ? nil : rawValue
            options.unresolvedLegacyInterface = nil
            settings.network.discovery = options
        case "network.automaticTraffic":
            var options = settings.network.discovery ?? NetworkOptions()
            options.automaticTraffic = try bool(rawValue)
            settings.network.discovery = options
        case "network.enabled": settings.network.enabled = try bool(rawValue)
        case "network.lanInterface": settings.network.lanInterface = rawValue
        case "network.wifiInterface": settings.network.wifiInterface = rawValue
        case "network.wifiGraceMinutes": settings.network.wifiGraceMinutes = try int(rawValue)
        case "network.disableWifiWhenLanActive": settings.network.disableWifiWhenLanActive = try bool(rawValue)
        case "network.enableWifiWhenLanUnhealthy": settings.network.enableWifiWhenLanUnhealthy = try bool(rawValue)
        case "network.lanFailureThreshold": settings.network.lanFailureThreshold = try int(rawValue)
        case "network.lanRecoveryStableChecks":
            guard try int(rawValue) == 3 else { throw ConfigurationError.invalidValue("Ethernet recovery requires exactly three stable periodic checks") }
            settings.network.lanRecoveryStableChecks = 3
        case "network.gatewayHost": settings.network.gatewayHost = rawValue
        case "network.remoteReachabilityHosts": settings.network.remoteReachabilityHosts = stringList(rawValue)
        case "network.trafficEnabled": settings.network.trafficEnabled = try bool(rawValue)
        case "network.trafficInterfaces": settings.network.trafficInterfaces = stringList(rawValue)
        case "network.trafficMaxBytes": settings.network.trafficMaxBytes = try int(rawValue)
        case "diagnostics.enabled": settings.diagnostics.enabled = try bool(rawValue)
        case "diagnostics.networkEventsEnabled": settings.diagnostics.networkEventsEnabled = try bool(rawValue)
        case "diagnostics.sleepWakeEventsEnabled": settings.diagnostics.sleepWakeEventsEnabled = try bool(rawValue)
        case "diagnostics.macLogsEnabled": settings.diagnostics.macLogsEnabled = try bool(rawValue)
        case "diagnostics.macLogLookbackMinutes": settings.diagnostics.macLogLookbackMinutes = try int(rawValue)
        case "diagnostics.retentionDays": settings.diagnostics.retentionDays = try int(rawValue)
        case "diagnostics.retentionIntervalMinutes": settings.diagnostics.retentionIntervalMinutes = try int(rawValue)
        case "diagnostics.maximumStoreBytes": settings.diagnostics.maximumStoreBytes = try int(rawValue)
        case "diagnostics.redactPathsInExports": settings.diagnostics.redactPathsInExports = try bool(rawValue)
        case "transfer.monitoringEnabled": settings.transfer.monitoringEnabled = try bool(rawValue)
        case "transfer.highTrafficBytesPerSecond": settings.transfer.highTrafficBytesPerSecond = try int(rawValue)
        case "transfer.sustainedSeconds": settings.transfer.sustainedSeconds = try int(rawValue)
        case "transfer.rollingPiCaptureEnabled": settings.transfer.rollingPiCaptureEnabled = try bool(rawValue)
        case "transfer.incidentBundleOnFailure": settings.transfer.incidentBundleOnFailure = try bool(rawValue)
        case "transfer.defaultResumePolicy": settings.transfer.defaultResumePolicy = try enumValue(rawValue, type: TransferResumePolicy.self)
        case "transfer.maximumAutoRetries": settings.transfer.maximumAutoRetries = try int(rawValue)
        case "transfer.unlimitedAutoRetries": settings.transfer.unlimitedAutoRetries = try bool(rawValue)
        case "transfer.verifyAfterCopy": settings.transfer.verifyAfterCopy = try bool(rawValue)
        case "transfer.keepMacAwakeByDefault": settings.transfer.keepMacAwakeByDefault = try bool(rawValue)
        case "packetCapture.enabled": settings.packetCapture.enabled = try bool(rawValue)
        case "packetCapture.host": settings.packetCapture.host = rawValue
        case "packetCapture.user": settings.packetCapture.user = rawValue
        case "packetCapture.interface": settings.packetCapture.interface = rawValue
        case "packetCapture.durationSeconds": settings.packetCapture.durationSeconds = try int(rawValue)
        case "packetCapture.remoteDirectory": settings.packetCapture.remoteDirectory = rawValue
        case "packetCapture.maximumFiles": settings.packetCapture.maximumFiles = try int(rawValue)
        case "packetCapture.maximumFileBytes": settings.packetCapture.maximumFileBytes = try int(rawValue)
        case "synology.syslogEnabled": settings.synology.syslogEnabled = try bool(rawValue)
        case "synology.syslogPort": settings.synology.syslogPort = try int(rawValue)
        case "synology.readOnlySSHEnabled": settings.synology.readOnlySSHEnabled = try bool(rawValue)
        case "synology.sshHost": settings.synology.sshHost = rawValue
        case "synology.sshUser": settings.synology.sshUser = rawValue
        case "synology.dsmAPIEnabled": settings.synology.dsmAPIEnabled = try bool(rawValue)
        case "synology.dsmBaseURL": settings.synology.dsmBaseURL = rawValue
        case "synology.csvImportEnabled": settings.synology.csvImportEnabled = try bool(rawValue)
        case "ai.enabled": settings.ai.enabled = try bool(rawValue)
        case "ai.provider": settings.ai.provider = try enumValue(rawValue, type: AIProviderKind.self)
        case "ai.actionMode": settings.ai.actionMode = try enumValue(rawValue, type: AIActionMode.self)
        case "ai.cloudDataMode": settings.ai.cloudDataMode = try enumValue(rawValue, type: CloudDataMode.self)
        case "ai.openAIModel": settings.ai.openAIModel = rawValue
        case "ai.selectedEvidenceIDs": settings.ai.selectedEvidenceIDs = try uuidList(rawValue)
        case "wake.targetName": settings.wake.targetName = rawValue
        case "wake.targetMACAddress": settings.wake.targetMACAddress = rawValue
        case "wake.targetHost": settings.wake.targetHost = rawValue
        default: throw ConfigurationError.invalidValue("Unknown configuration key: \(key)")
        }
    }

    // transferStartRequest maps stable command arguments into a typed transfer request.
    private func transferStartRequest(arguments: [String]) throws -> TransferStartRequest {
        guard arguments.count >= 7 else {
            throw ConfigurationError.invalidValue("transfer.start requires operation, direction, resume policy, keep-awake, unlimited-retry, destination, and at least one source")
        }
        guard let operation = TransferOperation(rawValue: arguments[0]) else {
            throw ConfigurationError.invalidValue("Unsupported transfer operation: \(arguments[0])")
        }
        // The GUI delegates direction selection to the same validator used by the worker.
        let direction = TransferDirection(rawValue: arguments[1])
        guard arguments[1] == "auto" || direction != nil else {
            throw ConfigurationError.invalidValue("Unsupported transfer direction: \(arguments[1])")
        }
        guard let resumePolicy = TransferResumePolicy(rawValue: arguments[2]) else {
            throw ConfigurationError.invalidValue("Unsupported transfer resume policy: \(arguments[2])")
        }
        let keepMacAwake = try bool(arguments[3])
        let unlimitedAutoRetries = try bool(arguments[4])
        return TransferStartRequest(
            operation: operation,
            direction: direction,
            resumePolicy: resumePolicy,
            unlimitedAutoRetries: unlimitedAutoRetries,
            sources: Array(arguments.dropFirst(6)),
            destination: arguments[5],
            keepMacAwake: keepMacAwake
        )
    }

    private func bool(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: throw ConfigurationError.invalidValue("Expected a boolean value")
        }
    }

    private func int(_ value: String) throws -> Int {
        guard let result = Int(value) else { throw ConfigurationError.invalidValue("Expected an integer value") }
        return result
    }

    // stringList parses comma-separated advanced settings without accepting empty list entries.
    private func stringList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // uuidList validates every optional evidence identifier before updating cloud privacy scope.
    private func uuidList(_ value: String) throws -> [UUID]? {
        let values = stringList(value)
        if values.isEmpty { return nil }
        let identifiers = values.compactMap(UUID.init(uuidString:))
        guard identifiers.count == values.count else { throw ConfigurationError.invalidValue("Expected comma-separated UUID values") }
        return identifiers
    }

    private func enumValue<T: RawRepresentable>(_ value: String, type: T.Type) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: value) else { throw ConfigurationError.invalidValue("Unsupported value: \(value)") }
        return result
    }

    private func settingsJSON(_ settings: AppSettings) throws -> String { try encodeJSON(settings) }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func usage(_ message: String) -> CommandResult {
        CommandResult(ok: false, code: "INVALID_ARGUMENT", message: message)
    }

    // disabled returns one consistent result for explicitly switched-off features.
    private func disabled(_ message: String) -> CommandResult {
        CommandResult(ok: false, code: "FEATURE_DISABLED", message: message)
    }

    private func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }
}
