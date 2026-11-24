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

    init(controller: CubbyController) {
        self.controller = controller
        super.init()

        statusItem.autosaveName = "CapyBar"
        if let button = statusItem.button {
            icon = CapybaraIconAnimator(button: button)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let panel = NSHostingController(
            rootView: PanelView(
                controller: controller,
                open: { [weak self] entry in
                    self?.popover.performClose(nil)
                    self?.controller.open(entry)
                }
            ))
        // Without this NSPopover lays itself out for its default 320×320 content and keeps
        // the bottom edge when SwiftUI shrinks it, so the panel hangs far below the icon.
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        controller.onTrustGranted = { [weak self] in self?.showPanel(withSettings: true) }

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
    }

    func popoverWillClose(_ notification: Notification) {
        icon?.face(false)
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClicks?.stop()
        lastClose = Date()
        controller.showsSettings = false
    }

    /// Opens the panel, on the app list when asked to or when nothing is hidden yet.
    func showPanel(withSettings: Bool = false) {
        controller.refreshItems()
        if withSettings || controller.wantsSettingsOnOpen { controller.showsSettings = true }
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        outsideClicks?.start()
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
        if controller.isPaused {
            menu.addItem(withTitle: "Hide Icons Again", action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Show All Icons", action: #selector(pause), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(settingsChosen), keyEquivalent: ",").target = self
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
