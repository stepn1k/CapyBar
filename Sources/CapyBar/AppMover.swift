import AppKit
import CapyBarCore
import Security
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "install")

/// Moves CapyBar into /Applications and reopens it from there, so that a copy opened
/// from Downloads works without the user doing anything (see `InstallLocation`).
@MainActor
enum AppMover {

    enum Failure: Error {
        case otherApp
        case notWritable
        case failed(String)

        var message: String {
            switch self {
            case .otherApp:
                "Couldn’t move CapyBar to Applications: another app named CapyBar is already there."
            case .notWritable:
                "Couldn’t move CapyBar to Applications: macOS didn’t allow it. "
                    + "Drag CapyBar into Applications in Finder and open it from there."
            case .failed(let details):
                "Couldn’t move CapyBar to Applications: \(details)"
            }
        }
    }

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Only a real app bundle can move: `swift run` starts a bare binary whose
    /// "bundle" is the build folder.
    static func canMove(bundleID: String) -> Bool {
        !bundleID.isEmpty && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// A copy opened straight from Downloads, which `moveAndRelaunch` should handle at launch.
    static func isDownloadedCopy(bundleID: String) -> Bool {
        let running = Bundle.main.bundleURL
        return canMove(bundleID: bundleID)
            && InstallLocation.shouldMoveAutomatically(
                bundlePath: running.path, isQuarantined: isQuarantined(originalURL(of: running)))
    }

    /// Installs this copy as /Applications/CapyBar.app (replacing an older CapyBar there),
    /// moves the download to the Trash and starts the installed copy once this process
    /// has quit. An installed copy that is as new or newer is kept and started instead.
    /// Returns nil on success: the caller must quit right away.
    static func moveAndRelaunch(bundleID: String) -> Failure? {
        guard canMove(bundleID: bundleID) else { return .failed("this copy isn’t an app bundle.") }
        let running = Bundle.main.bundleURL
        let source = originalURL(of: running)
        let destination = URL(fileURLWithPath: InstallLocation.installedPath)
        let fm = FileManager.default

        if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            return .failed("\(destination.path) is a link.")
        }
        let installed = fm.fileExists(atPath: destination.path) ? Bundle(url: destination) : nil
        if fm.fileExists(atPath: destination.path), installed?.bundleIdentifier != bundleID {
            return .otherApp
        }
        if let installed,
            !InstallLocation.shouldReplace(
                installedBuild: installed.infoDictionary?["CFBundleVersion"] as? String,
                ownBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        {
            // An older or the same download opened again: never downgrade.
            logger.info("installed copy is as new or newer, switching to it")
            forget(source, running)
            return relaunch(destination) ? nil : .failed("couldn’t open the copy in Applications.")
        }

        // Copy and check everything before touching the installed copy, so a failure
        // leaves it running as it was.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".CapyBar-\(ProcessInfo.processInfo.processIdentifier).app")
        do {
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: source, to: staged)
        } catch {
            try? fm.removeItem(at: staged)
            return failure(error)
        }
        // The flag goes only from bytes Gatekeeper already let run: the copy must be
        // this very code, unmodified. That also keeps the Accessibility grant, which is
        // tied to the code's hash.
        guard isSameCode(as: staged) else {
            try? fm.removeItem(at: staged)
            logger.error("staged copy differs from the running code")
            return .failed("the downloaded copy changed while CapyBar was running.")
        }
        // Copied by Finder, the bundle would lose the flag; copied here it keeps it, and
        // Gatekeeper would translocate the installed copy again.
        removeQuarantine(staged)

        // An update opened while the old version runs: quit the old one, or `open`
        // would bring it forward instead of starting the new copy.
        let quitOld = quitOtherCopies(bundleID: bundleID)
        do {
            if installed != nil {
                _ = try fm.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged)
            if quitOld { NSWorkspace.shared.openApplication(at: destination, configuration: .init()) }
            return failure(error)
        }

        forget(source, running)
        LSRegisterURL(destination as CFURL, true)
        logger.info("installed at \(destination.path, privacy: .public), relaunching")
        guard relaunch(destination) else {
            return .failed("CapyBar is there now, but couldn’t reopen. Quit it and open it from Applications.")
        }
        return nil
    }

    /// Where the user's copy really is: for a translocated app, the folder it was
    /// opened from (Security's `SecTranslocateCreateOriginalPathForURL`).
    static func originalURL(of url: URL) -> URL {
        guard InstallLocation.isTranslocated(url.path) else { return url }
        typealias OriginalPath =
            @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) ->
            Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
            let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return url }
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        return originalPath(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }

    /// MenuBarAgent finds CapyBar through LaunchServices, which must resolve the bundle
    /// ID to the installed copy: drop the download and the translocated view of it, then
    /// trash the download.
    private static func forget(_ source: URL, _ running: URL) {
        runLSRegister(["-u", source.path])
        if running != source { runLSRegister(["-u", running.path]) }
        if !InstallLocation.isInApplications(source.path) {
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
    }

    private static func failure(_ error: Error) -> Failure {
        logger.error("move failed: \(error.localizedDescription, privacy: .public)")
        let code = (error as? CocoaError)?.code
        return code == .fileWriteNoPermission || code == .fileReadNoPermission
            ? .notWritable : .failed(error.localizedDescription)
    }

    /// The bundle at `url` is valid and carries the same code directory hash as the
    /// running process.
    private static func isSameCode(as url: URL) -> Bool {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var copy: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
            SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
            SecStaticCodeCreateWithPath(url as CFURL, [], &copy) == errSecSuccess, let copy,
            SecStaticCodeCheckValidity(copy, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return false }
        guard let own = uniqueHash(selfStatic), let other = uniqueHash(copy) else { return false }
        return own == other
    }

    private static func uniqueHash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoUnique as String] as? Data
    }

    /// Returns whether any other copy was running.
    private static func quitOtherCopies(bundleID: String) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        return true
    }

    private static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func removeQuarantine(_ bundle: URL) {
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func runLSRegister(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Opens the installed copy only after this process is gone, so two copies never
    /// hold restrictions at once.
    private static func relaunch(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$1""#,
            String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        return (try? process.run()) != nil
    }
}
