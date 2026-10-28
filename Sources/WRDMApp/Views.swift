import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WRDMCore

// HealthTone standardizes compact status presentation across the app.
private enum HealthTone {
    case good
    case warning
    case neutral

    // color maps semantic health to an accessible system color.
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

// localized resolves static labels passed through String-based reusable views.
private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// localizedFormat formats a localized dynamic status without exposing interpolation keys.
private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: arguments)
}

// StatusPill renders a stable status indicator with an icon and concise label.
private struct StatusPill: View {
    let title: String
    let value: String
    let symbol: String
    let tone: HealthTone

    // body presents scan-friendly state without decorative card nesting.
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }
}

// PopoverView is the primary quick-control surface opened from the menu bar.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    // body prioritizes current health and the most common recovery actions.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("We Rock Drive Mounts").font(.headline)
                    Text(!model.configurationLoaded ? "Settings could not be loaded." : (model.settings.general.enabled ? "Automatic recovery is active" : "Automatic recovery is paused"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.configurationLoaded {
                    Toggle("Mounts automatically recover", isOn: Binding(
                        get: { model.settings.general.enabled },
                        set: { enabled in model.mutate({ $0.general.enabled = enabled }) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            VStack(spacing: 10) {
                StatusPill(
                    title: localized("Network drives"),
                    value: driveStatusValue(model),
                    symbol: model.statusOperational && model.status.healthyMounts == model.status.enabledMounts ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    tone: model.statusOperational && model.status.healthyMounts == model.status.enabledMounts ? .good : .warning
                )
                StatusPill(
                    title: localized("Preferred connection"),
                    value: connectionStatusValue(model),
                    symbol: model.status.lanHealthy ? "network" : "wifi",
                    tone: model.networkReportFresh && (model.ethernetConnected || model.networkReport?.policyState.fallbackActive == true) ? .good : .warning
                )
            }
            .padding(16)

            HStack(spacing: 8) {
                Button {
                    Task { _ = await model.run("mounts.recover") }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { _ = await model.run("network.wifi.allow", arguments: [String(model.settings.network.wifiGraceMinutes)], confirmed: true) }
                } label: {
                    Label("AirDrop", systemImage: "airplayaudio")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Allow Wi-Fi temporarily")
            }
            .padding(.horizontal, 16)

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else if !model.lastMessage.isEmpty {
                Text(model.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                Spacer(minLength: 16)
            }

            Divider()

            HStack {
                Button("Settings") { model.openSettings() }
                Spacer()
                Text(agentTimestampValue(model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .frame(width: 390, height: 390)
    }

    // driveStatusValue distinguishes unavailable evidence from an actual zero-drive state.
    private func driveStatusValue(_ model: AppModel) -> String {
        guard model.statusOperational else {
            if model.status.phase == "disabled" { return localized("Automatic recovery is paused") }
            return localized(model.statusAvailability == .stale ? "Status out of date" : "Agent not connected")
        }
        if model.status.phase == "restartRequired" { return localized("Restart required") }
        return localizedFormat("%lld of %lld connected", model.status.healthyMounts, model.status.enabledMounts)
    }

    // connectionStatusValue renders connectivity only from a fresh agent snapshot.
    private func connectionStatusValue(_ model: AppModel) -> String {
        guard model.networkReportFresh else { return localized("Status out of date") }
        if model.ethernetConnected { return model.networkReport?.observation.selected?.name ?? localized("Ethernet") }
        if model.networkReport?.policyState.fallbackActive == true { return localized("Wi-Fi fallback") }
        return localized("No healthy connection")
    }

    // agentTimestampValue labels stale snapshots instead of presenting their timestamp as current.
    private func agentTimestampValue(_ model: AppModel) -> String {
        switch model.statusAvailability {
        case .fresh: model.status.timestamp.formatted(date: .omitted, time: .shortened)
        case .stale: localized("Status out of date")
        case .unavailable: localized("Agent not connected")
        }
    }
}

// SettingsView provides the complete, approachable configuration surface.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    // Keep sidebar visibility independent of the toolbar item's placement.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // body uses standard macOS sidebar navigation for predictable discovery.
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(selection: $model.selectedSection)
                .frame(minWidth: 210)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsFeedbackBanner(model: model)
                    Group {
                        // Never render default form values as the user's saved configuration.
                        if !model.configurationLoaded {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Settings could not be loaded.").font(.headline)
                                Text("Your saved settings remain unchanged. Reload them after updating the app.")
                                Button("Reload settings") { Task { await model.reloadAll() } }
                            }
                        } else {
                            switch model.selectedSection {
                            case .overview: OverviewSettings(model: model)
                            case .configuration: ConfigurationTransferSettings(model: model)
                            case .mounts: MountsSettings(model: model)
                            case .transfers: TransfersSettings(model: model)
                            case .network: NetworkSettings(model: model)
                            case .diagnostics: DiagnosticsSettings(model: model)
                            case .integrations: IntegrationsSettings(model: model)
                            case .ai: AISettingsView(model: model)
                            case .wake: WakeSettingsView(model: model)
                            case .advanced: AdvancedSettings(model: model)
                            }
                        }
                    }
                }
                .frame(maxWidth: 690, alignment: .topLeading)
                .padding(28)
            }
            // The leading toolbar owns the title and toggle together, independently of split columns.
            .navigationTitle(model.selectedSection.title)
            .toolbar(removing: .title)
        }
        .toolbar {
            // A navigation item stays anchored when the split view removes its sidebar column.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 20) {
                    Text(model.selectedSection.title)
                        .font(.headline)
                    Button {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(localized(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar"))
                    .accessibilityLabel(localized(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar"))
                    .accessibilityIdentifier("wrdm.sidebar-toggle")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView(model: model)
        }
        .sheet(isPresented: $model.showMountEditor) {
            if let mount = model.editingMount {
                MountEditorView(model: model, mount: mount)
            }
        }
        .task { model.start() }
    }
}

// SettingsFeedbackBanner keeps persistence and action results visible in the window where the action occurred.
private struct SettingsFeedbackBanner: View {
    @ObservedObject var model: AppModel

    // body presents errors before success and stays absent when no action has completed.
    var body: some View {
        if let error = model.lastError, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("wrdm.settings-error")
        } else if model.hasUnsavedSettings {
            Label("Unsaved settings are not active until you save them.", systemImage: "square.and.pencil")
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("wrdm.settings-unsaved")
        } else if !model.lastMessage.isEmpty {
            Label(model.lastMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("wrdm.settings-success")
        }
    }
}

// SettingsSidebar avoids fragile List selection behavior in an accessory menu-bar app.
private struct SettingsSidebar: View {
    @Binding var selection: AppSection

    // body renders explicit full-row buttons so every click target updates selection.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppSection.allCases) { section in
                    SettingsSidebarButton(
                        section: section,
                        isSelected: selection == section,
                        action: { selection = section }
                    )
                }
            }
            .padding(10)
        }
    }
}

// SettingsSidebarButton presents one predictable navigation row.
private struct SettingsSidebarButton: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void

    // body keeps the hit area stable and mirrors native sidebar selection.
    var body: some View {
        Button(action: action) {
            Label {
                Text(section.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            } icon: {
                Image(systemName: section.symbol)
                    .frame(width: 22)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
                isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.32) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}

// SectionHeader gives each settings page a concise purpose statement.
private struct SectionHeader: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    // body keeps headings sized for a compact operational settings surface.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// SettingsGroup visually groups related controls without nesting cards.
private struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    // body uses an inset grouped surface aligned with macOS settings conventions.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

// OverviewSettings summarizes health and exposes safe recovery actions.
private struct OverviewSettings: View {
    @ObservedObject var model: AppModel

    // body keeps ordinary health information separate from technical diagnostics.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Everything at a glance", text: "Your network drives are automatically restored in the background when the connection drops.")
            HStack(spacing: 12) {
                StatusPill(title: localized("Drives"), value: driveValue, symbol: "externaldrive.fill", tone: freshAndHealthyDrives ? .good : .warning)
                StatusPill(title: localized("Ethernet"), value: ethernetValue, symbol: "network", tone: model.ethernetConnected ? .good : .warning)
                StatusPill(title: localized("Wi-Fi"), value: wifiValue, symbol: "wifi", tone: model.statusAvailability == .fresh ? (model.status.wifiEnabled ? .neutral : .good) : .warning)
            }
            SettingsGroup(title: "Application") {
                LabeledContent("Version") {
                    Text(appVersionValue)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("wrdm.app-version")
                }
                Toggle("Open app after login", isOn: Binding(
                    get: { model.settings.general.openAppAtLogin },
                    set: { model.setOpenAppAtLogin($0) }
                ))
                Text("The background service starts independently. This switch only opens the visible menu-bar app after you log in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Updates") {
                if let version = model.updateStatus.availableVersion {
                    Label(localizedFormat("Version %@ is available", version), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                    if let notes = model.updateStatus.releaseNotesURL {
                        Link("What’s new", destination: notes)
                    }
                    if model.updateInstallDeferred {
                        Text("The update will be offered after active transfers finish.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Install update") { model.installAvailableUpdate() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wrdm.install-update")
                } else if model.updateStatus.lastCheckedAt != nil && model.updateStatus.lastError == nil {
                    Label("You’re up to date", systemImage: "checkmark.circle")
                } else {
                    Text("No update check has completed yet.").foregroundStyle(.secondary)
                }
                if let checked = model.updateStatus.lastCheckedAt {
                    Text(localizedFormat("Last checked: %@", checked.formatted(date: .abbreviated, time: .shortened)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.updateStatus.lastError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
                HStack {
                    Button(model.updateCheckInProgress ? "Checking…" : "Check for updates") { model.checkForUpdates() }
                        .disabled(model.updateCheckInProgress)
                        .accessibilityIdentifier("wrdm.check-updates")
                    Button("Enable update notifications") { model.enableUpdateNotifications() }
                }
                Text("Updates are checked daily in the background. Installation always needs your confirmation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Quick actions") {
                ViewThatFits(in: .horizontal) {
                    HStack { quickActionButtons }
                    VStack(alignment: .leading, spacing: 10) { quickActionButtons }
                }
            }
        }
    }

    // freshAndHealthyDrives requires current evidence before selecting a healthy tone.
    private var freshAndHealthyDrives: Bool {
        model.statusOperational && model.status.healthyMounts == model.status.enabledMounts
    }

    // driveValue presents the compact count only when the snapshot is current.
    private var driveValue: String {
        guard model.statusOperational else { return localized(model.status.phase == "disabled" ? "Automatic recovery is paused" : model.statusAvailability == .stale ? "Status out of date" : "Unavailable") }
        return localizedFormat("%lld of %lld connected", model.status.healthyMounts, model.status.enabledMounts)
    }

    // ethernetValue avoids classifying absent evidence as a real connection failure.
    private var ethernetValue: String {
        guard model.networkReportFresh else { return localized("Status out of date") }
        return model.ethernetConnected ? (model.networkReport?.observation.selected?.name ?? localized("Connected")) : "Kein nutzbarer Anschluss"
    }

    // Wi-Fi evidence uses the independent network timestamp rather than the mount recovery timestamp.
    private var wifiValue: String {
        guard model.networkReportFresh, model.networkReport?.execution.error != "WIFI_STATUS_UNKNOWN" else { return "Unklar" }
        return localized(model.networkReport?.execution.observedWiFiEnabled == true ? "On" : "Off")
    }

    // Show the product version; the internal bundle build identifier is not user-facing.
    private var appVersionValue: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? localized("Unknown")
    }

    // quickActionButtons keeps the same commands available in horizontal and vertical layouts.
    @ViewBuilder private var quickActionButtons: some View {
        Button { Task { _ = await model.run("mounts.recover") } } label: {
            Label("Reconnect drives", systemImage: "arrow.clockwise")
        }
        .fixedSize(horizontal: true, vertical: false)

        Button { Task { _ = await model.run("diagnostics.capture") } } label: {
            Label("Record current issue", systemImage: "waveform.badge.magnifyingglass")
        }
        .fixedSize(horizontal: true, vertical: false)

        Button { model.exportSupportBundle() } label: {
            Label("Export support file", systemImage: "square.and.arrow.up")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// ConfigurationTransferSettings gives users a safe way to move their setup between accounts or Macs.
private struct ConfigurationTransferSettings: View {
    @ObservedObject var model: AppModel

    // body keeps transfer controls separate from diagnostics support bundles.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(
                title: "Move configuration",
                text: "Export these settings for another local user or import a previously saved We Rock Drive Mounts configuration."
            )
            SettingsGroup(title: "Configuration file") {
                Text("The export includes network drive addresses, local network hosts, capture settings, Synology sources, AI preferences, and Wake-on-LAN targets.")
                    .foregroundStyle(.secondary)
                Label("Passwords, installation passwords, API keys, and tokens stay in macOS Keychain and are not exported.", systemImage: "key.slash")
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { transferButtons }
                    VStack(alignment: .leading, spacing: 10) { transferButtons }
                }
            }
            SettingsGroup(title: "Current location") {
                LabeledContent("Active configuration") {
                    Button("Show in Finder") { model.reveal(model.configurationFile) }
                }
            }
        }
    }

    // transferButtons route export and import through AppModel so feedback stays visible.
    @ViewBuilder private var transferButtons: some View {
        Button { model.exportConfiguration() } label: {
            Label("Export configuration", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isBusy)

        Button { model.importConfiguration() } label: {
            Label("Import configuration", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }
}

// TransfersSettings contains only persistent defaults; operational transfers live in separate app windows.
private struct TransfersSettings: View {
    @ObservedObject var model: AppModel

    // body keeps durable monitoring and behavior defaults separate from individual jobs.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(
                title: "NAS transfers",
                text: "Copy or move files through the mounted network drives and keep interruption evidence when something breaks."
            )
            SettingsGroup(title: "Transfer monitoring") {
                Toggle("Monitor large NAS transfers", isOn: model.immediateToggle(\.transfer.monitoringEnabled, key: "transfer.monitoringEnabled"))
                Toggle("Create an incident bundle if a transfer fails", isOn: model.immediateToggle(\.transfer.incidentBundleOnFailure, key: "transfer.incidentBundleOnFailure"))
                Toggle("Use Raspberry Pi rolling capture when enabled", isOn: model.immediateToggle(\.transfer.rollingPiCaptureEnabled, key: "transfer.rollingPiCaptureEnabled"))
                LabeledContent("High traffic threshold") {
                    TextField("Bytes per second", value: $model.settings.transfer.highTrafficBytesPerSecond, format: .number)
                        .frame(width: 180)
                }
                Stepper("Traffic must stay high for \(model.settings.transfer.sustainedSeconds) seconds", value: $model.settings.transfer.sustainedSeconds, in: 5...600, step: 5)
                Picker("Default after interruption", selection: $model.settings.transfer.defaultResumePolicy) {
                    ForEach(TransferResumePolicy.allCases) { policy in
                        Text(resumePolicyTitle(policy)).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Retry without a fixed limit", isOn: model.immediateToggle(\.transfer.unlimitedAutoRetries, key: "transfer.unlimitedAutoRetries"))
                    .disabled(model.settings.transfer.defaultResumePolicy != .autoRetry)
                Stepper("Automatic retries: \(model.settings.transfer.maximumAutoRetries)", value: $model.settings.transfer.maximumAutoRetries, in: 0...10)
                    .disabled(model.settings.transfer.defaultResumePolicy != .autoRetry || !model.settings.transfer.automaticRetryCountEditable)
                Text(model.settings.transfer.defaultResumePolicy != .autoRetry
                     ? "Choose automatic retry to use a finite or unlimited retry policy."
                     : model.settings.transfer.unlimitedAutoRetries
                         ? "Failed transfers keep retrying with a capped delay until they succeed or you pause or stop them. Permanent configuration and permission errors stop immediately."
                         : "The saved retry count is used for newly started transfers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Verify copied files before completing", isOn: model.immediateToggle(\.transfer.verifyAfterCopy, key: "transfer.verifyAfterCopy"))
                Toggle("Keep this Mac awake during transfers by default", isOn: Binding(
                    get: { model.settings.transfer.keepMacAwakeByDefault ?? false },
                    set: { model.settings.transfer.keepMacAwakeByDefault = $0 }
                ))
                Button("Save transfer settings") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent)
            }
            SettingsGroup(title: "Transfer window") {
                Text("Start transfers from the menu-bar droplet or manage current and past jobs in the separate transfer window.")
                    .foregroundStyle(.secondary)
                Button { model.openTransferWindow() } label: {
                    Label("Open transfers", systemImage: "arrow.left.arrow.right.square")
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            if model.transferResumePolicy != model.settings.transfer.defaultResumePolicy {
                model.transferResumePolicy = model.settings.transfer.defaultResumePolicy
            }
        }
    }

    // resumePolicyTitle presents policy names as user-facing behavior.
    private func resumePolicyTitle(_ policy: TransferResumePolicy) -> LocalizedStringKey {
        switch policy {
        case .ask: "Ask"
        case .autoRetry: "Retry automatically"
        case .manual: "Stop until I resume"
        }
    }
}

// TransferDropletView is the small persistent drop target shown directly below the menu-bar item.
struct TransferDropletView: View {
    @ObservedObject var model: AppModel
    let onAccepted: () -> Void
    @State private var isDropTargeted = false

    // body accepts generic Finder file URLs and offers an accessible picker alternative.
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 9) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(isDropTargeted ? Color.white : Color.accentColor)
                Text("Drop files or folders here")
                    .font(.headline)
                Text("They stay selected only until you start or cancel the transfer.")
                    .font(.caption)
                    .foregroundStyle(isDropTargeted ? Color.white.opacity(0.9) : Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 118)
            .padding(12)
            .background(isDropTargeted ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                TransferDropLoader.load(providers: providers) { urls in
                    if model.prepareTransferSources(urls) {
                        onAccepted()
                    }
                }
                return !providers.isEmpty
            }
            .accessibilityIdentifier("wrdm.transfer-droplet")

            HStack {
                Button("Choose…") {
                    model.chooseTransferSources()
                    if !model.transferSourcePaths.isEmpty { onAccepted() }
                }
                Button("Transfers") { model.openTransferWindow() }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 360, height: 220)
    }
}

// TransferDialogView gathers one complete transfer request after sources have been selected.
struct TransferDialogView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    // body keeps source selection, target, behavior, and feedback in one focused dialog.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New transfer").font(.title2.weight(.semibold))
                    Text("Choose how and where the selected items should be transferred.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.transferSourcePaths.isEmpty {
                        Text("No files or folders selected.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.transferSourcePaths, id: \.self) { path in
                            Text(path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Button("Choose files or folders…") { model.chooseTransferSources() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Picker("Action", selection: $model.transferOperation) {
                Text("Copy").tag(TransferOperation.copy)
                Text("Move after verification").tag(TransferOperation.move)
            }
            .pickerStyle(.segmented)
            // Source and destination determine direction in the shared transfer service.
            Picker("If interrupted", selection: $model.transferResumePolicy) {
                ForEach(TransferResumePolicy.allCases) { policy in
                    Text(transferResumePolicyTitle(policy)).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Retry without a fixed limit", isOn: transferUnlimitedRetryBinding)
                .disabled(model.transferResumePolicy != .autoRetry)
            Toggle("Keep this Mac awake until this transfer ends", isOn: $model.transferKeepMacAwake)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Destination").font(.callout.weight(.semibold))
                    Text(model.transferDestinationPath.isEmpty ? "No folder selected" : model.transferDestinationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Choose folder…") { model.chooseTransferDestination() }
            }

            if let error = model.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("wrdm.transfer-error")
            }

            HStack {
                Button("Cancel") {
                    model.resetTransferDraft()
                    onClose()
                }
                Spacer()
                Button("Start transfer") {
                    Task {
                        if await model.startTransfer() { onClose() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.transferSourcePaths.isEmpty || model.transferDestinationPath.isEmpty)
                .accessibilityIdentifier("wrdm.transfer-start")
            }
        }
        .padding(24)
        .frame(width: 650, height: 600)
    }

    // transferUnlimitedRetryBinding hides inactive unlimited retry state from non-retry policies.
    private var transferUnlimitedRetryBinding: Binding<Bool> {
        Binding(
            get: { model.transferResumePolicy == .autoRetry && model.transferUnlimitedAutoRetries },
            set: { model.transferUnlimitedAutoRetries = $0 }
        )
    }
}

// TransferControlView is the independent operational surface for current and past jobs.
struct TransferControlView: View {
    @ObservedObject var model: AppModel

    // body separates active work from history while keeping generic controls available.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transfers").font(.title2.weight(.semibold))
                    Text("Running, interrupted, and completed NAS transfers")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshRuntime() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    model.resetTransferDraft()
                    model.openTransferDialog()
                } label: {
                    Label("New transfer", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    transferSection(title: "Active", jobs: activeJobs)
                    transferSection(title: "History", jobs: historicalJobs)
                    Button { model.createTransferIncident(nil) } label: {
                        Label("Create incident from current evidence", systemImage: "archivebox")
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .task { await model.refreshRuntime() }
    }

    // activeJobs contains only jobs that can still change without a user action.
    private var activeJobs: [TransferJob] {
        model.transferJobs.filter { $0.state == .queued || $0.state == .running }
    }

    // historicalJobs keeps resumable and completed jobs in newest-first order.
    private var historicalJobs: [TransferJob] {
        model.transferJobs.filter { $0.state != .queued && $0.state != .running }
    }

    // transferSection renders one stable state group without duplicating row actions.
    @ViewBuilder private func transferSection(title: LocalizedStringKey, jobs: [TransferJob]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if jobs.isEmpty {
                Text("No transfers in this section.").foregroundStyle(.secondary)
            } else {
                ForEach(jobs) { job in
                    TransferJobRow(model: model, job: job)
                }
            }
        }
    }
}

// TransferDropLoader collects asynchronous Finder providers before updating the main-actor model.
private enum TransferDropLoader {
    // load resolves each provider exactly once and returns all valid file URLs together.
    static func load(providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        guard !providers.isEmpty else {
            Task { @MainActor in completion([]) }
            return
        }
        let accumulator = TransferDropAccumulator(expectedCount: providers.count, completion: completion)
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                accumulator.complete(url: url)
            }
        }
    }
}

// TransferDropAccumulator serializes provider callbacks without sharing mutable value state across closures.
private final class TransferDropAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: @MainActor ([URL]) -> Void

    // init records the bounded provider count and the main-actor completion handler.
    init(expectedCount: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        remaining = expectedCount
        self.completion = completion
    }

    // complete stores one callback result and emits the final collection on the main actor.
    func complete(url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let result = urls
        lock.unlock()
        if finished {
            Task { @MainActor in completion(result) }
        }
    }
}

// transferResumePolicyTitle maps durable enum values to user-facing behavior labels.
private func transferResumePolicyTitle(_ policy: TransferResumePolicy) -> LocalizedStringKey {
    switch policy {
    case .ask: "Ask"
    case .autoRetry: "Retry automatically"
    case .manual: "Stop until I resume"
    }
}

// TransferJobRow renders one persisted transfer and exposes valid next actions.
struct TransferJobRow: View {
    @ObservedObject var model: AppModel
    let job: TransferJob

    // body uses compact status plus buttons that match the persisted job state.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text("\(job.state.rawValue) · \(job.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(job.sources.count) source(s) → \(job.destination)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            if let percent = job.progress.percent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
            }
            transferProgressDetails
            if let error = job.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if job.keepMacAwake == true {
                Label(keepAwakeStatus, systemImage: "moon.fill")
                    .font(.caption2)
                    .foregroundStyle(job.powerAssertionActive == true ? .green : .secondary)
            }
            if let assertionError = job.powerAssertionError, !assertionError.isEmpty {
                Label(assertionError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    // transferProgressDetails renders agent-persisted progress without requiring an external watcher.
    @ViewBuilder private var transferProgressDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let completed = job.progress.completedBytes, let total = job.progress.totalBytes, total > 0 {
                Text("\(formatBytes(completed)) of \(formatBytes(total)) · \(Int((Double(completed) / Double(total) * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let completedFiles = job.progress.completedFiles, let totalFiles = job.progress.totalFiles {
                Text("\(completedFiles) of \(totalFiles) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let current = job.progress.currentPath, !current.isEmpty {
                Text("Current: \(current)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let bytesPerSecond = job.progress.bytesPerSecond {
                Text("Speed: \(formatBytes(UInt64(max(0, bytesPerSecond))))/s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let remaining = estimatedRemainingDuration {
                Text(localizedFormat("Remaining: %@", formatDuration(remaining) as NSString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let highTrafficSeconds = job.progress.highTrafficSeconds, highTrafficSeconds > 0, job.state == .running {
                Label("High transfer traffic for \(highTrafficSeconds) seconds", systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            if let stallSeconds = job.progress.stallSeconds, stallSeconds >= 30, job.state == .running {
                Label("No transfer progress for \(stallSeconds) seconds", systemImage: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // actions exposes only commands that make sense for the current state.
    @ViewBuilder private var actions: some View {
        if job.state == .running {
            Button("Pause") { model.pauseTransfer(job) }
            Button("Stop") { model.stopTransfer(job) }
        }
        if [.paused, .stopped, .failed].contains(job.state) {
            Button("Resume") { model.resumeTransfer(job) }
        }
        if job.operation == .move, job.state == .verified {
            Button("Finalize move") { model.finalizeTransferMove(job) }
                .buttonStyle(.borderedProminent)
        }
        Button("Incident") { model.createTransferIncident(job) }
    }

    // The selected paths already express direction; show only the localized operation.
    private var title: LocalizedStringKey {
        job.operation == .copy ? "Copy" : "Move"
    }

    // keepAwakeStatus distinguishes a live assertion from a completed job's historical choice.
    private var keepAwakeStatus: LocalizedStringKey {
        if job.powerAssertionActive == true { return "Keeping this Mac awake" }
        if job.state == .queued || job.state == .running { return "Keep-awake requested" }
        return "Keep-awake was enabled"
    }

    // formatBytes keeps large transfer values readable in the operational transfer window.
    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    // estimatedRemainingDuration uses the smoothed agent rate so ETA text stays stable.
    private var estimatedRemainingDuration: TimeInterval? {
        guard job.state == .running,
              let total = job.progress.totalBytes,
              let completed = job.progress.completedBytes,
              total > completed,
              let rate = job.progress.smoothedBytesPerSecond,
              rate.isFinite,
              rate > 1 else {
            return nil
        }
        return Double(total - completed) / rate
    }

    // formatDuration rounds up to minutes to avoid noisy second-level ETA changes.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let roundedMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = roundedMinutes < 60 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(roundedMinutes * 60)) ?? localizedFormat("%lld minutes", Int64(roundedMinutes))
    }

    // symbol maps terminal states to understandable visuals.
    private var symbol: String {
        switch job.state {
        case .running: "arrow.triangle.2.circlepath"
        case .completed, .verified, .finalized: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .stopped: "stop.circle.fill"
        case .queued: "clock.fill"
        }
    }

    // color mirrors the state without requiring users to parse raw codes.
    private var color: Color {
        switch job.state {
        case .completed, .verified, .finalized: .green
        case .failed: .orange
        case .running: .accentColor
        default: .secondary
        }
    }
}

// MountsSettings manages credential-free SMB share definitions.
private struct MountsSettings: View {
    @ObservedObject var model: AppModel
    @State private var removalCandidate: MountDefinition?
    @State private var forceRecoveryCandidate: MountDefinition?

    // body renders one direct row per share with familiar edit and delete icons.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Network drives", text: "Add the shared folders that should stay connected. Passwords remain in macOS Keychain.")
            HStack {
                Text("\(model.settings.mounts.filter(\.enabled).count) active drives").foregroundStyle(.secondary)
                Spacer()
                Button { model.addMount() } label: { Label("Add drive", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            VStack(spacing: 1) {
                ForEach(model.settings.mounts) { mount in
                    let runtime = state(for: mount)
                    HStack(spacing: 12) {
                        Image(systemName: runtime.availability == .healthy ? "externaldrive.fill.badge.checkmark" : runtime.recoveryPhase == .restartRequired ? "restart.circle.fill" : "externaldrive.badge.exclamationmark")
                            .foregroundStyle(runtime.availability == .healthy ? .green : runtime.recoveryPhase == .restartRequired ? .red : .orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mount.name).font(.callout.weight(.semibold))
                            Text(mount.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(availabilityLabel(runtime.availability)) · \(recoveryLabel(runtime.recoveryPhase))")
                                .font(.caption2)
                                .foregroundStyle(runtime.recoveryPhase == .restartRequired ? .red : .secondary)
                            Text(runtime.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if let failureCode = runtime.failureCode {
                                Text(localizedFormat("Failure code: %@", failureCode.rawValue as NSString))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if let incidentID = runtime.incidentID {
                                Text(localizedFormat("Incident: %@", incidentID.uuidString as NSString))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let nextAttemptAt = runtime.nextAttemptAt {
                                Text(localizedFormat("Next attempt: %@", nextAttemptAt.formatted(date: .abbreviated, time: .standard) as NSString))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let localPath = runtime.localPath {
                                Text(localPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if runtime.recoveryPhase == .manualConfirmationRequired {
                            Button("Force recovery…") { forceRecoveryCandidate = mount }
                                .buttonStyle(.bordered)
                        }
                        Toggle("Enabled", isOn: Binding(
                            get: { mount.enabled },
                            set: { enabled in
                                Task { _ = await model.setMountEnabled(mount, enabled: enabled) }
                            }
                        ))
                        .labelsHidden()
                        Button { model.editMount(mount) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help("Edit drive")
                        Button { removalCandidate = mount } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.red).help("Remove drive")
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.55))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            if model.settings.mounts.isEmpty {
                ContentUnavailableView("No network drives", systemImage: "externaldrive.badge.plus", description: Text("Add your first SMB shared folder."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
            Divider()
            importableMounts
        }
        .confirmationDialog("Remove this network drive?", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let candidate = removalCandidate else { return }
                Task {
                    if await model.removeMount(candidate) { removalCandidate = nil }
                }
            }
        }
        .confirmationDialog("Force recovery for this network drive?", isPresented: Binding(
            get: { forceRecoveryCandidate != nil },
            set: { if !$0 { forceRecoveryCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Force unmount and reconnect", role: .destructive) {
                guard let candidate = forceRecoveryCandidate else { return }
                Task {
                    _ = await model.run("mounts.force-recover", arguments: [candidate.id.uuidString], confirmed: true)
                    forceRecoveryCandidate = nil
                }
            }
        } message: {
            Text("WRDM will first verify that no active WRDM transfer uses this drive. If macOS remains trapped in kernel wait, a restart will still be required.")
        }
        .task { await model.refreshImportableMounts() }
    }

    // importableMounts lets first-run users adopt already mounted SMB shares without retyping URLs.
    @ViewBuilder private var importableMounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mounted drives").font(.headline)
                    Text("Import mounted drives into automatic recovery.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshImportableMounts() }
                } label: {
                    Label("Refresh mounted drives", systemImage: "arrow.clockwise")
                }
            }
            if model.importableMounts.isEmpty {
                Text("No mounted SMB drives available to import.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.importableMounts) { mount in
                        importableMountRow(mount)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // importableMountRow previews one discovered mount before adding it to automatic recovery.
    private func importableMountRow(_ mount: DiscoveredSMBMount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(mount.name).font(.callout.weight(.semibold))
                Text(mount.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(localizedFormat("Mounted at %@", mount.localPath as NSString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { _ = await model.importDiscoveredMount(mount) }
            } label: {
                Label("Import", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55))
    }

    // state returns the latest runtime record for one configured share.
    private func state(for mount: MountDefinition) -> MountRuntimeState {
        model.mountStates.first(where: { $0.mountID == mount.id }) ?? MountRuntimeState(
            mountID: mount.id,
            timestamp: .distantPast,
            availability: mount.enabled ? .missing : .disabled,
            consecutiveFailures: 0,
            message: "Not checked"
        )
    }

    // availabilityLabel translates the observation dimension without hiding its meaning.
    private func availabilityLabel(_ availability: MountAvailability) -> String {
        switch availability {
        case .disabled: localized("Disabled")
        case .healthy: localized("Connected")
        case .missing: localized("Missing")
        case .staleMounted: localized("Stale mount")
        case .unknown: localized("Unknown")
        }
    }

    // recoveryLabel translates the independent recovery phase into a concise user action state.
    private func recoveryLabel(_ phase: MountRecoveryPhase) -> String {
        switch phase {
        case .idle: localized("Idle")
        case .waitingForNetwork: localized("Waiting for SMB server")
        case .scheduled: localized("Retry scheduled")
        case .mounting: localized("Connecting")
        case .unmounting: localized("Disconnecting")
        case .verifyingDetach: localized("Verifying disconnect")
        case .verifyingHealth: localized("Verifying SMB health")
        case .deferredActiveTransfer: localized("Waiting for active transfer")
        case .manualConfirmationRequired: localized("Confirmation required")
        case .circuitOpen: localized("Automatic recovery stopped")
        case .restartRequired: localized("Restart required")
        }
    }
}

// MountEditorView validates the friendly name and SMB address before save.
private struct MountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State var mount: MountDefinition
    @State private var isSaving = false

    // body presents the minimum fields needed by an inexperienced user.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mount.name.isEmpty ? "Add network drive" : "Edit network drive").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $mount.name, prompt: Text("Team files"))
                TextField("Shared folder address", text: $mount.url, prompt: Text("smb://server/shared-folder"))
                Toggle("Connect this drive automatically", isOn: $mount.enabled)
            }
            Text("Use an address beginning with smb://. macOS will ask for the password when it first connects.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("wrdm.mount-editor-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    isSaving = true
                    Task {
                        if await model.saveMount(mount) { dismiss() }
                        isSaving = false
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

// NetworkSettings exposes Ethernet preference, fallback, grace time, and traffic tracking.
private struct NetworkSettings: View {
    @ObservedObject var model: AppModel

    // body favors plain-language controls while retaining interfaces in an advanced group.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Ethernet first", text: "Keep Wi-Fi available for AirDrop without letting it become the permanent route by accident.")
            SettingsGroup(title: "Automatic connection control") {
                Toggle("Prefer Ethernet automatically", isOn: model.immediateToggle(\.network.enabled, key: "network.enabled"))
                Toggle("Turn Wi-Fi off when Ethernet is healthy", isOn: model.immediateToggle(\.network.disableWifiWhenLanActive, key: "network.disableWifiWhenLanActive"))
                Toggle("Turn Wi-Fi on if Ethernet fails", isOn: model.immediateToggle(\.network.enableWifiWhenLanUnhealthy, key: "network.enableWifiWhenLanUnhealthy"))
                Stepper("Keep Wi-Fi on for \(model.settings.network.wifiGraceMinutes) minutes", value: $model.settings.network.wifiGraceMinutes, in: 1...240)
                HStack {
                    Button { Task { _ = await model.run("network.wifi.allow", arguments: [String(model.settings.network.wifiGraceMinutes)], confirmed: true) } } label: { Label("Start AirDrop window", systemImage: "timer") }
                    Button { Task { _ = await model.run("network.wifi.off", confirmed: true) } } label: { Label("Turn Wi-Fi off now", systemImage: "wifi.slash") }
                }
            }
            SettingsGroup(title: "Traffic") {
                Toggle("Track data usage per network interface", isOn: model.immediateToggle(\.network.trafficEnabled, key: "network.trafficEnabled"))
                Toggle("Erkannte Ethernet- und WLAN-Anschlüsse automatisch erfassen", isOn: Binding(get: {
                    model.settings.network.discovery?.automaticTraffic ?? true
                }, set: { value in
                    var options = model.settings.network.discovery ?? NetworkOptions()
                    options.automaticTraffic = value
                    model.settings.network.discovery = options
                }))
                TrafficSummary(samples: model.traffic, names: Dictionary(model.networkInventory.ports.map { ($0.interface, $0.name) }, uniquingKeysWith: { first, _ in first }))
            }
            NetworkDetailsView(model: model)
            Button("Systemmitteilungen für Portabweichungen aktivieren") { model.enableNetworkNotifications() }
            Button("Save network settings") { Task { await model.save() } }.buttonStyle(.borderedProminent)
        }
    }
}

// TrafficSummary aggregates the latest deltas by interface for useful human-scale totals.
private struct TrafficSummary: View {
    let samples: [InterfaceTrafficSample]
    var names: [String: String] = [:]

    // totals adds bounded interval samples without exposing raw counters.
    private var totals: [(String, UInt64)] {
        Dictionary(grouping: samples, by: \.interface)
            .map { key, values in (key, values.reduce(0) { $0 + $1.receivedDelta + $1.sentDelta }) }
            .sorted { $0.0 < $1.0 }
    }

    // latestRates selects the newest observed aggregate throughput for each interface.
    private var latestRates: [String: Double] {
        Dictionary(grouping: samples, by: \.interface).mapValues { values in
            let latest = values.max { $0.timestamp < $1.timestamp }
            return (latest?.receivedBytesPerSecond ?? 0) + (latest?.sentBytesPerSecond ?? 0)
        }
    }

    // body presents one stable row per observed interface.
    var body: some View {
        if totals.isEmpty {
            Text("No traffic samples yet.").foregroundStyle(.secondary)
        } else {
            ForEach(totals, id: \.0) { interface, bytes in
                LabeledContent(names[interface] ?? interface) {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(latestRates[interface] ?? 0), countStyle: .file))/s")
                }
            }
        }
    }
}

// DiagnosticsSettings controls local collection and presents recent evidence.
private struct DiagnosticsSettings: View {
    @ObservedObject var model: AppModel

    // body separates collection controls from the chronological event list.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Connection diagnostics", text: "Record sleep, wake, network changes, disconnects, and recovery attempts so failures can be explained later.")
            SettingsGroup(title: "Collection") {
                Toggle("Collect diagnostic events", isOn: model.immediateToggle(\.diagnostics.enabled, key: "diagnostics.enabled"))
                Toggle("Record network status changes", isOn: model.immediateToggle(\.diagnostics.networkEventsEnabled, key: "diagnostics.networkEventsEnabled"))
                Toggle("Record sleep and wake events", isOn: model.immediateToggle(\.diagnostics.sleepWakeEventsEnabled, key: "diagnostics.sleepWakeEventsEnabled"))
                Toggle("Include relevant macOS system logs", isOn: model.immediateToggle(\.diagnostics.macLogsEnabled, key: "diagnostics.macLogsEnabled"))
                Toggle("Track interface traffic", isOn: model.immediateToggle(\.network.trafficEnabled, key: "network.trafficEnabled"))
                Stepper("Keep data for \(model.settings.diagnostics.retentionDays) days", value: $model.settings.diagnostics.retentionDays, in: 1...365)
                HStack {
                    Button { Task { _ = await model.run("diagnostics.capture") } } label: { Label("Record issue now", systemImage: "record.circle") }
                    Button { model.exportSupportBundle() } label: { Label("Export support file", systemImage: "square.and.arrow.up") }
                    Button("Support-E-Mail vorbereiten") { model.exportSupportBundle(email: true) }
                }
            }
            SettingsGroup(title: "Recent events") {
                if model.events.isEmpty {
                    Text("No diagnostic events recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(model.events.prefix(30)) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.type == .error ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                            .foregroundStyle(event.type == .error ? .orange : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary).font(.callout)
                            Text("\(event.source) · \(event.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Save diagnostic settings") { Task { await model.save() } }.buttonStyle(.borderedProminent)
        }
    }
}

// IntegrationsSettings configures Raspberry Pi, packet capture, and Synology sources.
private struct IntegrationsSettings: View {
    @ObservedObject var model: AppModel

    // body keeps each external system independently optional and testable.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Data sources", text: "Add network-side evidence only where it helps. Every source can be switched off independently.")
            SettingsGroup(title: "Raspberry Pi packet capture") {
                Toggle("Enable packet capture on Raspberry Pi", isOn: model.immediateToggle(\.packetCapture.enabled, key: "packetCapture.enabled"))
                LabeledContent("Address") { TextField("Address", text: $model.settings.packetCapture.host).frame(width: 230) }
                LabeledContent("User") { TextField("User", text: $model.settings.packetCapture.user).frame(width: 230) }
                LabeledContent("Network interface") { TextField("Interface", text: $model.settings.packetCapture.interface).frame(width: 230) }
                Stepper("Capture for \(model.settings.packetCapture.durationSeconds) seconds", value: $model.settings.packetCapture.durationSeconds, in: 5...300, step: 5)
                SecureField("Installation password", text: $model.piPasswordDraft)
                HStack {
                    Button("Save installation password in Keychain") { model.savePiPassword() }
                        .disabled(model.piPasswordDraft.isEmpty)
                    if model.piPasswordConfigured {
                        Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Remove", role: .destructive) { model.deletePiPassword() }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { piActionButtons }
                    VStack(alignment: .leading, spacing: 10) { piActionButtons }
                }
                if let health = model.piHealth {
                    LabeledContent("Companion version", value: health.version)
                    LabeledContent("Current address", value: health.addresses?.joined(separator: ", ") ?? "Unavailable")
                    LabeledContent("Architecture", value: health.architecture)
                    LabeledContent("Capture tool", value: health.dumpcapAvailable ? "dumpcap" : health.tsharkAvailable ? "tshark" : "Unavailable")
                    LabeledContent("Syslog receiver", value: health.syslogReceiverActive ? "Active" : "Inactive")
                }
            }
            SettingsGroup(title: "Synology") {
                Toggle("Receive Synology syslog events", isOn: model.immediateToggle(\.synology.syslogEnabled, key: "synology.syslogEnabled"))
                Toggle("Allow read-only SSH diagnostics", isOn: model.immediateToggle(\.synology.readOnlySSHEnabled, key: "synology.readOnlySSHEnabled"))
                LabeledContent("NAS address") { TextField("NAS address", text: $model.settings.synology.sshHost).frame(width: 230) }
                LabeledContent("Read-only user") { TextField("Read-only user", text: $model.settings.synology.sshUser).frame(width: 230) }
                Toggle("Allow CSV log imports", isOn: model.immediateToggle(\.synology.csvImportEnabled, key: "synology.csvImportEnabled"))
                HStack {
                    Button { model.testSynologySources() } label: { Label("Test sources", systemImage: "stethoscope") }
                    Button { model.importSynologyCSV() } label: { Label("Import CSV", systemImage: "doc.badge.plus") }
                        .disabled(!model.settings.synology.csvImportEnabled)
                    Button { model.fetchSynologyDSM() } label: { Label("Fetch DSM logs", systemImage: "arrow.down.doc") }
                        .disabled(!model.settings.synology.dsmAPIEnabled)
                }
                ForEach(model.synologyHealth) { health in
                    HStack {
                        Image(systemName: health.healthy ? "checkmark.circle.fill" : health.enabled ? "exclamationmark.circle.fill" : "minus.circle")
                            .foregroundStyle(health.healthy ? .green : health.enabled ? .orange : .secondary)
                        Text(health.source)
                        Spacer()
                        Text(health.message).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Button("Save data sources") { Task { await model.save() } }.buttonStyle(.borderedProminent)
        }
    }

    // piActionButtons keeps operational Pi commands readable at the minimum window size.
    @ViewBuilder private var piActionButtons: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.liveCaptureStatus.canStart || model.liveCaptureStatus.state == .running ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.liveCaptureStatus.canStart || model.liveCaptureStatus.state == .running ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wireshark live capture")
                    .font(.headline)
                Text(LocalizedStringKey(model.liveCaptureStatus.reason))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("live-capture-status")

        Button { model.testPiConnection() } label: {
            Label("Test connection", systemImage: "checkmark.circle")
        }
        .fixedSize(horizontal: true, vertical: false)

        Button { model.installPiCompanion() } label: {
            Label("Install companion", systemImage: "shippingbox.and.arrow.backward")
        }
        .fixedSize(horizontal: true, vertical: false)

        Button { Task { _ = await model.run("capture.start", confirmed: true) } } label: {
            Label("Start test capture", systemImage: "waveform")
        }
        .fixedSize(horizontal: true, vertical: false)

        Button { model.toggleLiveCapture() } label: {
            Label(model.liveCaptureSession == nil ? "Open live Wireshark" : "Stop live Wireshark", systemImage: model.liveCaptureSession == nil ? "dot.radiowaves.left.and.right" : "stop.fill")
        }
        .disabled(model.liveCaptureSession == nil && (!model.liveCaptureStatus.canStart || !model.settings.packetCapture.enabled))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// AISettingsView explains provider and action authority in user-facing terms.
private struct AISettingsView: View {
    @ObservedObject var model: AppModel

    // body makes cloud transfer and autonomous actions explicit decisions.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "AI-assisted diagnosis", text: "AI can correlate recorded evidence and explain likely causes with references to the underlying events.")
            SettingsGroup(title: "Analysis") {
                Toggle("Enable AI analysis", isOn: model.immediateToggle(\.ai.enabled, key: "ai.enabled"))
                Picker("Provider", selection: $model.settings.ai.provider) {
                    Text("On this Mac").tag(AIProviderKind.local)
                    Text("OpenAI").tag(AIProviderKind.openAI)
                }
                .pickerStyle(.segmented)
                // Explain unavailable on-device inference while retaining existing evidence correlation.
                if model.settings.ai.provider == .local,
                   let reason = LocalFoundationModelProvider().unavailableReason {
                    Text(localized(reason)).font(.footnote).foregroundStyle(.secondary)
                    Text("Recorded evidence can still be analyzed using rule-based diagnostics.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Allowed actions", selection: $model.settings.ai.actionMode) {
                    Text("Always ask").tag(AIActionMode.confirmAll)
                    Text("Ask for critical changes").tag(AIActionMode.guarded)
                    Text("Act automatically").tag(AIActionMode.autonomous)
                }
                if model.settings.ai.provider == .openAI {
                    Picker("Data sent for analysis", selection: $model.settings.ai.cloudDataMode) {
                        Text("Summaries only").tag(CloudDataMode.reducedFindings)
                        Text("Selected logs").tag(CloudDataMode.selectedRawLogs)
                        Text("Full diagnostics").tag(CloudDataMode.fullDiagnostics)
                    }
                    SecureField("OpenAI API key", text: $model.openAIKeyDraft)
                    HStack {
                        Button("Save in Keychain") { model.saveOpenAIKey() }
                            .disabled(model.openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.openAIKeyConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove", role: .destructive) { model.deleteOpenAIKey() }
                        }
                    }
                    if model.settings.ai.cloudDataMode == .selectedRawLogs {
                        Text("Selected evidence preview").font(.callout.weight(.semibold))
                        ForEach(model.events.prefix(20)) { event in
                            Toggle(isOn: Binding(
                                get: { model.settings.ai.selectedEvidenceIDs?.contains(event.id) == true },
                                set: { model.setEvidenceSelection(event.id, selected: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.summary).lineLimit(1)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            SettingsGroup(title: "Ask about the latest incident") {
                TextField("Question", text: $model.aiQuestion)
                Button { model.analyzeQuestion() } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .disabled(model.aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(model.aiFindings) { finding in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(finding.title).font(.headline)
                        Text(finding.explanation).textSelection(.enabled)
                        Text("Confidence: \(Int(finding.confidence * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(finding.evidenceIDs, id: \.self) { evidenceID in
                            Label(evidenceLabel(evidenceID), systemImage: "link")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Button("Save AI settings") { Task { await model.save() } }.buttonStyle(.borderedProminent)
        }
    }

    // evidenceLabel resolves a finding reference back to source and timestamp.
    private func evidenceLabel(_ id: UUID) -> String {
        guard let event = model.events.first(where: { $0.id == id }) else {
            return "Unavailable evidence \(id.uuidString)"
        }
        return "\(event.source) · \(event.timestamp.formatted(date: .abbreviated, time: .shortened))"
    }
}

// WakeSettingsView configures explicit opt-in routes for waking this Mac remotely.
private struct WakeSettingsView: View {
    @ObservedObject var model: AppModel

    // body surfaces target identity and independent trigger routes.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Wake this Mac", text: "Send a Wake-on-LAN request from a device that remains available while this Mac sleeps.")
            SettingsGroup(title: "This Mac") {
                LabeledContent("Name") { TextField("Name", text: $model.settings.wake.targetName).frame(width: 250) }
                LabeledContent("Ethernet MAC address") { TextField("MAC address", text: $model.settings.wake.targetMACAddress).frame(width: 250) }
                LabeledContent("Current address") { TextField("Address", text: $model.settings.wake.targetHost).frame(width: 250) }
            }
            SettingsGroup(title: "Wake routes") {
                ForEach($model.settings.wake.routes) { $route in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(routeTitle(route.kind), isOn: $route.enabled)
                            Spacer()
                            Image(systemName: route.verified ? "checkmark.seal.fill" : "questionmark.circle")
                                .foregroundStyle(route.verified ? .green : .secondary)
                                .help(route.verified ? "Verified" : "Not verified")
                            if route.kind == .iosShortcut {
                                Label("External trigger", systemImage: "iphone")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Test") { model.verifyWakeRoute(route.kind) }
                                    .disabled(!route.enabled)
                            }
                        }
                        if route.kind == .synologyTask {
                            TextField("user@nas|task-id", text: $route.command)
                                .textFieldStyle(.roundedBorder)
                        }
                        if route.kind == .tailscale {
                            TextField("Tailscale address of the Raspberry Pi", text: $route.command)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            HStack {
                Button("Save wake settings") { Task { await model.save() } }.buttonStyle(.borderedProminent)
                Button { Task { _ = await model.run("wake", arguments: [WakeRouteKind.raspberryPiLAN.rawValue], confirmed: true) } } label: { Label("Send test request", systemImage: "power") }
            }
        }
    }

    // routeTitle translates technical route identifiers into recognizable labels.
    private func routeTitle(_ route: WakeRouteKind) -> LocalizedStringKey {
        switch route {
        case .raspberryPiLAN: "Raspberry Pi on local network"
        case .tailscale: "Tailscale"
        case .synologyTask: "Synology scheduled task"
        case .iosShortcut: "iPhone Shortcut"
        case .cli: "Command line"
        }
    }
}

// AdvancedSettings exposes bounded operational details without crowding normal workflows.
private struct AdvancedSettings: View {
    @ObservedObject var model: AppModel

    // body contains service timing, file locations, and manual refresh controls.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Advanced", text: "Service timing and diagnostic file locations for support and troubleshooting.")
            SettingsGroup(title: "Background service") {
                Picker("Language", selection: $model.settings.general.language) {
                    Text("Use system language").tag(AppLanguage.system)
                    Text("Deutsch").tag(AppLanguage.german)
                    Text("English").tag(AppLanguage.english)
                }
                Stepper("Check every \(model.settings.general.checkIntervalSeconds) seconds", value: $model.settings.general.checkIntervalSeconds, in: 5...600, step: 5)
                Stepper("Wait \(model.settings.general.bootDelaySeconds) seconds after login", value: $model.settings.general.bootDelaySeconds, in: 0...300, step: 5)
                Stepper(localizedFormat("Stop automatic recovery after %lld attempts", model.settings.general.maximumAutomaticRecoveryAttempts), value: $model.settings.general.maximumAutomaticRecoveryAttempts, in: 1...20)
                Stepper("Mount timeout: \(model.settings.general.mountTimeoutSeconds) seconds", value: $model.settings.general.mountTimeoutSeconds, in: 5...120, step: 5)
                Stepper("SMB health timeout: \(model.settings.general.smbHealthTimeoutSeconds) seconds", value: $model.settings.general.smbHealthTimeoutSeconds, in: 1...30)
            }
            SettingsGroup(title: "Network policy details") {
                Stepper("LAN failure threshold: \(model.settings.network.lanFailureThreshold)", value: $model.settings.network.lanFailureThreshold, in: 1...20)
                Text("LAN-Stabilität: drei erfolgreiche periodische Prüfungen")
                LabeledContent("Reachability hosts") {
                    TextField("Comma-separated hosts", text: stringListBinding(\.network.remoteReachabilityHosts)).frame(width: 320)
                }
                LabeledContent("Traffic interfaces") {
                    TextField("Comma-separated interfaces", text: stringListBinding(\.network.trafficInterfaces)).frame(width: 320)
                }
                LabeledContent("Traffic store limit") {
                    TextField("Bytes", value: $model.settings.network.trafficMaxBytes, format: .number).frame(width: 160)
                }
            }
            SettingsGroup(title: "Diagnostic limits") {
                Stepper("macOS log lookback: \(model.settings.diagnostics.macLogLookbackMinutes) minutes", value: $model.settings.diagnostics.macLogLookbackMinutes, in: 1...240)
                Stepper("Run cleanup every \(model.settings.diagnostics.retentionIntervalMinutes) minutes", value: $model.settings.diagnostics.retentionIntervalMinutes, in: 5...1_440, step: 5)
                LabeledContent("Diagnostic store limit") {
                    TextField("Bytes", value: $model.settings.diagnostics.maximumStoreBytes, format: .number).frame(width: 160)
                }
                Label("Support exports always hide private infrastructure and user paths", systemImage: "lock.shield.fill")
                    .foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Raspberry Pi limits") {
                LabeledContent("Remote capture directory") { TextField("Directory", text: $model.settings.packetCapture.remoteDirectory).frame(width: 320) }
                Stepper("Keep at most \(model.settings.packetCapture.maximumFiles) captures", value: $model.settings.packetCapture.maximumFiles, in: 1...200)
                LabeledContent("Capture store limit") {
                    TextField("Bytes", value: $model.settings.packetCapture.maximumFileBytes, format: .number).frame(width: 160)
                }
            }
            SettingsGroup(title: "Synology details") {
                Stepper("Syslog port: \(model.settings.synology.syslogPort)", value: $model.settings.synology.syslogPort, in: 1...65535)
                Toggle("Enable DSM API source", isOn: model.immediateToggle(\.synology.dsmAPIEnabled, key: "synology.dsmAPIEnabled"))
                LabeledContent("DSM address") { TextField("DSM address", text: $model.settings.synology.dsmBaseURL).frame(width: 320) }
                if model.settings.synology.dsmAPIEnabled {
                    TextField("DSM account", text: $model.synologyAccountDraft)
                    SecureField("DSM password", text: $model.synologyPasswordDraft)
                    HStack {
                        Button("Save DSM credentials in Keychain") { model.saveSynologyCredentials() }
                            .disabled(model.synologyAccountDraft.isEmpty || model.synologyPasswordDraft.isEmpty)
                        if model.synologyCredentialsConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove DSM credentials", role: .destructive) { model.deleteSynologyCredentials() }
                        }
                    }
                }
            }
            SettingsGroup(title: "AI model") {
                LabeledContent("OpenAI model") { TextField("Model", text: $model.settings.ai.openAIModel).frame(width: 240) }
            }
            SettingsGroup(title: "Files") {
                LabeledContent("Configuration") { Button("Show in Finder") { model.reveal(model.configurationFile) } }
                LabeledContent("Logs") { Button("Show in Finder") { model.reveal(model.logsDirectory) } }
            }
            HStack {
                Button("Save advanced settings") { Task { await model.save() } }.buttonStyle(.borderedProminent)
                Button("Reload") { Task { await model.reloadAll() } }
            }
        }
    }

    // stringListBinding presents string arrays as editable comma-separated advanced values.
    private func stringListBinding(_ keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: keyPath].joined(separator: ", ") },
            set: { value in
                model.settings[keyPath: keyPath] = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

// OnboardingView introduces the core decisions without exposing diagnostic internals.
private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var page = 0

    // body implements a short, resumable three-step first-run flow.
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: onboardingSymbol).font(.system(size: 52)).foregroundStyle(.tint)
            Text(onboardingTitle).font(.title.weight(.semibold))
            Text(onboardingText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if page == 1 {
                Toggle("Prefer Ethernet and use Wi-Fi only as fallback", isOn: model.immediateToggle(\.network.enabled, key: "network.enabled"))
                    .frame(maxWidth: 440)
            }
            if page == 2 {
                Toggle("Collect local connection diagnostics", isOn: model.immediateToggle(\.diagnostics.enabled, key: "diagnostics.enabled"))
                    .frame(maxWidth: 440)
            }
            HStack {
                Button("Back") { page -= 1 }.disabled(page == 0)
                Spacer()
                Button(page == 2 ? "Finish" : "Continue") {
                    if page == 2 { model.completeOnboarding() } else { page += 1 }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(36)
        .frame(width: 560, height: 390)
    }

    // onboardingSymbol selects a relevant visual for the current setup decision.
    private var onboardingSymbol: String {
        ["externaldrive.connected.to.line.below", "network", "waveform.path.ecg"][page]
    }

    // onboardingTitle names the current setup step.
    private var onboardingTitle: LocalizedStringKey {
        ["Keep your drives connected", "Choose the best connection", "Understand interruptions"][page]
    }

    // onboardingText explains immediate user value in one short paragraph.
    private var onboardingText: LocalizedStringKey {
        [
            "We Rock Drive Mounts reconnects selected network drives after sleep, network changes, or temporary server outages.",
            "Ethernet can remain the preferred route. Wi-Fi may switch on when Ethernet fails and can stay on briefly for AirDrop.",
            "Local diagnostics record only the evidence needed to explain disconnects. Collection and retention remain under your control.",
        ][page]
    }
}
