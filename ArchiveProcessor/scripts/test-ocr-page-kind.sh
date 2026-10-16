#!/bin/bash
# Key-free ($0), no-network contract for W41.app-page-kind: each page's kind on this Mac, and the reader it chooses.
# Runs OCRPageKindTestDriver headless: the bundled classifier weights, routing from the kind to the model guide's first
# runnable pick, the file list's plan, the estimate, the real performOCRCall over an injected HTTP transport, the run
# history and a render guard. Keys come from a test seam, never the Keychain; every output is in one temporary
# directory; never the corpus.
#
# Parity with the bench: when the bench's private cache is on this Mac (~/Library/Caches/ArchiveSuiteRehearsal/
# kind-classifier, W41.bench-kind-classifier), the app also classifies the bench's own labelled pages and this script
# checks it calls the same kind as the bench's model on the bench's measured signals. Only ids and figures are printed.
# Skip it with PAGE_KIND_PARITY=0.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
cache="${KIND_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal/kind-classifier}"
parity=()
if [ "${PAGE_KIND_PARITY:-1}" = 1 ] && [ -f "$cache/signals-list.tsv" ] && [ -f "$cache/featureprints.tsv" ]; then
    parity=(OCRPAGEKIND_PARITY_LIST="$cache/signals-list.tsv" OCRPAGEKIND_PARITY_OUT="$work/parity.tsv")
fi

env ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    OCRPAGEKIND_TEST=1 OCRPAGEKIND_TEST_OUT="$report" ${parity[@]+"${parity[@]}"} \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

wait_for_test_report "$report" "$log" "$pid" "OCR-page-kind" "OCRPAGEKIND" 600
cat "$report"
grep -q '^ALL PASS$' "$report"

if [ ${#parity[@]} -eq 0 ]; then
    echo "PARITY SKIPPED: no bench cache at $cache"
    exit 0
fi
/usr/bin/python3 - "$cache" "$work/parity.tsv" segbench-results/kind-classifier-model.json <<'EOF'
import json, math, sys
cache, app_path, model_path = sys.argv[1:]
model = json.load(open(model_path))
def rows(p):
    lines = open(p).read().splitlines()
    head = lines[0].split('\t')
    return {r[0]: dict(zip(head, r)) for r in (l.split('\t') for l in lines[1:]) if r}
sig = rows(f'{cache}/signals.tsv')
fp = {}
for line in open(f'{cache}/featureprints.tsv'):
    pid, _, v = line.rstrip('\n').partition('\t')
    fp[pid] = [float(x) for x in v.split(',')]
def num(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if v != v else v
def probs(m, x):
    s = list(m['b'])
    for i, xi in enumerate(x):
        z = (xi - m['mean'][i]) / m['sd'][i]
        for k in range(len(s)):
            s[k] += z * m['W'][i][k]
    top = max(s); e = [math.exp(v - top) for v in s]; t = sum(e)
    return [v / t for v in e]
app = {}
for line in open(app_path):
    f = line.rstrip('\n').split('\t')
    app[f[0]] = f
same = n = unread = 0
worst = 0.0
for pid, a in sorted(app.items()):
    if len(a) < 3:
        unread += 1; continue
    s = sig.get(pid)
    if not s or pid not in fp:
        continue
    scal = [num(s[c]) for c in ('harmonic', 'periodic', 'conf', 'text_px', 'lines')]
    h = probs(model['hand'], scal + fp[pid])
    f = probs(model['form'], [num(s['table_share']), num(s['table_cells'])] + scal + fp[pid])
    kind = 'forms' if f[1] > f[0] else model['hand']['classes'][h.index(max(h))]
    n += 1
    same += kind == a[1]
    worst = max(worst, max(abs(x - float(y)) for x, y in zip(h + [f[1]], a[3:7])))
    if kind != a[1]:
        print(f'DIFFER {pid}: bench {kind}, app {a[1]} ({a[2]})')
print(f'PARITY: the app calls the bench\'s kind on {same} of {n} pages; largest probability difference {worst:.4f}; {unread} unread')
# Vision is the same OS model on the same Mac, so the calls should agree; allow one page in fifty for a borderline
# probability that a re-measured signal tips.
sys.exit(0 if n >= 100 and same >= n - max(1, n // 50) and unread == 0 else 1)
EOF
