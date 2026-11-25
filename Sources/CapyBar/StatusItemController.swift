import AppKit
import CapyBarCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    /// A click on our icon while the popover is open first closes it (transient
    /// behaviour, on mouse-down) and then reaches our action on mouse-up; clicks this
    /// soon after a close are ignored so the panel does not reopen at once.
    static let reopenGuard: TimeInterval = 0.3

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let controller: CubbyController
    private var lastClose = Date.distantPast
    private var outsideClicks: OutsideClickWatcher?
    private var icon: CapybaraIconAnimator?
    /// The app that was in front before the shortcut opened the panel; it gets the
    /// keyboard back when the panel closes.
    private var previousApp: NSRunningApplication?
    /// Watches key-downs while the panel is open (see `panelKey`).
    private var keyMonitor: Any?
    private let openEntry: (CubbyController.PanelEntry) -> Void

    init(controller: CubbyController) {
        self.controller = controller
        var close: (() -> Void)?
        openEntry = { entry in
            close?()
            // Mark the panel closed now: AppKit may report the close after `open` has
            // already posted why it failed, which must wait for the panel, not vanish.
            controller.panelClosed()
            controller.open(entry)
        }
        super.init()
        close = { [weak self] in self?.popover.performClose(nil) }

        statusItem.autosaveName = "CapyBar"
        if let button = statusItem.button {
            icon = CapybaraIconAnimator(button: button)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let panel = NSHostingController(
            rootView: PanelView(controller: controller, open: openEntry))
        // Without this NSPopover lays itself out for its default 320×320 content and keeps
        // the bottom edge when SwiftUI shrinks it, so the panel hangs far below the icon.
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        controller.onTrustGranted = { [weak self] in
            guard let self else { return }
            // An open panel now shows its notes instead of the request: they are seen.
            if popover.isShown { controller.panelOpened(fromKeyboard: false) }
            showPanel(withSettings: true)
        }
        HotkeyCenter.shared.onPress = { [weak self] in self?.hotkeyPressed() }
        controller.takeKeyboard = { [weak self] in self?.takeKeyboard() }
        controller.closePanel = { [weak self] in self?.popover.performClose(nil) }
        controller.showPanel = { [weak self] in self?.showReason() }
        controller.onHotkeyChange = { [weak self] in self?.updateToolTip() }
        updateToolTip()

        outsideClicks = OutsideClickWatcher(
            insideFrames: { [weak self] in
                guard let self else { return [] }
                // Our own windows too: an alert or sheet may reach past the panel.
                return [popover.contentViewController?.view.window?.frame, statusItem.button?.window?.frame]
                    .compactMap { $0 } + NSApp.windows.filter(\.isVisible).map(\.frame)
            },
            onOutsideClick: { [weak self] in self?.popover.performClose(nil) }
        )
    }

    func popoverWillShow(_ notification: Notification) {
        icon?.face(true)
        startKeyMonitor()
    }

    func popoverWillClose(_ notification: Notification) {
        icon?.face(false)
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClicks?.stop()
        stopKeyMonitor()
        lastClose = Date()
        controller.showsSettings = false
        controller.panelClosed()
        controller.isRecordingHotkey = false
        giveKeyboardBack()
    }

    /// Hands the keyboard back to the app that had it before the panel opened, unless
    /// the user has moved to another app meanwhile (clicking it or ⌘Tab is what closed
    /// the panel then): that app keeps it.
    private func giveKeyboardBack() {
        defer { previousApp = nil }
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    /// The shortcut toggles the panel. Opening it takes the keyboard, so the search
    /// field can be typed into at once; closing gives the keyboard back.
    private func hotkeyPressed() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPanel(fromKeyboard: true)
    }

    // MARK: - Keyboard

    /// The panel's keys go through an AppKit monitor rather than SwiftUI focus, which a
    /// popover does not reliably give: every key-down CapyBar receives while the panel
    /// is open is checked here first.
    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return panelKey(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the panel used the key.
    private func panelKey(_ event: NSEvent) -> Bool {
        // The shortcut recorder in settings has its own monitor; alerts get their keys.
        guard popover.isShown, !controller.isRecordingHotkey,
            event.window == nil || event.window === popover.contentViewController?.view.window
        else { return false }
        let route = PanelKeyRoute(
            keyCode: event.keyCode, characters: event.characters ?? "",
            modifiers: KeyCombo.Modifiers(event.modifierFlags))
        switch controller.handlePanelKey(route) {
        case .ignored:
            return false
        case .handled:
            return true
        case .open(let index):
            if controller.panelEntries.indices.contains(index), !controller.isBusy {
                openEntry(controller.panelEntries[index])
            }
            return true
        case .close:
            popover.performClose(nil)
            return true
        }
    }

    /// Hovering the capybara reminds of the shortcut.
    private func updateToolTip() {
        statusItem.button?.toolTip = controller.hotkey.map { "CapyBar (\($0.displayString))" } ?? "CapyBar"
    }

    /// CapyBar runs in the background, so its panel gets no keystrokes until it is
    /// activated. The app in front is remembered and activated again on close.
    private func takeKeyboard() {
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            NSApp.activate()
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens the panel, on the app list when asked to or when nothing is hidden yet. It
    /// takes the keyboard, so typing searches however it was opened; from the shortcut
    /// the first icon is also selected.
    func showPanel(withSettings: Bool = false, fromKeyboard: Bool = false) {
        controller.refreshItems()
        Updater.shared.checkIfDue()
        if withSettings || controller.wantsSettingsOnOpen { controller.showsSettings = true }
        guard !popover.isShown, let button = statusItem.button else { return }
        controller.panelOpened(fromKeyboard: fromKeyboard)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        outsideClicks?.start()
        takeKeyboard()
    }

    /// Brings the panel back to say why a click on an icon failed. It leaves the keyboard
    /// with whatever app the user is in by now, and a click anywhere else closes it. One
    /// turn of the run loop later, so the close that the click caused has fully ended;
    /// if the panel is open again by then, the reason is already on screen.
    private func showReason() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !popover.isShown, let button = statusItem.button else { return }
            // A click into the panel makes CapyBar active; its close then hands the
            // keyboard back to this app.
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            controller.panelOpened(fromKeyboard: false)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            outsideClicks?.start()
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        // On macOS 27 a status item click can arrive without a current event; treat it as
        // a left click.
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard Date().timeIntervalSince(lastClose) > Self.reopenGuard else { return }
        showPanel()
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        // The shortcut shows at the right of this item, grey, like every menu shortcut:
        // the quiet place where Mac users look for one.
        if !controller.isPaused, !controller.panelEntries.isEmpty || controller.hotkey != nil {
            let search = menu.addItem(
                withTitle: "Search Hidden Icons", action: #selector(searchChosen), keyEquivalent: "")
            search.target = self
            if let hotkey = controller.hotkey {
                search.keyEquivalent = hotkey.menuKeyEquivalent
                search.keyEquivalentModifierMask = hotkey.modifierFlags
            }
            menu.addItem(.separator())
        }
        if controller.isPaused {
            menu.addItem(withTitle: "Hide Icons Again", action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Show All Icons", action: #selector(pause), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(settingsChosen), keyEquivalent: ",").target = self
        let updater = Updater.shared
        if let update = updater.available {
            menu.addItem(
                withTitle: "Download CapyBar \(update.version)…", action: #selector(downloadUpdate), keyEquivalent: ""
            ).target = self
        } else {
            let item = menu.addItem(
                withTitle: updater.isChecking ? "Checking for Updates…" : "Check for Updates…",
                action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self
            item.isEnabled = !updater.isChecking
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall CapyBar…", action: #selector(uninstallChosen), keyEquivalent: "")
            .target = self
        menu.addItem(
            withTitle: "Quit CapyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Let the system place the menu under the status item. A manual popUp(at:) from
        // the button's bounds lands inside the menu bar (the button is shorter than the
        // bar), so AppKit clips the first item behind a scroll arrow.
        // performClick tracks the menu synchronously; detach it afterwards so a left
        // click opens the panel again.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func pause() { controller.isPaused = true }
    @objc private func resume() { controller.isPaused = false }
    @objc private func settingsChosen() { showPanel(withSettings: true) }
    /// Like the shortcut: the panel opens with the keyboard, ready for typing.
    @objc private func searchChosen() {
        // The menu is still closing; open once it is gone so the panel can take the keyboard.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            showPanel(fromKeyboard: true)
            _ = controller.handlePanelKey(.openSearch)
        }
    }
    @objc private func checkForUpdates() { Updater.shared.checkNow() }
    @objc private func downloadUpdate() { Updater.shared.openDownloadPage() }

    @objc private func uninstallChosen() {
        // An accessory app's alert would open behind the frontmost app.
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall CapyBar?"
        alert.informativeText = "All icons come back to the menu bar. CapyBar and its settings move to the Trash."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // On success CapyBar has already quit.
            guard let failure = await controller.uninstall() else { return }
            NSApp.activate()
            let error = NSAlert()
            error.alertStyle = .critical
            error.messageText = failure
            error.runModal()
        }
    }
}
