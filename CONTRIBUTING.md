# Contributing

## Build and test

You need macOS 27 and the Command Line Tools with Swift 6.

```bash
swift build                  # debug build
swift run CapyBarTests       # tests; exit code 0 means all passed
swift format lint --strict --recursive Sources Package.swift scripts/make-icon.swift
scripts/bundle.sh            # build CapyBar.app into ./build without installing
scripts/bundle.sh --install  # build and install into /Applications
scripts/bundle.sh --zip      # build and pack build/CapyBar.zip to share
```

Pull requests and pushes to `main` are linted, tested and built (`ci.yml`). A push to `main` that changes the app itself is released as the next patch version (`release.yml`, `scripts/next-version.sh`). For a minor or major release, raise the version in `Resources/Info.plist`; local builds keep that version.

The release's "What's new" list is the subjects of the commits that changed the app since the last release, so write them for people who use CapyBar: say what changed for them ("Open CapyBar with a keyboard shortcut", "Keep icons hidden after sleep"), not how ("Add HotkeyCenter"). One change per commit, so each gets its own line.

Tests are a plain executable, because the Command Line Tools ship without XCTest. The private API, Accessibility and mouse clicks are replaced with fakes, so tests never touch the real menu bar.

Changes to hiding should keep [Reliability](docs/RELIABILITY.md) true: run `scripts/check-reliability.sh agent` on a real Mac before releasing them.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and Accessibility has to be granted again. `bundle.sh --install` removes the stale entry for you.

## Layout

| Path | Contents |
|---|---|
| `Sources/CapyBar` | The app: status item, panel, settings |
| `Sources/CapyBarCore` | UI-free logic: allowlist, restriction, Accessibility |
| `Sources/MenuBarPrivate` | Thin Objective-C bridge to the private framework |
| `Sources/CapyBarTests` | Tests |
| `scripts/` | App bundling, icon generation (`make-icon.swift` compresses with `pngquant` if installed) and `check-reliability.sh` |

See [How it works](docs/HOW_IT_WORKS.md) for the approach, and [AGENTS.md](AGENTS.md) for which file to change, the rules every change keeps and the done checklist.

## Licensing

CapyBar is MIT. Do not copy code from GPL-licensed menu bar managers (such as Ice); MIT and Apache-2.0 sources are fine with attribution.
