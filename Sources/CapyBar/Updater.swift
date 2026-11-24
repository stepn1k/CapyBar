import AppKit
import CapyBarCore
import Observation

/// Opt-in update checks. CapyBar touches the network only when the user clicks Check for
/// Updates or turns on automatic checks. Automatic checks are event-driven like the rest
/// of the app: at launch and when the panel opens, at most once a day, no timer.
@MainActor
@Observable
final class Updater {

    static let shared = Updater()

    static let interval: TimeInterval = 24 * 60 * 60
    /// After a failed automatic check (offline, say), wait this long before trying again.
    static let retryAfterFailure: TimeInterval = 60 * 60

    /// The running app's version; nil when run outside an app bundle.
    let current = ReleaseInfo(infoDictionary: Bundle.main.infoDictionary)
    /// A newer version found by the last check.
    private(set) var available: ReleaseInfo?
    private(set) var isChecking = false

    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            prefs.checksForUpdates = checksAutomatically
            if checksAutomatically { checkIfDue() }
        }
    }

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var lastFailure: Date?

    init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
        checksAutomatically = prefs.checksForUpdates
    }

    /// Checks quietly when automatic checks are on and the last one is old enough. A
    /// newer version then shows next to the version label and in the right-click menu.
    func checkIfDue() {
        guard checksAutomatically, !isChecking else { return }
        let now = Date()
        if let last = prefs.lastUpdateCheck, last <= now, now.timeIntervalSince(last) < Self.interval { return }
        if let failed = lastFailure, now.timeIntervalSince(failed) < Self.retryAfterFailure { return }
        Task { await check() }
    }

    /// Checks now and tells the user the result.
    func checkNow() {
        Task { present(await check()) }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(UpdateCheck.downloadPageURL)
    }

    @discardableResult
    private func check() async -> Result<ReleaseInfo, Error> {
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await UpdateCheck.fetchLatest()
            prefs.lastUpdateCheck = Date()
            lastFailure = nil
            available = current.map { latest.isNewer(than: $0) } == true ? latest : nil
            return .success(latest)
        } catch {
            lastFailure = Date()
            return .failure(error)
        }
    }

    private func present(_ result: Result<ReleaseInfo, Error>) {
        // An accessory app's alert would open behind the frontmost app.
        NSApp.activate()
        let alert = NSAlert()
        let installed = current?.version ?? "?"
        switch result {
        case .success(let latest) where available == latest:
            alert.messageText = "CapyBar \(latest.version) is available"
            alert.informativeText = """
                You have \(installed). Download the new version and open it: it replaces \
                this one in Applications. macOS asks for Accessibility again after the update.
                """
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { openDownloadPage() }
        case .success:
            alert.messageText = "CapyBar is up to date"
            alert.informativeText = "Version \(installed) is the newest."
            alert.runModal()
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
