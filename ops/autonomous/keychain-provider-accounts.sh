#!/usr/bin/env bash
# keychain-provider-accounts.sh — source-only provider-key identity and marker comparison helpers.
#
# The one-time partition-list repair and daemon's stale-marker warning must agree on this exact provider
# account list. Keeping it here avoids the W21.seed-fu failure mode: add a provider to the repair script,
# then silently lose the warning that its old marker does not cover it. DriveClientSecret is deliberately
# absent — it is an app-owned OAuth secret, never read by the command-line smoke tools.

KEYCHAIN_PROVIDER_SERVICE="com.archiveprocessor.app"
KEYCHAIN_PROVIDER_ACCOUNTS=(Gemini Anthropic Mistral OpenAI Gateway)

# Print provider accounts that are present in LOGIN_KEYCHAIN but absent from MARKER. Attribute-only Keychain
# lookups omit `-w`, so this discovery neither reads a secret nor causes an access prompt. An absent marker
# means the whole repair has not been run; status already has its separate, direct "Keychain not set up" ask.
keychain_unmarked_present_provider_accounts() {
  local marker="$1" login_keychain="$2" covered account
  [ -f "$marker" ] || return 0
  covered="$(sed -n '1s/^[^|]*|[[:space:]]*//p' "$marker" 2>/dev/null)"
  for account in "${KEYCHAIN_PROVIDER_ACCOUNTS[@]}"; do
    security find-generic-password -s "$KEYCHAIN_PROVIDER_SERVICE" -a "$account" "$login_keychain" >/dev/null 2>&1 || continue
    case " $covered " in
      *" $account "*) ;;
      *) printf '%s\n' "$account" ;;
    esac
  done
}
