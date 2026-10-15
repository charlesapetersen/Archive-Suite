#!/usr/bin/env bash
# vm-zotero.sh — a real Zotero for the Notes integration journey (W40.d10). Runs INSIDE the Tart GUI VM
# (`tart exec archive-gui-runner bash "/Volumes/My Shared Files/repo/ArchiveNotes/scripts/vm-zotero.sh" start`),
# never on the host: it installs and launches a GUI app, and the host display is the owner's.
#
#   install  download the current Zotero release into ~/Applications (once; the VM disk keeps it)
#   start    install if absent, give it a profile with the local API switched on, launch it, wait for its
#            HTTP server, and seed the journey's item if the library lacks it. Prints `ZOTERO_KEY=<key>`.
#   stop     quit Zotero
#
# Why a profile is written by hand: the Notes client reads items through Zotero's local API
# (`/api/users/0/…` on 127.0.0.1:23119), which ships switched off ("Allow other applications on this
# computer to communicate with Zotero" in Settings ▸ Advanced). The pref is
# `extensions.zotero.httpServer.localAPI.enabled`; a `user.js` in the profile sets it before first launch.
#
# The seeded item goes in through `/connector/saveItems`, the endpoint the browser connector uses: the local
# API is read-only, and a library with no account has no web API to write through. Its fields are fixed so
# the journey can assert on what Zotero itself returns.
set -euo pipefail

ZAPP="$HOME/Applications/Zotero.app"
ZSUP="$HOME/Library/Application Support/Zotero"
PORT=23119
TITLE="Notes on the Analytical Engine (W40.d10 seed)"

log() { printf '[vm-zotero] %s\n' "$*" >&2; }

install_zotero() {
  [ -d "$ZAPP" ] && return 0
  log "downloading the Zotero release…"
  local dmg="$HOME/Downloads/Zotero.dmg" mnt
  curl -sSL -m 600 -o "$dmg" "https://www.zotero.org/download/client/dl?channel=release&platform=mac"
  mnt="$(mktemp -d /tmp/zmnt.XXXX)"
  hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$dmg"
  mkdir -p "$HOME/Applications"
  ditto "$mnt/Zotero.app" "$ZAPP"
  hdiutil detach -quiet "$mnt"
  rm -f "$dmg"
}

ensure_profile() {
  if [ ! -f "$ZSUP/profiles.ini" ]; then
    mkdir -p "$ZSUP/Profiles/w40d10.default"
    printf '[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/w40d10.default\nDefault=1\n' \
      > "$ZSUP/profiles.ini"
  fi
  local prof
  prof="$(sed -nE 's/^Path=(.*)$/\1/p' "$ZSUP/profiles.ini" | head -1)"
  mkdir -p "$ZSUP/$prof"
  cat > "$ZSUP/$prof/user.js" <<'JS'
user_pref("extensions.zotero.httpServer.enabled", true);
user_pref("extensions.zotero.httpServer.localAPI.enabled", true);
user_pref("extensions.zotero.firstRun2", false);
user_pref("extensions.zotero.firstRunGuidance", false);
JS
}

wait_http() {
  local i
  for i in $(seq 1 90); do
    curl -s -m 2 "http://127.0.0.1:$PORT/connector/ping" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

seed_key() {
  # The local API's quick search matches titles; the newest match wins if a run seeded twice.
  curl -s -m 10 "http://127.0.0.1:$PORT/api/users/0/items?q=W40.d10&format=keys" | head -1
}

seed_item() {
  local key; key="$(seed_key || true)"
  if [ -z "$key" ]; then
    log "seeding the journey item…"
    curl -s -m 20 -X POST "http://127.0.0.1:$PORT/connector/saveItems" \
      -H 'Content-Type: application/json' -H 'X-Zotero-Connector-API-Version: 3' \
      -d '{"uri":"https://example.org/w40-d10","items":[{"itemType":"book","title":"'"$TITLE"'",
           "creators":[{"firstName":"Ada","lastName":"Lovelace","creatorType":"author"}],
           "date":"1843","publisher":"Richard and John E. Taylor","place":"London","id":"w40d10"}]}' \
      -o /dev/null -w '[vm-zotero] saveItems HTTP %{http_code}\n' >&2
    local i; for i in $(seq 1 20); do key="$(seed_key || true)"; [ -n "$key" ] && break; sleep 1; done
  fi
  [ -n "$key" ] || { log "the seed item never appeared in the local API"; return 1; }
  echo "ZOTERO_KEY=$key"
}

case "${1:-start}" in
  install) install_zotero ;;
  start)
    install_zotero
    if ! curl -s -m 2 "http://127.0.0.1:$PORT/connector/ping" >/dev/null 2>&1; then
      ensure_profile
      open -a "$ZAPP"
      wait_http || { log "Zotero's HTTP server never answered on $PORT"; exit 1; }
    fi
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/users/0/items?limit=1")"
    [ "$code" = 200 ] || { log "local API answered HTTP $code (is localAPI.enabled set?)"; exit 1; }
    seed_item
    ;;
  stop) osascript -e 'tell application id "org.zotero.zotero" to quit' >/dev/null 2>&1 || pkill -x zotero || true ;;
  *) echo "usage: vm-zotero.sh install|start|stop" >&2; exit 2 ;;
esac
