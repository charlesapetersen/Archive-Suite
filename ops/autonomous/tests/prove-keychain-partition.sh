#!/usr/bin/env bash
# prove-keychain-partition.sh — hermetic proof for the provider-key partition marker (W21.seed-fu).
#
# Runs the REAL repair script and marker-comparison helper against a fake `security`; it cannot open the
# login Keychain, obtain a password, or change a partition list. The fixture deliberately contains a
# DriveClientSecret-shaped non-provider account only as a name outside the provider list — no real secret.
#
# EXTERNAL PREREQ: `rg` (ripgrep), used by step [3] to grep `daemon.sh`. It is the only `rg` in this repo —
# everything else greps with `grep` — and it arrived on 2026-08-19 (`2c4ff4e`) from an agent sandbox that
# ships its own `rg` at `/Applications/ChatGPT.app/Contents/Resources/rg`. So it measured 10/0 there and
# 9/1 under the health gate, whose PATH is `/opt/homebrew/bin` + this repo's shims and had no `rg` at all.
# The 9/1 is the reason for the guard below: with `rg` absent, bash prints `rg: command not found`, the
# `&&` chain falls through, and the harness asserts `daemon is not wired to the marker comparison` — a RED
# gate and a PARKED run, blamed on daemon wiring that is in fact correct. (`daemon.sh` does call both
# helpers; verified.) Compare the note on `prove-vm-lane.sh` in `health-gate.sh`, which records that that
# harness needs nothing from the gate's PATH line: that is the standard these harnesses are held to.
#
# A missing prerequisite therefore exits **3 + `SKIPPED:`** and the gate runs this through
# `step_skippable`, exactly as `fixture-scripts` does for `/opt/homebrew/bin/tag` — a machine without the
# tool gets a loud `⊘ … SKIPPED` instead of a false park (`ops/autonomous/README.md`). Never let this
# become a plain `exit 1`: an unrunnable check must not read as a failed one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/../fix-keychain-access.sh"
LIB="$HERE/../keychain-provider-accounts.sh"
[ -f "$FIX" ] && [ -f "$LIB" ] || { echo "FATAL: keychain repair/helper missing"; exit 2; }
# Not a FATAL and not a failure: an absent tool means this proof did not RUN. See the header.
command -v rg >/dev/null 2>&1 || { echo "SKIPPED: ripgrep (rg) is not on PATH — install it with: brew install ripgrep"; exit 3; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/Library/Keychains" "$T/state" "$T/bin"
LOGIN="$HOME/Library/Keychains/login.keychain-db"; : > "$LOGIN"
MARKER="$T/state/keychain-partition-fixed"; SECURITY_LOG="$T/security.log"; : > "$SECURITY_LOG"
PASS=0; FAIL=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# The stub accepts the real script's argv shape. It never records a password, only the account and requested
# partition list, so a failing proof cannot leak the fixture password either.
printf '%s\n' \
  '#!/bin/sh' \
  'cmd="$1"; shift' \
  'account=""; service=""; partitions=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -a) account="$2"; shift 2 ;;' \
  '    -s) service="$2"; shift 2 ;;' \
  '    -S) partitions="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case "$cmd" in' \
  '  find-generic-password)' \
  '    case " ${KEYCHAIN_PRESENT:-} " in *" $account "*) exit 0 ;; *) exit 44 ;; esac ;;' \
  '  unlock-keychain) printf "unlock\n" >> "$SECURITY_LOG"; exit 0 ;;' \
  '  set-generic-password-partition-list)' \
  '    printf "set:%s:%s:%s\n" "$service" "$account" "$partitions" >> "$SECURITY_LOG"' \
  '    [ "${KEYCHAIN_FAIL_ACCOUNT:-}" = "$account" ] && exit 1; exit 0 ;;' \
  '  *) exit 64 ;;' \
  'esac' > "$T/bin/security"
chmod +x "$T/bin/security"

run_fix() {
  printf 'fixture-password\n' | \
    PATH="$T/bin:$PATH" SECURITY_LOG="$SECURITY_LOG" AUTONOMOUS_STATE="$T/state" \
    KEYCHAIN_PRESENT="$1" KEYCHAIN_FAIL_ACCOUNT="${2:-}" bash "$FIX" 2>&1
}

echo "[0] repair and warning share the complete provider account list"
ACCOUNTS="$(bash -c '. "$1"; printf "%s " "${KEYCHAIN_PROVIDER_ACCOUNTS[@]}"' _ "$LIB")"
[ "$ACCOUNTS" = 'Gemini Anthropic Mistral OpenAI Gateway ' ] \
  && ok "shared list names every CLI-read provider, never DriveClientSecret" || bad "shared provider list drifted: $ACCOUNTS"

echo "[1] repair records only the present provider accounts"
OUT="$(run_fix 'Gemini OpenAI DriveClientSecret')"; rc=$?
[ "$rc" = 0 ] && ok "repair completed with the fake Keychain" || bad "repair failed (rc=$rc): $OUT"
grep -qE '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] .* \| Gemini OpenAI$' "$MARKER" \
  && ok "marker records the two present provider accounts" || bad "marker wrong: $(cat "$MARKER" 2>/dev/null || echo missing)"
grep -qx 'set:com.archiveprocessor.app:Gemini:apple-tool:,apple:' "$SECURITY_LOG" \
  && grep -qx 'set:com.archiveprocessor.app:OpenAI:apple-tool:,apple:' "$SECURITY_LOG" \
  && ok "repair uses the intended partition list for every present provider" || bad "unexpected security calls: $(tr '\n' '|' < "$SECURITY_LOG")"
grep -q 'DriveClientSecret' "$SECURITY_LOG" && bad "non-provider Drive secret entered the repair" || ok "DriveClientSecret stays app-owned and untouched"
grep -q 'fixture-password' "$SECURITY_LOG" && bad "fixture password leaked into the log" || ok "password is not logged"

echo "[2] a partial repair never advances the durable marker"
rm -f "$MARKER"; : > "$SECURITY_LOG"
OUT="$(run_fix 'Gemini OpenAI' OpenAI)"; rc=$?
[ "$rc" != 0 ] && ok "one failed account makes repair fail" || bad "partial repair returned success: $OUT"
[ ! -e "$MARKER" ] && ok "partial repair leaves no false-covered marker" || bad "partial repair wrote a marker"

echo "[3] the daemon helper finds a later-added present provider, not an absent one"
printf '2026-08-19 00:00:00 | Gemini\n' > "$MARKER"
MISSING="$(PATH="$T/bin:$PATH" KEYCHAIN_PRESENT='Gemini OpenAI DriveClientSecret' bash -c '. "$1"; keychain_unmarked_present_provider_accounts "$2" "$3"' _ "$LIB" "$MARKER" "$LOGIN")"
[ "$MISSING" = OpenAI ] && ok "marker comparison names only the unmarked present provider" || bad "marker comparison wrong: ${MISSING:-<empty>}"
rg -q 'warn_unmarked_keychain_provider' "$HERE/../daemon.sh" \
  && rg -q 'keychain_unmarked_present_provider_accounts' "$HERE/../daemon.sh" \
  && ok "daemon start calls the proven marker comparison" || bad "daemon is not wired to the marker comparison"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
