# How CapyBar works

## Hiding

macOS 27 has a private "assessment mode" (`MBAssessmentModeAssertion` in `MenuBarClientCore`): while it is active, the menu bar shows icons only for an allowlist of apps. CapyBar holds that assertion with every running app on the list except the ones you hid.

The assertion lives exactly as long as the CapyBar process, which is why quitting or crashing restores everything. If MenuBarAgent restarts, the Mac wakes, or the session comes back from another user, CapyBar sends it again, retrying while MenuBarAgent is not ready (see [Reliability](RELIABILITY.md)).

MenuBarAgent matches allowlisted apps by bundle ID through LaunchServices, so CapyBar's own icon stays visible only when the running copy is the one LaunchServices resolves. That is why CapyBar hides nothing unless it runs from `/Applications`; a copy opened anywhere else moves itself there and starts again.

## Opening a hidden item

To open a hidden item, CapyBar briefly adds its app back to the allowlist, waits for the icon to appear and presses it through Accessibility (`AXPress`), falling back to a real click if the app doesn't respond. When the menu closes, the icon is hidden again.

The panel shows app icons, not captures of the menu bar glyphs, so CapyBar never needs Screen Recording.

## Shortcut and search

The shortcut you record is registered with Carbon's `RegisterEventHotKey`, which delivers only that one combination: no Input Monitoring or Accessibility permission, and no other keystroke is ever seen. While the panel is open, CapyBar reads only its own key presses.

Search matches the names in the panel, ignoring case and accents: prefix first, then word starts, then initials ("im" for iStat Menus), then anywhere.

## Private API safety

`MenuBarClientCore` is loaded at runtime, and the classes and method signatures CapyBar needs are checked once, before the first call. If anything is missing or has changed, the feature turns itself off instead of calling into it, and the icons stay visible.
