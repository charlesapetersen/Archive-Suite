#!/bin/bash
# PAID proof of the W36 segmentation build (W36.seg-opt-proof): one small real folder through each route, end to
# end through the Processor's own window stage (box/folder confirmation, the windows, the flagged pass answered
# from the folder's truth, the skim). Runs SegmentationProofDriver headless: no window, no manifest save, the plan
# calibration put back afterwards. The folder's pages are COPIED to a temp directory first; nothing is written
# under Test Files/ (read only, as the bench reads it).
#
# Cost: the Anthropic and Gemini key routes at list price, about $0.36 and $0.08 for the default 21-page folder
# (the script prints its estimate from options.json before it runs); the plan route uses the signed-in `claude`'s
# plan (about 1% of a five-hour window) and no money. Without --paid it prints the estimate and stops.
#
#   scripts/test-segmentation-proof.sh [--paid] [--runs gemini:key,claude:key,claude:plan]
#                                      [--box Herrnstein --from 19 --to 39]
#
# No ChatGPT run: since W36.seg-opt-openai the mix is Claude + ChatGPT, and the driver has no OpenAI route (an
# OpenAI API key is not to be used; the subscription route is W36.seg-opt-siwc), so openai and mix are refused.
#
# Keys are read from the Keychain (service com.archiveprocessor.app, accounts Anthropic and Gemini) by
# /usr/bin/security, as the bench reads them, and passed to the app in its environment only.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

paid=0
runs="gemini:key,claude:key,claude:plan"
box="Herrnstein"; from=19; to=39
while [ $# -gt 0 ]; do
    case "$1" in
        --paid) paid=1 ;;
        --runs) runs="$2"; shift ;;
        --box) box="$2"; shift ;;
        --from) from="$2"; shift ;;
        --to) to="$2"; shift ;;
        *) echo "unknown argument $1" >&2; exit 64 ;;
    esac
    shift
done
case ",$runs" in *,openai:*|*,mix:*)
    echo "openai and mix need ChatGPT, which this proof has no route for (W36.seg-opt-siwc)." >&2; exit 64 ;;
esac

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

# The folder: its pages copied out, their cached Apple Vision text, and the truth labels.
/usr/bin/python3 - "$box" "$from" "$to" "$work" "$runs" <<'PY'
import json, shutil, sys
from pathlib import Path
sys.path.insert(0, "scripts/segbench")
import data
box, a, b, work, runs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]), sys.argv[5]
col = data.load(box, with_exif=False)
pages = [p for p in col.pages if a <= p.n <= b]
if len(pages) != b - a + 1:
    raise SystemExit(f"{box} {a}-{b}: found {len(pages)} pages")
(work / "pages").mkdir()
out = []
for p in pages:
    dst = work / "pages" / p.path.name
    shutil.copyfile(p.path, dst)
    t = data.ocr_cache_path(box, p.n)
    if not t.exists():
        raise SystemExit(f"no cached OCR text for {box} page {p.n}; run the bench's OCR first")
    out.append({"image": str(dst), "text": t.read_text(), "label": p.label})
(work / "manifest.json").write_text(json.dumps({"folder": f"{box} {a}-{b}", "pages": out}))

opts = json.loads(Path("segbench-results/options.json").read_text())
by_id = {x["id"]: x for x in opts["approaches"]}
total = 0.0
print(f"Folder: {box} pages {a}-{b} ({len(out)} pages, a development box: tuned on, not held out)")
for r in runs.split(","):
    approach, route = r.split(":")
    usd = 0.0
    for m, c in by_id[approach]["cost"]["per_model"].items():
        if m == "C" and route == "plan":
            continue
        usd += c["list_usd_per_1000_pages"] * len(out) / 1000
    total += usd
    print(f"  {r:14s} about ${usd:.2f} at list price" + ("; Claude by the plan, no money" if route == "plan" else ""))
print(f"Estimated total: ${total:.2f}")
PY

if [ "$paid" != 1 ]; then
    echo "Not run: pass --paid to spend it."
    exit 2
fi

key() { /usr/bin/security find-generic-password -s com.archiveprocessor.app -a "$1" -w 2>/dev/null || true; }
case "$runs" in *gemini*) gemini_key=$(key Gemini) ;; *) gemini_key="" ;; esac
case "$runs" in *claude:key*) anthropic_key=$(key Anthropic) ;; *) anthropic_key="" ;; esac

report="$work/result.txt"
json="${SEGMENTATION_PROOF_JSON:-$work/result.json}"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    SEGMENTATION_PROOF=1 SEGMENTATION_PROOF_MANIFEST="$work/manifest.json" SEGMENTATION_PROOF_RUNS="$runs" \
    SEGMENTATION_PROOF_OUT="$report" SEGMENTATION_PROOF_JSON="$json" \
    SEGMENTATION_PROOF_ANTHROPIC_KEY="$anthropic_key" SEGMENTATION_PROOF_GEMINI_KEY="$gemini_key" \
    "$bin" >"$log" 2>&1 &
pid=$!
unset anthropic_key gemini_key

# Each run is a few minutes; the plan route's windows are the slowest (seven Read turns each).
for _ in $(seq 1 3600); do
    [ -f "$report" ] && break
    sleep 1
done
if [ ! -f "$report" ]; then
    echo "Segmentation proof timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
[ -f "$json" ] && cat "$json"
grep -q '^ALL PASS$' "$report"
