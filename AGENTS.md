# AGENTS.md

A short guide for anyone changing CapyBar's code, people and AI agents alike. Users want the [README](README.md) instead.

CapyBar is a macOS 27 menu bar app that hides other apps' menu bar icons. It holds a private MenuBarAgent "assessment mode" allowlist ([how it works](docs/HOW_IT_WORKS.md)). Hidden icons wait in a panel under the capybara icon. It's Swift 6 and SwiftPM, with no Xcode project and no dependencies.

## Commands

```bash
swift build                                                                  # build
swift run CapyBarTests                                                       # tests; exit 0 = all passed
swift format lint --strict --recursive Sources Package.swift scripts/make-icon.swift   # lint, CI fails on any finding
scripts/bundle.sh --install                                                  # build CapyBar.app into /Applications
scripts/bundle.sh                                                            # build into ./build only (--zip also packs build/CapyBar.zip)
```

## Where to change what

| To change… | Look in (`Sources/…`) |
|---|---|
| Which apps may show icons | `CapyBarCore/Allowlist.swift` |
| The call into MenuBarAgent (private API) | `MenuBarPrivate/`, `CapyBarCore/Restriction.swift` |
| Re-hiding after sleep, restarts, user switch | `CapyBarCore/RestrictionKeeper.swift`, `MenuBarAgentWatch.swift`; events wired in `CapyBar/CubbyController.swift` |
| Finding other apps' icons (Accessibility) | `CapyBarCore/MenuBarScanner.swift` |
| Opening a hidden icon's menu | `CapyBarCore/ItemPresser.swift` |
| Panel keys and search | `CapyBarCore/PanelNavigator.swift`, `PanelSearch.swift`; key monitor in `CapyBar/StatusItemController.swift` |
| VPN status (shield on the capybara, VPN row in the panel) | `CapyBarCore/NetworkWatch.swift`, `VPNStatus.swift`; wired in `CapyBar/CubbyController.swift` (VPN section), drawn in `StatusItemController.swift`, `CapybaraIcon.swift`, `PanelView.swift` |
| Clicking the clock while icons are hidden (opens Notification Center) | `CapyBarCore/ClockBridge.swift` (`ClockGate` decides which clicks the tap holds, `ClockEngine` runs a session), lift and resume in `Restriction.swift`; wired in `CapyBar/CubbyController.swift` (Clock section) |
| Global shortcut | `CapyBar/HotkeyCenter.swift`, `CapyBarCore/KeyCombo.swift` |
| Stored settings | `CapyBarCore/Preferences.swift` |
| App state, glue between all of the above | `CapyBar/CubbyController.swift` |
| Menu bar icon, right-click menu, opening and closing the panel | `CapyBar/StatusItemController.swift`, `CapybaraIcon.swift`, `CapyBarCore/OutsideClickWatcher.swift` |
| Panel and settings UI | `CapyBar/PanelView.swift`, `SettingsView.swift` (the "?" tips are here too) |
| Install location, moving into /Applications | `CapyBarCore/InstallLocation.swift`, `CapyBar/AppMover.swift` |
| Updates, login item, uninstall | `CapyBarCore/UpdateCheck.swift`, `CapyBar/Updater.swift`, `LoginItem.swift`, `Uninstaller.swift` |
| Tests | `CapyBarTests/<Area>Tests.swift`. Call new test functions from `CapyBarTests/main.swift` |
| Build, CI, releases | `scripts/bundle.sh`, `scripts/next-version.sh`, `.github/workflows/` ([details](CONTRIBUTING.md#releases)) |
| App icon | `scripts/make-icon.swift` (compresses with `pngquant` if installed) |

`CapyBarCore` contains no UI. Put logic there so it can be tested with fakes. `CapyBar` holds the AppKit/SwiftUI app.

## Rules that must stay true

- **Fail open.** If CapyBar quits, crashes or hits an error, every icon shows again. Never add a state that can leave icons hidden without CapyBar running.
- **Private API is checked first.** `MenuBarClientCore` is loaded at runtime and validated before the first call. If it is missing or changed, the feature turns off.
- **One permission.** Accessibility only. No Screen Recording, no Input Monitoring. The global shortcut uses Carbon `RegisterEventHotKey`, which sees only its own combination. The clock's event tap is an active one (it holds clicks), which Accessibility covers; a listen-only tap would need Input Monitoring.
- **No network** except the opt-in update check (`version.json` from the latest GitHub release). No analytics, no accounts.
- **Event-driven.** No repeating timers. React to app launches, wake, MenuBarAgent restarts and user actions. The one exception is short polling while something the user opened is on screen (an icon's menu, Notification Center from the clock), which stops by itself.
- **Runs only from `/Applications`.** MenuBarAgent resolves bundle IDs through LaunchServices.
- **Tests never touch the real menu bar.** The private API, Accessibility and clicks are faked.
- **No default global shortcut.** It would take a combination away from every app.
- **MIT.** Never copy code from GPL projects (for example Ice). MIT or Apache-2.0 code is fine with attribution.

## Done checklist

1. Lint, tests and build pass (commands above).
2. Update the docs that your change makes untrue:
   - behaviour users see: README "Features", "Install" and "FAQ", and the "?" tips in `SettingsView.swift`
   - how hiding works: `docs/HOW_IT_WORKS.md`
   - re-hiding after events: `docs/RELIABILITY.md`, plus `scripts/check-reliability.sh agent` on a real Mac
   - permissions, network or stored data: `SECURITY.md`
3. Commit subjects become the release notes. Write them for users ("Search hidden icons", not "Add PanelSearch"), one change per commit.
4. A push to `main` releases the next patch automatically. For a new feature, raise `CFBundleShortVersionString` in `Resources/Info.plist` to the next minor.

## Gotchas

- Tests are a plain executable using `check()` and `section()` from `TestKit.swift`, because the Command Line Tools ship without XCTest.
- Builds are ad-hoc signed, so every rebuild needs Accessibility granted again. `bundle.sh --install` removes the stale entry.
- Panel keys go through an AppKit key monitor, not SwiftUI focus, because a popover doesn't reliably give SwiftUI focus. `PanelKeyRoute` and `PanelNavigator` hold the logic; the views only draw the state.
- Logs: `log show --info --last 30m --predicate 'subsystem == "app.capybar.CapyBar" AND process == "CapyBar"'`. Settings live in `defaults read app.capybar.CapyBar`.
- Hold Option while launching to start with every icon visible.
