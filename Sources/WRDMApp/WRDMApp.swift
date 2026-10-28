import AppKit
import Combine
import OSLog
import Sparkle
import SwiftUI
import WRDMCore

// WRDMApp owns an explicit AppKit lifecycle so menu-bar actions never depend on SwiftUI scene activation.
@main
enum WRDMApp {
    // main removes inherited secrets while preserving the GUI session variables required by AppKit.
    @MainActor
    static func main() {
        ProcessRunner.sanitizeCurrentProcessEnvironment()
        // Direct login launches must not create a second menu-bar instance or activate the existing one.
        if ProcessInfo.processInfo.arguments.contains("--background"),
           NSRunningApplication.runningApplications(withBundleIdentifier: LoginItemService.bundleIdentifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

// AppDelegate implements distinct left-click popover and right-click command-menu behavior.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private let logger = Logger(subsystem: "com.we-rock.drive-mounts", category: "menu-bar")
    // Fixed positive widths avoid AppKit's negative sentinel lengths in mirrored macOS status-bar scenes.
    private let idleStatusItemWidth: CGFloat = 28
    private let activeStatusItemWidth: CGFloat = 68
    let model = AppModel()
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var transferDialogWindow: NSWindow?
    private var transferWindow: NSWindow?
    private var networkWarningObservation: AnyCancellable?
    private var transferProgressObservation: AnyCancellable?
    private var displayedTransferSummary: TransferStatusSummary?

    // applicationDidFinishLaunching creates the menu-bar item after AppKit initialization.
    func applicationDidFinishLaunching(_ notification: Notification) {
        attach()
    }

    // applicationShouldHandleReopen gives Finder and LaunchServices a predictable Settings entry point.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettingsWindow() }
        return true
    }

    // attach binds the SwiftUI model once and creates the status control.
    private func attach() {
        guard statusItem == nil else { return }
        // Register the explicit URL Apple-event handler because Finder may target an already-running accessory app.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        model.setOpenSettingsHandler { [weak self] in
            self?.showSettingsWindow()
        }
        model.setOpenTransferDialogHandler { [weak self] in
            self?.showTransferDialog()
        }
        model.setOpenTransferWindowHandler { [weak self] in
            self?.showTransferWindow()
        }
        model.setInstallUpdateHandler { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        _ = updaterController
        model.start()
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 360, height: 220)
        popover.contentViewController = NSHostingController(rootView: TransferDropletView(model: model) { [weak self] in
            self?.popover.performClose(nil)
            self?.showTransferDialog()
        })

        let item = NSStatusBar.system.statusItem(withLength: idleStatusItemWidth)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "We Rock Drive Mounts")
        button.identifier = NSUserInterfaceItemIdentifier("wrdm.status-item")
        button.setAccessibilityIdentifier("wrdm.status-item")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        transferProgressObservation = model.$transferJobs.sink { [weak self] jobs in
            self?.updateStatusItem(jobs: jobs)
        }
        networkWarningObservation = model.$networkReport.sink { [weak self] report in
            let warning = report?.warnings.contains { $0.state == "deviation" } == true
            self?.statusItem?.button?.image = NSImage(systemSymbolName: warning ? "exclamationmark.triangle.fill" : "externaldrive.connected.to.line.below", accessibilityDescription: warning ? "Ethernet-Einstellungen weichen ab" : "We Rock Drive Mounts")
        }
        logger.notice("Menu-bar status item registered")
    }

    // statusItemClicked routes primary clicks to the popover and secondary clicks to the menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Accessibility activation may call the action without a current mouse event.
        if NSApp.currentEvent?.type == .rightMouseUp {
            logger.notice("Menu-bar status item received right click")
            // Close synchronously so this same mouse event can immediately track the command menu.
            popover.close()
            presentContextMenu()
        } else if popover.isShown {
            logger.notice("Menu-bar status item received left click; closing popover")
            popover.performClose(sender)
        } else {
            logger.notice("Menu-bar status item received left click; opening popover")
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // presentContextMenu builds direct commands from the current settings snapshot.
    private func presentContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        // Unavailable settings have no meaningful on/off state in the context menu.
        if model.configurationLoaded {
            let enabled = model.settings.general.enabled
            menu.addItem(commandItem(NSLocalizedString(enabled ? "Pause automatic recovery" : "Enable automatic recovery", comment: ""), action: #selector(toggleMonitoring)))
            menu.addItem(commandItem(NSLocalizedString("Reconnect drives", comment: ""), action: #selector(reconnectDrives)))
            menu.addItem(commandItem(NSLocalizedString("Allow Wi-Fi for AirDrop", comment: ""), action: #selector(allowWiFi)))
        }
        menu.addItem(.separator())
        menu.addItem(commandItem(NSLocalizedString("New transfer…", comment: ""), action: #selector(newTransfer)))
        menu.addItem(commandItem(NSLocalizedString("Transfers…", comment: ""), action: #selector(openTransfers)))
        menu.addItem(.separator())
        menu.addItem(commandItem(NSLocalizedString("Record current issue", comment: ""), action: #selector(captureDiagnostics)))
        menu.addItem(commandItem(NSLocalizedString("Export support file", comment: ""), action: #selector(exportSupportBundle)))
        menu.addItem(commandItem(NSLocalizedString("Check for updates", comment: ""), action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(commandItem(NSLocalizedString("Settings...", comment: ""), action: #selector(openSettings)))
        menu.addItem(commandItem(NSLocalizedString("Quit", comment: ""), action: #selector(quit)))
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: statusItem.button ?? NSView())
        } else if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    // commandItem creates a consistently targeted menu action.
    private func commandItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // toggleMonitoring persists the global agent switch.
    @objc private func toggleMonitoring() {
        model.mutate { $0.general.enabled.toggle() }
    }

    // reconnectDrives runs the canonical mount recovery command.
    @objc private func reconnectDrives() {
        Task { _ = await model.run("mounts.recover") }
    }

    // allowWiFi starts the configured grace window for AirDrop use.
    @objc private func allowWiFi() {
        Task { _ = await model.run("network.wifi.allow", arguments: [String(model.settings.network.wifiGraceMinutes)], confirmed: true) }
    }

    // newTransfer opens an empty focused dialog without routing the user through Settings.
    @objc private func newTransfer() {
        model.resetTransferDraft()
        showTransferDialog()
    }

    // openTransfers presents the retained operational transfer window.
    @objc private func openTransfers() {
        showTransferWindow()
    }

    // captureDiagnostics records macOS evidence around the current moment.
    @objc private func captureDiagnostics() {
        Task { _ = await model.run("diagnostics.capture") }
    }

    // exportSupportBundle creates the privacy-filtered support archive.
    @objc private func exportSupportBundle() {
        model.exportSupportBundle()
    }

    // checkForUpdates refreshes the visible update state without starting installation.
    @objc private func checkForUpdates() {
        model.checkForUpdates()
        showSettingsWindow()
    }

    // openSettings presents the app-owned settings window.
    @objc private func openSettings() {
        showSettingsWindow()
    }

    // showSettingsWindow creates and retains one AppKit window hosting the SwiftUI settings view.
    private func showSettingsWindow() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("We Rock Drive Mounts Settings", comment: "")
            window.identifier = NSUserInterfaceItemIdentifier("wrdm.settings-window")
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // showTransferDialog creates one focused AppKit window for a transfer draft.
    private func showTransferDialog() {
        if transferDialogWindow == nil {
            let controller = NSHostingController(rootView: TransferDialogView(model: model) { [weak self] in
                self?.transferDialogWindow?.orderOut(nil)
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 570),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("New We Rock Transfer", comment: "")
            window.identifier = NSUserInterfaceItemIdentifier("wrdm.transfer-dialog")
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.center()
            transferDialogWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        transferDialogWindow?.makeKeyAndOrderFront(nil)
    }

    // showTransferWindow creates one reusable job-control and history window.
    private func showTransferWindow() {
        if transferWindow == nil {
            let controller = NSHostingController(rootView: TransferControlView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("We Rock Transfers", comment: "")
            window.identifier = NSUserInterfaceItemIdentifier("wrdm.transfer-window")
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.center()
            transferWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        transferWindow?.deminiaturize(nil)
        transferWindow?.makeKeyAndOrderFront(nil)
    }

    // updateStatusItem adds compact aggregate progress next to the icon only while work is active.
    private func updateStatusItem(jobs: [TransferJob]) {
        guard let statusItem, let button = statusItem.button else { return }
        let summary = TransferStatusSummary.current(jobs: jobs)
        // Avoid redundant geometry mutations because macOS mirrors status items across every active display.
        guard summary != displayedTransferSummary else { return }
        displayedTransferSummary = summary
        if summary.activeJobCount > 0 {
            statusItem.length = activeStatusItemWidth
            button.imagePosition = .imageLeading
            button.title = " \(summary.percent ?? 0)%"
            button.toolTip = "\(summary.activeJobCount) active transfer(s)"
        } else {
            statusItem.length = idleStatusItemWidth
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = NSLocalizedString("We Rock Drive Mounts", comment: "")
        }
    }

    // updater postpones relaunch until background transfers have released their files.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard model.hasActiveTransfers else { return false }
        Task { [weak self] in
            while let self, self.model.hasActiveTransfers {
                await self.model.refreshRuntime()
                try? await Task.sleep(for: .seconds(5))
            }
            installHandler()
        }
        return true
    }

    // application routes Finder extension handoffs through the same validated transfer draft as drag and drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let handoff = urls.first(where: { $0.scheme == TransferHandoff.scheme }) else { return }
        handleTransferHandoff(handoff)
    }

    // handleGetURLEvent receives custom URL events when LaunchServices activates the running accessory app.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value), url.scheme == TransferHandoff.scheme else {
            logger.error("Finder transfer handoff did not contain a valid URL")
            return
        }
        handleTransferHandoff(url)
    }

    // handleTransferHandoff validates the selected sources before presenting the focused transfer dialog.
    private func handleTransferHandoff(_ handoff: URL) {
        popover.performClose(nil)
        guard model.prepareTransferHandoff(handoff) else {
            logger.error("Finder transfer handoff failed validation")
            showTransferDialog()
            return
        }
        logger.notice("Finder transfer handoff accepted")
        showTransferDialog()
    }

    // applicationWillTerminate releases the process-global Apple-event handler owned by this delegate.
    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // quit closes app-owned live streams before the independent launchd agent remains running.
    @objc private func quit() {
        Task {
            await model.stop()
            NSApp.terminate(nil)
        }
    }
}
