# How CapyBar works

## Hiding

macOS 27 has a private "assessment mode" (`MBAssessmentModeAssertion` in `MenuBarClientCore`): while it is active, the menu bar shows icons only for an allowlist of apps. CapyBar holds that assertion with every running app on the list except the ones you hid.

The assertion lives exactly as long as the CapyBar process, which is why quitting or crashing restores everything. If MenuBarAgent restarts, the Mac wakes, or the session comes back from another user, CapyBar sends it again, retrying while MenuBarAgent is not ready (see [Reliability](RELIABILITY.md)).

MenuBarAgent matches allowlisted apps by bundle ID through LaunchServices, so CapyBar's own icon stays visible only when the running copy is the one LaunchServices resolves. That is why CapyBar refuses to hide anything unless it runs from `/Applications`. A copy opened from Downloads, which Gatekeeper runs from a temporary read-only folder (App Translocation), moves itself into `/Applications` as CapyBar.app, replacing an older build there (never a newer one), and starts again from there.

## Opening a hidden item

To open a hidden item, CapyBar briefly adds its app back to the allowlist, waits for the icon to appear and presses it through Accessibility (`AXPress`), falling back to a real click if the app doesn't respond. When the menu closes, the icon is hidden again.

The panel shows app icons, not captures of the menu bar glyphs, so CapyBar never needs Screen Recording.

## Shortcut and search

The shortcut, once the user records one (there is no default, since a global shortcut takes its combination away from every app), is registered with Carbon's `RegisterEventHotKey`, which delivers only that one combination: no Input Monitoring or Accessibility permission, and no other keystroke is ever seen.

Opening the panel activates CapyBar so it gets typing; closing it hands the keyboard back to the previous app, unless you had already switched to another one. While the panel is open, an AppKit monitor reads CapyBar's own key-downs, `PanelKeyRoute` maps each to an action (arrows, Return, typing or ⌘F to search, ⌘V, Escape) and `PanelNavigator` holds the state. Both live in `CapyBarCore` and are tested without UI; the views only draw the state, since a popover doesn't reliably give SwiftUI focus.

Search matches the names in the panel, ignoring case and accents: prefix first, then word starts, then initials ("im" for iStat Menus), then anywhere.

## Private API safety

`MenuBarClientCore` is loaded at runtime, and the classes and method signatures CapyBar needs are checked once, before the first call. If anything is missing or has changed, the feature turns itself off instead of calling into it, and the icons stay visible.
