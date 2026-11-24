import Foundation

/// The single place that decides which apps may draw their menu bar icons.
///
/// MenuBarAgent draws only the bundle identifiers we list, so "hide X" means
/// "list every running app except X".
public enum Allowlist {

    /// The list is deliberately monotonic: it contains every app ever seen (`known`), not
    /// just the running ones, so apps quitting and relaunching never change it. Every
    /// change makes MenuBarAgent re-lay out the whole menu bar with an animation, so the
    /// list may only change when the user hides or shows something, or a never-seen app
    /// appears.
    ///
    /// - Parameters:
    ///   - running: bundle IDs of running apps that can own status items. An app missing
    ///     from both `running` and `known` disappears from the menu bar.
    ///   - known: every app seen before.
    ///   - hidden: apps the user put into the cubby.
    ///   - revealed: hidden apps shown temporarily (while their menu is open).
    ///   - ownBundleID: CapyBar's own bundle ID — always allowed, or the user loses the way back.
    public static func compute(
        running: Set<String>,
        known: Set<String> = [],
        hidden: Set<String>,
        revealed: Set<String> = [],
        ownBundleID own: String
    ) -> Set<String> {
        running.union(known)
            .subtracting(hidden)
            .union(revealed)
            .union([own])
    }

    /// When nothing running is hidden we hold no assertion, which avoids its side effects
    /// (for example Notification Center not opening while a restriction is active).
    public static func needsRestriction(
        running: Set<String>,
        hidden: Set<String>,
        revealed: Set<String> = [],
        ownBundleID own: String
    ) -> Bool {
        !running.intersection(hidden).subtracting(revealed).subtracting([own]).isEmpty
    }

    /// Apps seen for the first time go into the cubby when `hideNewApps` is on —
    /// except Apple's own agents (input sources, Siri and the like), which stay visible.
    public static func shouldAutoHide(
        bundleID: String, known: Set<String>, hideNewApps: Bool, ownBundleID own: String
    ) -> Bool {
        guard hideNewApps, bundleID != own, !known.contains(bundleID) else { return false }
        return !isAppleProcess(bundleID)
    }

    /// A hidden app that runs but whose icons the scan did not find still gets a place in
    /// the cubby: after a restart, apps that open at login after CapyBar create their
    /// status items while already hidden, and those publish no Accessibility element
    /// until they are drawn once. Apps that turned out to have no icon at all
    /// (`iconless`) are left out.
    public static func needsUnscannedEntry(
        bundleID: String,
        scanned: Set<String>,
        hidden: Set<String>,
        iconless: Set<String>,
        ownBundleID own: String
    ) -> Bool {
        hidden.contains(bundleID) && !scanned.contains(bundleID) && !iconless.contains(bundleID)
            && bundleID != own && !isAppleProcess(bundleID)
    }

    /// Apple's own processes (MenuBarAgent, the input menu and the like). Their menu bar
    /// items are managed by macOS itself, so CapyBar neither lists nor hides them.
    public static func isAppleProcess(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.")
    }
}

/// System items are passed to MenuBarAgent as small integers
/// (battery 0, Bluetooth 1, clock 2, displays 3, keyboard 4, sound 5, Wi-Fi 6,
/// screen mirroring 7, Control Center 8 on macOS 27.2). CapyBar never hides them, so it
/// allows the whole range; values the system does not know are ignored by it.
enum SystemItems {
    static let allowAll: [NSNumber] = (0...255).map { NSNumber(value: $0) }
}
