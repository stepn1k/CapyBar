# Security

## What CapyBar can access

- **Accessibility.** Needed to read menu bar items (`AXExtrasMenuBar`) and press them (`AXPress`). CapyBar does not read window contents, keystrokes or text in other apps.
- **No Screen Recording.** The panel shows app icons, not captures of the menu bar.
- **No network by default.** No analytics or accounts. The only request CapyBar ever makes is the update check: when you choose Check for Updates or turn on automatic checks, it downloads `version.json` from the latest GitHub release over HTTPS, without cookies.
- **Stored data.** Only the apps it has seen, which of them are hidden, their order and a few settings, in `UserDefaults` (`app.capybar.CapyBar`). *Open at login* is a standard login item.

CapyBar calls a private macOS framework (`MenuBarClientCore`). It is loaded at runtime and checked once before the first call; if Apple changed it, CapyBar turns the feature off instead of calling it. See [How it works](docs/HOW_IT_WORKS.md).

## Reporting a vulnerability

Please do not open a public issue. Use **[Report a vulnerability](../../security/advisories/new)** on the Security tab of this repository. I will reply as soon as I can.
