#!/bin/bash
# W46.ocr-new-open-boxes: Nemotron-Parse 2.0 again, after its first retry (resubmit-20261031.sh) failed at model build.
# Cause, from slurm-895-nemotron-parse-2-50550135.out: the model's constructor (RadioWithNeck) loads its encoder's code
# from nvidia/C-RADIOv2-H by name, which setup never downloaded, and the GPU job runs offline. Fixed in boxes_setup.py
# (the candidate's code_repos are downloaded; the check builds the model on the meta device, which runs that
# constructor). Unlimited-OCR (running) and granite-docling are left alone.
#   bash <pack>/support/sherlock/new-open-boxes/resubmit-nemotron-20261031.sh <pack> [--dry-run]
# Run after copying this checkout's candidates and boxes_setup.py into the pack. It sets nemotron-parse-2 back to
# `downloaded` in both roots, so setup fetches the encoder code and checks again (its overlay is kept), then queues
# the setup and Nemotron's 895 afterok the setup and 96 afterok the 895. Rows go in the pack's jobs.tsv as
# "retry2 ...".
set -euo pipefail
PACK="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
[ "${ARCHIVE_UNATTENDED:-0}" != 1 ] || { echo 'Sherlock needs an owner-attended session'; exit 2; }
PACK="$(cd "$PACK" && pwd)"; NAME="$(basename "$PACK")"
SH_DIR="$PACK/support/sherlock"; CANDS="$SH_DIR/new-open-boxes/candidates-boxes-20261031.json"
source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/$NAME"; TSV="$ROOT/jobs.tsv"; KEY=nemotron-parse-2
grep -q code_repos "$CANDS" && grep -q code_repos "$SH_DIR/new-open-boxes/boxes_setup.py" ||
  { echo "the pack's candidates and boxes_setup.py are not the fixed ones: copy them in first"; exit 2; }
grep -q 'retry2 setup' "$TSV" 2>/dev/null && { echo "$TSV has a retry2 already: inspect it"; exit 2; }
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf 'retry2 %s\t%s\n' "$1" "$2" >&2; else printf 'retry2 %s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
if [ "$DRY" != --dry-run ]; then
  "$FS_PY" - "$FS_ROOT/new-open-boxes-895" "$FS_ROOT/new-open-boxes-96" "$KEY" <<'PY'
import json, pathlib, sys
for root in sys.argv[1:3]:
    p = pathlib.Path(root) / sys.argv[3] / 'prepared.json'; r = json.loads(p.read_text())
    r['state'] = 'downloaded'; r.pop('reason', None); p.write_text(json.dumps(r, indent=1) + '\n')
PY
fi
export NEW_OPEN_RESULTS="$GROUP_HOME/$USER/archive-suite/sherlock-results/$NAME"
read -r h895 h96 < <(python3 -c 'import json,sys
c=[x for x in json.load(open(sys.argv[1])) if x["key"]==sys.argv[2]][0];print(int(c["hours_895"]),int(c["hours_96"]))' \
  "$CANDS" "$KEY")
setup=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=32G --time=04:00:00 --job-name=boxes-setup \
  --output="$ROOT/logs/setup-%j.out" "$SH_DIR/new-open-boxes/setup-job.sh" "$SH_DIR" "$CANDS")
record setup "$setup"
g=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
a=$(run sbatch --parsable "${g[@]}" --time="$h895:00:00" --dependency="afterok:$setup" --job-name="boxes-895-$KEY" \
  --output="$ROOT/logs/slurm-895-$KEY-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 895 "$KEY")
record "895 $KEY" "$a"
b=$(run sbatch --parsable "${g[@]}" --time="$h96:00:00" --dependency="afterok:$a" --job-name="boxes-96-$KEY" \
  --output="$ROOT/logs/slurm-96-$KEY-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 96 "$KEY")
record "96 $KEY" "$b"
echo "submitted: setup $setup, $KEY $a/$b; results: $NEW_OPEN_RESULTS"
