<p align="center">
  <img src="docs/icon.png" width="96" alt="CapyBar icon">
</p>

<h1 align="center">CapyBar</h1>

<p align="center">
  Hide menu bar icons on macOS 27.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-27%2B-lightgrey?logo=apple" alt="macOS 27+">
  <img src="https://img.shields.io/badge/status-prototype-orange" alt="Status: prototype">
</p>

<p align="center">
  <img src="docs/screenshot.png" width="341" alt="CapyBar panel with five hidden app icons under the menu bar">
</p>

<p align="center">
  <img src="docs/screenshot-apps.png" width="340" alt="Settings, Apps tab: a switch for each app with a menu bar icon">
  <img src="docs/screenshot-options.png" width="340" alt="Settings, Options tab: show apps that aren't running, hide new apps automatically, open at login">
</p>

## Why

Too many icons in the menu bar, and on a MacBook with a notch some end up behind it. CapyBar hides the ones you pick and keeps them one click away, under the capybara.

- **Private.** No network, no analytics, no accounts, no Screen Recording permission.
- **One permission.** Grant Accessibility once, switch on the apps to hide.
- **Nothing to lose.** Quit CapyBar and every hidden icon comes back at once, even after a crash.

## Install

You need **macOS 27**.

<!-- download:start -->
**[Download CapyBar 0.2.0](https://github.com/stepn1k/CapyBar/releases/latest/download/CapyBar.zip)** · built 2026-11-24
<!-- download:end -->

1. Open `CapyBar.zip` and drag **CapyBar.app** into **Applications**.
2. Open CapyBar. macOS says it can't check the developer, because CapyBar isn't notarized by Apple. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

### Build from source

You need the **Command Line Tools** (`xcode-select --install`).

```bash
git clone https://github.com/stepn1k/CapyBar.git
cd CapyBar
scripts/bundle.sh --install
open /Applications/CapyBar.app
```

On first launch CapyBar asks for **Accessibility** access. Grant it, then pick the apps to hide. Keep the app in `/Applications`: it can't hide icons from anywhere else. After each reinstall macOS asks for Accessibility again.

> [!WARNING]
> CapyBar uses a private part of macOS 27. A macOS update may stop it from hiding icons until CapyBar is updated; your icons stay visible in that case. CapyBar is not affiliated with Apple.

## Using it

Click the capybara to see your hidden icons, then click one to open that app's real menu. The gear opens settings: **Apps** lists the apps to hide (drag to reorder), **Options** has the rest. To get every icon back for a while, right-click the capybara and choose **Show All Icons**, or just quit CapyBar. The same menu has Uninstall and Quit.

## Good to know

- **Whole apps only.** If an app has several menu bar icons, all of them are hidden.
- **Some system icons hide too** while anything is hidden, for example Focus or Now Playing. This is how macOS 27 behaves.
- **Something went wrong?** Hold **Option** while launching CapyBar to start with every icon visible.

## Uninstall

Right-click the capybara → **Uninstall CapyBar…**. It removes its Accessibility permission, login item and settings, and moves itself to the Trash.

If you already deleted the app by hand, run `defaults delete app.capybar.CapyBar` and remove CapyBar from System Settings → Privacy & Security → Accessibility.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for building and testing, and [How it works](docs/HOW_IT_WORKS.md) for the details. Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
