#!/usr/bin/env bash
# keychain-provider-accounts.sh — source-only provider-key identity and marker comparison helpers.
#
# The one-time partition-list repair and daemon's stale-marker warning must agree on this exact provider
# account list. Keeping it here avoids the W21.seed-fu failure mode: add a provider to the repair script,
# then silently lose the warning that its old marker does not cover it. DriveClientSecret is deliberately
# absent — it is an app-owned OAuth secret, never read by the command-line smoke tools. Gateway is excluded
# for the same reason: only the app reads it.

KEYCHAIN_PROVIDER_SERVICE="com.archiveprocessor.app"
KEYCHAIN_PROVIDER_ACCOUNTS=(Gemini Anthropic Mistral OpenAI)

# Convert a local marker timestamp (the format written by date '+%F %T') to epoch seconds.
keychain_local_timestamp_epoch() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s' 2>/dev/null
}

# Convert Keychain's mdat representation (UTC, trailing Z) to epoch seconds.
keychain_mdat_epoch() {
  local mdat="$1" normalized
  [[ "$mdat" =~ ^[0-9]{14}Z$ ]] || return 1
  normalized="${mdat:0:4}-${mdat:4:2}-${mdat:6:2}T${mdat:8:2}:${mdat:10:2}:${mdat:12:2}Z"
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' 2>/dev/null
}

# Print an item's modification date without reading its secret. The default security output includes
# attributes; deliberately do not pass -g or -w, either of which can request secret access.
keychain_provider_item_mdat() {
  local account="$1" login_keychain="$2" attrs
  attrs="$(security find-generic-password -s "$KEYCHAIN_PROVIDER_SERVICE" -a "$account" "$login_keychain" 2>/dev/null)" || return 1
  printf '%s\n' "$attrs" | sed -nE 's/.*"mdat"<timedate>.*"([0-9]{14}Z).*"/\1/p' | head -n 1
}

# Print present provider accounts that are unmarked or whose Keychain item changed after repair. Versioned
# markers contain `mdat|ACCOUNT|YYYYMMDDHHMMSSZ` lines. Legacy markers have only the original local repair
# timestamp and account names; for those, compare the current mdat to the repair time. A warning means
# re-verify /usr/bin/security access: an in-app Always Allow can bump mdat without evicting CLI access.
keychain_unmarked_present_provider_accounts() {
  local marker="$1" login_keychain="$2" first covered account live_mdat live_epoch recorded_mdat recorded_epoch repair_epoch
  [ -f "$marker" ] || return 0
  first="$(sed -n '1p' "$marker" 2>/dev/null)"
  repair_epoch="$(keychain_local_timestamp_epoch "${first%%|*}" 2>/dev/null || true)"
  covered="${first#*| }"
  for account in "${KEYCHAIN_PROVIDER_ACCOUNTS[@]}"; do
    security find-generic-password -s "$KEYCHAIN_PROVIDER_SERVICE" -a "$account" "$login_keychain" >/dev/null 2>&1 || continue
    case " $covered " in
      *" $account "*)
        live_mdat="$(keychain_provider_item_mdat "$account" "$login_keychain")"
        live_epoch="$(keychain_mdat_epoch "$live_mdat" 2>/dev/null || true)"
        recorded_mdat="$(sed -nE "s/^mdat\\|${account}\\|([0-9]{14}Z)$/\\1/p" "$marker" | head -n 1)"
        if [ -n "$recorded_mdat" ]; then
          recorded_epoch="$(keychain_mdat_epoch "$recorded_mdat" 2>/dev/null || true)"
        else
          recorded_epoch="$repair_epoch"
        fi
        if [ -z "$live_epoch" ] || [ -z "$recorded_epoch" ] || [ "$live_epoch" -gt "$recorded_epoch" ]; then
          printf '%s\n' "$account"
        fi
        ;;
      *) printf '%s\n' "$account" ;;
    esac
  done
}
