#!/bin/bash
# repro-s044-names.sh — W49.proc-s044-reproduce: suspect S-044 (verification/SUSPECTS.md), "the cost estimate leaves
# out the names call". Two real Process Files runs through `startProcessing` (PROCESSFILES_TESTMODE), Automatic
# tagging, sidecars on, on six synthetic scratch photos, against the stand-in gateway (scripts/fake_gateway.py) on
# 127.0.0.1 — $0, no network. The stand-in reads every document as a "Letter". One run's output folder carries a
# collection layer ranking names (PROCESSFILES_PRIORITIES, as the collection interview writes it), the other none.
#
#   ./scripts/repro-s044-names.sh
#
# Each run prints its calls by kind, from the stand-in's log, beside the terms of the estimate the driver wrote with
# the app's own CostEstimator (estimate.txt), and a verdict line `CASE <name>: ...`. It never reads or writes anything
# outside a fresh mktemp directory.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (macOS/build/DD)" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ap-s044.XXXXXX")
echo "scratch: $WORK"
source "$REPO/scripts/test-child.sh"
processor_test_init "$WORK"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')

mkdir -p "$WORK/in"
for i in 1 2 3 4 5 6; do
    magick -size 600x400 xc:white -fill black -draw "rectangle 40,40 $((100 + i * 60)),$((80 + i * 30))" "$WORK/in/p$i.jpg"
done

run_case() {   # name env...
    local name="$1"; shift
    local out="$WORK/$name"
    mkdir -p "$out"
    python3 "$REPO/scripts/fake_gateway.py" "$PORT" "$out/gateway.log" 500 stand-in-key &
    local gw=$!
    sleep 1
    local kv vars=(ARCHIVEPROC_HEADLESS=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup"
        PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key
        "PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in
        PROCESSFILES_GATEWAY_IN_PER_1M=2 PROCESSFILES_GATEWAY_OUT_PER_1M=10
        PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=100 PROCESSFILES_TAGGING=automatic
        "PROCESSFILES_TESTIN=$WORK/in" "PROCESSFILES_TESTOUT=$out" "PROCESSFILES_TESTDONE=$out/DONE.txt"
        PROCESSFILES_MAXIMAGES=6 "$@")
    for kv in "${vars[@]}"; do export "$kv"; done
    processor_test_start pid "$BIN" >"$out/app.log" 2>&1
    for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
    local i
    for i in $(seq 1 120); do [ -f "$out/DONE.txt" ] && break; sleep 1; done
    processor_test_stop "$pid"
    kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
    rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
    local rd; rd=$(ls -d "$out"/run-* 2>/dev/null | head -1)
    echo "── $name   driver: $(cat "$out/DONE.txt" 2>/dev/null || echo '(timed out)')"
    [ -n "$rd" ] && echo "  status: $(cat "$rd/status.txt" 2>/dev/null)"
    [ -n "$rd" ] && echo "  estimate: $(cat "$rd/estimate.txt" 2>/dev/null)"
    python3 - "$out/gateway.log" "$rd" "$name" <<'EOF'
import collections, glob, json, os, sys
log, rd, name = sys.argv[1:4]
kinds = collections.Counter()
for line in open(log, encoding='utf-8'):
    kind, _, _, head = (line.rstrip('\n').split('\t') + ['', '', ''])[:4]
    if kind == 'other':
        kind = ('names' if head.startswith('You are extracting correspondence metadata') else
                'dating-trace' if 'You are dating a document' in head else
                'dating-image' if 'These are the first pages of one archival document' in head else
                'item-fields' if 'You are labelling catalogue fields' in head else 'other: ' + head[:50])
    kinds[kind] += 1
print('  calls by kind: ' + ', '.join(f'{k} {n}' for k, n in sorted(kinds.items())))
est = dict(p.split('=', 1) for p in open(os.path.join(rd, 'estimate.txt')).read().strip().split('\t'))
terms = [k for k in ('ocr', 'classification', 'tagging', 'dating', 'itemFields', 'names') if k in est]
named = 0
for p in glob.glob(os.path.join(rd, '**', '*.json'), recursive=True):
    try:
        o = json.load(open(p))
    except Exception:
        continue
    if isinstance(o, dict) and 'entities' in o:
        named += 1
print(f'  sidecars with an entities object: {named}')
print(f'CASE {name}: {kinds["names"]} names call(s) of {sum(kinds.values())}; the estimate prices '
      f'{", ".join(terms)} and has {"a names term" if any("name" in k.lower() or "entit" in k.lower() for k in est) else "no names term"}'
      f' (total {est.get("total")})')
EOF
}

run_case s044-names-ranked PROCESSFILES_PRIORITIES=names,reading,dates,findingDocuments
run_case s044-names-unranked
