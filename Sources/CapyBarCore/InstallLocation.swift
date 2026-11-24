import Foundation

/// Where CapyBar runs from, and whether that copy can hide icons.
///
/// MenuBarAgent recognizes an allowlisted app by bundle ID only for the copy
/// LaunchServices resolves for that ID, and only inside /Applications: Hidden Bar's
/// measurements on 27.2 found ~/Applications ignored too (dwarvesf/hidden#535). Any
/// other copy would lose its own icon along with the ones it hides.
public enum InstallLocation {

    public static let applicationsFolder = "/Applications"
    /// Always the same name, so a download renamed "CapyBar 2.app" replaces the
    /// installed copy instead of landing next to it.
    public static let installedPath = applicationsFolder + "/CapyBar.app"

    public enum Problem: Equatable, Sendable {
        /// Runs from outside /Applications: Downloads, a build folder, or the read-only
        /// copy Gatekeeper makes of a downloaded app (App Translocation).
        case outsideApplications
        /// Runs from /Applications, but LaunchServices resolves the bundle ID to another
        /// copy (its path), or to none.
        case otherCopy(String?)
    }

    /// Paths are compared as given: the caller standardizes them and resolves symlinks.
    public static func problem(bundlePath: String, resolvedPath: String?) -> Problem? {
        guard isInApplications(bundlePath) else { return .outsideApplications }
        guard let resolvedPath, trimmed(resolvedPath) == trimmed(bundlePath) else {
            return .otherCopy(resolvedPath)
        }
        return nil
    }

    public static func isInApplications(_ path: String) -> Bool {
        path.hasPrefix(applicationsFolder + "/") && !isTranslocated(path)
    }

    /// Gatekeeper runs a quarantined app opened where it was downloaded from a random
    /// read-only folder.
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// A LaunchServices record left behind by a move: the translocated view of a
    /// download, or a copy in the Trash. Registering the running copy again fixes it.
    public static func isLeftover(_ path: String) -> Bool {
        isTranslocated(path) || path.contains("/.Trash/")
    }

    /// Only a downloaded copy moves itself: one Gatekeeper translocated, or one still
    /// flagged as downloaded. A build run from a source checkout stays where it is.
    public static func shouldMoveAutomatically(bundlePath: String, isQuarantined: Bool) -> Bool {
        !isInApplications(bundlePath) && (isTranslocated(bundlePath) || isQuarantined)
    }

    /// An installed copy is replaced only by a newer build (`CFBundleVersion`, a whole
    /// number in every release). Unreadable numbers fall back to replacing.
    public static func shouldReplace(installedBuild: String?, ownBuild: String?) -> Bool {
        guard let installed = installedBuild.flatMap({ Int($0) }), let own = ownBuild.flatMap({ Int($0) })
        else { return true }
        return own > installed
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
