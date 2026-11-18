#!/bin/bash
# journey-bulk-ocr.sh — W40.d1: bulk OCR on a ground-truth collection, through the real Process Files pipeline,
# in the Tart VM (never on this Mac's screen), then checked against the truth CSV and SPEC/tag-format.md.
#
#   ./scripts/journey-bulk-ocr.sh --route vision [--max N]            free: Apple Vision, No tagging (plumbing)
#   ./scripts/journey-bulk-ocr.sh --route fake [--max N] [--cap USD] [--completion TOKENS]
#                                     free: the gateway route against scripts/fake_gateway.py in the guest
#                                     (the meter, the cap, the key hand-over and Automatic tagging's tags)
#   ./scripts/journey-bulk-ocr.sh --route gateway --paid [--cap USD]  the Stanford gateway, Gemini 3.7 Flash,
#                                                                     Automatic tagging (the journey itself)
#   ./scripts/journey-bulk-ocr.sh --route anthropic|mistral --paid --max N   W40.d3: a direct provider's own
#                                     client (Keychain key), No tagging, at most 5 photos, a few cents
#
# The box is the W40.c1 rehearsal copy (verification/rehearsal.md; default RG 165 — War Department, a held-out
# test box: score on it, never tune on it). The app's own estimator states the cost in the run's estimate.txt
# and the driver refuses a run whose estimate is over the cap; its meter reads every reply's usage and stops
# sending once the cap is spent (spend.tsv). The gateway key is read from the Keychain (account Gateway) with
# /usr/bin/security, or from W40D1_KEY_FILE, and reaches the guest only as a 0600 file deleted after the run.
# Output: verification/evidence/processor/ gets nothing automatically; the run lands in
# ~/.tart-mirror/vm-artifacts/processor/bulk-ocr and the checker's JSON beside it.
set -uo pipefail
cd "$(dirname "$0")/.."
APPDIR="$PWD"; REPO="$(cd .. && pwd)"
ROUTE=""; PAID=0; MAX=1000; CAP="5.00"
COLLECTION="${W40D1_COLLECTION:-RG 165 — War Department}"
while [ $# -gt 0 ]; do
  case "$1" in
    --route) ROUTE="$2"; shift 2 ;;
    --paid) PAID=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    --cap) CAP="$2"; shift 2 ;;
    --completion) export W40D1_FAKE_COMPLETION="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
SET="${REHEARSAL_DIR:-$HOME/Library/Caches/ArchiveSuiteRehearsal}/processor-set/$COLLECTION"
[ -f "$SET/Ground Truth.csv" ] || { echo "no rehearsal box at $SET (python3 ArchiveProcessor/scripts/make-processor-rehearsal.py)"; exit 1; }
PAGES="$(find "$SET" -maxdepth 1 -iname '*.jpg' | wc -l | tr -d ' ')"
[ "$PAGES" -gt "$MAX" ] && PAGES="$MAX"

export PROCESSOR_JOURNEY=bulkocr W40D1_COLLECTION="$COLLECTION" W40D1_MAXIMAGES="$MAX"
KEYDIR=""
trap '[ -n "$KEYDIR" ] && rm -rf "$KEYDIR"' EXIT
trap 'exit 143' TERM HUP; trap 'exit 130' INT   # so a kill still runs the EXIT trap that deletes the key
# A long run prints a line a minute; this only keeps the VM lane's stall guard from ending a slow paid run early.
export TART_TEST_STALL="${TART_TEST_STALL:-3600}"
case "$ROUTE" in
  vision)
    export W40D1_PROVIDER="Apple Vision" W40D1_TAGGING=none MODE=none
    echo "route: Apple Vision on $PAGES pages, No tagging — \$0" ;;
  fake)
    export W40D1_FAKE_GATEWAY=1 W40D1_GATEWAY_URL="http://127.0.0.1:18471/v1" W40D1_GATEWAY_MODEL="gemini-3.7-flash" \
      W40D1_GATEWAY_IN_PER_1M=0.75 W40D1_GATEWAY_OUT_PER_1M=3.75 W40D1_GATEWAY_UPSTREAM=Gemini \
      W40D1_METER=1 W40D1_CAP_USD="$CAP" W40D1_TAGGING=automatic MODE=automatic
    KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"; ( umask 077; echo "stand-in-key" > "$KEYDIR/key" )
    export W40D1_KEY_FILE="$KEYDIR/key"
    echo "route: the stand-in gateway in the guest on $PAGES pages, Automatic tagging, metered to a cap of \$$CAP — \$0" ;;
  gateway)
    # Gemini 3.7 Flash on the gateway: \$0.75 in / \$3.75 out per 1M tokens (segbench item_fields_retruth.py).
    awk -v c="$CAP" 'BEGIN { exit !(c > 0 && c <= 7) }' || { echo "--cap must be above 0 and at most 7 (the \$7 rule)"; exit 2; }
    echo "route: the Stanford gateway, gemini-3.7-flash, Automatic tagging, $PAGES pages"
    # The app's estimator prices a Gemini page at 40,000 image tokens, about \$0.034 a page with tagging (the \$0
    # stand-in run, 2026-11-18); the meter's spend.tsv is the real figure.
    echo "app estimate: about \$$(awk -v n="$PAGES" 'BEGIN { printf "%.2f", n * 0.0341 }'); the driver refuses above the cap of \$$CAP and stops sending at it"
    [ "$PAID" = 1 ] || { echo "not run: add --paid to spend it"; exit 0; }
    export W40D1_GATEWAY_URL="https://aiapi-prod.stanford.edu/v1" W40D1_GATEWAY_MODEL="gemini-3.7-flash" \
      W40D1_GATEWAY_IN_PER_1M=0.75 W40D1_GATEWAY_OUT_PER_1M=3.75 W40D1_GATEWAY_UPSTREAM=Gemini \
      W40D1_METER=1 W40D1_CAP_USD="$CAP" W40D1_TAGGING=automatic MODE=automatic
    if [ -z "${W40D1_KEY_FILE:-}" ]; then
      KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"
      ( umask 077; /usr/bin/security find-generic-password -s com.archiveprocessor.app -a Gateway -w > "$KEYDIR/key" ) \
        || { echo "could not read the Gateway key (ops/autonomous/fix-keychain-access.sh)"; exit 1; }
      export W40D1_KEY_FILE="$KEYDIR/key"
    fi ;;
  anthropic|mistral)
    # W40.d3: a direct provider through the app's own client, No tagging, on a few photos (--max, at most 5). The
    # cheapest built-in model: Claude Sonnet 4.6 ($3 in / $15 out per 1M, about $0.02 a photo) or Mistral OCR
    # (about $0.001 a page). Not metered: the page count is the bound, and the app's estimate is in estimate.txt.
    [ "$MAX" -le 5 ] || { echo "--max must be 5 or fewer for a direct-provider route"; exit 2; }
    if [ "$ROUTE" = anthropic ]; then ACCOUNT=Anthropic MODEL_ID=claude-sonnet-4-6 PER=0.02
    else ACCOUNT=Mistral MODEL_ID=mistral-ocr-latest PER=0.001; fi
    echo "route: $ACCOUNT direct, $MODEL_ID, No tagging, $PAGES pages, about \$$(awk -v n="$PAGES" -v p="$PER" 'BEGIN { printf "%.3f", n * p }')"
    [ "$PAID" = 1 ] || { echo "not run: add --paid to spend it"; exit 0; }
    export W40D1_PROVIDER="$ACCOUNT" W40D1_MODEL="$MODEL_ID" W40D1_TAGGING=none MODE=none
    if [ -z "${W40D1_KEY_FILE:-}" ]; then
      KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"
      ( umask 077; /usr/bin/security find-generic-password -s com.archiveprocessor.app -a "$ACCOUNT" -w > "$KEYDIR/key" ) \
        || { echo "could not read the $ACCOUNT key (ops/autonomous/fix-keychain-access.sh)"; exit 1; }
      export W40D1_KEY_FILE="$KEYDIR/key"
    fi ;;
  *) echo "--route vision|fake|gateway|anthropic|mistral" >&2; exit 2 ;;
esac

ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}/processor"
"$REPO/ops/gui/vm-gui-runner.sh" processor xcuitest; rc=$?
[ -n "$KEYDIR" ] && rm -rf "$KEYDIR" && KEYDIR=""
grep -h '\[w40d1\] driver:' "$ART/xcuitest.log" 2>/dev/null | tail -1
[ -d "$ART/bulk-ocr" ] || { echo "no output came back from the guest (runner exit $rc)"; exit 1; }
python3 "$APPDIR/scripts/journey_bulk_ocr_check.py" "$ART/bulk-ocr" --truth "$SET/Ground Truth.csv" \
  --mode "$MODE" --json "$ART/bulk-ocr/check.json"
