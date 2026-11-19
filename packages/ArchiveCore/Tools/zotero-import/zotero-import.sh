#!/bin/bash
# Imports a CSL-JSON file with the installed Zotero's own importer and prints the Zotero items as JSON (import.js).
# Usage: zotero-import.sh <csl.json>. Needs Zotero 10 in /Applications (or $ZOTERO_APP) and node. Exit 3 when either
# is missing. Unpacks Zotero's omni.ja into a temporary folder and removes it; opens no window, touches no library.
set -euo pipefail
app="${ZOTERO_APP:-/Applications/Zotero.app}"
omni="$app/Contents/Resources/app/omni.ja"
node="$(command -v node || true)"
[ -z "$node" ] && [ -x /opt/homebrew/bin/node ] && node=/opt/homebrew/bin/node
[ -f "$omni" ] && [ -n "$node" ] || { echo "zotero-import: no Zotero or node here" >&2; exit 3; }
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
unzip -q "$omni" 'chrome/content/zotero/xpcom/translate/modules/utilities/*' -d "$tmp" 2>/dev/null || true
utils="$tmp/chrome/content/zotero/xpcom/translate/modules/utilities"
[ -f "$utils/utilities_item.js" ] || { echo "zotero-import: Zotero's utilities not found in $omni" >&2; exit 3; }
"$node" "$(dirname "$0")/import.js" "$utils" "$1"
