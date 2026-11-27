<p align="center">
  <img src="docs/icon.png" width="96" alt="CapyBar icon">
</p>

<h1 align="center">CapyBar</h1>

<p align="center">
  Hide menu bar icons on macOS 27. Free and open source.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-27%2B-lightgrey?logo=apple" alt="macOS 27+">
  <img src="https://img.shields.io/badge/status-beta-blue" alt="Status: beta">
  <a href="https://github.com/stepn1k/CapyBar/releases/latest"><img src="https://img.shields.io/github/v/release/stepn1k/CapyBar?label=release" alt="Latest release"></a>
</p>

<p align="center">
  <a href="https://github.com/stepn1k/CapyBar/releases/latest/download/CapyBar.zip"><b>Download</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#install">Install</a> ·
  <a href="#faq">FAQ</a>
</p>

<p align="center">
  <img src="docs/demo.gif" width="720" alt="Switching on apps in CapyBar's settings removes their icons from the menu bar. Clicking the capybara shows them in a panel.">
</p>

Too many menu bar icons, or some stuck behind the notch? CapyBar hides the ones you pick and keeps them one click away, under the capybara.

- **Private.** No analytics, no accounts. Goes online only to check for updates, if you allow it.
- **One permission.** Accessibility, nothing else.
- **Safe.** If CapyBar quits or crashes, every icon comes back.
- **Stays put.** Icons stay hidden after sleep, restarts and app updates.

## Features

### Find any icon from the keyboard

Set a shortcut in Options, then pick an icon with the arrow keys and open it with <kbd>Return</kbd>. Or just start typing to search.

<p align="center">
  <img src="docs/keyboard.gif" width="480" alt="The arrow keys move between hidden icons. Typing “cla” narrows the panel down to Claude.">
</p>

### See your VPN at a glance

When a VPN is on, the capybara wears a small shield. The VPN sits at the top of the panel, even if its own icon is hidden.

<p align="center">
  <img src="docs/vpn.png" width="480" alt="The capybara wears a shield. The panel shows the connected VPN above the hidden icons.">
</p>

## Install

1. [Download CapyBar](https://github.com/stepn1k/CapyBar/releases/latest/download/CapyBar.zip), unzip it and open CapyBar.app.
2. macOS blocks it the first time, because CapyBar isn't notarized yet. Click Done, then go to System Settings → Privacy & Security and click Open Anyway.
3. CapyBar moves itself to Applications and opens again.
4. Allow Accessibility when asked.
5. Click the capybara, then the gear, and switch on the apps you want to hide. Their icons move into the panel under the capybara.

## FAQ

### My menu bar icons are hidden behind the notch. How do I get to them?

Hide the icons you don't need every day, and the rest fit next to the notch again.

### Is CapyBar an alternative to Bartender, Ice or Hidden Bar?

Yes, for the main job: choosing which icons are shown. CapyBar is free, uses macOS 27's own menu bar allowlist, and hides whole apps rather than single icons.

### Does CapyBar need Screen Recording?

No. Accessibility is the only permission.

### Why do hidden icons show while Notification Center is open?

While any app is hidden, macOS ignores clicks on the clock. So CapyBar holds your click on the clock for a moment, stops hiding, lets the click through, and hides again when Notification Center closes. If you'd rather keep icons hidden, for example while sharing your screen, turn off Clock opens Notification Center in Options: the clock then does nothing while icons are hidden. Swiping left with two fingers from the right edge of the trackpad opens Notification Center either way, and keeps icons hidden.

### Why did Focus or Now Playing disappear from the menu bar?

While any app is hidden, macOS also hides some of its own icons, like Focus and Now Playing.

### macOS says CapyBar can't be opened. What do I do?

Click Done, then go to System Settings → Privacy & Security and click Open Anyway.

### Why does macOS ask for Accessibility again after an update?

CapyBar isn't signed with an Apple developer certificate yet, so macOS treats each update as a new app. Allow it again.

### Can a macOS update break CapyBar?

It can, because CapyBar uses a private part of macOS. If that changes, CapyBar stops hiding and every icon stays visible until CapyBar is updated.

### How do I uninstall it?

Right-click the capybara and choose Uninstall CapyBar. It removes its settings and permission, then moves itself to the Trash. If you deleted it by hand, also run `defaults delete app.capybar.CapyBar`.

## More

[How it works](docs/HOW_IT_WORKS.md) · [Build it yourself](CONTRIBUTING.md#build) · [Reliability](docs/RELIABILITY.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md) · [Questions](https://github.com/stepn1k/CapyBar/discussions) · [Report a bug](https://github.com/stepn1k/CapyBar/issues/new/choose)

CapyBar is [MIT](LICENSE) licensed.
