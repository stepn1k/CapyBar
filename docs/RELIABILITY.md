# Reliability

Hidden icons must stay hidden through the things a Mac does every day. CapyBar's restriction lives in MenuBarAgent, not in CapyBar, so anything that resets MenuBarAgent's state drops it. When that happens the icons come back (CapyBar always fails open), and CapyBar sends the restriction again.

## What CapyBar does

| Event | What drops the restriction | What CapyBar does |
|---|---|---|
| MenuBarAgent restarts (crash, `killall`, some system updates) | The restriction dies with the old process | Notices the new MenuBarAgent and resends after 1 s |
| The Mac wakes from sleep | MenuBarAgent may restart or forget it | Resends 2 s after wake |
| Switching back from another user, unlocking | Same | Resends 1 s after the session is active |
| Restart and login | CapyBar can start before MenuBarAgent accepts requests | A refused or unanswered request is retried |
| A hidden app updates and relaunches | Nothing: apps are hidden by bundle ID | Hidden again the moment it launches; the allowlist doesn't change, so the bar isn't re-laid out |
| Any request refused or unanswered (3 s) | Every icon is shown (fail-open) | Retries |
| A click on the clock | CapyBar itself, while Notification Center is open, so macOS takes the click | Sends the restriction again once Notification Center closes (and a menu opened meanwhile from the bar), or if it opens nothing; at the latest after 11 minutes. Resends asked for meanwhile wait and go out with it |

A resend is tried up to 4 times, waiting twice as long before each retry (about 15 s in all after a restart, 30 s after a failure). Several events at once (waking usually restarts MenuBarAgent too) make one resend. Nothing is resent while nothing hidden is running or while all icons are shown. If every retry fails, CapyBar gives up and the icons stay visible, which is the safe outcome; the next event tries again.

The logic is `RestrictionKeeper` in `Sources/CapyBarCore`; the events are wired up in `CubbyController`.

## How it's checked

**Automated** (`swift run CapyBarTests`, runs in CI): `ReliabilityTests` covers every row of the table above with the system faked and delays shortened to milliseconds, including retries, refusals and timeouts that fail open, and a stale reply arriving after a newer event.

**On a real Mac** (`scripts/check-reliability.sh`), with CapyBar in /Applications and a running app hidden:

```bash
scripts/check-reliability.sh agent                       # restarts MenuBarAgent, expects "restored on attempt N"
scripts/check-reliability.sh relaunch com.example.App    # quits and reopens a hidden app, expects no failures
scripts/check-reliability.sh report 30                   # after sleep, a restart or a user switch: what happened
```

Sleep and restart can't be scripted safely, so check them by hand:

1. Hide an app that's running. Sleep the Mac (Apple menu → Sleep), wait a minute, wake it. The icon stays hidden (it may flash for a moment). `scripts/check-reliability.sh report 5` shows `woke: restored`.
2. Restart with Open at Login on. After login the icons of hidden apps don't show up. `report 5` shows no `gave up`.
3. Update a hidden app (or quit and reopen it). Its icon stays hidden and still opens from the panel.
4. Switch to another user and back. `report 5` shows `sessionActivated: restored`.

The log is also readable directly:

```bash
log show --info --last 30m --predicate 'subsystem == "app.capybar.CapyBar" AND process == "CapyBar"'
```
