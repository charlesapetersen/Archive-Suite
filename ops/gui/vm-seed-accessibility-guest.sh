#!/usr/bin/env bash
# vm-seed-accessibility-guest.sh — the GUEST half of the Accessibility repair. Runs INSIDE the GUI VM,
# invoked from the repo mount by ops/gui/vm-seed-accessibility.sh (the entry point — read its header for
# what broke on 2026-08-10, and why writing TCC is defensible in a throwaway VM and nowhere else).
#
# It is a file rather than a quoted blob inside `tart exec bash -lc '…'` because the TCC path contains a
# space and the SQL contains single quotes: nesting needs three levels of escaping, and the first attempt
# died on `unexpected EOF while looking for matching '` before it changed anything.
#
# ── THE TWO THINGS THAT ACTUALLY HAVE TO BE TRUE ──────────────────────────────────────────────────────
# Both were measured on 2026-08-10, each after the previous "fix" failed its own verification:
#
# 1. THE BINARY MUST BE REALLY SIGNED. The installed agent was **linker-signed** ad-hoc
#    (`flags=0x20002(adhoc,linker-signed)`), and `codesign --verify` calls that "code object is not signed
#    at all". Such a binary satisfies NO code requirement, so tccd rejects the grant no matter what is
#    stored against it — the first repair wrote a perfectly good cdhash and changed nothing. Re-signing it
#    properly ad-hoc (`codesign --force --sign -`) is what makes any requirement evaluable.
#
# 2. THE REQUIREMENT MUST BE THE BINARY'S **DESIGNATED REQUIREMENT**, not a cdhash we compose. The agent
#    is a FAT binary, and each slice has its own cdhash; `codesign -v -R 'cdhash H"<arm64>"'` FAILS
#    against the fat file. The designated requirement is the `or` of both slices —
#      cdhash H"<arm64>" or cdhash H"<x86_64>"
#    — which is exactly the shape the original 2026-07-28 grant had, and the only one that matches. So ask
#    codesign for it rather than building one; a hand-built single-slice requirement is the failure mode
#    this comment exists to stop someone re-introducing.
#
# Refuses unless SIP is off. Backs up the database before every write. Verifies before it claims anything.
set -euo pipefail

DB='/Library/Application Support/com.apple.TCC/TCC.db'
SERVICES=(kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServiceSystemPolicyAllFiles)

csrutil status | grep -qi disabled \
  || { echo "SIP is ENABLED in this guest — refusing; the TCC write cannot work" >&2; exit 3; }

BIN="$(ls -1 /opt/homebrew/Cellar/tart-guest-agent/*/bin/tart-guest-agent 2>/dev/null | head -1)"
[ -n "$BIN" ] || { echo "no tart-guest-agent binary found in the guest" >&2; exit 3; }
echo "agent binary: $BIN"

# (1) Make the signature evaluable. Only when it is not already — re-signing changes the cdhash, so doing
# it unconditionally would invalidate a grant that was working and make this script its own worst enemy.
if codesign --verify "$BIN" >/dev/null 2>&1; then
  echo "signature: already verifiable — left alone"
else
  echo "signature: linker-signed only (no requirement can match it) — re-signing ad-hoc"
  sudo -n codesign --force --sign - --preserve-metadata=entitlements "$BIN" 2>&1 | sed 's/^/  /'
  codesign --verify "$BIN" >/dev/null 2>&1 \
    || { echo "still unverifiable after re-signing — stopping before touching TCC" >&2; exit 3; }
fi

# (2) Take the requirement from codesign, never from us.
DR="$(codesign -d -r- "$BIN" 2>/dev/null | sed -n 's/^# designated => //p')"
[ -n "$DR" ] || { echo "could not read a designated requirement from $BIN" >&2; exit 3; }
echo "requirement: $DR"
printf '%s\n' "$DR" | csreq -r- -b /tmp/vm-a11y-req.bin

# Prove the binary satisfies what we are about to store. Without this the script can "succeed" into a
# database row that tccd will silently ignore — the exact failure that made this bug invisible for a day.
codesign -v -R /tmp/vm-a11y-req.bin "$BIN" >/dev/null 2>&1 \
  || { echo "the binary does NOT satisfy its own designated requirement — refusing to write it" >&2; exit 3; }
echo "requirement verified against the binary"

HEX="$(xxd -p /tmp/vm-a11y-req.bin | tr -d '\n')"
[ -n "$HEX" ] || { echo "csreq produced an empty requirement blob" >&2; exit 3; }

BAK="$DB.bak-$(date +%Y%m%dT%H%M%S)"
sudo -n cp "$DB" "$BAK"
echo "backed up -> $BAK"

for SVC in "${SERVICES[@]}"; do
  if [ "$(sudo -n sqlite3 "$DB" "select count(*) from access where service='$SVC' and client='$BIN';")" = "0" ]; then
    # No row at all (a re-cloned VM): create one. Explicit column list so a schema change fails loudly
    # rather than silently writing a row tccd will ignore.
    sudo -n sqlite3 "$DB" \
      "insert into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified)
       values ('$SVC', '$BIN', 1, 2, 4, 1, X'$HEX', 0, strftime('%s','now'));"
    echo "  $SVC: inserted"
  else
    # The row already read auth_value = 2 throughout the outage; it is the stale REQUIREMENT that made
    # tccd ignore it. That is why "the grant is there and allowed" was such a convincing red herring.
    sudo -n sqlite3 "$DB" \
      "update access set csreq = X'$HEX', auth_value = 2, auth_reason = 4,
         last_modified = strftime('%s','now')
       where service = '$SVC' and client = '$BIN';"
    echo "  $SVC: updated"
  fi
done

# tccd caches its decisions in memory; without this the repair would only take effect on the next boot.
sudo -n killall tccd 2>/dev/null || true
sleep 3
echo "tccd restarted"
