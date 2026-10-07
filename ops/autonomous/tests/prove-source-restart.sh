#!/usr/bin/env bash
# prove-source-restart.sh — restart-on-source-change (owner, 2026-10-06: "Plan to re-start after every commit
# for the multi-session work").
#
# WHAT IT PROVES, against the real daemon run from an INSTALLED copy (as launchd runs it), with a stub session
# that commits a change to the checkout's daemon:
#   [1] with the flag file and under launchd (XPC_SERVICE_NAME = the job), the loop installs the committed
#       daemon over its installed copy, re-renders the prompt, logs it and exits, with the reason in "daemon down";
#   [2] without the flag file it keeps running and installs nothing;
#   [3] not under launchd (no XPC_SERVICE_NAME) it keeps running and installs nothing;
#   [4] an uncommitted change in ops/autonomous/ is never installed (logged once, the run continues);
#   [5] a committed daemon that fails `bash -n` is never installed.
# Sandboxed like prove-gate-fix.sh: own HOME, STATE and git REPO; host commands stubbed; never touches launchd.
# shellcheck disable=SC2015 # ok/bad always return success; assertion chains are intentional.
set -uo pipefail
unset AUTONOMOUS_AGENT XPC_SERVICE_NAME

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"
. "$HERE/fixture-processes.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

FIXTURE_HOME="$T/home"; mkdir -p "$FIXTURE_HOME/Desktop" "$FIXTURE_HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
for c in security osascript launchctl caffeinate curl; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
printf '#!/bin/sh\necho "Filesystem 1M-blocks Used Available Capacity iused ifree %%iused Mounted on"\necho "/dev/disk1 1000000 1000 999999 1%% 1 1 0%% /"\n' > "$BIN/df"
chmod +x "$BIN/df"
export PATH="$BIN:$PATH"

LABEL=provesrc; JOB="com.$LABEL.autonomous"
REPO="$T/repo with space"; STATE="$T/state"; PLAN="$T/plan.md"; INSTALLED="$T/installed/archive-suite-autonomous.sh"
L="$STATE/daemon.log"; SESSCTL="$T/sessctl"

setup() {  # a fresh checkout whose daemon is the one under test, installed and rendered as `daemon.sh start` does
  rm -rf "$REPO" "$STATE" "$T/installed"; mkdir -p "$REPO/ops/autonomous" "$STATE" "$T/installed"
  git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  cp "$DAEMON" "$REPO/ops/autonomous/archive-suite-autonomous.sh"
  printf 'session prompt for __REPO__ (prove-source-restart fixture)\n' > "$REPO/ops/autonomous/resume-prompt.txt"
  printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
  git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  install -m 755 "$DAEMON" "$INSTALLED"
  sed "s|__REPO__|$REPO|g" "$REPO/ops/autonomous/resume-prompt.txt" > "$STATE/resume-prompt.txt"
  printf 'RUN STATUS: IN_PROGRESS — test\n\n## WORK QUEUE (priority order)\n- [ ] item one\n\n## Session Log\n' > "$PLAN"
  rm -f "$T/sessions"
}

# The stub session: the FIRST one changes the checkout's daemon as $SESSCTL says (commit | dirty | broken).
cat > "$T/claude" <<STUB
#!/bin/bash
n=\$(cat "$T/sessions" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$T/sessions"
[ "\$n" = 1 ] || exit 0
d="$REPO/ops/autonomous/archive-suite-autonomous.sh"
case "\$(cat "$SESSCTL")" in
  commit) echo "# v2 (prove-source-restart)" >> "\$d"; echo "v2 prompt" >> "$REPO/ops/autonomous/resume-prompt.txt"
          git -C "$REPO" add -A && git -C "$REPO" commit -qm v2 ;;
  dirty)  echo "# uncommitted (prove-source-restart)" >> "\$d" ;;
  broken) echo "if then fi (" >> "\$d"; git -C "$REPO" add -A && git -C "$REPO" commit -qm broken ;;
esac
exit 0
STUB
chmod +x "$T/claude"
printf '#!/bin/sh\necho STATUS-OK\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {  # $1 = XPC_SERVICE_NAME to run under ("" = not launchd)
  fixture_launch env -u BASH_ENV -u SHELLOPTS ${1:+XPC_SERVICE_NAME="$1"} HOME="$FIXTURE_HOME" AUTONOMOUS_LABEL=$LABEL \
    AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" \
    AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=2 AUTONOMOUS_IDLE_STOP=0 AUTONOMOUS_MAX_NOCOMPLETE=0 \
    AUTONOMOUS_GATE_EVERY=0 AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_COMPACTOR="$T/none" \
    AUTONOMOUS_DOC_PREGATE=0 AUTONOMOUS_BUDGET_CMD="$T/none" AUTONOMOUS_HB_POLL=1 AUTONOMOUS_YIELD_CMD="$T/no-yield" AUTONOMOUS_GRANT_CMD="$T/no-grant" \
    AUTONOMOUS_USAGE_CMD="$HERE/../usage-window.sh" AUTONOMOUS_WINDOW_POLL=1 \
    bash "$INSTALLED" >"$T/daemon.out" 2>&1
}
await() {  # await <seconds> <command…>: true as soon as the command is
  local deadline=$((SECONDS+$1)); shift
  while [ "$SECONDS" -lt "$deadline" ]; do "$@" && return 0; sleep 0.2; done; return 1
}
sessions_at_least() { [ "$(cat "$T/sessions" 2>/dev/null || echo 0)" -ge "$1" ]; }
dead() { ! kill -0 "$P" 2>/dev/null; }
same_as_repo() { cmp -s "$INSTALLED" "$REPO/ops/autonomous/archive-suite-autonomous.sh"; }

echo "[1] flag + launchd: the committed daemon is installed and the loop exits for launchd to relaunch it"
setup; echo commit > "$SESSCTL"; touch "$STATE/restart-on-source-change"; launch "$JOB"
await 60 dead && ok "the loop exited after the session" || { bad "still running: $(tail -3 "$L")"; stop "$P"; }
same_as_repo && ok "installed copy now equals the committed daemon" || bad "installed copy not updated"
grep -q 'v2 prompt' "$STATE/resume-prompt.txt" && grep -q "$REPO" "$STATE/resume-prompt.txt" \
  && ok "resume prompt re-rendered with the checkout path" || bad "prompt not re-rendered: $(cat "$STATE/resume-prompt.txt")"
grep -q 'restart-on-source-change: installed the committed daemon resume-prompt' "$L" && ok "logged what it installed" || bad "no install line: $(grep restart "$L")"
grep -q 'daemon down.*reason: restart-on-source-change' "$L" && ok "daemon-down line names the reason" || bad "exit reason: $(grep 'daemon down' "$L")"
[ "$(cat "$T/sessions")" = 1 ] && ok "no second session ran on the old code" || bad "sessions: $(cat "$T/sessions")"

echo "[2] no flag file: keeps running, installs nothing"
setup; echo commit > "$SESSCTL"; launch "$JOB"
await 30 sessions_at_least 2 && ok "a second session ran on the same daemon" || bad "no second session"
dead && bad "the loop exited" || ok "the loop kept running"
stop "$P" || exit 1
same_as_repo && bad "installed although the flag is absent" || ok "installed copy untouched"

echo "[3] not under launchd: keeps running, installs nothing"
setup; echo commit > "$SESSCTL"; touch "$STATE/restart-on-source-change"; launch ""
await 30 sessions_at_least 2 && ok "a second session ran" || bad "no second session"
dead && bad "the loop exited outside launchd" || ok "the loop kept running"
stop "$P" || exit 1
same_as_repo && bad "installed outside launchd" || ok "installed copy untouched"

echo "[4] an uncommitted change in ops/autonomous/ is never installed"
setup; echo dirty > "$SESSCTL"; touch "$STATE/restart-on-source-change"; launch "$JOB"
await 30 sessions_at_least 3 && ok "sessions continue" || bad "sessions stopped: $(cat "$T/sessions" 2>/dev/null)"
dead && bad "the loop exited on uncommitted code" || ok "the loop kept running"
stop "$P" || exit 1
same_as_repo && bad "uncommitted code was installed" || ok "installed copy untouched"
[ "$(grep -c 'NOT installed — ops/autonomous/ has uncommitted changes' "$L")" = 1 ] && ok "refusal logged once" \
  || bad "refusal lines: $(grep -c 'NOT installed' "$L")"

echo "[5] a committed daemon that fails bash -n is never installed"
setup; echo broken > "$SESSCTL"; touch "$STATE/restart-on-source-change"; launch "$JOB"
await 30 sessions_at_least 2 && ok "sessions continue" || bad "sessions stopped"
dead && bad "the loop exited for a broken daemon" || ok "the loop kept running"
stop "$P" || exit 1
same_as_repo && bad "a broken daemon was installed" || ok "installed copy untouched"
grep -q 'NOT installed — the committed daemon fails bash -n' "$L" && ok "refusal logged" || bad "no refusal: $(grep restart "$L")"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
