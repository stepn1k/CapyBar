import AppKit
import CapyBarCore
import Observation
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "controller")

/// Event-driven only: it reacts to app launches and quits and to user actions; nothing
/// runs on a repeating timer. Accessibility scans happen when the panel or settings
/// open, plus two one-shot checks after a never-seen app launches.
@MainActor
@Observable
final class CubbyController {

    struct AppEntry: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        /// False for a hidden app that is not running: it is listed so the user still
        /// sees everything in the cubby and can take it out.
        var isRunning = true
        var id: String { bundleID }
    }

    struct PanelEntry: Identifiable {
        let bundleID: String
        /// Nil for a hidden app that is not running: it has no menu bar icon to open,
        /// so clicking it launches the app instead.
        let item: MenuBarItem?
        /// Set for a hidden app that runs but whose icons the scan did not find (see
        /// `Allowlist.needsUnscannedEntry`). Clicking it reveals the app first and looks
        /// for its icon then.
        var pid: pid_t? = nil
        let title: String
        let icon: NSImage?
        var isRunning: Bool { item != nil || pid != nil }
        var id: String {
            if let item { return item.id }
            return pid != nil ? "unscanned:\(bundleID)" : "notRunning:\(bundleID)"
        }
    }

    /// Delays of the one-shot checks for a status item after a never-seen app launches.
    static let newAppChecks: [Duration] = [.seconds(3), .seconds(10)]
    /// Candidates are dropped right after the last check.
    static let candidateLifetime: Duration = .seconds(11)
    static let launchDebounce: Duration = .milliseconds(500)
    /// How long a revealed app that was never laid out may take to publish its icons.
    static let revealTimeout: TimeInterval = 1.5

    // Derived lists are rebuilt only when their inputs change, never per SwiftUI render.
    private(set) var appEntries: [AppEntry] = []
    private(set) var panelEntries: [PanelEntry] = []
    private(set) var hidden: Set<String>
    private(set) var appOrder: [String]
    private(set) var isScanning = false
    private(set) var isBusy = false
    /// A move to /Applications started from the panel is under way.
    private(set) var isMoving = false
    /// The last thing that happened, until the panel has shown it (see `PanelNotes`).
    private(set) var notes = PanelNotes()
    /// Why hiding doesn't work right now. Unlike a note it stays while it holds, and
    /// goes once hiding works again or nothing needs hiding.
    private(set) var hidingProblem: String?
    private(set) var isTrusted = MenuBarScanner.isTrusted
    /// On while registered, also when macOS still waits for the user's approval.
    private(set) var opensAtLogin = false
    private(set) var loginItemNeedsApproval = false

    /// Nothing was remembered before this launch.
    let isFirstRun: Bool
    /// Called once Accessibility is granted while CapyBar runs.
    @ObservationIgnored var onTrustGranted: (() -> Void)?
    /// Makes the panel take keystrokes (set by the status item, which owns the panel).
    @ObservationIgnored var takeKeyboard: (() -> Void)?
    /// Closes the panel (set by the status item).
    @ObservationIgnored var closePanel: (() -> Void)?
    /// Called when the shortcut changes, so the status item's tooltip can show it.
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    var hideNewApps: Bool {
        didSet { prefs.hideNewApps = hideNewApps }
    }

    /// Hidden apps that are not running also appear in the cubby, greyed out.
    var showsNotRunningApps: Bool {
        didSet {
            guard showsNotRunningApps != oldValue else { return }
            prefs.showsNotRunningApps = showsNotRunningApps
            rebuildEntries()
        }
    }

    /// Reset when the panel closes.
    var showsSettings = false

    /// The panel's keyboard state: search query, matches, selection, search field.
    private(set) var navigator = PanelNavigator(columns: CubbyController.panelColumns)

    /// The gear beside the icons and the gap before it.
    static let gearWidth: CGFloat = 20
    static let gearSpacing: CGFloat = 8
    /// Icons a row: 24 pt icons with 4 pt padding and 4 pt gaps, in the panel's 276 pt
    /// less the gear.
    static let panelColumns = GridLayout.columns(
        width: 276 - Double(gearWidth + gearSpacing), cell: 32, spacing: 4)

    /// What the panel shows: the icons that match the search, best first.
    var visibleEntries: [PanelEntry] {
        navigator.results.compactMap { panelEntries.indices.contains($0) ? panelEntries[$0] : nil }
    }

    /// Keys only mean something while there are icons to move through; Escape always
    /// closes.
    private var acceptsPanelKeys: Bool { isTrusted && !isPaused && !panelEntries.isEmpty }

    /// A key-down while the panel is open, already translated (`PanelKeyRoute`). Returns
    /// what the panel must do; `.ignored` lets the event go on to the system.
    func handlePanelKey(_ route: PanelKeyRoute) -> PanelNavigator.Effect {
        guard acceptsPanelKeys else { return route == .key(.escape) ? .close : .ignored }
        let effect: PanelNavigator.Effect
        switch route {
        case .passThrough:
            return .ignored
        case .openSearch:
            navigator.openSearch()
            effect = .handled
        case .paste:
            guard let text = NSPasteboard.general.string(forType: .string) else { return .handled }
            navigator.paste(text)
            effect = .handled
        case .key(let key):
            effect = navigator.handle(key)
        }
        return effect
    }

    /// The field's close button.
    func closeSearch() { navigator.closeSearch() }

    /// The panel opened: from the shortcut, the first icon is selected so Return works
    /// at once.
    func panelOpened(fromKeyboard: Bool) {
        if fromKeyboard { navigator.beginKeyboardUse() }
        // Before Accessibility is granted the panel shows the request instead of notes.
        notes.panelOpened(showsNotes: isReady)
    }

    /// The panel can show the icons and the notes under them.
    var isReady: Bool { isRestrictionAvailable && isTrusted }

    /// The panel closed: what it showed has been seen. Safe to call more than once.
    func panelClosed() {
        navigator.reset()
        notes.panelClosed()
        refusedHotkey = nil
    }

    /// Temporarily shows every icon. Not remembered across launches.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                keeper.cancel()
                notes.everythingShown()
            }
            apply()
        }
    }

    /// The global shortcut that opens the panel, nil when none is set.
    private(set) var hotkey: KeyCombo?
    /// A new shortcut macOS just refused. It was an attempt, so it is said until the
    /// panel closes.
    private var refusedHotkey: KeyCombo?
    /// The saved shortcut isn't registered: macOS or another app holds it. Said for as
    /// long as that holds.
    private var isSavedHotkeyTaken = false
    /// Why the shortcut doesn't work; shown under the shortcut setting.
    var hotkeyProblem: String? {
        (refusedHotkey ?? (isSavedHotkeyTaken ? hotkey : nil)).map(Self.shortcutTaken)
    }

    /// Registers the saved shortcut again and remembers whether macOS took it.
    private func registerSavedHotkey() {
        isSavedHotkeyTaken = !HotkeyCenter.shared.register(hotkey)
    }
    /// While the settings record a new shortcut the current one is off, so pressing it
    /// again records it instead of closing the panel.
    var isRecordingHotkey = false {
        didSet {
            guard isRecordingHotkey != oldValue else { return }
            if isRecordingHotkey {
                refusedHotkey = nil
                isSavedHotkeyTaken = false
                HotkeyCenter.shared.unregister()
            } else {
                registerSavedHotkey()
            }
        }
    }

    let ownID: String
    /// Why this copy cannot hide, if it cannot (see `InstallLocation`).
    let installProblem: InstallLocation.Problem?
    /// Hiding is only safe when this process is the copy MenuBarAgent matches by bundle
    /// ID: otherwise our own icon would vanish with the others and leave no way back.
    var canHide: Bool { installProblem == nil }

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let restriction = Restriction()
    @ObservationIgnored private let presser = ItemPresser()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "app.capybar.scan", qos: .userInitiated)
    @ObservationIgnored private var items: [MenuBarItem] = []
    @ObservationIgnored private var revealed: Set<String> = []
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastRunning: Set<String> = []
    /// Never-seen apps waiting for their status-item check, with the time after which
    /// they are dropped.
    @ObservationIgnored private var autoHideCandidates: [String: ContinuousClock.Instant] = [:]
    /// In-memory copy of `prefs.known`; it is read on every apply.
    @ObservationIgnored private var known: Set<String> = []
    /// In-memory copy of `prefs.iconless`.
    @ObservationIgnored private var iconless: Set<String>
    /// Waits for a revealed app's icons; separate from `scanQueue` so a scan opened
    /// meanwhile does not queue behind it.
    @ObservationIgnored private let revealQueue = DispatchQueue(label: "app.capybar.reveal", qos: .userInitiated)
    @ObservationIgnored private var runningCheckScheduled = false
    @ObservationIgnored private var askedForAccessibility = false
    @ObservationIgnored private var trustObserver: NSObjectProtocol?
    @ObservationIgnored private var agentWatch = MenuBarAgentWatch(currentPID: nil)
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// Sends the restriction again after MenuBarAgent restarts, the Mac wakes, the
    /// session comes back or a send fails (see `RestrictionKeeper`).
    @ObservationIgnored private lazy var keeper = RestrictionKeeper(
        isWanted: { [weak self] in self?.wantsRestriction ?? false },
        resend: { [weak self] done in
            guard let self else { return done(false) }
            send(force: true) { failure in done(failure == nil) }
        })

    var isRestrictionAvailable: Bool { restriction.isAvailable }

    /// With nothing chosen yet the cubby is empty, so the panel opens on the app list.
    var wantsSettingsOnOpen: Bool {
        isRestrictionAvailable && isTrusted && !isPaused && hidden.isEmpty
    }

    init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
        isFirstRun = prefs.known.isEmpty
        hidden = prefs.hidden
        iconless = prefs.iconless
        appOrder = prefs.appOrder
        hideNewApps = prefs.hideNewApps
        showsNotRunningApps = prefs.showsNotRunningApps
        hotkey = prefs.hotkey
        ownID = Bundle.main.bundleIdentifier ?? ""
        installProblem = Self.findInstallProblem(bundleID: ownID)
    }

    private static func findInstallProblem(bundleID: String) -> InstallLocation.Problem? {
        let own = Bundle.main.bundleURL
        func resolved() -> String? {
            guard !bundleID.isEmpty else { return nil }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(canonicalPath)
        }
        var problem = InstallLocation.problem(bundlePath: canonicalPath(own), resolvedPath: resolved())
        // Right after a move, LaunchServices may still point at the download's
        // translocated view or at the trashed copy: register this copy and look again.
        if case .otherCopy(let path) = problem, path.map(InstallLocation.isLeftover) ?? true {
            LSRegisterURL(own as CFURL, true)
            problem = InstallLocation.problem(bundlePath: canonicalPath(own), resolvedPath: resolved())
        }
        return problem
    }

    /// Why hiding is off because of where CapyBar runs. Kept apart from `notes`, which
    /// go once seen, so it never goes away while it holds.
    var installMessage: String? {
        switch installProblem {
        case .outsideApplications:
            return "To hide icons, CapyBar must run from the Applications folder."
        case .otherCopy(let path?):
            let folder = FileManager.default.displayName(atPath: (path as NSString).deletingLastPathComponent)
            return "Another copy of CapyBar, in \(folder), stops this one from hiding icons. "
                + "Move it to the Trash and open CapyBar again."
        case .otherCopy(nil):
            return "macOS doesn’t know this copy of CapyBar yet. Quit it and open it again."
        case nil:
            return nil
        }
    }

    /// The panel offers the move a downloaded copy makes by itself at launch.
    var canMoveToApplications: Bool {
        installProblem == .outsideApplications && AppMover.canMove(bundleID: ownID) && !isMoving
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True when LaunchServices resolves `bundleID` to exactly the bundle at `url`, which
    /// is the copy MenuBarAgent matches by bundle ID.
    static func isResolvedCopy(bundleID: String, at url: URL?) -> Bool {
        guard !bundleID.isEmpty, let url,
            let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        return resolved.standardizedFileURL.resolvingSymlinksInPath()
            == url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Lifecycle

    func start() {
        // Safe mode: hold Option while launching to start with everything visible.
        if NSEvent.modifierFlags.contains(.option) { isPaused = true }
        // A copy outside /Applications is a build being tried out: don't make it a
        // login item.
        if canHide, !prefs.loginItemOffered {
            prefs.loginItemOffered = true
            setOpensAtLogin(true)
        } else {
            refreshLoginItem()
        }
        if !isTrusted { watchForTrust() }

        let running = runningBundleIDs
        // First launch: everything that runs now is "known" and stays visible.
        if prefs.known.isEmpty { prefs.known = running }
        known = prefs.known
        lastRunning = running
        agentWatch = MenuBarAgentWatch(currentPID: MenuBarAgentWatch.currentPID())

        // KVO on runningApplications, not didLaunchApplicationNotification: the
        // notification is not posted for LSUIElement apps, which most menu bar apps are.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) {
            @Sendable [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleRunningAppsCheck() }
        }
        watchSleepAndSessions()
        // A shortcut another app took meanwhile is kept, so it works again once freed.
        if hotkey != nil { registerSavedHotkey() }
        // Apps launched at login before CapyBar and never seen: check them like new ones.
        considerNewApps(running.subtracting(known))
        apply()
    }

    /// The restriction lives in MenuBarAgent and may not outlast sleep or a switch to
    /// another user, so it is sent again when either ends.
    private func watchSleepAndSessions() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, RestrictionKeeper.Trigger)] = [
            (NSWorkspace.didWakeNotification, .woke),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
        ]
        workspaceObservers = events.map { name, trigger in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keeper.trigger(trigger) }
            }
        }
    }

    /// The panel's button for a copy outside /Applications that did not move itself at
    /// launch. On success CapyBar quits and the moved copy starts.
    func moveToApplications() {
        guard canMoveToApplications else { return }
        isMoving = true
        if let failure = AppMover.moveAndRelaunch(bundleID: ownID) {
            isMoving = false
            notes.post(.general(failure.message))
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Shown when the automatic move at launch did not work.
    func reportMoveFailure(_ text: String) {
        notes.post(.general(text))
    }

    func stop() {
        runningObservation?.invalidate()
        runningObservation = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        keeper.cancel()
        HotkeyCenter.shared.unregister()
        restriction.clear()
    }

    // MARK: - Shortcut

    /// Saves and registers a new shortcut; nil removes it. A combination macOS refuses
    /// is not saved, and the previous one stays.
    func setHotkey(_ combo: KeyCombo?) {
        isRecordingHotkey = false
        guard combo != hotkey else { return }
        if let combo, !HotkeyCenter.shared.register(combo) {
            refusedHotkey = combo
            registerSavedHotkey()
            return
        }
        if combo == nil { HotkeyCenter.shared.unregister() }
        refusedHotkey = nil
        isSavedHotkeyTaken = false
        hotkey = combo
        prefs.hotkey = combo
        onHotkeyChange?()
    }

    /// Launches come in bursts (a login, System Settings starting its helpers), so
    /// changes are coalesced before acting on them. Exception: a hidden app that just
    /// launched is handled at once, so its icon does not flash before the restriction
    /// catches it.
    private func scheduleRunningAppsCheck() {
        if agentWatch.observe(MenuBarAgentWatch.currentPID()) {
            logger.info("MenuBarAgent restarted")
            keeper.trigger(.agentRestarted)
        }
        if !hidden.isEmpty, !runningBundleIDs.subtracting(lastRunning).isDisjoint(with: hidden) {
            runningAppsChanged()
            return
        }
        guard !runningCheckScheduled else { return }
        runningCheckScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.launchDebounce)
            guard let self else { return }
            runningCheckScheduled = false
            runningAppsChanged()
        }
    }

    private func runningAppsChanged() {
        let running = runningBundleIDs
        let launched = running.subtracting(lastRunning)
        let quit = lastRunning.subtracting(running)
        lastRunning = running
        if !quit.isEmpty { notes.appsQuit(quit) }
        if !launched.isEmpty {
            considerNewApps(launched)
            apply()
        } else if !quit.isEmpty {
            appTerminated()
        }
    }

    // MARK: - Permissions

    /// One window at a time: the first ask shows the system prompt (which itself offers
    /// to open System Settings and puts CapyBar into the list there); asking again, after
    /// the prompt was dismissed, opens System Settings directly.
    func askForAccessibility() {
        if askedForAccessibility {
            MenuBarScanner.openAccessibilitySettings()
        } else {
            askedForAccessibility = true
            MenuBarScanner.requestTrust()
        }
    }

    /// macOS posts this when the Accessibility list changes; event-driven, so no polling
    /// while the user is in System Settings.
    private func watchForTrust() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // AXIsProcessTrusted() flips a moment after the notification.
                try? await Task.sleep(for: .milliseconds(500))
                self?.trustMayHaveChanged()
            }
        }
    }

    private func trustMayHaveChanged() {
        guard !isTrusted, MenuBarScanner.isTrusted else { return }
        isTrusted = true
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
        onTrustGranted?()
    }

    // MARK: - Open at Login

    func setOpensAtLogin(_ isOn: Bool) {
        if let error = LoginItem.set(isOn) {
            notes.post(.general("Couldn’t change Open at Login: \(error)"))
        }
        refreshLoginItem()
    }

    /// The user can change it in System Settings too, so it is re-read when the panel opens.
    func refreshLoginItem() {
        let status = LoginItem.status
        let isOn = status == .enabled || status == .requiresApproval
        if opensAtLogin != isOn { opensAtLogin = isOn }
        if loginItemNeedsApproval != (status == .requiresApproval) {
            loginItemNeedsApproval = status == .requiresApproval
        }
    }

    /// Quitting releases the restriction, so every icon comes back. Returns why it
    /// failed; on success CapyBar quits.
    func uninstall() async -> String? {
        if let failure = await Uninstaller.uninstall(bundleID: ownID, bundleURL: Bundle.main.bundleURL) {
            refreshLoginItem()
            return failure.message
        }
        NSApp.terminate(nil)
        return nil
    }

    // MARK: - Hiding

    /// Running apps that can own a status item. Background-only (`.prohibited`) apps
    /// cannot, and they come and go constantly, so they are left out entirely.
    var runningBundleIDs: Set<String> {
        Set(Self.statusCapableApps().compactMap(\.bundleIdentifier))
    }

    static func statusCapableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
    }

    /// Recomputes the allowlist and hands it to MenuBarAgent (skipped when unchanged).
    /// The completion always runs, also when nothing needs hiding or the call fails.
    /// A refused restriction leaves every icon visible, so the keeper tries again.
    func apply(completion: (@MainActor () -> Void)? = nil) {
        send(force: false) { [weak self] failure in
            if case .rejected = failure { self?.keeper.trigger(.failed) }
            completion?()
        }
    }

    /// One attempt, without retries: `apply` and the keeper's resends both end here.
    /// The completion gets nil also when nothing needs hiding.
    private func send(force: Bool, completion: @escaping @MainActor (Restriction.Failure?) -> Void) {
        let running = runningBundleIDs
        guard wantsRestriction(running: running) else {
            restriction.clear()
            hidingProblem = nil  // nothing to hide, so nothing refused
            completion(nil)
            return
        }
        let allowed = Allowlist.compute(
            running: running, known: known, hidden: hidden, revealed: revealed, ownBundleID: ownID)
        restriction.apply(allowing: allowed, force: force) { [weak self] failure in
            self?.hidingProblem = failure.map(Self.describe)
            completion(failure)
        }
    }

    /// Something hidden is running and hiding is allowed right now.
    private var wantsRestriction: Bool { wantsRestriction(running: runningBundleIDs) }

    private func wantsRestriction(running: Set<String>) -> Bool {
        canHide && !isPaused
            && Allowlist.needsRestriction(running: running, hidden: hidden, revealed: revealed, ownBundleID: ownID)
    }

    func setHidden(_ isHidden: Bool, for bundleID: String) {
        guard bundleID != ownID, Preferences.isValidBundleID(bundleID) else { return }
        if isHidden {
            hidden.insert(bundleID)
        } else {
            hidden.remove(bundleID)
        }
        prefs.hidden = hidden
        // Hiding it again gives an app marked iconless another chance in the cubby.
        if iconless.remove(bundleID) != nil { prefs.iconless = iconless }
        notes.appToggled(bundleID)
        rebuildEntries()
        apply()
    }

    /// Records never-seen apps as known and, if the setting is on, schedules two one-shot
    /// checks: only an app that actually owns a status item goes into the cubby. A
    /// browser or editor without a menu bar icon is never hidden (and never makes us hold
    /// an assertion with its side effects).
    private func considerNewApps(_ bundleIDs: Set<String>) {
        let fresh = bundleIDs.subtracting(known)
        guard !fresh.isEmpty else { return }
        let candidates = fresh.filter {
            Allowlist.shouldAutoHide(bundleID: $0, known: known, hideNewApps: hideNewApps, ownBundleID: ownID)
        }
        known.formUnion(fresh)
        prefs.known = known
        guard isTrusted || MenuBarScanner.isTrusted, !candidates.isEmpty else { return }
        let expiry = ContinuousClock.now + Self.candidateLifetime
        for id in candidates { autoHideCandidates[id] = expiry }
        for delay in Self.newAppChecks {
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.checkAutoHideCandidates()
            }
        }
    }

    private func checkAutoHideCandidates() {
        let now = ContinuousClock.now
        autoHideCandidates = autoHideCandidates.filter { $0.value > now && !hidden.contains($0.key) }
        let candidates = Set(autoHideCandidates.keys)
        guard hideNewApps, !candidates.isEmpty else {
            autoHideCandidates.removeAll()
            return
        }
        let apps = Self.statusCapableApps().compactMap { app -> (pid: pid_t, bundleID: String)? in
            guard let id = app.bundleIdentifier, candidates.contains(id) else { return nil }
            return (app.processIdentifier, id)
        }
        scanQueue.async { [weak self] in
            let owners = Set((MenuBarScanner.sweep(apps) ?? []).map(\.bundleID))
            Task { @MainActor in self?.autoHide(owners) }
        }
    }

    private func autoHide(_ owners: Set<String>) {
        let toHide = owners.intersection(autoHideCandidates.keys).subtracting(hidden)
        for id in owners { autoHideCandidates[id] = nil }
        guard hideNewApps, !toHide.isEmpty else { return }
        hidden.formUnion(toHide)
        prefs.hidden = hidden
        notes.postNewlyHidden(Dictionary(uniqueKeysWithValues: toHide.map { ($0, Self.appName($0)) }))
        rebuildEntries()
        apply()
    }

    private func appTerminated() {
        // A quit app left in the allowlist is harmless, so only drop the assertion when
        // nothing hidden is running any more.
        let running = runningBundleIDs
        if !Allowlist.needsRestriction(running: running, hidden: hidden, revealed: revealed, ownBundleID: ownID) {
            restriction.clear()
            hidingProblem = nil
        }
    }

    /// Reorders the settings list; the cubby follows the same order.
    func moveApps(from source: IndexSet, to destination: Int) {
        var listed = appEntries.map(\.bundleID)
        listed.move(fromOffsets: source, toOffset: destination)
        let listedSet = Set(listed)
        appOrder = listed + appOrder.filter { !listedSet.contains($0) }
        prefs.appOrder = appOrder
        rebuildEntries()
    }

    // MARK: - Scanning

    /// Reads every app's status items through Accessibility, off the main thread.
    func refreshItems() {
        refreshLoginItem()
        let trusted = MenuBarScanner.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        if !isTrusted { watchForTrust() }
        guard isTrusted, !isScanning else { return }
        isScanning = true
        let own = ownID
        let apps = Self.statusCapableApps().compactMap { app -> (pid: pid_t, bundleID: String)? in
            guard let id = app.bundleIdentifier, id != own, !Allowlist.isAppleProcess(id) else { return nil }
            return (app.processIdentifier, id)
        }
        scanQueue.async { [weak self] in
            let found = MenuBarScanner.sweep(apps) ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                items = found
                isScanning = false
                let owners = Set(found.map(\.bundleID))
                if !iconless.isDisjoint(with: owners) {
                    iconless.subtract(owners)
                    prefs.iconless = iconless
                }
                rebuildEntries()
            }
        }
    }

    private func rebuildEntries() {
        var info: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { info[app.processIdentifier] = app }

        let ranks = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let rank = { (bundleID: String) in ranks[bundleID] ?? ranks.count }

        // Apps with status items, plus hidden running apps whose items we cannot see
        // right now, plus hidden apps that are not running: anything in the cubby can
        // always be seen and taken out again.
        var entries: [String: AppEntry] = [:]
        let owners = items.map { ($0.bundleID, $0.pid) }
        let hiddenRunning = info.values.compactMap { app in
            app.bundleIdentifier.flatMap { hidden.contains($0) ? ($0, app.processIdentifier) : nil }
        }
        for (bundleID, pid) in owners + hiddenRunning where entries[bundleID] == nil && bundleID != ownID {
            let app = info[pid]
            entries[bundleID] = AppEntry(
                bundleID: bundleID,
                name: app?.localizedName ?? bundleID,
                icon: app?.icon
            )
        }
        for bundleID in hidden where entries[bundleID] == nil && bundleID != ownID {
            entries[bundleID] = Self.notRunningEntry(bundleID)
        }
        appEntries = entries.values.sorted { lhs, rhs in
            let left = rank(lhs.bundleID)
            let right = rank(rhs.bundleID)
            if left != right { return left < right }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // The offset keeps the sort stable, so several icons of one app stay in their
        // menu bar order; apps that are not running follow their settings order.
        var ranked: [(key: (Int, Int), entry: PanelEntry)] = items.enumerated()
            .filter { hidden.contains($0.element.bundleID) }
            .map { offset, item in
                let app = info[item.pid]
                let name = app?.localizedName ?? item.bundleID
                let title = item.label.map { $0 == name ? name : "\(name) — \($0)" } ?? name
                let entry = PanelEntry(bundleID: item.bundleID, item: item, title: title, icon: app?.icon)
                return ((rank(item.bundleID), offset), entry)
            }
        var listed = Set(items.map(\.bundleID))
        let scanned = listed
        let unscanned = Self.statusCapableApps()
            .filter { app in
                app.bundleIdentifier.map {
                    Allowlist.needsUnscannedEntry(
                        bundleID: $0, scanned: scanned, hidden: hidden, iconless: iconless, ownBundleID: ownID)
                } ?? false
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        for (offset, app) in unscanned.enumerated() {
            guard let bundleID = app.bundleIdentifier, listed.insert(bundleID).inserted else { continue }
            let entry = PanelEntry(
                bundleID: bundleID, item: nil, pid: app.processIdentifier,
                title: app.localizedName ?? bundleID, icon: app.icon)
            ranked.append(((rank(bundleID), items.count + offset), entry))
        }
        if showsNotRunningApps {
            for (offset, app) in appEntries.enumerated() where !app.isRunning {
                let entry = PanelEntry(
                    bundleID: app.bundleID, item: nil, title: "\(app.name) — not running", icon: app.icon)
                ranked.append(((rank(app.bundleID), items.count + offset), entry))
            }
        }
        panelEntries = ranked.sorted { $0.key < $1.key }.map(\.entry)
        navigator.update(titles: panelEntries.map(\.title))
    }

    /// Starts a hidden app that is not running; its icon then waits in the cubby.
    func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            notes.post(.app(bundleID: bundleID, text: "Couldn’t find \(bundleID)."))
            return
        }
        notes.clearReport()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            guard let error else { return }
            let text = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.notes.post(.app(bundleID: bundleID, text: "Couldn’t open the app: \(text)"))
            }
        }
    }

    // MARK: - Opening a hidden item

    /// What a click on a panel entry does.
    func open(_ entry: PanelEntry) {
        if let item = entry.item {
            open(item)
        } else if let pid = entry.pid {
            openUnscanned(bundleID: entry.bundleID, pid: pid)
        } else {
            launch(entry.bundleID)
        }
    }

    /// A hidden app whose icon was never laid out: reveal it, wait until its status
    /// items show up in Accessibility, then open the first one like any other item.
    private func openUnscanned(bundleID: String, pid: pid_t) {
        guard !isBusy else { return }
        guard isTrusted else {
            notes.post(.general("CapyBar needs Accessibility permission."))
            return
        }
        // The entry may be older than the last quit; never read another process's items
        // under this app's name.
        guard Self.isRunning(bundleID, pid: pid) else {
            rebuildEntries()
            return
        }
        isBusy = true
        notes.clearReport()
        revealed.insert(bundleID)
        let timeout = Self.revealTimeout
        apply { [weak self] in
            self?.revealQueue.async { [weak self] in
                let found = MenuBarScanner.waitForItems(pid: pid, bundleID: bundleID, timeout: timeout)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let first = found.first, Self.isRunning(bundleID, pid: pid) else {
                        revealed.remove(bundleID)
                        apply()
                        isBusy = false
                        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID {
                            // A Dock app (a browser, an editor) often has no status item at
                            // all, so it leaves the cubby. A menu-bar-only app exists for its
                            // icon, so it stays: this was more likely a slow app.
                            let isDockApp = app.activationPolicy == .regular
                            if isDockApp {
                                iconless.insert(bundleID)
                                prefs.iconless = iconless
                            }
                            let name = Self.appName(bundleID)
                            let text =
                                isDockApp
                                ? "\(name) has no menu bar icon."
                                : "Couldn’t find the menu bar icon of \(name)."
                            notes.post(.app(bundleID: bundleID, text: text))
                        }
                        rebuildEntries()
                        return
                    }
                    // Now that the icons exist, the cubby lists them one by one.
                    items.removeAll { $0.pid == pid }
                    items.append(contentsOf: found)
                    rebuildEntries()
                    presser.press(first, preferred: prefs.preferredMethod(for: bundleID)) { [weak self] outcome in
                        self?.finishOpen(first, outcome)
                    }
                }
            }
        }
    }

    /// Reveals the item's app for a moment, opens its menu, hides it again once closed.
    func open(_ item: MenuBarItem) {
        guard !isBusy else { return }
        guard isTrusted else {
            notes.post(.general("CapyBar needs Accessibility permission."))
            return
        }
        isBusy = true
        notes.clearReport()
        revealed.insert(item.bundleID)
        apply { [weak self] in
            guard let self else { return }
            presser.press(item, preferred: prefs.preferredMethod(for: item.bundleID)) { [weak self] outcome in
                self?.finishOpen(item, outcome)
            }
        }
    }

    private func finishOpen(_ item: MenuBarItem, _ outcome: PressOutcome) {
        revealed.remove(item.bundleID)
        apply()
        isBusy = false
        switch outcome {
        case .finished(let method):
            prefs.setPreferredMethod(method, for: item.bundleID)
        case .notDrawn:
            let app = NSRunningApplication(processIdentifier: item.pid)
            let name = Self.appName(item.bundleID)
            let reason =
                if let app, !Self.isResolvedCopy(bundleID: item.bundleID, at: app.bundleURL) {
                    "the app isn’t running from the Applications folder"
                } else {
                    "not enough room in the menu bar"
                }
            notes.post(.app(bundleID: item.bundleID, text: "Couldn’t open the menu of \(name): \(reason)."))
        case .noResponse:
            notes.post(.app(bundleID: item.bundleID, text: "\(Self.appName(item.bundleID)) isn’t responding."))
        }
    }

    /// Name and icon from the app's bundle on disk; a deleted app shows its bundle ID.
    private static func notRunningEntry(_ bundleID: String) -> AppEntry {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppEntry(bundleID: bundleID, name: bundleID, icon: nil, isRunning: false)
        }
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        return AppEntry(
            bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isRunning: false)
    }

    private static func isRunning(_ bundleID: String, pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
    }

    private static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    private static func shortcutTaken(_ combo: KeyCombo) -> String {
        "\(combo.displayString) is taken by macOS or another app. Choose another shortcut."
    }

    private static func describe(_ failure: Restriction.Failure) -> String {
        switch failure {
        case .unavailable: "This version of macOS isn’t supported."
        case .rejected: "Couldn’t hide icons."
        }
    }
}
