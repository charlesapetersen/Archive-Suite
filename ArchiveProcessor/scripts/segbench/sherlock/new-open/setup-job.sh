#!/bin/bash
#SBATCH --job-name=new-open-setup
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=06:00:00
# W46.ocr-new-open on Sherlock (2026-10-22): one CPU job, because Sherlock keeps downloads off login nodes.
#   sbatch --output=... setup-job.sh SH_DIR CANDIDATES_JSON
# Builds two roots with the open sweep's own layout and manifests: $FS_ROOT/new-open-895 (open-sweep-20261019's
# public895.jsonl and pilot3.jsonl, its runner) and $FS_ROOT/new-open-96 (truth96-20261020's truth99.jsonl and
# pilot3.jsonl, its runner, which refuses settings that differ from the 895 run's). Then open_sweep_setup.py, unchanged,
# inside the image: a gated, private, over-size or vLLM-unsupported model is recorded as skipped with its reason,
# never worked around; a ready one has its pinned snapshot in $FS_ROOT/hf. Each key gets the frozen collector and its
# prompt. Rerunnable for keys not prepared yet.
set -euo pipefail
SH_DIR="$1"; CANDS="$2"; source "$SH_DIR/sh.env"
OS="$FS_ROOT/open-sweep-20261019" T96="$FS_ROOT/truth96-20261020" A="$FS_ROOT/new-open-895" B="$FS_ROOT/new-open-96"
mkdir -p "$A/recovery" "$A/logs" "$B/recovery" "$B/logs"
cp "$OS/public895.jsonl" "$OS/pilot3.jsonl" "$A/"; cp "$OS/recovery/open_sweep_run.py" "$A/recovery/"
# This checkout's open_sweep_setup.py, not the FarmShare pack's copy: that one capped every model at 25 GB and ignored
# a candidate's weight_limit_bytes (2026-10-22: Qwen3.8-27B and MiniCPM-V 4.7 35B-A3B were skipped by it).
cp "$SH_DIR/../corpus/open_sweep_setup.py" "$A/recovery/"
cp "$T96/truth99.jsonl" "$T96/pilot3.jsonl" "$B/"; cp "$T96/recovery/open_sweep_run.py" "$B/recovery/"
cp "$CANDS" "$A/candidates.json"
PANEL="$OS/qwen3-vl-8b/ocr/panel-prompt.txt" COLLECTOR="$OS/qwen3-vl-8b/ocr/ocr_run.py"
# open_sweep_setup.py refuses a key that already has prepared.json, so only new keys go to it.
"$FS_PY" - "$A/candidates.json" "$A/candidates-todo.json" "$A" <<'PY'
import json, pathlib, sys
c = json.load(open(sys.argv[1])); root = pathlib.Path(sys.argv[3])
json.dump([x for x in c if not (root / x['key'] / 'prepared.json').exists()], open(sys.argv[2], 'w'), indent=1)
PY
mkdir -p "$A/todo"; mv "$A/candidates-todo.json" "$A/todo/candidates.json"
apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" --env PYTHONPATH="$SH_SHIM" "$SH_IMG" \
  python3 "$A/recovery/open_sweep_setup.py" "$A/todo" || true
"$FS_PY" - "$A" "$B" "$PANEL" "$COLLECTOR" <<'PY'
import json, pathlib, shutil, sys
A, B = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); panel, collector = sys.argv[3], sys.argv[4]
for prep in sorted((A / 'todo').glob('*/prepared.json')):
    key = prep.parent.name; rec = json.loads(prep.read_text())
    for root in (A, B):
        d = root / key; (d / 'ocr').mkdir(parents=True, exist_ok=True); (d / 'logs').mkdir(exist_ok=True)
        shutil.copy(prep, d / 'prepared.json'); shutil.copy(collector, d / 'ocr' / 'ocr_run.py')
        p = d / 'ocr' / 'panel-prompt.txt'
        if rec.get('route') == 'panel':
            shutil.copy(panel, p)
        else:
            p.write_text(rec.get('prompt') or '')
    print(key, rec['state'], rec.get('reason', '')[:160])
PY
rm -rf "$A/todo"; du -sh "$HF_HOME"
# Submit each ready model's pair from here, as a workflow step (Sherlock allows jobs that only submit): 895 pages,
# then the 96 afterok, on the card class the candidate names (`gpu_c`, else sh.env's) for its `hours` (default 4).
TSV="$FS_ROOT/new-open-jobs.tsv"
for prep in "$A"/*/prepared.json; do
  read -r key state c hours < <("$FS_PY" -c 'import json,sys;r=json.load(open(sys.argv[1]));print(r["key"],r["state"],r.get("gpu_c") or "-",r.get("hours",4))' "$prep")
  [ "$state" = ready ] || continue
  grep -q -P "^$key\t" "$TSV" 2>/dev/null && continue          # submitted by an earlier run of this job
  [ "$c" != - ] || c="$SH_GPU_C"
  g=(--partition=gpu -G 1 -C "$c" --cpus-per-task=8 --mem=64G --time="$hours:00:00")
  a=$(sbatch --parsable "${g[@]}" --job-name="new-open-895-$key" --output="$A/$key/logs/slurm-%j.out" "$SH_DIR/new-open/job.sh" "$SH_DIR" 895 "$key")
  b=$(sbatch --parsable "${g[@]}" --dependency="afterok:$a" --job-name="new-open-96-$key" --output="$B/$key/logs/slurm-%j.out" "$SH_DIR/new-open/job.sh" "$SH_DIR" 96 "$key")
  printf '%s\t%s\t%s\n' "$key" "$a" "$b" | tee -a "$TSV"
done
