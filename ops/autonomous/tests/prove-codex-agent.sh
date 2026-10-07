#!/usr/bin/env bash
# prove-codex-agent.sh — the daemon's `--agent codex` lane (owner, 2026-10-04), against a stub `codex`.
#
# WHAT IT PROVES: with AGENT=codex the REAL daemon launches `codex exec` (never claude) with the flags the lane
# depends on, the codex preamble ahead of the resume prompt in ONE argv element, stdin closed, and the
# unattended environment; that it reads the usage window from the session's ROLLOUT file and waits for the
# reset; that a codex limit error is reported as a usage limit, not as an empty queue; that the agent can come
# from $STATE/agent (what a launchd relaunch reads); and that a bad agent or a missing preamble refuses to start.
# Sandboxed like prove-daemon.sh: its own HOME, STATE, CODEX_HOME and git REPO, host commands stubbed.
#
# USAGE:  ops/autonomous/tests/prove-codex-agent.sh [path/to/archive-suite-autonomous.sh]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"
. "$HERE/fixture-processes.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

unset AUTONOMOUS_AGENT   # an inherited value would override every scenario below (2026-10-04 review)
FIXTURE_HOME="$T/home"; mkdir -p "$FIXTURE_HOME/Desktop" "$FIXTURE_HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
for c in security osascript launchctl caffeinate curl; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk1 1000000 1000 999999 1% 1 1 0% /"
STUB
chmod +x "$BIN/df"
export PATH="$BIN:$PATH"

REPO="$T/repo with space"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD
PLAN="$T/plan.md"
cat > "$PLAN" <<'EOF'
RUN STATUS: IN_PROGRESS — test

## WORK QUEUE (priority order)
- [ ] item one

## Session Log
EOF

STATE="$T/state"; mkdir -p "$STATE"
printf 'autonomous maintenance session for the Archive Suite (prove-codex fixture prompt)\n' > "$STATE/resume-prompt.txt"
printf 'YOU ARE RUNNING UNDER CODEX (prove-codex fixture preamble)\n' > "$STATE/codex-preamble.txt"
FIXTURE_CODEX_HOME="$T/codexhome"; mkdir -p "$FIXTURE_CODEX_HOME/sessions/2026/10/04"

# The stub codex. $CTRL: "<rc>:<pct or none>:<reset offset s>:<limit-error yes|no>[:<grow|silent>:<seconds>]".
# grow = stay quiet on stdout but append to the rollout every second (a codex session thinking or delegating);
# silent = stay quiet everywhere (a wedged session).
CTRL="$T/ctrl"; ARGV="$T/argv"; CHILDENV="$T/childenv"; STDIN="$T/stdin"
cat > "$T/codex" <<STUB
#!/usr/bin/env bash
: > "$ARGV"; for a in "\$@"; do printf '%s\n----\n' "\$a" >> "$ARGV"; done
env > "$CHILDENV"
if [ -t 0 ]; then echo tty > "$STDIN"; else cat > "$STDIN.content"; echo notty > "$STDIN"; fi
IFS=: read -r rc pct off lim hold hsecs < "$CTRL"
tid="tid-\$(date +%s)-\$\$"
echo '{"type":"thread.started","thread_id":"'"\$tid"'"}'
if [ "\$pct" != none ]; then
  rr=\$(( \$(date +%s) + off ))
  echo '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":'"\$pct"'.0,"window_minutes":300,"resets_at":'"\$rr"'},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":'"\$((rr+99999))"'},"credits":null}}}' \
    > "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-2026-10-04T00-00-00-\$tid.jsonl"
fi
# A transient retry notice, as the real CLI emits inside sessions that then succeed: must not read as a failure.
echo '{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}'
echo '{"type":"turn.started"}'
roll="$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-2026-10-04T00-00-00-\$tid.jsonl"
case "\$hold" in
  grow)   for _ in \$(seq 1 "\$hsecs"); do sleep 1; echo '{"type":"response_item","payload":{"type":"reasoning"}}' >> "\$roll"; done ;;
  silent) sleep "\$hsecs" ;;
esac
if [ "\$lim" = yes ]; then
  echo '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again later."}}'
else
  echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"stub done"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
fi
exit "\$rc"
STUB
chmod +x "$T/codex"
# The stub claude records that it ran and, for the FIRST session since a reset, its argv one argument per line.
printf '#!/bin/sh\necho CLAUDE-WAS-CALLED >> "%s"\n[ -e "%s" ] || printf "%%s\\n" "$@" > "%s"\nexit 1\n' \
  "$T/claude.calls" "$T/claude.argv" "$T/claude.argv" > "$T/claude"; chmod +x "$T/claude"
printf '#!/bin/sh\necho STATUS-OK\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {   # $1 = AUTONOMOUS_AGENT value ("" = unset)
  fixture_launch env -u AUTONOMOUS_AGENT -u AUTONOMOUS_EFFORT -u AUTONOMOUS_MAX_MODEL ${EFF:+AUTONOMOUS_EFFORT="$EFF"} ${MAXM:+AUTONOMOUS_MAX_MODEL="$MAXM"} HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX_HOME" ${1:+AUTONOMOUS_AGENT="$1"} CODEX_THREAD_ID=leaked-parent CODEX_SANDBOX=seatbelt \
  AUTONOMOUS_HB_STALL="${HB_STALL:-600}" AUTONOMOUS_HB_IDLE_N=2 AUTONOMOUS_YIELD_CMD="${YIELD_CMD:-$T/no-yield}" AUTONOMOUS_GRANT_CMD="${GRANT_CMD:-$T/no-grant}" ${UPKEEP:+AUTONOMOUS_UPKEEP_ONLY=1} \
  AUTONOMOUS_LABEL=provecodex AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_STATE="$STATE" \
  AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_CODEX="$T/codex" \
  AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=2 AUTONOMOUS_IDLE_STOP=0 AUTONOMOUS_MAX_NOCOMPLETE=0 \
  AUTONOMOUS_GATE_EVERY=0 AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_COMPACTOR="$T/none" \
  AUTONOMOUS_DOC_PREGATE=0 AUTONOMOUS_BUDGET_CMD="$T/none" AUTONOMOUS_HB_POLL=1 \
  AUTONOMOUS_USAGE_CMD="$HERE/../usage-window.sh" AUTONOMOUS_WINDOW_POLL=1 AUTONOMOUS_WINDOW_SLACK=0 \
    bash "$DAEMON" >"$T/daemon.out" 2>&1
}
reset() { : > "$STATE/daemon.log"; rm -f "$STATE/usage-window.last" "$STATE/usage-window.tsv" "$STATE/idle.since" \
          "$STATE/engine.lock" "$STATE/agent" "$T/claude.calls" "$T/claude.argv" "$ARGV" "$STDIN"; rm -f "$FIXTURE_CODEX_HOME/sessions/2026/10/04"/*; }
L="$STATE/daemon.log"

echo "[1] AUTONOMOUS_AGENT=codex launches codex exec, never claude"
reset; echo "0:40:3600:no" > "$CTRL"; launch codex; sleep 6; stop "$P" || exit 1
grep -q 'daemon up (pid [0-9]*, agent codex' "$L" && ok "daemon logs agent codex" || bad "no 'agent codex' in the up line"
[ -s "$ARGV" ] && ok "codex stub ran" || bad "codex stub never ran: $(tail -3 "$L")"
[ ! -e "$T/claude.calls" ] && ok "claude never called" || bad "claude was called under AGENT=codex"
[ "$(sed -n 1p "$ARGV")" = exec ] && ok "first argument is 'exec'" || bad "argv[1] is '$(sed -n 1p "$ARGV")'"
for f in --json --approve-for-me --add-dir; do grep -qx -- "$f" "$ARGV" && ok "passes $f" || bad "missing $f"; done
grep -qx -- "$STATE" "$ARGV" && ok "state dir is writable (--add-dir)" || bad "state dir not passed to --add-dir"
grep -qx -- "$T" "$ARGV" && ok "the repo's parent is writable, for sibling worktrees" || bad "repo parent not passed to --add-dir"
grep -q -- 'dangerously' "$ARGV" && bad "a --dangerously flag was passed" || ok "no --dangerously flag"
grep -qx -- 'model_reasoning_effort=high' "$ARGV" && ok "Codex's own effort passed: high, not Claude's medium" || bad "codex effort not high"
awk 'BEGIN{RS="\n----\n"} {a[NR]=$0} END{for(i=1;i<NR;i++) if(a[i]=="-m" && a[i+1]=="gpt-6.1-sol") f=1; exit !f}' "$ARGV" \
  && ok "model pinned: -m gpt-6.1-sol" || bad "model not pinned to gpt-6.1-sol"
# The prompt: preamble first, then the resume prompt, in ONE argument (what `daemon.sh stop` matches).
awk 'BEGIN{RS="\n----\n"} /YOU ARE RUNNING UNDER CODEX/ && /autonomous maintenance session for the Archive Suite/ {f=1}
     END{exit !f}' "$ARGV" && ok "preamble + resume prompt are one argument" || bad "prompt not one argument with both parts"
awk 'BEGIN{RS="\n----\n"} /autonomous maintenance session/ { exit !(index($0,"YOU ARE RUNNING UNDER CODEX") < index($0,"autonomous maintenance session")) }' "$ARGV" \
  && ok "preamble comes before the resume prompt" || bad "preamble is not first"
# (Non-interactive bash already gives a background job /dev/null as stdin, so this holds even without the
# daemon's explicit `< /dev/null`: a mutant removing it survives as an EQUIVALENT mutant, checked 2026-10-04.
# The redirect stays because the property matters — a foreground `codex exec` waits on its stdin.)
[ "$(cat "$STDIN" 2>/dev/null)" = notty ] && [ ! -s "$STDIN.content" ] && ok "stdin is closed (empty, not a terminal)" || bad "stdin was '$(cat "$STDIN" 2>/dev/null)'"
grep -q '^ARCHIVE_UNATTENDED=1$' "$CHILDENV" && ok "ARCHIVE_UNATTENDED=1 reaches the session" || bad "ARCHIVE_UNATTENDED missing"
grep -q '^AUTONOMOUS_AGENT=' "$CHILDENV" && bad "AUTONOMOUS_AGENT exported to the session (it leaks into the gate)" || ok "AUTONOMOUS_AGENT not exported to the session"
grep -q '^CODEX_THREAD_ID=\|^CODEX_SANDBOX=' "$CHILDENV" && bad "a parent CODEX_* variable leaked into the session" || ok "parent CODEX_* variables scrubbed"
grep -q "^CODEX_HOME=$FIXTURE_CODEX_HOME\$" "$CHILDENV" && ok "CODEX_HOME kept" || bad "CODEX_HOME was dropped"
grep -q 'ops/autonomous/bin' <(grep '^PATH=' "$CHILDENV") && ok "GUI shims first on PATH" || bad "GUI shims not on PATH"
grep -q 'turns, ended completed' "$L" && ok "session outcome logged from the codex events" || bad "outcome not logged: $(grep 'session cost' "$L" | tail -1)"
[ "$(cat "$STATE/last-session.txt" 2>/dev/null)" = "stub done" ] && ok "last agent message mirrored to last-session.txt" || bad "last-session.txt is '$(cat "$STATE/last-session.txt" 2>/dev/null)'"
grep -q '^40 ' "$STATE/usage-window.last" 2>/dev/null && ok "window reading taken from the rollout file (40%)" || bad "usage-window.last is '$(cat "$STATE/usage-window.last" 2>/dev/null)'"

echo "[2] a window at 97% makes the next cycle wait for the reset"
# The reset is 60 s out, not 4: on a busy machine (the health gate runs this beside a VM) a 4 s window had already
# reset before the next cycle looked, so nothing waited and the check failed (2026-10-05 gate). Stopping the
# daemon mid-wait is fine: the wait polls every second.
reset; echo "1:97:60:no" > "$CTRL"; launch codex; sleep 9; stop "$P" || exit 1
grep -q 'usage window 97% used.*waiting until' "$L" && ok "waits for the reset" || bad "no wait: $(grep -E 'usage|session' "$L" | tail -4)"
[ "$(grep -c 'launching fresh' "$L")" -le 3 ] && ok "does not hammer the window ($(grep -c 'launching fresh' "$L") launches in 9 s)" || bad "too many launches"

echo "[2b] the owner's own Codex use counts: a newer rollout from another session at 98% also makes it wait"
reset; echo "0:30:3600:no" > "$CTRL"
echo '{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":98.0,"window_minutes":300,"resets_at":'"$(( $(date +%s) + 60 ))"'},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":'"$(( $(date +%s) + 99999 ))"'}}}' \
  > "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-owner-interactive.jsonl"
touch -t "$(date -v+1H '+%Y%m%d%H%M.%S')" "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-owner-interactive.jsonl"   # newest of all
launch codex; sleep 6; stop "$P" || exit 1
grep -q 'usage window 98% used.*waiting until' "$L" && ok "waits on the account-wide reading, not just its own session's" || bad "ignored the newer reading: $(grep -E 'usage|launching' "$L" | tail -3)"

echo "[2c] usage-window.sh: a session's no-argument call reads codex's window when \$STATE/agent says codex"
reset; echo codex > "$STATE/agent"
echo '{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":61.0,"window_minutes":300,"resets_at":'"$(( $(date +%s) + 3600 ))"'},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":'"$(( $(date +%s) + 99999 ))"'}}}' \
  > "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-a.jsonl"
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-a.jsonl"
echo '{"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":null}}' > "$FIXTURE_CODEX_HOME/sessions/2026/10/04/rollout-b.jsonl"
out="$(HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX_HOME" AUTONOMOUS_STATE="$STATE" bash "$HERE/../usage-window.sh" --raw)"
[ "${out%% *}" = 61 ] && ok "no-argument call reads the codex rollout" || bad "no-argument call gave '$out'"
out="$(HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX_HOME" bash "$HERE/../usage-window.sh" --raw --codex-latest)"
[ "${out%% *}" = 61 ] && ok "a newer premium-only rollout does not hide the codex reading" || bad "--codex-latest gave '$out'"
rm -f "$STATE/agent"
out="$(HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX_HOME" AUTONOMOUS_STATE="$STATE" bash "$HERE/../usage-window.sh" --raw)"; rc=$?
[ "$rc" = 3 ] && ok "under claude the no-argument call still reads the session log" || bad "claude no-arg call gave '$out' rc=$rc"

echo "[3] a codex limit error is a USAGE LIMIT, not an empty queue"
reset; echo "1:none:0:yes" > "$CTRL"; launch codex; sleep 4; stop "$P" || exit 1
grep -q 'hit a USAGE LIMIT (codex' "$L" && ok "reported as a usage limit" || bad "not reported as a limit: $(grep 'session (rc' "$L" | tail -2)"
grep -q 'advanced nothing' "$L" && bad "also reported as 'advanced nothing'" || ok "not reported as an idle queue"

echo "[4] the agent comes from \$STATE/agent when the environment does not set it (a launchd relaunch)"
reset; echo "0:30:3600:no" > "$CTRL"; echo codex > "$STATE/agent"; launch ""; sleep 4; stop "$P" || exit 1
grep -q 'agent codex' "$L" && [ -s "$ARGV" ] && ok "\$STATE/agent=codex is honoured" || bad "state file ignored: $(head -2 "$L")"
reset; launch ""; sleep 4; stop "$P" || exit 1
grep -q 'agent claude' "$L" && [ -e "$T/claude.calls" ] && ok "no file, no env -> claude (the default)" || bad "default is not claude: $(head -2 "$L")"

echo "[6] watchdog: a codex session quiet on stdout but writing its rollout is spared; one silent everywhere is not"
reset; echo "0:30:3600:no:grow:9" > "$CTRL"; HB_STALL=3 launch codex; sleep 13; stop "$P" || exit 1
grep -q 'watchdog:' "$L" && bad "killed a session whose rollout was growing: $(grep 'watchdog:' "$L" | head -1)" || ok "growing rollout keeps the session alive"
grep -q 'turns, ended completed' "$L" && ok "…and it ran to completion" || bad "session did not complete: $(grep 'session' "$L" | tail -2)"
reset; echo "0:30:3600:no:silent:20" > "$CTRL"; HB_STALL=3 launch codex; sleep 12; stop "$P" || exit 1
grep -q 'watchdog:' "$L" && ok "silent session killed by the watchdog" || bad "silent session never killed: $(cat "$L")"

echo "[7] yield (owner, 2026-10-04): no gate or session while the priority project says so; resumes after"
# The detail in brackets changes on every call, as the real one's page label does: still logged once.
printf '#!/bin/sh\n[ -f "%s" ] && { echo "Vision OCR is running a model job (stub page $(date +%%s%%N))"; exit 0; }\nexit 1\n' "$T/yield.on" > "$T/yield-stub"; chmod +x "$T/yield-stub"
reset; echo "0:30:3600:no" > "$CTRL"; touch "$T/yield.on"; YIELD_CMD="$T/yield-stub" launch codex; sleep 4
[ ! -s "$ARGV" ] && ok "no session while yielding" || bad "a session started while yielding"
[ "$(grep -c 'yielding — Vision OCR is running a model job (stub page' "$L")" = 1 ] && ok "yield logged once, not every cycle, though its detail changes" || bad "yield log count $(grep -c yielding "$L")"
[ ! -f "$STATE/idle.since" ] && ok "a yield is not idleness (no idle stopwatch)" || bad "idle.since set while yielding"
rm -f "$T/yield.on"; sleep 4; stop "$P" || exit 1
grep -q 'yield over' "$L" && [ -s "$ARGV" ] && ok "session starts once the yield ends" || bad "no session after the yield ended: $(tail -3 "$L")"

echo "[7b] Agent Manager grant (stage 4, 2026-10-07): the manager's helper decides first; yield-check.sh is the fallback"
# The stub grant logs its argv, says wait while $T/grant.wait exists, and otherwise exits with $T/grant.rc (0 = granted).
cat > "$T/grant-stub" <<STUB
#!/bin/sh
printf '%s|' "\$@" >> "$T/grant.calls"; echo >> "$T/grant.calls"
[ -f "$T/grant.wait" ] && { echo "wait: Claude's five-hour window is 98% used; it resets at 19:00"; exit 75; }
rc=\$(cat "$T/grant.rc" 2>/dev/null || echo 0); [ "\$rc" = 0 ] && echo granted || echo "broken" >&2
exit "\$rc"
STUB
chmod +x "$T/grant-stub"
# held_reason() alone, sourced from the daemon: every answer the helper can give, and its fallback.
held() { env HOME="$FIXTURE_HOME" AUTONOMOUS_REPO="$REPO" AUTONOMOUS_STATE="$STATE" AUTONOMOUS_AGENT=codex \
           AUTONOMOUS_WORKER_ID=worker-2 AUTONOMOUS_GRANT_CMD="$1" AUTONOMOUS_YIELD_CMD="$2" ${GT:+AUTONOMOUS_GRANT_TIMEOUT=$GT} \
           bash -c '. "$1" >/dev/null 2>&1; held_reason $2' _ "$DAEMON" "${3:-}"; }
rm -f "$T/grant.calls" "$T/grant.rc"; touch "$T/grant.wait" "$T/yield.on"
out="$(held "$T/grant-stub" "$T/yield-stub")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "Claude's five-hour window is 98% used; it resets at 19:00" ] \
  && ok "grant 75 holds off, with its reason and no 'wait:' prefix" || bad "grant wait: rc=$rc out='$out'"
[ "$(head -1 "$T/grant.calls")" = "--project|Archive Suite|--agent|codex|--worker|worker-2|" ] \
  && ok "asks for this project, agent and worker" || bad "grant argv: $(head -1 "$T/grant.calls")"
rm -f "$T/grant.wait"
held "$T/grant-stub" "$T/yield-stub" >/dev/null && bad "grant 0 still held off (yield-check was consulted)" \
  || ok "grant 0 goes ahead even though yield-check would hold off"
echo 3 > "$T/grant.rc"
out="$(held "$T/grant-stub" "$T/yield-stub")" && case "$out" in "Vision OCR is running a model job"*) true ;; *) false ;; esac \
  && ok "an erroring helper (exit 3) falls back to yield-check" || bad "erroring helper: out='$out'"
echo 1 > "$T/grant.rc"
held "$T/grant-stub" "$T/yield-stub" >/dev/null && ok "a crashing helper (exit 1) falls back to yield-check" || bad "crashing helper went ahead"
rm -f "$T/yield.on"
held "$T/grant-stub" "$T/yield-stub" >/dev/null && bad "erroring helper + yield go still held" || ok "erroring helper + yield-check go: goes ahead"
touch "$T/yield.on"
out="$(held "$T/absent-grant" "$T/yield-stub")" && ok "no helper installed: yield-check decides ($out)" || bad "absent helper did not fall back"
rm -f "$T/yield.on" "$T/grant.calls" "$T/grant.rc"
held "$T/grant-stub" "$T/yield-stub" --gate >/dev/null
[ "$(head -1 "$T/grant.calls")" = "--project|Archive Suite|--gate|--worker|worker-2|" ] \
  && ok "--gate asks about exclusive jobs only (no agent)" || bad "gate argv: $(head -1 "$T/grant.calls")"
# The real daemon: a grant wait holds the session (logged once, not idleness); the grant ending lets it start.
reset; rm -f "$T/grant.calls"; echo "0:30:3600:no" > "$CTRL"; touch "$T/grant.wait"
GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 4
[ ! -s "$ARGV" ] && ok "no session while the manager says wait" || bad "a session started while the manager said wait"
[ "$(grep -c "yielding — Claude's five-hour window is 98% used; it resets at 19:00" "$L")" = 1 ] \
  && ok "the manager's reason is logged once" || bad "grant wait log: $(grep yielding "$L")"
[ "$(cat "$STATE/yield.reason" 2>/dev/null)" = "Claude's five-hour window is 98% used; it resets at 19:00" ] \
  && ok "yield.reason carries the manager's reason (status shows Waiting)" || bad "yield.reason: $(cat "$STATE/yield.reason" 2>/dev/null)"
grep -q -- '--agent|codex|' "$T/grant.calls" && ok "serial daemon asks with its agent, not --gate" || bad "serial argv: $(head -1 "$T/grant.calls")"
[ ! -f "$STATE/idle.since" ] && ok "a grant wait is not idleness" || bad "idle.since set during a grant wait"
rm -f "$T/grant.wait"; sleep 4; stop "$P" || exit 1
grep -q 'yield over' "$L" && [ -s "$ARGV" ] && ok "session starts once the manager grants" || bad "no session after the grant: $(tail -3 "$L")"
# Upkeep under the supervisor asks with --gate: a full Claude window must not stop the health gate or the other lane.
reset; rm -f "$T/grant.calls"; touch "$T/grant.wait"
UPKEEP=1 GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 3; stop "$P" || exit 1
grep -q -- '--gate|' "$T/grant.calls" && ! grep -q -- '--agent' "$T/grant.calls" \
  && ok "upkeep asks with --gate only" || bad "upkeep argv: $(cat "$T/grant.calls" 2>/dev/null)"
rm -f "$T/grant.wait"
# Upkeep clears only the wait it recorded itself (2026-10-07 review, finding E). Its own hold above ends: logged
# once and both files go. A lane wait the supervisor wrote to yield.reason is not upkeep's: a --gate grant leaves it.
reset; UPKEEP=1 GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 3; stop "$P" || exit 1
[ "$(grep -c 'yield over — no longer waiting: Claude' "$L")" = 1 ] && [ ! -f "$STATE/upkeep-yield.reason" ] && [ ! -f "$STATE/yield.reason" ] \
  && ok "upkeep's own hold ending is logged once and cleared" || bad "upkeep hold end: $(grep -E 'yield' "$L") / $(ls "$STATE" | grep yield)"
echo "Codex's five-hour window is 97% used (supervisor lane wait)" > "$STATE/yield.reason"
reset; UPKEEP=1 GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 3; stop "$P" || exit 1
grep -q 'yield over' "$L" && bad "upkeep's --gate grant logged a false yield over: $(grep 'yield over' "$L")" \
  || ok "a --gate grant does not log a lane's wait as over"
[ "$(cat "$STATE/yield.reason" 2>/dev/null)" = "Codex's five-hour window is 97% used (supervisor lane wait)" ] \
  && ok "…and leaves the supervisor's yield.reason in place" || bad "upkeep deleted the supervisor's yield.reason"
# Upkeep held, then the supervisor writes a lane wait over upkeep's words: upkeep's hold ending is logged, but the
# lanes' yield.reason stays.
touch "$T/grant.wait"; reset; UPKEEP=1 GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 3; stop "$P" || exit 1
echo "Codex's five-hour window is 97% used (supervisor lane wait)" > "$STATE/yield.reason"; rm -f "$T/grant.wait"
reset; UPKEEP=1 GRANT_CMD="$T/grant-stub" YIELD_CMD="$T/yield-stub" launch codex; sleep 3; stop "$P" || exit 1
grep -q 'yield over — no longer waiting: Claude' "$L" && [ ! -f "$STATE/upkeep-yield.reason" ] \
  && [ "$(cat "$STATE/yield.reason" 2>/dev/null)" = "Codex's five-hour window is 97% used (supervisor lane wait)" ] \
  && ok "upkeep's hold ending keeps a lane wait the supervisor wrote since" || bad "upkeep hold end over a lane wait: $(grep yield "$L") / $(cat "$STATE/yield.reason" 2>/dev/null)"
rm -f "$STATE/yield.reason"
# A hung helper (finding H): the call is bounded by AUTONOMOUS_GRANT_TIMEOUT and yield-check.sh decides. The stub's
# sleep is a child of its shell, so after the alarm kills the shell the sleep still holds whatever stdout it was given.
printf '#!/bin/sh\nsleep 20\necho granted\n' > "$T/grant-hang"; chmod +x "$T/grant-hang"
touch "$T/yield.on"; t0=$(date +%s)
out="$(GT=2 held "$T/grant-hang" "$T/yield-stub")"; rc=$?; took=$(( $(date +%s) - t0 ))
[ "$took" -le 6 ] && ok "a hung helper is cut off (${took}s, timeout 2s)" || bad "a hung helper held the caller ${took}s"
[ "$rc" = 0 ] && case "$out" in "Vision OCR is running a model job"*) true ;; *) false ;; esac \
  && ok "…and yield-check decides after the timeout" || bad "after the timeout: rc=$rc out='$out'"
rm -f "$T/yield.on"

echo "[8] the Claude session's model follows its effort (owner, 2026-10-07: Fable for hard items only)"
# claude_after FLAG — the value the stub claude session was given for FLAG.
claude_after() { awk -v f="$1" 'p{print; exit} $0==f{p=1}' "$T/claude.argv" 2>/dev/null; }
reset; echo "0:30:3600:no" > "$CTRL"; launch claude; sleep 4; stop "$P" || exit 1
[ -s "$T/claude.argv" ] && ok "premise: the claude stub ran and recorded its argv" || bad "claude stub never ran: $(tail -3 "$L")"
[ "$(claude_after --model)" = opus ] && [ "$(claude_after --fallback-model)" = sonnet ] && [ "$(claude_after --effort)" = medium ] \
  && ok "default effort: --model opus --fallback-model sonnet --effort medium" \
  || bad "default: --model '$(claude_after --model)' --fallback-model '$(claude_after --fallback-model)' --effort '$(claude_after --effort)'"
grep -q 'agent claude, backstop [0-9]*s, model opus, effort medium' "$L" && ok "…and the launch line names the model" \
  || bad "launch line: $(grep 'launching fresh' "$L" | head -1)"
reset; EFF=max launch claude; sleep 4; stop "$P" || exit 1
[ "$(claude_after --model)" = fable ] && [ "$(claude_after --fallback-model)" = opus ] && [ "$(claude_after --effort)" = max ] \
  && ok "AUTONOMOUS_EFFORT=max: --model fable --fallback-model opus --effort max" \
  || bad "max: --model '$(claude_after --model)' --fallback-model '$(claude_after --fallback-model)' --effort '$(claude_after --effort)'"
grep -q 'agent claude (fable, effort max)' "$L" && grep -q 'model fable, effort max' "$L" && ok "…and both log lines say fable" \
  || bad "max log lines: $(grep -E 'daemon up|launching fresh' "$L" | head -2)"
reset; EFF=max MAXM=claude-test-model launch claude; sleep 4; stop "$P" || exit 1
[ "$(claude_after --model)" = claude-test-model ] && [ "$(claude_after --fallback-model)" = opus ] \
  && ok "AUTONOMOUS_MAX_MODEL overrides the max-effort model" || bad "override: --model '$(claude_after --model)' --fallback-model '$(claude_after --fallback-model)'"
reset; EFF=max MAXM=opus launch claude; sleep 4; stop "$P" || exit 1
[ "$(claude_after --model)" = opus ] && [ "$(claude_after --fallback-model)" = sonnet ] \
  && ok "an override to opus never falls back to itself" || bad "opus override: --model '$(claude_after --model)' --fallback-model '$(claude_after --fallback-model)'"
reset; EFF=max launch codex; sleep 4; stop "$P" || exit 1
awk 'BEGIN{RS="\n----\n"} {a[NR]=$0} END{for(i=1;i<NR;i++) if(a[i]=="-m" && a[i+1]=="gpt-6.1-sol") f=1; exit !f}' "$ARGV" \
  && grep -qx -- 'model_reasoning_effort=high' "$ARGV" && ! grep -qx -- fable "$ARGV" \
  && ok "a codex lane is unchanged by AUTONOMOUS_EFFORT=max (gpt-6.1-sol, effort high)" || bad "codex lane changed under EFF=max"

echo "[5] refusals"
refusal_rc() {   # $1 = agent; runs the daemon in THIS shell (not a $(…) subshell) so its exit code is waitable
  fixture_launch env HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX_HOME" AUTONOMOUS_AGENT="$1" AUTONOMOUS_LABEL=provecodex AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" \
    AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_CODEX="$T/codex" \
    bash "$DAEMON" >"$T/daemon.out" 2>&1
  local p="$P"; sleep 2
  if kill -0 "$p" 2>/dev/null; then stop "$p"; rc=running; else wait "$p"; rc=$?; stop "$p" || exit 1; fi
}
reset; refusal_rc gpt
[ "$rc" = 2 ] && grep -q "unknown agent 'gpt'" "$T/daemon.out" && ok "unknown agent refuses to start (exit 2)" || bad "unknown agent: rc=$rc $(cat "$T/daemon.out")"
mv "$STATE/codex-preamble.txt" "$T/preamble.bak"; reset; refusal_rc codex
[ "$rc" = 2 ] && grep -q 'codex preamble missing' "$T/daemon.out" && ok "missing preamble refuses to start (exit 2)" || bad "missing preamble: rc=$rc $(cat "$T/daemon.out")"
mv "$T/preamble.bak" "$STATE/codex-preamble.txt"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
