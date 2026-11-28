# Security

## What CapyBar can access

- **Accessibility.** Needed to read menu bar items (`AXExtrasMenuBar`) and press them (`AXPress`). CapyBar does not read window contents, keystrokes or text in other apps.
- **Clicks, while icons are hidden.** To open Notification Center from the clock (see [How it works](docs/HOW_IT_WORKS.md#clicking-the-clock)), CapyBar runs an event tap on left clicks, which Accessibility allows. It holds back only a click on the clock, for a few hundred milliseconds (never more than 1.5 s), and then lets it through; every other click passes at once, and while Notification Center is open its position only tells whether it closed it. It also reads the clock's position and whether Notification Center is open through Accessibility. Nothing is recorded or stored. The tap is removed as soon as Accessibility is revoked or CapyBar is uninstalled.
- **No Screen Recording.** The panel shows app icons, not captures of the menu bar.
- **No network by default.** No analytics or accounts. The only request CapyBar ever makes is the update check: when you choose Check for Updates or turn on automatic checks, it downloads `version.json` from the latest GitHub release over HTTPS, without cookies.
- **Network state, read locally.** To show VPN status, CapyBar reads which VPNs are set up and whether one is connected from macOS's System Configuration. Nothing from it is stored or sent.
- **Stored data.** Only the apps it has seen, which of them are hidden, their order and a few settings, in `UserDefaults` (`app.capybar.CapyBar`). *Open at login* is a standard login item.

Releases are built by GitHub Actions from the tagged commit, with a build provenance attestation. To check a download: `gh attestation verify CapyBar.zip -R stepn1k/CapyBar`. From 0.6 the app is signed with a Developer ID (team `JWZV3K7K8X`) and notarized by Apple: `spctl --assess --verbose=2 /Applications/CapyBar.app`. The signing keys are GitHub secrets that only the release job on `main` can read.

CapyBar calls a private macOS framework (`MenuBarClientCore`). It is loaded at runtime and checked once before the first call; if Apple changed it, CapyBar turns the feature off instead of calling it. See [How it works](docs/HOW_IT_WORKS.md).

## Reporting a vulnerability

Please do not open a public issue. Use **[Report a vulnerability](../../security/advisories/new)** on the Security tab of this repository. I will reply as soon as I can.
