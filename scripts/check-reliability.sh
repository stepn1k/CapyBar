#!/bin/bash
# Checks on a real Mac that hidden icons come back hidden after the events that drop
# CapyBar's restriction. Reads CapyBar's own log lines (unified log, subsystem
# app.capybar.CapyBar); it changes no settings.
#
#   scripts/check-reliability.sh agent          restart MenuBarAgent, expect a resend that holds
#   scripts/check-reliability.sh relaunch <ID>  quit and reopen a hidden app (what an update does)
#   scripts/check-reliability.sh report [MIN]   what CapyBar did in the last MIN minutes (default 30):
#                                               run it after waking the Mac, a restart or a user switch
#
# Needs CapyBar running from /Applications with at least one running app hidden.
# `agent` makes the whole menu bar redraw once; nothing else is touched.
set -euo pipefail

SUBSYSTEM="app.capybar.CapyBar"
PREDICATE="subsystem == \"$SUBSYSTEM\" AND process == \"CapyBar\""

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

capybar_running() { pgrep -xq CapyBar; }

# CapyBar's log lines since a given time ("YYYY-MM-DD HH:MM:SS").
log_since() {
  log show --style compact --info --start "$1" --predicate "$PREDICATE" 2>/dev/null | grep -v '^Timestamp' || true
}

now() { date '+%Y-%m-%d %H:%M:%S'; }

# Waits up to $2 seconds for a line matching $3 in the log since $1.
wait_for_line() {
  local since="$1" timeout="$2" pattern="$3" waited=0
  while (( waited < timeout )); do
    if log_since "$since" | grep -Eq "$pattern"; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

check_agent() {
  capybar_running || fail "CapyBar is not running"
  local before since
  before="$(pgrep -x MenuBarAgent || true)"
  [[ -n "$before" ]] || fail "MenuBarAgent is not running"
  since="$(now)"
  echo "Restarting MenuBarAgent (pid $before); launchd starts it again…"
  killall MenuBarAgent
  local waited=0
  until pgrep -xq MenuBarAgent; do
    sleep 1
    waited=$((waited + 1))
    (( waited < 20 )) || fail "MenuBarAgent did not come back"
  done
  echo "MenuBarAgent is back (pid $(pgrep -x MenuBarAgent))"
  if ! wait_for_line "$since" 5 "MenuBarAgent restarted"; then
    fail "CapyBar did not notice the restart"
  fi
  pass "CapyBar noticed the restart"
  if log_since "$since" | grep -q "agentRestarted: nothing hidden"; then
    echo "Nothing hidden is running, so there was nothing to resend. Hide a running app and try again."
    exit 0
  fi
  # Four attempts span about 15 s.
  if wait_for_line "$since" 20 "agentRestarted: restored on attempt"; then
    pass "$(log_since "$since" | grep -Eo 'agentRestarted: restored on attempt [0-9]+' | tail -1)"
  elif log_since "$since" | grep -q "agentRestarted: gave up"; then
    fail "MenuBarAgent refused every resend; the icons are visible. Log:"$'\n'"$(log_since "$since")"
  else
    fail "no resend finished within 20 s. Log:"$'\n'"$(log_since "$since")"
  fi
}

check_relaunch() {
  local id="${1:-}"
  [[ -n "$id" ]] || fail "pass the bundle ID of a hidden, running app, like com.getdropbox.dropbox"
  capybar_running || fail "CapyBar is not running"
  local hidden
  hidden="$(defaults read "$SUBSYSTEM" hiddenBundleIDs 2>/dev/null || true)"
  grep -q "\"\\?$id\"\\?" <<<"$hidden" || fail "$id is not hidden in CapyBar"
  local path
  path="$(mdfind "kMDItemCFBundleIdentifier == '$id'" | head -1)"
  [[ -n "$path" ]] || fail "can't find the app for $id"
  local since
  since="$(now)"
  echo "Quitting $id…"
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  sleep 3
  echo "Opening $path again…"
  open "$path"
  sleep 5
  local failures
  failures="$(log_since "$since" | grep -E "finished, error: [^n]|gave up" || true)"
  [[ -z "$failures" ]] || fail "a restriction failed after the relaunch:"$'\n'"$failures"
  if log_since "$since" | grep -q "finished, error: none"; then
    pass "the restriction was sent again and accepted after $id came back"
  else
    pass "no failures; the restriction did not need sending again"
  fi
  echo "Now look at the menu bar: $id's icon should not be there."
}

report() {
  local minutes="${1:-30}"
  local since
  since="$(date -v-"${minutes}"M '+%Y-%m-%d %H:%M:%S')"
  local lines
  lines="$(log_since "$since")"
  if [[ -z "$lines" ]]; then
    echo "No CapyBar log lines in the last $minutes minutes."
    capybar_running || echo "CapyBar is not running."
    exit 0
  fi
  echo "$lines" | grep -E "keeper|MenuBarAgent restarted|activation|restriction cleared" || true
  echo
  local restored gaveup
  restored="$(grep -c "restored on attempt" <<<"$lines" || true)"
  gaveup="$(grep -c "gave up" <<<"$lines" || true)"
  echo "Restored: $restored, gave up: $gaveup"
  (( gaveup == 0 )) || fail "CapyBar gave up at least once; icons may have stayed visible"
  pass "every event that dropped the restriction was recovered"
}

case "${1:-}" in
  agent) check_agent ;;
  relaunch) check_relaunch "${2:-}" ;;
  report) report "${2:-30}" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
