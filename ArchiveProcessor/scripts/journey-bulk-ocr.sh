#!/bin/bash
# journey-bulk-ocr.sh — W40.d1: bulk OCR on a ground-truth collection, through the real Process Files pipeline,
# in the Tart VM (never on this Mac's screen), then checked against the truth CSV and SPEC/tag-format.md.
#
#   ./scripts/journey-bulk-ocr.sh --route vision [--max N]            free: Apple Vision, No tagging (plumbing)
#   ./scripts/journey-bulk-ocr.sh --route fake [--max N] [--cap USD] [--completion TOKENS] [--fail-tags N,M]
#                                     free: the gateway route against scripts/fake_gateway.py in the guest
#                                     (the meter, the cap, the key hand-over and Automatic tagging's tags;
#                                     --fail-tags answers those tagging calls with a 500, W49.proc-fix-s042)
#   ./scripts/journey-bulk-ocr.sh --route gateway --paid [--cap USD]  the Stanford gateway, Gemini 3.7 Flash,
#                                                                     Automatic tagging (the journey itself)
#   ./scripts/journey-bulk-ocr.sh --route openrouter --paid [--max N] [--cap USD]   OpenRouter, Qwen3.8 Flash
#                                     (Alibaba), Automatic tagging, metered (the paid run, owner 2026-11-18)
#   ./scripts/journey-bulk-ocr.sh --route anthropic|mistral --paid --max N   W40.d3: a direct provider's own
#                                     client (Keychain key), No tagging, at most 5 photos, a few cents
#   ./scripts/journey-bulk-ocr.sh --route anthropic|mistral --batch [--cancel] --paid --max N   W40.d4: the same
#                                     through the provider's batch path (submit, poll, collect), half price;
#                                     --cancel presses Stop once the submission is journaled. Afterwards the
#                                     provider is asked what became of each batch ID (batch-status.txt)
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
ROUTE=""; PAID=0; MAX=1000; CAP="5.00"; BATCH=0; CANCEL=0
COLLECTION="${W40D1_COLLECTION:-RG 165 — War Department}"
while [ $# -gt 0 ]; do
  case "$1" in
    --route) ROUTE="$2"; shift 2 ;;
    --paid) PAID=1; shift ;;
    --batch) BATCH=1; shift ;;
    --cancel) CANCEL=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    --cap) CAP="$2"; shift 2 ;;
    --completion) export W40D1_FAKE_COMPLETION="$2"; shift 2 ;;
    --fail-tags) export W40D1_FAKE_TAG_FAIL="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
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
case "$ROUTE" in anthropic|mistral) ;; *) [ "$BATCH$CANCEL" = 00 ] || { echo "--batch is for --route anthropic|mistral"; exit 2; } ;; esac
[ "$CANCEL" = 1 ] && [ "$BATCH" = 0 ] && { echo "--cancel needs --batch"; exit 2; }
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
  openrouter)
    # Owner, 2026-11-18: the gateway's November budget is spent, so the journey runs on the cheapest route, Qwen3.8
    # Flash through OpenRouter (the app's catalog entry, pinned to Alibaba, max_price $0.15 in / $0.47 out per 1M).
    # OpenRouter's replies carry OpenAI-shaped usage, so the same meter prices them at that pinned ceiling.
    awk -v c="$CAP" 'BEGIN { exit !(c > 0 && c <= 7) }' || { echo "--cap must be above 0 and at most 7 (the \$7 rule)"; exit 2; }
    echo "route: OpenRouter, qwen/qwen3.8-flash (alibaba), Automatic tagging, $PAGES pages, metered to a cap of \$$CAP"
    [ "$PAID" = 1 ] || { echo "not run: add --paid to spend it (the app's estimate is in estimate.txt)"; exit 0; }
    export W40D1_PROVIDER=OpenRouter W40D1_MODEL="qwen/qwen3.8-flash" \
      W40D1_METER=1 W40D1_CAP_USD="$CAP" W40D1_TAGGING=automatic MODE=automatic
    if [ -z "${W40D1_KEY_FILE:-}" ]; then
      KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"
      ( umask 077; /usr/bin/security find-generic-password -s com.archiveprocessor.app -a OpenRouter -w > "$KEYDIR/key" ) \
        || { echo "could not read the OpenRouter key"; exit 1; }
      export W40D1_KEY_FILE="$KEYDIR/key"
    fi ;;
  anthropic|mistral)
    # W40.d3: a direct provider through the app's own client, No tagging, on a few photos (--max, at most 5). The
    # cheapest built-in model: Claude Sonnet 4.6 ($3 in / $15 out per 1M, about $0.02 a photo) or Mistral OCR
    # (about $0.001 a page). Not metered: the page count is the bound, and the app's estimate is in estimate.txt.
    [ "$MAX" -le 5 ] || { echo "--max must be 5 or fewer for a direct-provider route"; exit 2; }
    if [ "$ROUTE" = anthropic ]; then ACCOUNT=Anthropic MODEL_ID=claude-sonnet-4-6 PER=0.02
    else ACCOUNT=Mistral MODEL_ID=mistral-ocr-latest PER=0.001; fi
    [ "$BATCH" = 1 ] && PER="$(awk -v p="$PER" 'BEGIN { print p / 2 }')"   # batch is half price at both
    echo "route: $ACCOUNT direct$([ "$BATCH" = 1 ] && echo ", batch$([ "$CANCEL" = 1 ] && echo ' then Stop')"), $MODEL_ID, No tagging, $PAGES pages, about \$$(awk -v n="$PAGES" -v p="$PER" 'BEGIN { printf "%.3f", n * p }')"
    [ "$PAID" = 1 ] || { echo "not run: add --paid to spend it"; exit 0; }
    export W40D1_PROVIDER="$ACCOUNT" W40D1_MODEL="$MODEL_ID" W40D1_TAGGING=none MODE=none
    [ "$BATCH" = 1 ] && export W40D1_BATCH=1
    [ "$CANCEL" = 1 ] && export W40D1_BATCH_CANCEL=1
    if [ -z "${W40D1_KEY_FILE:-}" ]; then
      KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"
      ( umask 077; /usr/bin/security find-generic-password -s com.archiveprocessor.app -a "$ACCOUNT" -w > "$KEYDIR/key" ) \
        || { echo "could not read the $ACCOUNT key (ops/autonomous/fix-keychain-access.sh)"; exit 1; }
      export W40D1_KEY_FILE="$KEYDIR/key"
    fi ;;
  *) echo "--route vision|fake|gateway|openrouter|anthropic|mistral" >&2; exit 2 ;;
esac

ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}/processor"
"$REPO/ops/gui/vm-gui-runner.sh" processor xcuitest; rc=$?
# W40.d4: ask the provider, with the same key, what became of each batch the app submitted. The key goes to curl
# in a header file (never on a command line) and the reply is cut to the status fields.
if [ "$BATCH" = 1 ]; then
  ids="$(cat "$ART"/bulk-ocr/run-*/batch.tsv 2>/dev/null | sed -n 's/.*ids=\([^	]*\).*/\1/p' | head -1)"
  [ -n "$KEYDIR" ] || { KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"; }
  hdr="$KEYDIR/hdr"
  if [ "$ROUTE" = anthropic ]; then
    ( umask 077; printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "$(cat "$W40D1_KEY_FILE")" > "$hdr" ); base=https://api.anthropic.com/v1/messages/batches
  else
    ( umask 077; printf 'Authorization: Bearer %s\n' "$(cat "$W40D1_KEY_FILE")" > "$hdr" ); base=https://api.mistral.ai/v1/batch/jobs
  fi
  for id in ${ids//,/ }; do
    curl -s -H @"$hdr" "$base/$id" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k: d.get(k) for k in ("id","processing_status","request_counts","status","total_requests","succeeded_requests","failed_requests","cancelled_at","ended_at","completed_at") if k in d}))'
  done | tee "$ART/bulk-ocr/batch-status.txt"
  [ -n "$ids" ] || echo "no batch ID came back (batch.tsv)" | tee "$ART/bulk-ocr/batch-status.txt"
fi
[ -n "$KEYDIR" ] && rm -rf "$KEYDIR" && KEYDIR=""
grep -h '\[w40d1\] driver:' "$ART/xcuitest.log" 2>/dev/null | tail -1
[ -d "$ART/bulk-ocr" ] || { echo "no output came back from the guest (runner exit $rc)"; exit 1; }
python3 "$APPDIR/scripts/journey_bulk_ocr_check.py" "$ART/bulk-ocr" --truth "$SET/Ground Truth.csv" \
  --mode "$MODE" --json "$ART/bulk-ocr/check.json"
