#!/usr/bin/env bash
# fix-keychain-access.sh — stop the recurring "security wants to use your keychain login" prompt for good.
# RUN THIS ONCE (it needs your login password, so it can't be part of the unattended daemon). Re-run only
# after you rotate/re-add an API key (a re-created Keychain item gets a fresh, empty partition list).
#
# WHY (the real cause, WS12 of the 2-week hardening): the daemon's smoke gates read the OCR key(s) with
# `security find-generic-password -w` (Gemini in ArchiveProcessor/test-smoke.sh; Gemini + Mistral in
# scripts/test-smoke.sh) — i.e. the requester is /usr/bin/security, NOT the app. macOS gates a command-line
# tool's prompt-free access to a Keychain item by the item's PARTITION LIST, which is separate from the
# "Always Allow" ACL. Clicking "Always Allow" edits the ACL but never the partition list, so /usr/bin/security
# keeps prompting no matter how many times you click it. This sets each item's partition list to Apple's code
# partitions (apple:, apple-tool:), which is what lets /usr/bin/security read them without prompting.
#
# CAVEAT: `-S` REPLACES the partition list (there is no append). On modern macOS the app's own "Always Allow"
# can also live in that list, so replacing it may make the APP re-prompt ONCE — hence the "confirm the app"
# step printed at the end is NOT optional. Recoverable (one click), never a lockout.
set -uo pipefail

SVC="com.archiveprocessor.app"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
# All LLM-provider key accounts the app stores under $SVC (the ones a smoke/E2E run reads via /usr/bin/
# security). MUST include Mistral — scripts/test-smoke.sh reads it via the CLI, so omitting it would leave a
# live prompt while this script reports success. Non-provider items (Drive secrets, gateway config) are left
# alone: the CLI never reads them, so touching their partition lists would risk an app re-prompt for no gain.
CANDIDATES=(Gemini Anthropic Mistral OpenAI Gateway)

echo "== fix-keychain-access =="
[ -f "$LOGIN_KC" ] || { echo "no login keychain at $LOGIN_KC"; exit 1; }

# Discover which items actually exist — reading ATTRIBUTES (no -w) does NOT touch the secret, so it never
# prompts and never needs the keychain unlocked.
present=()
for a in "${CANDIDATES[@]}"; do
  # Scope the probe to $LOGIN_KC (same keychain the fix targets), so "found" can't mean an item in a different
  # keychain that the fix call would then fail to match.
  if security find-generic-password -s "$SVC" -a "$a" "$LOGIN_KC" >/dev/null 2>&1; then present+=("$a"); fi
done
if [ "${#present[@]}" -eq 0 ]; then
  echo "No '$SVC' key items found (accounts checked: ${CANDIDATES[*]}). Nothing to do."
  exit 0
fi
echo "Items to fix: ${present[*]}"
echo

# One password entry for all items. Read silently; never echoed, never written to disk. It IS passed to
# `security` via -k, so it is briefly visible in this user's own process table for each call — acceptable for
# a one-time, local, owner-run setup; the alternative (omitting -k) is one GUI password dialog PER item.
printf 'Enter your macOS login password (authorizes the partition-list change; not stored): '
read -rs PW; echo
[ -n "$PW" ] || { echo "No password entered — aborting."; exit 1; }

# Make sure the keychain is unlocked for the operation (harmless if it already is; it is set no-timeout).
if ! security unlock-keychain -p "$PW" "$LOGIN_KC" 2>/dev/null; then
  echo "✗ Could not unlock the login keychain — wrong password? Aborting (nothing changed)."; exit 1
fi

rc=0
for a in "${present[@]}"; do
  # -S apple-tool:,apple: — REPLACES the partition list with Apple's code partitions, which is what a
  # command-line tool needs. This is the standard, documented recipe for the "security wants to use your
  # keychain" loop.
  if security set-generic-password-partition-list \
        -S 'apple-tool:,apple:' -s "$SVC" -a "$a" -k "$PW" "$LOGIN_KC" >/dev/null 2>&1; then
    echo "  ✓ $a — partition list set (apple-tool:,apple:)"
  else
    echo "  ✗ $a — FAILED"; rc=1
  fi
done
PW=""   # drop it from this shell's memory promptly

# Durable marker so `daemon.sh status` can stop nagging (reading the partition list itself would need auth).
# Records WHICH accounts were fixed, so daemon.sh can warn if a NEW key (e.g. an OpenAI key added later) is
# present but not yet covered — the exact "added a provider after running this" gap.
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"
if [ "$rc" -eq 0 ]; then
  mkdir -p "$STATE" 2>/dev/null && printf '%s | %s\n' "$(date '+%F %T')" "${present[*]}" > "$STATE/keychain-partition-fixed" 2>/dev/null || true
fi

echo
if [ "$rc" -eq 0 ]; then
  cat <<EOF
Done. /usr/bin/security can now read those items without prompting, so the daemon's test-smoke gate won't
wake you again for them.

ONE more step to be safe — confirm the APP still has access under the new partition list:
  ./launch.sh processor
If (and only if) the Processor prompts for the key, click **Always Allow** once — that re-adds the app to the
partition list. Do this now, while you're here, so an unattended GUI-verify session never hangs on it later.

Re-run this script after you rotate or re-add any API key.
EOF
else
  echo "One or more items failed (see ✗ above). Re-run and double-check your password."; exit 1
fi
