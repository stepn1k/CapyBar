import AppKit

/// Removes CapyBar together with what macOS keeps about it outside the bundle:
/// the privacy permissions (Accessibility), the login item and the app's own defaults domain.
@MainActor
enum Uninstaller {

    enum Failure: Error {
        case notABundle
        case permissionsNotReset(String)
        case notTrashed(String)

        var message: String {
            switch self {
            case .notABundle:
                "Nothing to uninstall: the CapyBar app was not found."
            case .permissionsNotReset(let details):
                "Couldn’t uninstall CapyBar: \(details)"
            case .notTrashed(let details):
                "Couldn’t move CapyBar to the Trash: \(details). Drag it there yourself."
            }
        }
    }

    /// Order matters: `tccutil` finds the app through LaunchServices, so permissions
    /// are reset while the bundle is still in place, and only then is it trashed.
    /// On success the caller must quit at once.
    /// The bundle goes to the Trash, not deleted outright, so it can be put back.
    static func uninstall(bundleID: String, bundleURL: URL) async -> Failure? {
        guard !bundleID.isEmpty, bundleURL.pathExtension == "app" else { return .notABundle }

        if let error = resetPermissions(bundleID: bundleID) {
            return .permissionsNotReset(error)
        }
        // Like the permissions, the login item is found through the bundle, so it goes
        // before the bundle does, and comes back if the bundle stays.
        let wasLoginItem = LoginItem.status != .notRegistered
        if wasLoginItem { LoginItem.set(false) }
        do {
            try await NSWorkspace.shared.recycle([bundleURL])
        } catch {
            if wasLoginItem { LoginItem.set(true) }
            return .notTrashed(error.localizedDescription)
        }
        // Last, so a failed step above leaves the settings intact and CapyBar keeps
        // working as before. The caller quits right after.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        return nil
    }

    /// `tccutil reset All <id>` drops every privacy grant of this bundle ID, including
    /// stale ones left by earlier ad-hoc builds. No admin password is needed for an
    /// app's own entries.
    private static func resetPermissions(bundleID: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleID]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "exit code \(process.terminationStatus)" : output
    }
}
