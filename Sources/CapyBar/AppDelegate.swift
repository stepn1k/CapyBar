import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = CubbyController()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(controller: controller)
        controller.start()
        // Off unless the user turned on automatic checks. Not right at launch, so a
        // login-time start does not race the network coming up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Updater.shared.checkIfDue() }
        // Show where CapyBar lives and what to do first. A moment later, so the status
        // item has its place in the menu bar to anchor the panel to.
        if controller.isFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItem?.showPanel()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The assertion would die with the process anyway; releasing it explicitly
        // gives every icon back without waiting for MenuBarAgent to notice.
        controller.stop()
    }

    private func showSettings() {
        statusItem?.showPanel(withSettings: true)
    }
}
