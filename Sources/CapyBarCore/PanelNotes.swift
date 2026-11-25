import Foundation

/// The lines of news under the icons in the panel, and when they go away.
///
/// A note reports something that just happened. There are two, each with its own line,
/// so neither pushes the other out before it is seen:
///
/// - the news: apps "Hide new apps" put in the cubby. It is the one note that explains
///   an icon gone from the menu bar, so later reports never replace it.
/// - the latest report: a menu that didn't open, a setting that couldn't change.
///
/// Both follow two rules:
///
/// - A note is said once. It waits for the panel to show it, so it is not missed when
///   it happens while the panel is closed or can't show notes (before Accessibility is
///   granted), and goes when the panel closes after showing it. A note posted after the
///   panel started closing waits for the next opening.
/// - A note never outlives what it says. Showing or hiding an app again in settings
///   drops what was said about that app, quitting an app drops its errors, and "Show
///   All Icons" drops the news.
///
/// Problems that hold right now (hiding refused, CapyBar outside Applications) are not
/// notes: they are read from the current state and go once it changes.
public struct PanelNotes: Equatable, Sendable {

    public enum Report: Equatable, Sendable {
        /// Something that went wrong with one app.
        case app(bundleID: String, text: String)
        /// Something that is not about one app.
        case general(String)

        public var text: String {
            switch self {
            case .app(_, let text), .general(let text): text
            }
        }
    }

    /// Apps "Hide new apps" put in the cubby, by bundle ID, with their names.
    public private(set) var newlyHidden: [String: String] = [:]
    public private(set) var report: Report?
    private var isShown = false
    /// The panel showed the news, or the report, as it is now.
    private var isNewsSeen = false
    private var isReportSeen = false

    public init() {}

    /// What the panel shows, news first.
    public var lines: [String] {
        var lines: [String] = []
        if !newlyHidden.isEmpty {
            let names = newlyHidden.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            lines.append("Now hidden: \(names.joined(separator: ", ")).")
        }
        if let report { lines.append(report.text) }
        return lines
    }

    /// Apps hidden one after another add up until the panel shows them.
    public mutating func postNewlyHidden(_ names: [String: String]) {
        guard !names.isEmpty else { return }
        newlyHidden.merge(names) { _, new in new }
        isNewsSeen = isShown
    }

    /// Replaces the last report.
    public mutating func post(_ report: Report) {
        self.report = report
        isReportSeen = isShown
    }

    /// The user starts something new: the last report no longer applies. The news
    /// stays until seen.
    public mutating func clearReport() { report = nil }

    /// The panel opened. `showsNotes` is false while it shows something else instead,
    /// such as the request for Accessibility.
    public mutating func panelOpened(showsNotes: Bool = true) {
        isShown = showsNotes
        isNewsSeen = showsNotes && !newlyHidden.isEmpty
        isReportSeen = showsNotes && report != nil
    }

    /// Drops what the panel showed. Calling it again, for example when AppKit reports a
    /// close the app already handled, changes nothing.
    public mutating func panelClosed() {
        guard isShown else { return }
        isShown = false
        if isNewsSeen { newlyHidden = [:] }
        if isReportSeen { report = nil }
        isNewsSeen = false
        isReportSeen = false
    }

    /// The user hid or showed the app in settings: anything said about it is out of date.
    public mutating func appToggled(_ bundleID: String) {
        newlyHidden[bundleID] = nil
        if case .app(let id, _) = report, id == bundleID { report = nil }
    }

    /// The apps quit: their errors are over. They stay hidden, so the news stays.
    public mutating func appsQuit(_ bundleIDs: Set<String>) {
        if case .app(let id, _) = report, bundleIDs.contains(id) { report = nil }
    }

    /// Every icon is back in the menu bar: the news of apps just hidden is out of date.
    public mutating func everythingShown() { newlyHidden = [:] }
}
