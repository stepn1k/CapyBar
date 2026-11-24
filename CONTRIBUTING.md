# Contributing

## Build and test

You need macOS 27 and the Command Line Tools with Swift 6.

```bash
swift build                  # debug build
swift run CapyBarTests       # tests; exit code 0 means all passed
scripts/bundle.sh            # build CapyBar.app into ./build without installing
scripts/bundle.sh --install  # build and install into /Applications
scripts/bundle.sh --zip      # build and pack build/CapyBar.zip to share
```

Every push to `main` runs the tests on GitHub Actions (`.github/workflows/build.yml`) and publishes the build as `CapyBar.zip` on the rolling `latest` release, together with `version.json`, which the app's update check reads. The app offers an update only when `CFBundleShortVersionString` or `CFBundleVersion` in `Resources/Info.plist` goes up, so bump them (the build is a whole number) when a push should reach users. It then refreshes the version and date in README's download line (`scripts/readme-download.sh`) and pushes that as a bot commit, so pull before you push.

Tests are a plain executable, because the Command Line Tools ship without XCTest. The private API, Accessibility and mouse clicks are replaced with fakes, so tests never touch the real menu bar.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and Accessibility has to be granted again. `bundle.sh --install` removes the stale entry for you.

## Layout

| Path | Contents |
|---|---|
| `Sources/CapyBar` | The app: status item, panel, settings |
| `Sources/CapyBarCore` | UI-free logic: allowlist, restriction, Accessibility |
| `Sources/MenuBarPrivate` | Thin Objective-C bridge to the private framework |
| `Sources/CapyBarTests` | Tests |
| `scripts/` | App bundling and icon generation (`make-icon.swift` compresses with `pngquant` if installed) |

See [How it works](docs/HOW_IT_WORKS.md) for the approach.

## Licensing

CapyBar is MIT. Do not copy code from GPL-licensed menu bar managers (such as Ice); MIT and Apache-2.0 sources are fine with attribution.
