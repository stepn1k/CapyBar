# How CapyBar works

## Hiding

macOS 27 has a private "assessment mode" (`MBAssessmentModeAssertion` in `MenuBarClientCore`): while it is active, the menu bar shows icons only for an allowlist of apps. CapyBar holds that assertion with every running app on the list except the ones you hid.

The assertion lives exactly as long as the CapyBar process, which is why quitting or crashing restores everything. If MenuBarAgent restarts, the Mac wakes, or the session comes back from another user, CapyBar sends it again, retrying while MenuBarAgent is not ready (see [Reliability](RELIABILITY.md)).

MenuBarAgent matches allowlisted apps by bundle ID through LaunchServices, so CapyBar's own icon stays visible only when the running copy is the one LaunchServices resolves. That is why CapyBar hides nothing unless it runs from `/Applications`; a copy opened anywhere else moves itself there and starts again.

## Opening a hidden item

To open a hidden item, CapyBar briefly adds its app back to the allowlist, waits for the icon to appear and presses it through Accessibility (`AXPress`), falling back to a real click if the app doesn't respond. When the menu closes, the icon is hidden again.

The panel shows app icons, not captures of the menu bar glyphs, so CapyBar never needs Screen Recording.

## Clicking the clock

While the assertion is held, macOS treats the Mac as being in an exam and ignores clicks on the clock, so Notification Center can't open from it. Its own entry points are reserved for Apple's processes, and no setting of the assertion allows notifications, so the only way through is to lift the assertion.

While hiding is on, CapyBar holds a press on the clock back with an event tap (Accessibility allows it; every other click passes untouched). It releases the assertion, waits until MenuBarAgent answers Accessibility again (it does only once the release took effect, and at least 80 ms after it), and then lets the press through, so exactly one click reaches the clock and macOS opens Notification Center itself. Letting the user's own click race the release instead either lost it or, with a replayed click on top, opened and closed the panel at once. A click anywhere else before the press went through drops it, so the panel never opens after you moved on. The clock counts over the whole height of the menu bar, and its frame is read again whenever its text changes (MenuBarAgent tells through Accessibility), so a wider date or time never leaves part of it unclickable. Hidden icons show while Notification Center is open, as they would without CapyBar. A click left of its panel hides them again at once, so the bar changes while the panel slides out. A click on the clock closes the panel, and a second one soon after reopens it without hiding in between. A click on another icon in the bar keeps the icons until its menu closes. Other ways of closing (Escape, a swipe) are noticed by reading the window list every 50 ms while the panel is open. After 10 minutes CapyBar hides again in any case. A press is never held longer than 1.5 s, and the tap goes away the moment Accessibility is revoked.

## Shortcut and search

The shortcut you record is registered with Carbon's `RegisterEventHotKey`, which delivers only that one combination: no Input Monitoring or Accessibility permission, and no other keystroke is ever seen. While the panel is open, CapyBar reads only its own key presses.

Search matches the names in the panel, ignoring case and accents: prefix first, then word starts, then initials ("im" for iStat Menus), then anywhere.

## Private API safety

`MenuBarClientCore` is loaded at runtime, and the classes and method signatures CapyBar needs are checked once, before the first call. If anything is missing or has changed, the feature turns itself off instead of calling into it, and the icons stay visible.
