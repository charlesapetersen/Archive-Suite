#!/bin/bash
# test-smoke.sh — Unattended smoke test for Archive Processor.
#
# Runs with NO interaction (kick it off and walk away), and proves the load-bearing pieces work:
#   1. BUILD    — the macOS app compiles clean (0 errors).
#   2. LAUNCH   — it launches, shows a window, and doesn't crash; then quits.
#   3. OCR      — real OCR calls to each provider whose key is in the Keychain (Gemini + Mistral),
#                 on a few real Test Files images, asserting non-empty text comes back. Low cost
#                 (2 images x cheapest models). Uses the SAME request shapes as the app.
#   4. OUTPUT   — writes a timestamped PASS/FAIL report under .maintenance/test-results/ (gitignored).
#
# Keys are read from the app's Keychain (service com.archiveprocessor.app, account = provider name).
# The FIRST time, macOS pops a "security wants to use the … keychain" dialog — click "Always Allow"
# (this is the "log in with the Keychain credentials at the beginning" step). After that it never
# prompts again and runs fully unattended. To run headless with NO prompt at all (e.g. cron), export
# AP_GEMINI_KEY / AP_MISTRAL_KEY first and they win over the Keychain. Keys are never printed.
#
# It does NOT drive the Process Files GUI pipeline (review dialogs need interaction) — that's the
# Tier-2 GUI checklist in TESTING.md. Usage: ./scripts/test-smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
APPDIR="ArchiveProcessor"
APP="$APPDIR/build/DD/Build/Products/Debug/ArchiveProcessor.app"
KC_SERVICE="com.archiveprocessor.app"
OUT="$REPO/.maintenance/test-results"; mkdir -p "$OUT"
TS=$(date "+%Y%m%d-%H%M%S")
LOG="$OUT/smoke-$TS.log"
TMP=$(mktemp -d)
pass=0; fail=0
say(){ echo "$@" | tee -a "$LOG"; }
ok(){  pass=$((pass+1)); say "  ✓ PASS  $*"; }
no(){  fail=$((fail+1)); say "  ✗ FAIL  $*"; }

say "=== Archive Processor smoke test · $TS ==="
say "repo: $REPO"

# ---------- 1. BUILD ----------
say ""; say "[1/4] Build (Debug)…"
( cd "$APPDIR" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build ) \
   > "$TMP/build.log" 2>&1
if grep -q "BUILD SUCCEEDED" "$TMP/build.log"; then
  w=$(grep -c ': warning:' "$TMP/build.log")
  ok "build succeeded (warnings: $w)"
else
  no "build failed — see $TMP/build.log"; tail -20 "$TMP/build.log" >> "$LOG"
fi

# ---------- 2. LAUNCH ----------
say ""; say "[2/4] Launch smoke…"
if [ -d "$APP" ]; then
  pkill -x ArchiveProcessor 2>/dev/null; sleep 1
  open "$APP"; sleep 5
  if pgrep -x ArchiveProcessor >/dev/null; then
    win=$(osascript -e 'tell application "System Events" to tell (first process whose name is "ArchiveProcessor") to return name of windows' 2>/dev/null)
    [ -n "$win" ] && ok "launched, window: $win" || no "launched but no window found"
    osascript -e 'quit app "ArchiveProcessor"' 2>/dev/null; sleep 1; pkill -x ArchiveProcessor 2>/dev/null
  else
    no "app did not stay running (crash on launch?)"
  fi
else
  no "no built .app to launch (build step failed)"
fi

# ---------- 3. OCR (real, low cost) ----------
say ""; say "[3/4] Real OCR via Keychain keys (cheapest models, 2 images)…"
# Curated inputs: first 2 JPEGs from a text-heavy collection, downscaled to keep cost/size low.
# (macOS ships bash 3.2 — no `mapfile`/`readarray`; build the array with a read loop.)
IMGS=()
while IFS= read -r f; do IMGS+=("$f"); done < <(find "$REPO/Test Files/Ground Truth Segmentation/Herrnstein" -iname '*.jpg' 2>/dev/null | sort | head -2)
if [ ${#IMGS[@]} -eq 0 ]; then
  while IFS= read -r f; do IMGS+=("$f"); done < <(find "$REPO/Test Files/Herrnstein" -iname '*.jpg' 2>/dev/null | sort | head -2)
fi
if [ ${#IMGS[@]} -eq 0 ]; then no "no Test Files images found for OCR"; else
  i=0; for src in "${IMGS[@]}"; do i=$((i+1)); sips -Z 1100 "$src" --out "$TMP/img$i.jpg" >/dev/null 2>&1; done

  ocr_check(){  # $1=provider label  $2=1|0 non-empty text
    if [ "$2" = 1 ]; then ok "$1 returned OCR text"; else no "$1 returned NO text"; fi
  }
  # Gemini (account "Gemini"), cheapest model. Env override wins over Keychain (headless).
  GKEY="${AP_GEMINI_KEY:-$(security find-generic-password -s "$KC_SERVICE" -a "Gemini" -w 2>/dev/null)}"
  if [ -n "$GKEY" ]; then
    for n in 1 2; do
      [ -f "$TMP/img$n.jpg" ] || continue
      python3 -c "import base64,json,sys;d=base64.b64encode(open('$TMP/img$n.jpg','rb').read()).decode();json.dump({'contents':[{'parts':[{'inline_data':{'mime_type':'image/jpeg','data':d}},{'text':'Transcribe all text in this image verbatim.'}]}]},open('$TMP/g$n.json','w'))"
      code=$(curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=$GKEY" -H 'Content-Type: application/json' --data @"$TMP/g$n.json" -o "$TMP/gr$n.json" -w '%{http_code}')
      chars=$(python3 -c "import json;j=json.load(open('$TMP/gr$n.json'));c=j.get('candidates');print(len(''.join(p.get('text','') for p in c[0]['content']['parts'])) if c else 0)" 2>/dev/null || echo 0)
      say "    gemini-2.5-flash-lite img$n: HTTP $code, $chars chars"
      ocr_check "Gemini (gemini-2.5-flash-lite) img$n" "$([ "$code" = 200 ] && [ "${chars:-0}" -gt 20 ] && echo 1 || echo 0)"
    done
  else
    say "    (no Gemini key in Keychain — skipping)"
  fi
  # Mistral (account "Mistral"), OCR endpoint. Env override wins over Keychain (headless).
  MKEY="${AP_MISTRAL_KEY:-$(security find-generic-password -s "$KC_SERVICE" -a "Mistral" -w 2>/dev/null)}"
  if [ -n "$MKEY" ]; then
    for n in 1 2; do
      [ -f "$TMP/img$n.jpg" ] || continue
      python3 -c "import base64,json;d=base64.b64encode(open('$TMP/img$n.jpg','rb').read()).decode();json.dump({'model':'mistral-ocr-latest','document':{'type':'image_url','image_url':'data:image/jpeg;base64,'+d}},open('$TMP/m$n.json','w'))"
      code=$(curl -s -X POST "https://api.mistral.ai/v1/ocr" -H "Authorization: Bearer $MKEY" -H 'Content-Type: application/json' --data @"$TMP/m$n.json" -o "$TMP/mr$n.json" -w '%{http_code}')
      chars=$(python3 -c "import json;j=json.load(open('$TMP/mr$n.json'));p=j.get('pages',[]);print(len('\n'.join(x.get('markdown','') for x in p)) if p else 0)" 2>/dev/null || echo 0)
      say "    mistral-ocr-latest img$n: HTTP $code, $chars chars"
      ocr_check "Mistral (mistral-ocr-latest) img$n" "$([ "$code" = 200 ] && [ "${chars:-0}" -gt 20 ] && echo 1 || echo 0)"
    done
  else
    say "    (no Mistral key in Keychain — skipping)"
  fi
fi

# ---------- 4. REPORT ----------
say ""; say "[4/4] Result: $pass passed, $fail failed"
rm -rf "$TMP"
say "Full log: $LOG"
[ "$fail" -eq 0 ] && say "SMOKE TEST: PASS ✅" || say "SMOKE TEST: FAIL ❌ ($fail)"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
