# Contributing

You need macOS 27 and the Command Line Tools with Swift 6.

## Build

```bash
git clone https://github.com/stepn1k/CapyBar.git
cd CapyBar
scripts/bundle.sh --install
```

This builds CapyBar.app and installs it into /Applications. Builds are ad-hoc signed, so allow Accessibility again after each one.

## Changing the code

[AGENTS.md](AGENTS.md) has what you need to change the code: commands, which file to change, the rules every change keeps and the done checklist. It's written for people and AI agents alike. [How it works](docs/HOW_IT_WORKS.md) explains the approach.

## Releases

Pull requests and pushes to `main` are linted, tested and built (`ci.yml`). A push to `main` that changes the app itself is released as the next patch version (`release.yml`, `scripts/next-version.sh`). For a minor or major release, raise the version in `Resources/Info.plist`; local builds keep that version.

The release's "What's new" list is the subjects of the commits that changed the app since the last release, so write them for people who use CapyBar: say what changed for them ("Open CapyBar with a keyboard shortcut", "Keep icons hidden after sleep"), not how ("Add HotkeyCenter"). One change per commit, so each gets its own line.

Changes to hiding should keep [Reliability](docs/RELIABILITY.md) true: run `scripts/check-reliability.sh agent` on a real Mac before releasing them.
