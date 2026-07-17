#!/usr/bin/env bash
# prove-keepalive.sh — prove, on THIS machine's launchd, that the WS1 supervisor semantics hold:
#   (1) KeepAlive=true relaunches the job after an unexpected death (kill -9), and
#   (2) `launchctl bootout` (what every INTENTIONAL stop does) makes it stay dead.
# Uses a THROWAWAY label + script (NOT the real daemon), in the user's gui domain, and boots itself out +
# deletes its plist on exit. Safe to run anytime; it never touches com.archivesuite.autonomous.
# The real daemon's KeepAlive behavior can't go in the bash-only prove-daemon.sh (that runs the loop as a
# plain process); this is the launchd half. Run interactively.
#
# Ground truth = the probe's own heartbeat log (one line per launch, tagged with the live $$), NOT
# `launchctl print` — parsing a pid out of launchctl print proved unreliable (it can report a transient pid).
set -uo pipefail

UID_="$(id -u)"; DOMAIN="gui/$UID_"
LABEL="com.archivesuite.ws1probe.$$"          # unique per run — cannot collide with the real job
T="$(mktemp -d)"
PLIST="$T/$LABEL.plist"; BEAT="$T/beats.log"; SCRIPT="$T/probe.sh"; : > "$BEAT"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
cleanup() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
lines() { wc -l < "$BEAT" | tr -d ' '; }
pid_on() { awk -v n="$1" 'NR==n{print $2}' "$BEAT" | sed 's/pid=//'; }          # pid recorded by launch #n
wait_lines() { local i; for i in $(seq 1 "$2"); do [ "$(lines)" -ge "$1" ] && return 0; sleep 1; done; return 1; }

cat > "$SCRIPT" <<EOF
#!/bin/sh
echo "alive pid=\$\$ at \$(date +%s)" >> "$BEAT"
exec sleep 3600
EOF
chmod +x "$SCRIPT"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
</dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null || { echo "probe plist malformed"; exit 2; }

echo "[1] bootstrap -> RunAtLoad starts the job (it records a heartbeat)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
  echo "  (launchctl bootstrap unavailable in this context — run this test in an interactive shell)"; exit 3
fi
wait_lines 1 10 && ok "started (pid $(pid_on 1))" || { bad "never started"; exit 1; }

echo "[2] kill -9 the live process (simulate a crash) -> KeepAlive relaunches with a NEW pid"
P1="$(pid_on 1)"; kill -9 "$P1" 2>/dev/null
if wait_lines 2 20; then
  P2="$(pid_on 2)"
  [ -n "$P2" ] && [ "$P2" != "$P1" ] && ok "relaunched (pid $P1 -> $P2)" || bad "second launch pid looks wrong ($P1 -> $P2)"
else
  bad "did NOT relaunch after kill (KeepAlive broken)"
fi

echo "[3] launchctl bootout -> stays DEAD (what every intentional stop does)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
before="$(lines)"; sleep 4
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && bad "job still registered after bootout" || ok "job gone after bootout"
[ "$(lines)" = "$before" ] && ok "no new heartbeat after bootout (no relaunch)" || bad "relaunched after bootout (heartbeats grew $before -> $(lines))"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
