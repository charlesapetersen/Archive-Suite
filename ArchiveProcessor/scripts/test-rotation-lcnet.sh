#!/bin/bash
# W46.rotation-default: the app's bundled PP-LCNet (RotationLCNet.swift + PPLCNetDocOri.mlpackage) against the
# bench's PaddleX answers on the same turned pages (W46.rotation-routes: the 96 and six public strata, 864 turns;
# W46.rotation-heldout: 119 owner pages, 476 turns), and the free agreement rule with the shipped Vision answers.
# Free and headless; the pages are read-only and stay in the rehearsal cache. Fails under 98% agreement.
set -euo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
cache="$HOME/Library/Caches/ArchiveSuiteRehearsal/rotation-routes"
[ -f "$cache/answers/paddle.jsonl" ] || { echo "SKIP: no bench answers in $cache" >&2; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun coremlcompiler compile "$PWD/macOS/Sources/ArchiveProcessor/Resources/PPLCNetDocOri.mlpackage" "$work" >/dev/null
swiftc -parse-as-library -O \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionQueue.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/RotationLCNet.swift" \
    "$PWD/scripts/rotation-lcnet-headless.swift" -o "$work/rotation-lcnet"
for set in main heldout; do
    pages="$cache/pages.jsonl"; [ "$set" = heldout ] && pages="$cache/heldout/pages.jsonl"
    /usr/bin/python3 -c 'import json,sys
for l in open(sys.argv[1]):
    p=json.loads(l); print(p["id"]+"\t"+p["path"])' "$pages" > "$work/$set.tsv"
    "$work/rotation-lcnet" "$work/PPLCNetDocOri.mlmodelc" "$work/$set.tsv" > "$work/$set.jsonl"
done
/usr/bin/python3 - "$cache/answers" "$work" <<'PY'
import json, sys
ans, work = sys.argv[1:]
def load(p): return {(r['id'], r['turn']): r.get('found') for r in map(json.loads, open(p)) if 'turn' in r}
ok = True
for name, pre in (('the 96 + six public strata', ''), ('held out', 'heldout-')):
    app = load(f'{work}/{"heldout" if pre else "main"}.jsonl')
    bench, vision = load(f'{ans}/{pre}paddle.jsonl'), load(f'{ans}/{pre}vision.jsonl')
    # A page whose image the cache no longer holds (rebuildable public images are cleared) is reported, not scored.
    gone = sorted({r['id'] for r in map(json.loads, open(f'{work}/{"heldout" if pre else "main"}.jsonl')) if 'error' in r})
    if gone: print(f'{name}: {len(gone)} pages not in the cache, not scored: {" ".join(gone)}')
    keys = sorted(k for k in bench if k[0] not in gone)
    same = sum(app.get(k) == bench[k] for k in keys)
    print(f'{name}: app PP-LCNet equals the bench on {same}/{len(keys)} turns ({100 * same / len(keys):.1f}%)')
    for k in keys:
        if app.get(k) != bench[k]: print(f'  differs: {k[0]} turned {k[1]}: app {app.get(k)}, bench {bench[k]}')
    ok &= same >= 0.98 * len(keys)
    # The free rule, each detector as the app runs it, as stored: right / wrong / flagged turns, and pages.
    pages = {}
    for k in keys:
        v, p, truth = vision.get(k), app.get(k), (360 - k[1]) % 360
        out = 'flag' if v is None or v != p else ('right' if v == truth else 'wrong')
        pages.setdefault(k[0], []).append(out)
    turns = [o for os in pages.values() for o in os]
    wrong_pages = sum('wrong' in os for os in pages.values())
    flagged_pages = sum('flag' in os and 'wrong' not in os for os in pages.values())
    print(f'  free rule: turns right {turns.count("right")}, wrong {turns.count("wrong")}, flagged {turns.count("flag")}'
          f' of {len(turns)}; pages wrong {wrong_pages}, flagged {flagged_pages} of {len(pages)}')
print('ALL PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PY
