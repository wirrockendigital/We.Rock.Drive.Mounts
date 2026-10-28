import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WRDMCore

// AppSection enumerates the user-facing settings areas shown in the sidebar.
enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case configuration
    case mounts
    case transfers
    case network
    case diagnostics
    case integrations
    case ai
    case wake
    case advanced

    var id: String { rawValue }

    // title provides concise navigation labels for non-technical users.
    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .configuration: "Configuration"
        case .mounts: "Network drives"
        case .transfers: "Transfers"
        case .network: "Ethernet & Wi-Fi"
        case .diagnostics: "Diagnostics"
        case .integrations: "Data sources"
        case .ai: "AI analysis"
        case .wake: "Wake this Mac"
        case .advanced: "Advanced"
        }
    }

    // symbol maps every section to a familiar SF Symbol.
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .configuration: "square.and.arrow.up.on.square"
        case .mounts: "externaldrive.connected.to.line.below"
        case .transfers: "arrow.left.arrow.right.square"
        case .network: "network"
        case .diagnostics: "waveform.path.ecg"
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .ai: "sparkles"
        case .wake: "power"
        case .advanced: "gearshape.2"
        }
    }
}

// AppModel coordinates presentation state while delegating all operations to the shared core.
@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.we-rock.drive-mounts", category: "app")
    @Published private(set) var configurationLoaded = false
    @Published var settings = AppSettings.defaults
    @Published var networkInventory = NetworkInventory()
    @Published var networkReport: NetworkReport?
    @Published var networkRestoration: NetworkChangeResult?
    private var notifiedPortIncidents = Set(UserDefaults.standard.stringArray(forKey: "networkNotifiedIncidents") ?? [])
    @Published var status = AgentStatus.unavailable
    @Published var mountStates: [MountRuntimeState] = []
    @Published var events: [DiagnosticEvent] = []
    @Published var traffic: [InterfaceTrafficSample] = []
    @Published var transferJobs: [TransferJob] = []
    @Published var updateStatus = UpdateSnapshot()
    @Published var updateCheckInProgress = false
    @Published var updateInstallDeferred = false
    @Published var selectedSection: AppSection = .overview
    @Published var isBusy = false
    @Published var lastMessage = ""
    @Published var lastError: String?
    @Published var showOnboarding = false
    @Published var showMountEditor = false
    @Published var editingMount: MountDefinition?
    @Published var openAIKeyDraft = ""
    @Published var openAIKeyConfigured = false
    @Published var piHealth: PiCompanionHealth?
    @Published var piPasswordDraft = ""
    @Published var piPasswordConfigured = false
    @Published var aiQuestion = "What most likely caused the latest connection interruption?"
    @Published var aiFindings: [DiagnosticFinding] = []
    @Published var synologyHealth: [SynologySourceHealth] = []
    @Published var synologyAccountDraft = ""
    @Published var synologyPasswordDraft = ""
    @Published var synologyCredentialsConfigured = false
    @Published var liveCaptureSession: String?
    @Published var liveCaptureStatus = LiveCaptureStatus(
        state: .degraded,
        wiresharkAvailable: false,
        packetCaptureEnabled: false,
        activeSessionCount: 0,
        reason: "Checking Wireshark availability…"
    )
    @Published var transferOperation: TransferOperation = .copy
    @Published var transferResumePolicy: TransferResumePolicy = .ask
    @Published var transferUnlimitedAutoRetries = false
    @Published var transferSourcePaths: [String] = []
    @Published var transferDestinationPath = ""
    @Published var transferKeepMacAwake = false
    @Published var importableMounts: [DiscoveredSMBMount] = []

    private let paths: AppPaths
    private let configuration: ConfigurationStore
    private let runtime: RuntimeFileStore
    private let commands: CommandService
    private var persistedSettings = AppSettings.defaults
    private var refreshTask: Task<Void, Never>?
    private var installUpdateHandler: (() -> Void)?
    private var agentUpdateRestartAttempted = false

    // hasUnsavedSettings distinguishes editable drafts from settings already used by the agent.
    var hasUnsavedSettings: Bool { configurationLoaded && settings != persistedSettings }
    var hasActiveTransfers: Bool { TransferStatusSummary.current(jobs: transferJobs).activeJobCount > 0 }

    // immediateToggle persists independent Boolean options without committing unrelated draft fields.
    func immediateToggle(_ keyPath: WritableKeyPath<AppSettings, Bool>, key: String) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.setImmediateToggle(keyPath, key: key, value: value) }
        )
    }

    // setImmediateToggle serializes with form saves and verifies the persisted option before reporting success.
    private func setImmediateToggle(_ keyPath: WritableKeyPath<AppSettings, Bool>, key: String, value: Bool) {
        guard configurationLoaded else { return }
        let previous = settings[keyPath: keyPath]
        settings[keyPath: keyPath] = value
        Task {
            while saveInProgress { try? await Task.sleep(for: .milliseconds(25)) }
            saveInProgress = true
            isBusy = true
            defer { saveInProgress = false; isBusy = false }
            let result = await commands.execute(
                CommandRequest(command: "config.set", arguments: [key, value ? "true" : "false"], confirmed: true),
                actor: "app"
            )
            guard result.ok else {
                if settings[keyPath: keyPath] == value { settings[keyPath: keyPath] = previous }
                lastError = localizedCommandMessage(result)
                return
            }
            do {
                let current = try await configuration.load()
                persistedSettings[keyPath: keyPath] = current[keyPath: keyPath]
                if settings[keyPath: keyPath] == value { settings[keyPath: keyPath] = current[keyPath: keyPath] }
                lastError = nil
                lastMessage = localized("Setting saved immediately.")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
    private var openSettingsHandler: (() -> Void)?
    private var openTransferDialogHandler: (() -> Void)?
    private var openTransferWindowHandler: (() -> Void)?
    private var saveInProgress = false

    // init shares one explicit path scope so failure-state tests cannot touch live settings.
    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        configuration = ConfigurationStore(paths: paths)
        runtime = RuntimeFileStore(paths: paths)
        commands = CommandService(paths: paths, interactiveNetworkAuthorization: true)
    }

    // statusAvailability prevents stale or missing agent data from being rendered as healthy.
    var statusAvailability: AgentStatusAvailability {
        status.availability(maximumAge: Double(max(60, settings.general.checkIntervalSeconds * 3)))
    }

    // statusOperational accepts fresh degraded evidence while excluding disabled and failed agent cycles.
    var statusOperational: Bool {
        statusAvailability == .fresh && !["disabled", "error", "unavailable"].contains(status.phase)
    }

    // Network freshness is independent from slow or unavailable mount recovery status.
    var networkReportFresh: Bool {
        guard let report = networkReport else { return false }
        return Date().timeIntervalSince(report.observation.timestamp) <= Double(max(60, settings.general.checkIntervalSeconds * 3))
    }
    var ethernetConnected: Bool { networkReportFresh && networkReport?.observation.selected?.usable == true }

    // start loads persisted state and begins a bounded status refresh loop.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadAll()
            // Probe once from the app process so macOS can present the declared local-network permission.
            let permissionProbe = await self.run("network.status")
            self.logger.notice("Local-network permission probe completed with code \(permissionProbe.code, privacy: .public)")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.refreshRuntime()
            }
        }
    }

    // stop releases refresh work and closes app-owned live capture processes.
    func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        await commands.shutdown()
    }

    // reloadAll refreshes settings and current runtime evidence.
    func reloadAll() async {
        do {
            try await loadConfiguration()
            openAIKeyConfigured = CredentialStore().read(account: "openai-api-key") != nil
            piPasswordConfigured = CredentialStore().read(account: "raspberry-pi-sudo-password") != nil
            synologyCredentialsConfigured = CredentialStore().read(account: "synology-dsm-account") != nil
                && CredentialStore().read(account: "synology-dsm-password") != nil
            showOnboarding = !settings.general.onboardingCompleted
            // Reconcile launchd after installs and updates because the persisted preference survives package replacement.
            let loginResult = await commands.execute(
                CommandRequest(command: "app.login.reconcile", confirmed: true),
                actor: "app"
            )
            if !loginResult.ok {
                lastError = localizedCommandMessage(loginResult)
            }
            // Login startup must stay silent even when onboarding has not been completed.
            if showOnboarding && !ProcessInfo.processInfo.arguments.contains("--background") {
                openSettings()
            }
            await refreshRuntime()
        } catch {
            configurationLoaded = false
            showOnboarding = false
            lastError = error.localizedDescription
        }
    }

    // loadConfiguration separates durable settings load from app-only runtime integrations.
    func loadConfiguration() async throws {
        settings = try await configuration.load()
        configurationLoaded = true
        lastError = nil
        persistedSettings = settings
        transferResumePolicy = settings.transfer.defaultResumePolicy
        transferUnlimitedAutoRetries = settings.transfer.unlimitedAutoRetries
        transferKeepMacAwake = settings.transfer.keepMacAwakeByDefault ?? false
    }

    // refreshRuntime reads immutable snapshots without triggering recovery actions.
    func refreshRuntime() async {
        status = await runtime.readStatus()
        updateStatus = await UpdateService(paths: paths).read()
        networkReport = NetworkFiles(paths: paths).report()
        // User windows are persisted immediately and must not wait for the next agent observation to appear.
        if networkReport != nil { networkReport?.policyState = NetworkFiles(paths: paths).state() }
        if let data = try? Data(contentsOf: NetworkChanges(paths: paths).resultURL) {
            networkRestoration = try? NetworkFiles.decode(NetworkChangeResult.self, from: data)
        }
        if let report = networkReport { networkInventory = report.observation.inventory }
        else { await refreshNetworkInventory() }
        await notifyPortDeviations()
        events = await runtime.recentEvents(limit: 100).reversed()
        traffic = await runtime.recentTraffic(limit: 500)
        transferJobs = await runtime.readTransferJobs()
        reconcileAgentAfterUpdateIfNeeded()
        if updateInstallDeferred && TransferStatusSummary.current(jobs: transferJobs).activeJobCount == 0 {
            updateInstallDeferred = false
            let content = UNMutableNotificationContent()
            content.title = localized("Update ready to install")
            content.body = localized("Transfers have finished. Open We Rock Drive Mounts to install the update.")
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .authorized {
                try? await center.add(UNNotificationRequest(identifier: "wrdm-update-transfer-finished", content: content, trigger: nil))
            }
        }
        let maximumAge = Double(max(60, settings.general.checkIntervalSeconds * 3))
        mountStates = status.availability(maximumAge: maximumAge) == .fresh
            ? status.mountStates ?? []
            : []
        await refreshLiveCaptureStatus()
    }

    // reconcileAgentAfterUpdateIfNeeded restarts the installed helper only after transfers finish.
    private func reconcileAgentAfterUpdateIfNeeded() {
        guard !agentUpdateRestartAttempted, !hasActiveTransfers,
              let agentVersion = networkReport?.agentVersion,
              let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              agentVersion != "development", agentVersion != appVersion,
              Bundle.main.bundleURL.path == "/Applications/We Rock Drive Mounts.app" else { return }
        agentUpdateRestartAttempted = true
        let target = "gui/\(getuid())/com.we-rock.we-rock-drive-mounts"
        let extensionID = "com.we-rock.drive-mounts.finder-extension"
        let extensionPath = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/We Rock Transfer.appex").path
        Task.detached {
            _ = try? ProcessRunner.run("/usr/bin/pluginkit", arguments: ["-a", extensionPath], timeout: 10)
            _ = try? ProcessRunner.run("/usr/bin/pluginkit", arguments: ["-e", "use", "-i", extensionID], timeout: 10)
            _ = try? ProcessRunner.run("/bin/launchctl", arguments: ["kickstart", "-k", target], timeout: 15)
        }
    }

    // setInstallUpdateHandler connects the shared model to the app-owned Sparkle controller.
    func setInstallUpdateHandler(_ handler: @escaping () -> Void) {
        installUpdateHandler = handler
    }

    // checkForUpdates performs a user-initiated read and shows explicit result state.
    func checkForUpdates() {
        guard !updateCheckInProgress else { return }
        updateCheckInProgress = true
        Task {
            updateStatus = await UpdateService(paths: paths).check()
            updateCheckInProgress = false
        }
    }

    // installAvailableUpdate defers the installer while a transfer still owns files.
    func installAvailableUpdate() {
        guard updateStatus.availableVersion != nil else { return }
        if TransferStatusSummary.current(jobs: transferJobs).activeJobCount > 0 {
            updateInstallDeferred = true
            return
        }
        installUpdateHandler?()
    }

    // enableUpdateNotifications asks through the agent bundle that delivers update notices.
    func enableUpdateNotifications() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent").path
        Task.detached {
            _ = try? ProcessRunner.run(executable, arguments: ["--enable-update-notifications"], timeout: 30)
        }
    }

    // refreshLiveCaptureStatus reads the canonical preflight without changing user feedback.
    private func refreshLiveCaptureStatus() async {
        let result = await commands.execute(CommandRequest(command: "capture.live.status"), actor: "app")
        guard let json = result.data["json"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder.configured.decode(LiveCaptureStatus.self, from: data) else { return }
        applyLiveCaptureStatus(value)
    }

    // applyLiveCaptureStatus keeps the button state synchronized with terminal service states.
    private func applyLiveCaptureStatus(_ value: LiveCaptureStatus) {
        liveCaptureStatus = value
        if value.state != .running {
            liveCaptureSession = nil
        }
    }

    // save waits for earlier UI writes and reports success only after durable compare-and-swap persistence.
    @discardableResult
    func save(message: String = "Settings saved.") async -> Bool {
        // Yield once so button-triggered saves publish state after SwiftUI finishes the current view update.
        await Task.yield()
        while saveInProgress {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await persist(settings, expected: persistedSettings, message: message)
    }

    // persist commits one proposed snapshot without exposing it as current UI state before validation succeeds.
    private func persist(_ proposed: AppSettings, expected: AppSettings, message: String) async -> Bool {
        // Failed loads must never turn the in-memory defaults into persisted settings.
        guard configurationLoaded else { return false }
        saveInProgress = true
        isBusy = true
        defer {
            saveInProgress = false
            isBusy = false
        }
        do {
            try await configuration.replace(proposed, ifUnchanged: expected)
            settings = proposed
            persistedSettings = proposed
            applyLanguagePreference()
            lastError = nil
            lastMessage = localized(message)
            return true
        } catch {
            lastError = error.localizedDescription
            if let configurationError = error as? ConfigurationError,
               configurationError == .concurrentModification,
               let current = try? await configuration.load() {
                settings = current
                persistedSettings = current
            }
            return false
        }
    }

    // mutate applies a synchronous UI mutation before using the common save path.
    func mutate(_ change: (inout AppSettings) -> Void, message: String = "Settings saved.") {
        guard configurationLoaded else { return }
        change(&settings)
        Task { await save(message: message) }
    }

    // setOpenAppAtLogin applies the launchd side effect through the canonical command path.
    func setOpenAppAtLogin(_ enabled: Bool) {
        guard configurationLoaded else { return }
        settings.general.openAppAtLogin = enabled
        Task {
            isBusy = true
            defer { isBusy = false }
            let result = await commands.execute(
                CommandRequest(command: "config.set", arguments: ["general.openAppAtLogin", enabled ? "true" : "false"], confirmed: true),
                actor: "app"
            )
            if result.ok {
                do {
                    let current = try await configuration.load()
                    settings = current
                    persistedSettings = current
                    lastError = nil
                    lastMessage = localized(enabled ? "App will open after login." : "App will not open after login.")
                } catch {
                    lastError = error.localizedDescription
                }
            } else {
                settings.general.openAppAtLogin = persistedSettings.general.openAppAtLogin
                lastError = result.message
            }
        }
    }

    // run executes a canonical command and updates user-visible feedback.
    func run(_ command: String, arguments: [String] = [], confirmed: Bool = false) async -> CommandResult {
        // Operational actions require a loaded configuration, including the startup probe.
        guard configurationLoaded else {
            return CommandResult(ok: false, code: "CONFIG_UNAVAILABLE", message: lastError ?? localized("Settings could not be loaded."))
        }
        if settings != persistedSettings,
           !(await save(message: "Settings saved before running the action.")) {
            return CommandResult(ok: false, code: "CONFIG_NOT_SAVED", message: lastError ?? "Settings could not be saved.")
        }
        isBusy = true
        defer { isBusy = false }
        let result = await commands.execute(
            CommandRequest(command: command, arguments: arguments, confirmed: confirmed),
            actor: "app"
        )
        if result.ok {
            lastError = nil
            lastMessage = localizedCommandMessage(result)
        } else {
            lastError = localizedCommandMessage(result)
        }
        await refreshRuntime()
        return result
    }

    // completeOnboarding enables the agent and persists the onboarding decision.
    func completeOnboarding() {
        settings.general.onboardingCompleted = true
        settings.general.enabled = true
        showOnboarding = false
        Task { await save(message: "Setup completed.") }
    }

    // addMount opens an empty editor with credential-free defaults.
    func addMount() {
        editingMount = MountDefinition(name: "", url: "smb://")
        showMountEditor = true
    }

    // editMount opens a value copy that is saved only after validation.
    func editMount(_ mount: MountDefinition) {
        editingMount = mount
        showMountEditor = true
    }

    // saveMount validates and persists an editor draft before the caller dismisses the sheet.
    func saveMount(_ mount: MountDefinition) async -> Bool {
        var proposed = settings
        if let index = proposed.mounts.firstIndex(where: { $0.id == mount.id }) {
            proposed.mounts[index] = mount
        } else {
            proposed.mounts.append(mount)
        }
        let saved = await persist(proposed, expected: persistedSettings, message: "Network drive saved.")
        if saved {
            showMountEditor = false
            await refreshImportableMounts()
        }
        return saved
    }

    // setMountEnabled persists the Auto-Mount switch transactionally and restores the row after errors.
    func setMountEnabled(_ mount: MountDefinition, enabled: Bool) async -> Bool {
        var proposed = settings
        guard let index = proposed.mounts.firstIndex(where: { $0.id == mount.id }) else { return false }
        proposed.mounts[index].enabled = enabled
        return await persist(proposed, expected: persistedSettings, message: "Network drive updated.")
    }

    // removeMount deletes one configured mount only after the confirmed change is durably persisted.
    func removeMount(_ mount: MountDefinition) async -> Bool {
        var proposed = settings
        proposed.mounts.removeAll { $0.id == mount.id }
        let saved = await persist(proposed, expected: persistedSettings, message: "Network drive removed.")
        if saved { await refreshImportableMounts() }
        return saved
    }

    // refreshImportableMounts discovers visible SMB mounts that are not already configured.
    func refreshImportableMounts() async {
        let configuredMounts = settings.mounts
        importableMounts = await Task.detached {
            MountService().importableMountedSMBMounts(configuredMounts: configuredMounts)
        }.value
    }

    // importDiscoveredMount adds one currently mounted SMB share to automatic recovery.
    @discardableResult
    func importDiscoveredMount(_ discovered: DiscoveredSMBMount) async -> Bool {
        var proposed = settings
        proposed.mounts.append(MountDefinition(name: discovered.name, url: discovered.url, enabled: true))
        let saved = await persist(proposed, expected: persistedSettings, message: "Network drive imported.")
        if saved {
            importableMounts.removeAll { $0.id == discovered.id }
            await refreshRuntime()
        }
        return saved
    }

    // openSettings activates the app and presents its persistent settings window.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettingsHandler?()
    }

    // setOpenSettingsHandler connects presentation to the AppKit window owner.
    func setOpenSettingsHandler(_ handler: @escaping () -> Void) {
        openSettingsHandler = handler
    }

    // openTransferDialog presents the focused transfer draft outside the Settings window.
    func openTransferDialog() {
        NSApp.activate(ignoringOtherApps: true)
        openTransferDialogHandler?()
    }

    // setOpenTransferDialogHandler connects the model to the AppKit-owned transfer panel.
    func setOpenTransferDialogHandler(_ handler: @escaping () -> Void) {
        openTransferDialogHandler = handler
    }

    // openTransferWindow presents running and historical jobs in their own operational window.
    func openTransferWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openTransferWindowHandler?()
    }

    // setOpenTransferWindowHandler connects the model to the retained AppKit window owner.
    func setOpenTransferWindowHandler(_ handler: @escaping () -> Void) {
        openTransferWindowHandler = handler
    }

    // reveal opens an application-owned file or directory in Finder.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // exportConfiguration asks for a user-owned destination and writes only AppSettings data.
    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wrdmConfiguration]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "we-rock-drive-mounts-config.wrdmconfig"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { await exportConfiguration(to: file) }
    }

    // exportConfiguration writes a transfer file after current UI edits are durably saved.
    @discardableResult
    func exportConfiguration(to file: URL) async -> Bool {
        if settings != persistedSettings,
           !(await save(message: "Settings saved before exporting configuration.")) {
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await configuration.exportConfigurationData()
            try writeUserSelectedConfigurationFile(data, to: file)
            lastError = nil
            lastMessage = localized("Configuration exported.")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // importConfiguration asks for a transfer file and confirms the overwrite before loading it.
    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wrdmConfiguration, .propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = localized("Import configuration?")
        alert.informativeText = localized("This replaces the current app settings after validation. Passwords and API keys are not imported.")
        alert.addButton(withTitle: localized("Import"))
        alert.addButton(withTitle: localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await importConfiguration(from: file) }
    }

    // importConfiguration validates and replaces the active configuration in one store transaction.
    @discardableResult
    func importConfiguration(from file: URL) async -> Bool {
        guard settings == persistedSettings else {
            lastError = localized("Save or reload current changes before importing a configuration.")
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try Data(contentsOf: file)
            let imported = try await configuration.importConfigurationData(data, replacing: persistedSettings)
            settings = imported
            persistedSettings = imported
            applyLanguagePreference()
            lastError = nil
            lastMessage = localized("Configuration imported.")
            await refreshRuntime()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // refreshNetworkInventory performs read-only native discovery away from the main UI actor.
    func refreshNetworkInventory() async {
        networkInventory = await Task.detached { NativeNetworkInventory.read() }.value
    }

    // reloadNetworkSettings preserves unrelated unsaved fields after a profile command.
    func reloadNetworkSettings() async {
        if let loaded = try? await configuration.load() {
            settings.network.discovery = loaded.network.discovery
            persistedSettings.network.discovery = loaded.network.discovery
        }
    }

    var networkDecisionText: String {
        guard let report = networkReport else { return "Noch keine Agentenentscheidung verfügbar" }
        if !settings.general.enabled || !settings.network.enabled { return "Automatische WLAN-Steuerung deaktiviert" }
        if let error = report.execution.error { return "WLAN-Status oder Änderung unklar: " + error }
        if report.execution.reason == "ACTIVE_TRANSFERS" { return "WLAN bleibt während laufender WRDM-Transfers eingeschaltet" }
        if !settings.network.disableWifiWhenLanActive { return "Automatische WLAN-Abschaltung ist deaktiviert" }
        let explanations: [String: String] = [
            "NO_USABLE_ETHERNET": "Kein nutzbarer Ethernet-Anschluss",
            "INTERFACE_SELECTION_REQUIRED": "Anschlussauswahl erforderlich",
            "TARGET_ROUTE_UNKNOWN": "Der tatsächliche Weg zu einem Prüfziel ist unklar",
            "TARGET_ROUTE_NOT_ETHERNET": "Ein Prüfziel verwendet noch einen anderen Netzwerkweg",
            "DEFAULT_ROUTE_UNKNOWN": "Allgemeiner Netzwerkweg unbekannt",
            "DEFAULT_ROUTE_NOT_ETHERNET": "Ein allgemeiner Netzwerkweg verwendet noch WLAN oder VPN",
            "SMB_REQUIRES_WIFI": "Ein NAS ist derzeit nur über WLAN erreichbar",
            "SMB_REACHABILITY_UNKNOWN": "NAS-Erreichbarkeit über Ethernet nicht bestätigt",
            "NO_VERIFIED_TARGET": "Kein Prüfziel zur Bestätigung der Ethernet-Erreichbarkeit",
            "REQUIRED_TARGET_UNREACHABLE": "Ein verbindliches Prüfziel ist über Ethernet nicht erreichbar"
        ]
        if !report.observation.reasons.isEmpty {
            return report.observation.reasons.map { explanations[$0] ?? $0 }.joined(separator: " · ")
        }
        if let until = report.policyState.wifiGraceUntil, until > Date() { return "Bewusstes WLAN-/AirDrop-Zeitfenster aktiv" }
        if report.execution.observedWiFiEnabled { return "Ethernet erreichbar; Stabilitätsprüfung läuft" }
        return "Ethernet stabil; WLAN ausgeschaltet"
    }

    // enableNetworkNotifications is an explicit opt-in; the persistent in-app warning needs no permission.
    func enableNetworkNotifications() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notifyPortDeviations() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for warning in networkReport?.warnings.filter({ $0.state == "deviation" }) ?? [] {
            let key = warning.id.uuidString + ":" + ISO8601DateFormatter().string(from: warning.firstObserved)
            guard notifiedPortIncidents.insert(key).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = networkInventory.ports.first { $0.id == warning.portID }?.name ?? "Ethernet"
            content.body = "Abweichende Hardwareeinstellungen: " + warning.differences.joined(separator: ", ")
            do {
                try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                UserDefaults.standard.set(Array(notifiedPortIncidents.suffix(200)), forKey: "networkNotifiedIncidents")
            } catch { notifiedPortIncidents.remove(key) }
        }
    }

    // exportSupportBundle creates an archive, with a folder picker when Downloads is unavailable.
    func exportSupportBundle(email: Bool = false) {
        Task {
            var result = await run("diagnostics.export")
            if !result.ok && result.message.contains("DOWNLOADS_ACCESS_REQUIRED") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.prompt = "Support-ZIP speichern"
                if panel.runModal() == .OK, let folder = panel.url {
                    result = await run("diagnostics.export", arguments: [folder.path])
                }
            }
            guard result.ok, let path = result.data["path"] else { return }
            let file = URL(fileURLWithPath: path)
            if !email { reveal(file); return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbekannt"
            let subject = "We Rock Drive Mounts \(version) – Support"
            let diagnosis = networkReport.map { "Ethernet verfügbar: \($0.observation.selected?.usable == true ? "ja" : "unklar"); WLAN: \($0.execution.observedWiFiEnabled ? "an" : "aus"); Portabweichungen: \($0.warnings.filter { $0.state == "deviation" }.count)" } ?? "Noch keine Agentenbeobachtung verfügbar"
            let body = "Zeitpunkt: \(Date().formatted())\nDiagnose: \(diagnosis). Bereinigte Details im Support-ZIP.\n\nBeschreibung:\n\nSchritte zur Reproduktion:\n"
            let items: [Any] = [body, file]
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:support@wir.rocken.digital")!)
            let defaultID = defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }
            if defaultID == "com.apple.mail", let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
                service.recipients = ["support@wir.rocken.digital"]; service.subject = subject
                service.perform(withItems: items)
                lastMessage = "Mailübergabe gestartet. Bitte Entwurf und ZIP-Anhang im Mailprogramm prüfen."
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("An: support@wir.rocken.digital\nBetreff: " + subject + "\n\n" + body, forType: .string)
                reveal(file)
                lastMessage = "Das Mailprogramm bestätigt keine Anhangsübergabe. Nachrichtentext kopiert; ZIP bitte selbst anhängen."
            }
        }
    }

    // saveOpenAIKey stores the optional cloud credential in Keychain and clears the UI field.
    func saveOpenAIKey() {
        let value = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try CredentialStore().write(account: "openai-api-key", secret: value)
            openAIKeyDraft = ""
            openAIKeyConfigured = true
            lastError = nil
            lastMessage = localized("OpenAI credential saved in Keychain.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // deleteOpenAIKey removes the optional cloud credential from Keychain.
    func deleteOpenAIKey() {
        do {
            try CredentialStore().delete(account: "openai-api-key")
            openAIKeyDraft = ""
            openAIKeyConfigured = false
            lastError = nil
            lastMessage = localized("OpenAI credential removed.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // verifyWakeRoute performs a live route test and reloads persisted verification state.
    func verifyWakeRoute(_ route: WakeRouteKind) {
        Task {
            _ = await run("wake.verify", arguments: [route.rawValue], confirmed: true)
            await reloadAll()
        }
    }

    // testPiConnection loads and displays the versioned companion capability handshake.
    func testPiConnection() {
        Task {
            let result = await run("pi.health")
            guard let json = result.data["json"], let data = json.data(using: .utf8) else { return }
            piHealth = try? JSONDecoder().decode(PiCompanionHealth.self, from: data)
        }
    }

    // installPiCompanion deploys only the bundled managed files after explicit confirmation.
    func installPiCompanion() {
        guard let installer = Bundle.main.resourceURL?
            .appendingPathComponent("Pi/scripts/install-pi-companion.sh"),
              FileManager.default.fileExists(atPath: installer.path) else {
            lastError = "The bundled Raspberry Pi installer is unavailable."
            return
        }
        Task { _ = await run("pi.install", arguments: [installer.path], confirmed: true) }
    }

    // savePiPassword stores the one-time remote installer credential only in the user's Keychain.
    func savePiPassword() {
        guard !piPasswordDraft.isEmpty else { return }
        do {
            try CredentialStore().write(account: "raspberry-pi-sudo-password", secret: piPasswordDraft)
            piPasswordDraft = ""
            piPasswordConfigured = true
            lastError = nil
            lastMessage = localized("Raspberry Pi installation password saved in Keychain.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // deletePiPassword removes the installer credential after setup without affecting SSH keys.
    func deletePiPassword() {
        do {
            try CredentialStore().delete(account: "raspberry-pi-sudo-password")
            piPasswordDraft = ""
            piPasswordConfigured = false
            lastError = nil
            lastMessage = localized("Raspberry Pi installation password removed.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // analyzeQuestion runs the configured provider and preserves structured findings for source display.
    func analyzeQuestion() {
        let question = aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        Task {
            let result = await run("ai.analyze", arguments: [question])
            guard let json = result.data["json"], let data = json.data(using: .utf8),
                  let finding = try? JSONDecoder.configured.decode(DiagnosticFinding.self, from: data) else { return }
            aiFindings.insert(finding, at: 0)
        }
    }

    // setEvidenceSelection updates the explicit cloud preview selection without altering stored events.
    func setEvidenceSelection(_ eventID: UUID, selected: Bool) {
        var values = settings.ai.selectedEvidenceIDs ?? []
        if selected {
            if !values.contains(eventID) { values.append(eventID) }
        } else {
            values.removeAll { $0 == eventID }
        }
        settings.ai.selectedEvidenceIDs = values
    }

    // saveSynologyCredentials writes the optional DSM account and password only to Keychain.
    func saveSynologyCredentials() {
        let account = synologyAccountDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !synologyPasswordDraft.isEmpty else { return }
        do {
            try CredentialStore().write(account: "synology-dsm-account", secret: account)
            try CredentialStore().write(account: "synology-dsm-password", secret: synologyPasswordDraft)
            synologyAccountDraft = ""
            synologyPasswordDraft = ""
            synologyCredentialsConfigured = true
            lastError = nil
            lastMessage = localized("Synology DSM credentials saved in Keychain.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // deleteSynologyCredentials removes both optional DSM secrets from Keychain.
    func deleteSynologyCredentials() {
        do {
            try CredentialStore().delete(account: "synology-dsm-account")
            try CredentialStore().delete(account: "synology-dsm-password")
            synologyCredentialsConfigured = false
            lastError = nil
            lastMessage = localized("Synology DSM credentials removed.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // testSynologySources loads independent health results for every configured adapter.
    func testSynologySources() {
        Task {
            let result = await run("synology.health")
            guard let json = result.data["json"], let data = json.data(using: .utf8) else { return }
            synologyHealth = (try? JSONDecoder.configured.decode([SynologySourceHealth].self, from: data)) ?? []
        }
    }

    // importSynologyCSV asks for one user-selected Log Center export and imports it canonically.
    func importSynologyCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { _ = await run("synology.csv.import", arguments: [file.path]) }
    }

    // fetchSynologyDSM imports a bounded read-only Log Center page.
    func fetchSynologyDSM() {
        Task { _ = await run("synology.dsm.fetch") }
    }

    // toggleLiveCapture starts or stops the current app-owned Wireshark stream.
    func toggleLiveCapture() {
        Task {
            if let identifier = liveCaptureSession {
                let result = await run("capture.live.stop", arguments: [identifier], confirmed: true)
                if result.ok || result.code == "SESSION_NOT_FOUND" { liveCaptureSession = nil }
                if let json = result.data["json"], let data = json.data(using: .utf8),
                   let value = try? JSONDecoder.configured.decode(LiveCaptureStatus.self, from: data) {
                    applyLiveCaptureStatus(value)
                }
            } else {
                await refreshLiveCaptureStatus()
                guard liveCaptureStatus.canStart else {
                    lastError = localized(liveCaptureStatus.reason)
                    return
                }
                let result = await run("capture.live.start", confirmed: true)
                if result.ok { liveCaptureSession = result.data["session"] }
                if let json = result.data["json"], let data = json.data(using: .utf8),
                   let value = try? JSONDecoder.configured.decode(LiveCaptureStatus.self, from: data) {
                    applyLiveCaptureStatus(value)
                }
            }
        }
    }

    // chooseTransferSources lets the user select one or more local files or folders for the transfer job.
    func chooseTransferSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        _ = prepareTransferSources(panel.urls)
    }

    // prepareTransferSources validates dropped, selected, or Finder-provided URLs as one generic draft.
    @discardableResult
    func prepareTransferSources(_ urls: [URL]) -> Bool {
        do {
            let paths = try TransferSourceSelection.validatedPaths(from: urls)
            transferSourcePaths = paths
            transferDestinationPath = ""
            transferOperation = .copy
            transferResumePolicy = settings.transfer.defaultResumePolicy
            transferUnlimitedAutoRetries = settings.transfer.unlimitedAutoRetries
            transferKeepMacAwake = settings.transfer.keepMacAwakeByDefault ?? false
            lastError = nil
            lastMessage = localized("Transfer sources selected.")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // prepareTransferHandoff decodes one Finder URL before applying the normal source validation.
    @discardableResult
    func prepareTransferHandoff(_ url: URL) -> Bool {
        do {
            return prepareTransferSources(try TransferHandoff.sourceURLs(from: url))
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // chooseTransferDestination stores a user-selected destination folder path for the WRDM worker.
    func chooseTransferDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferDestinationPath = url.path
    }

    // startTransfer creates one canonical transfer job through CommandService and resets only after success.
    @discardableResult
    func startTransfer() async -> Bool {
        guard !transferSourcePaths.isEmpty else {
            lastError = localized("Select at least one source file or folder.")
            return false
        }
        guard !transferDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = localized("Select a destination folder.")
            return false
        }
        let useUnlimitedRetries = transferResumePolicy == .autoRetry && transferUnlimitedAutoRetries
        let arguments = [
            transferOperation.rawValue,
            "auto", // Infer direction from both paths in the shared transfer service.
            transferResumePolicy.rawValue,
            transferKeepMacAwake ? "true" : "false",
            useUnlimitedRetries ? "true" : "false",
            transferDestinationPath,
        ] + transferSourcePaths
        let result = await run("transfer.start", arguments: arguments, confirmed: true)
        if result.ok {
            resetTransferDraft()
            await refreshRuntime()
            openTransferWindow()
        }
        return result.ok
    }

    // resetTransferDraft clears user-selected paths while restoring persisted per-transfer defaults.
    func resetTransferDraft() {
        transferOperation = .copy
        transferResumePolicy = settings.transfer.defaultResumePolicy
        transferUnlimitedAutoRetries = settings.transfer.unlimitedAutoRetries
        transferKeepMacAwake = settings.transfer.keepMacAwakeByDefault ?? false
        transferSourcePaths = []
        transferDestinationPath = ""
    }

    // pauseTransfer requests an orderly worker termination that can later be resumed.
    func pauseTransfer(_ job: TransferJob) {
        Task { _ = await run("transfer.pause", arguments: [job.id.uuidString], confirmed: true) }
    }

    // stopTransfer stops one active job while keeping its persisted resume metadata.
    func stopTransfer(_ job: TransferJob) {
        Task { _ = await run("transfer.stop", arguments: [job.id.uuidString], confirmed: true) }
    }

    // resumeTransfer restarts one stopped, paused, or failed job with the same source and destination paths.
    func resumeTransfer(_ job: TransferJob) {
        Task { _ = await run("transfer.resume", arguments: [job.id.uuidString], confirmed: true) }
    }

    // finalizeTransferMove deletes source files only after a move job is verified.
    func finalizeTransferMove(_ job: TransferJob) {
        Task { _ = await run("transfer.finalizeMove", arguments: [job.id.uuidString], confirmed: true) }
    }

    // createTransferIncident stores a single evidence bundle for a transfer job.
    func createTransferIncident(_ job: TransferJob?) {
        Task {
            var arguments: [String] = []
            if let job { arguments = [job.id.uuidString] }
            let result = await run("transfer.incident", arguments: arguments)
            if let path = result.data["path"], !path.isEmpty {
                reveal(URL(fileURLWithPath: path))
            }
        }
    }

    // configurationFile exposes the documented advanced configuration location.
    var configurationFile: URL { paths.configFile }

    // logsDirectory exposes the application-owned diagnostic directory.
    var logsDirectory: URL { paths.logs }

    // applyLanguagePreference stores the explicit app language for the next app launch.
    private func applyLanguagePreference() {
        switch settings.general.language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .german:
            UserDefaults.standard.set(["de"], forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }

    // localized resolves dynamic UI messages that SwiftUI cannot infer as localization keys.
    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // localizedCommandMessage maps stable command codes while retaining actionable unknown errors.
    func localizedCommandMessage(_ result: CommandResult) -> String {
        // Generic failures carry their actionable cause in the command message.
        if !result.ok && result.code == "COMMAND_FAILED" { return localized(result.message) }
        let key = "command.\(result.code)"
        let value = NSLocalizedString(key, comment: "")
        return value == key ? result.message : value
    }

    // writeUserSelectedConfigurationFile protects the exported file without changing its parent directory.
    private func writeUserSelectedConfigurationFile(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        _ = chmod(file.path, SecureFileAccess.privateFileMode)
    }
}

// JSONDecoder configuration keeps date handling consistent with runtime stores.
private extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// UTType adds the dedicated WRDM transfer extension for file dialogs.
private extension UTType {
    static var wrdmConfiguration: UTType {
        UTType(filenameExtension: "wrdmconfig") ?? .propertyList
    }
}
