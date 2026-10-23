#!/bin/bash
# W46 restart on Sherlock (owner, 2026-10-22): the FarmShare jobs cancelled at 10:48 that morning, submitted again
# from a Sherlock login node in an owner-started session, which then logs out; nothing waits on the login.
#   bash restart-20261022.sh [--dry-run]
# One CPU job stages the packs and downloads the models (stage-job.sh). A three-page environment pilot (LightOnOCR-3
# 0.8B, the loops pack's n-gram pilot) follows it afterok and gates every GPU job, so a broken image or vLLM start
# stops the chain before the GPU hours. Each item's own job script then runs unchanged; this replaces only its
# FarmShare submit script, for the cancelled jobs alone:
#   W46.ocr-loops          12 one-GPU route x arm jobs (the routes FarmShare had not finished), then Ling's two
#                          four-GPU jobs afterany them, as on FarmShare
#   W46.ocr-regions        the seven reader shards (detect and pilot completed on FarmShare)
#   W46.enh-dewarp         Qwen3.6-27B and LightOnOCR-3 4B, each a three-image pilot then its shards
#   W46.enh-ocr-input      the two enhancement jobs, then the three vLLM readers afterok them
#   W46.ocr-logprob        its two GPU jobs (each runs its own three-page gate)
# PP-OCRv6 (dewarp and enh-ocr-input) is the ppocr section, on its own overlay venv (setup-ppocr-job.sh); W46.date-traceable-vision and
# W46.date-enclosure use the old kit's text mode, ported separately. Job ids: $FS_ROOT/sherlock-20261022.tsv.
set -euo pipefail
DRY="${1:-}"
SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SH_DIR/sh.env"
# ONLY=loops,regions,... submits those sections alone (a partial resubmission), into its own job list.
ONLY="${ONLY:-}"
want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }
TSV="$FS_ROOT/sherlock-20261022${ONLY:+-${ONLY//,/-}}.tsv"; [ "$DRY" != --dry-run ] || TSV=/dev/stderr
[ "$DRY" = --dry-run ] || [ ! -e "$TSV" ] || { echo "$TSV exists: this restart was submitted already"; exit 2; }
mkdir -p "$FS_ROOT/logs"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo 0; else "$@"; fi; }
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TSV"; }
G1=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
G4=(--partition=gpu --nodes=1 -G 4 -C "$SH_GPU_C" --cpus-per-task=16 --mem=220G)
# sbatch reads a job script at submission, before the stage job has put the packs in place: submit this checkout's
# copies (stage-job.sh puts the same files beside each pack).
CORPUS="$(cd "$SH_DIR/../corpus" && pwd)"
LOOPS="$FS_ROOT/loop-rerun-20261021" REG="$FS_ROOT/regions-20261021" DEW="$FS_ROOT/dewarp-20261022"
ENH="$FS_ROOT/enh-ocr-input-20261022" LP="$FS_ROOT/logprob-20261022"
# Hours come from the FarmShare copy in $GROUP_HOME (the same routes.json): the packs reach $FS_ROOT only when the
# stage job runs, after this script has submitted everything.
SRC="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr"
hours() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]["hours"])' "$SRC/$(basename "$1")/routes.json" "$2"; }
# Slurm opens each --output when the job starts; the folders must exist by then, and stage-job.sh only adds to them.
[ "$DRY" = --dry-run ] || mkdir -p "$LOOPS/logs" "$REG/logs" "$DEW/logs" "$ENH/logs" "$LP/logs"

# The vLLM sections share one stage job and one environment pilot; ONLY=ppocr needs neither.
vllm=0; for s in loops regions dewarp enh enhprobe logprob text; do want "$s" && vllm=1; done
if [ "$vllm" = 1 ]; then
  stage=$(run sbatch --parsable --output="$FS_ROOT/logs/stage-%j.out" "$SH_DIR/stage-job.sh" "$SH_DIR" \
    loop-rerun-20261021 regions-20261021 dewarp-20261022 enh-ocr-input-20261022 logprob-20261022 \
    open-sweep-20261019 truth96-20261020 interactive-20261018/ocr interactive-20261019/ocr)   # prompts, readings, page images the packs name
  rec stage - "$stage"
  pilot=$(run sbatch --parsable "${G1[@]}" --time=01:00:00 --dependency="afterok:$stage" --job-name=sh-env-pilot \
    --output="$FS_ROOT/logs/slurm-%j.out" "$CORPUS/loop-rerun-job.sh" "$LOOPS" pilot ngram)
  rec env-pilot loops "$pilot"
  after=(--dependency="afterok:$pilot")
fi

if want loops; then
# W46.ocr-loops (routes.json gives each route's hours, as loop-rerun-submit.sh reads them)
deps=()
for route in lightonocr3-4b qwen3.5-4b qwen3-vl-8b qwen3.6-35b-a3b qwen3.6-27b qwen3.5-27b; do
  h=$(hours "$LOOPS" "$route")
  for arm in ngram half; do
    id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" "${after[@]}" --job-name="loops-$route-$arm" \
      --output="$LOOPS/logs/slurm-%j.out" "$CORPUS/loop-rerun-job.sh" "$LOOPS" "$route" "$arm")
    rec loops "$route/$arm" "$id"; deps+=("$id")
  done
done
prev=$(IFS=:; echo "${deps[*]}")
for arm in ngram half; do
  # Held: an afterany chain runs even when the pilot failed and Slurm cancelled what it gated (2026-10-22, 49050179
  # reached the head of the queue that way). Release both with scontrol release once the pilot has passed.
  id=$(run sbatch --parsable --hold "${G4[@]}" --time=06:00:00 --dependency="afterany:$prev" --job-name="loops-ling-$arm" \
    --output="$LOOPS/logs/slurm-%j.out" "$CORPUS/loop-rerun-job.sh" "$LOOPS" ling3-flash-vl-fp8 "$arm")
  rec loops "ling3-flash-vl-fp8/$arm" "$id"; prev="$id"
done
fi

if want regions; then
# W46.ocr-regions (regions-submit.sh's shards and hours)
for spec in glm-ocr:1:6 paddleocr-vl1.5:1:8 lightonocr3-4b:1:8 qwen3.6-27b:4:12; do
  IFS=: read -r route shards h <<< "$spec"
  for ((i = 0; i < shards; i++)); do
    id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" "${after[@]}" --job-name="regions-$route-$i" \
      --output="$REG/logs/slurm-%j.out" "$CORPUS/regions-job.sh" "$REG" read "$route" "$i/$shards")
    rec regions "$route/$i/$shards" "$id"
  done
done
fi

if want dewarp; then
# W46.enh-dewarp (dewarp-submit.sh's pilots and shards, without PP-OCRv6)
for spec in qwen3.6-27b:4:4 lightonocr3-4b:1:2; do
  IFS=: read -r route shards h <<< "$spec"
  dp=$(run sbatch --parsable "${G1[@]}" --time=01:00:00 "${after[@]}" --job-name="dewarp-pilot-$route" \
    --output="$DEW/logs/slurm-%j.out" "$CORPUS/dewarp-job.sh" "$DEW" "$route" 0/1 3)
  rec dewarp "pilot/$route" "$dp"
  for ((i = 0; i < shards; i++)); do
    id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" --dependency="afterok:$dp" --job-name="dewarp-$route-$i" \
      --output="$DEW/logs/slurm-%j.out" "$CORPUS/dewarp-job.sh" "$DEW" "$route" "$i/$shards")
    rec dewarp "$route/$i/$shards" "$id"
  done
done
fi

if want enh; then
# W46.enh-ocr-input (enh-ocr-submit.sh's DocRes job and its vLLM readers, without PP-OCRv6; the probe arm is enhprobe)
main=$(run sbatch --parsable "${G1[@]}" --time=02:00:00 "${after[@]}" --job-name=enh-arms \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" enhance docres-appearance,docres-deshadow)
rec enh enhance/main "$main"
for spec in whole:qwen3-vl-8b:4 regions:glm-ocr:4; do
  IFS=: read -r kind route h <<< "$spec"
  id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" --dependency="afterok:$main" --job-name="enh-$kind-$route" \
    --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" "$kind" "$route" 0/1)
  rec enh "$kind/$route" "$id"
done
fi

if want enhprobe; then
# W46.enh-ocr-input's probe arm: the two diffusion restorers on the 30 probe pages, then Qwen3.6-27B on them
probe=$(run sbatch --parsable "${G1[@]}" --time=08:00:00 "${after[@]}" --job-name=enh-probe \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" enhance resshift-s1,resshift-s2,nafdpm-s1,nafdpm-s2)
rec enh enhance/probe "$probe"
id=$(run sbatch --parsable "${G1[@]}" --time=05:00:00 --dependency="afterok:$probe" --job-name=enh-probe-qwen3.6-27b \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" whole qwen3.6-27b 0/1 probe)
rec enh whole/qwen3.6-27b/probe "$id"
fi

if want logprob; then
# W46.ocr-logprob (logprob-submit.sh run; the stage job downloads Qwen3.5-9B, so no setup job)
for route in lightonocr3-4b qwen3.5-9b; do
  h=$(hours "$LP" "$route")
  id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" "${after[@]}" --job-name="logprob-$route" \
    --output="$LP/logs/slurm-%j.out" "$CORPUS/logprob-job.sh" "$LP" "$route")
  rec logprob "$route" "$id"
done
fi

if want text; then
# W46.date-traceable-vision and W46.date-enclosure: the old kit's text mode, Qwen3.6-27B thinking off, an hour each,
# as their FarmShare commands asked (submit.sh text qwen3.6-27b; job.sbatch reads these variables).
for spec in date-traceable-vision:fs-tracepack-vision date-enclosure:fs-enclosurepack; do
  IFS=: read -r item pack <<< "$spec"
  id=$(FS_DIR="$FS_ROOT/text-kit" FS_MODE=text FS_PRESET_NAME=qwen3.6-27b FS_WALL_MIN=60 FS_PACK="$FS_ROOT/text-packs/$pack" \
    FS_LABEL="$item-qwen3.6-27b-nothink" FS_TEXT_ARGS=--thinking-off \
    run sbatch --parsable --export=ALL "${G1[@]}" --time=01:00:00 "${after[@]}" --job-name="text-$item" \
    --output="$FS_ROOT/logs/%x-%j.out" "$SH_DIR/text-job.sh")
  rec text "$item" "$id"
done
fi

if want ppocr; then
# PP-OCRv6 for W46.enh-dewarp and W46.enh-ocr-input (owner, 2026-10-22): its overlay venv first (setup-ppocr-job.sh,
# CPU), then dewarp's three-image pilot, then dewarp's one shard and the enhancement test's reader on the DocRes
# images (made 2026-10-22 by enh-arms, so no enhancement job is waited on).
setup=$(run sbatch --parsable --output="$FS_ROOT/logs/ppocr-setup-%j.out" "$SH_DIR/setup-ppocr-job.sh" "$SH_DIR")
rec ppocr setup "$setup"
pp=$(run sbatch --parsable "${G1[@]}" --time=01:00:00 --dependency="afterok:$setup" --job-name=dewarp-pilot-ppocrv6 \
  --output="$DEW/logs/slurm-%j.out" "$CORPUS/dewarp-job.sh" "$DEW" ppocrv6 0/1 3)
rec ppocr dewarp/pilot "$pp"
id=$(run sbatch --parsable "${G1[@]}" --time=02:00:00 --dependency="afterok:$pp" --job-name=dewarp-ppocrv6-0 \
  --output="$DEW/logs/slurm-%j.out" "$CORPUS/dewarp-job.sh" "$DEW" ppocrv6 0/1)
rec ppocr dewarp/0/1 "$id"
id=$(run sbatch --parsable "${G1[@]}" --time=02:00:00 --dependency="afterok:$pp" --job-name=enh-ppocr \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" ppocr - 0/1)
rec ppocr enh "$id"
fi

[ "$DRY" = --dry-run ] || cat "$TSV"
