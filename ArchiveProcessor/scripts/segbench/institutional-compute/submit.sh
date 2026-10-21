#!/usr/bin/env bash
# Slurm submission; --dry-run is offline and never creates paths, installs models, clones data or submits work.
# bash submit.sh [--profile NAME|FILE] truth|seg|text|news|news-layout|bulk auto [mode options] [--dry-run]
# wave.py adds --parsable (print the job ID only), --hold (submit held) and --after ID (--dependency=afterok:ID).
set -euo pipefail
cd "$(dirname "$0")"
IC_DIR="$(pwd)"
profile=""; positional=(); IC_PACK="" IC_IN="" IC_OUT="" IC_SHARDS=""; hours="" dry="" after="" extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile|--pack|--in|--out|--shards|--hours|--after)
      [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      case "$1" in
        --profile) profile="$2";; --pack) IC_PACK="$2";; --in) IC_IN="$2";; --out) IC_OUT="$2";;
        --shards) IC_SHARDS="$2";; --hours) hours="$2";; --after) after="$2";;
      esac; shift 2 ;;
    --dry-run) dry=1; shift;;
    --parsable|--hold) extra+=("$1"); shift;;
    --*) echo "unknown option $1" >&2; exit 2;;
    *) positional+=("$1"); shift;;
  esac
done
[ "${#positional[@]}" -eq 2 ] || { echo 'need MODE PRESET (auto chooses by GPU memory)' >&2; exit 2; }
IC_MODE="${positional[0]}"; IC_PRESET_NAME="${positional[1]}"
active_profile="" active_profile_hash=""
if [ -f compute.env ]; then source compute.env; active_profile="$IC_PROFILE"; active_profile_hash="${IC_PROFILE_SHA256:-}"; fi
profile="${profile:-${active_profile:-farmshare}}"
profile_env="$(python3 profiles.py "$profile")"; eval "$profile_env"
IC_PY="${IC_PY:-python3}"
source models.sh; source scheduler.sh
if [ -z "$dry" ]; then
  [ -n "$active_profile" ] && [ "$active_profile" = "$IC_PROFILE" ] && [ "$active_profile_hash" = "$IC_PROFILE_SHA256" ] || { echo 'run setup.sh --profile for this profile revision first' >&2; exit 2; }
  [ -f limits.env ] || { echo 'run setup.sh first' >&2; exit 2; }
  source limits.env  # live caps checked at setup, capped by profile
fi
[ "$IC_MODE" != news ] || export IC_MAX_LEN="${IC_MAX_LEN:-32768}"
[ "$IC_MODE" != news-layout ] || export IC_GPU_UTIL="${IC_GPU_UTIL:-0.80}"
[ "$IC_MODE" != seg ] || export IC_MM_IMAGES=7 IC_MAX_LEN="${IC_MAX_LEN:-20480}"
preset "$IC_PRESET_NAME"
IC_PRESET_NAME="$IC_PRESET"
if [ "$IC_GPUS" -gt "$IC_GPUS_PER_NODE" ] || [ "$IC_GPUS" -gt "$IC_MAXGPU_PU" ]; then
  echo "$IC_PRESET_NAME needs $IC_GPUS GPUs; profile gives $IC_GPUS_PER_NODE per node, $IC_MAXGPU_PU per user" >&2; exit 2
fi
case "$IC_MODE" in
  truth|seg|text)
    [ -d "$IC_PACK" ] || { echo "$IC_MODE needs --pack DIR" >&2; exit 2; }
    IC_PACK="$(cd "$IC_PACK" && pwd)"; default_min=120
    if [ "$IC_MODE" = seg ]; then
      want_model="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["model"])' "$IC_PACK/pack.json")"
      [ "$want_model" = "${IC_SERVED:-$IC_MODEL}" ] || { echo 'pack model differs from preset' >&2; exit 2; }
    fi;;
  news|news-layout) default_min=120;;
  bulk)
    [ -d "$IC_IN" ] && [ -n "$IC_OUT" ] || { echo 'bulk needs --in DIR --out DIR' >&2; exit 2; }
    IC_IN="$(cd "$IC_IN" && pwd)"
    IC_OUT="$(python3 -c 'from pathlib import Path; import sys
src, out = (Path(p).resolve() for p in sys.argv[1:])
if src == out or src in out.parents or out in src.parents:
    raise SystemExit("--out must be outside --in (the input directory is never written)")
print(out)' "$IC_IN" "$IC_OUT")"
    default_min="$IC_MAXWALL_MIN"
    cap=$((IC_MAXGPU_PU / IC_GPUS)); [ "$IC_MAXJOBS_PU" -ge "$cap" ] || cap="$IC_MAXJOBS_PU"
    [ "$IC_MAXSUBMIT_PU" -ge "$cap" ] || cap="$IC_MAXSUBMIT_PU"
    IC_SHARDS="${IC_SHARDS:-$cap}"
    [[ "$IC_SHARDS" =~ ^[1-9][0-9]*$ ]] && [ "$IC_SHARDS" -le "$cap" ] || { echo "--shards must be 1..$cap" >&2; exit 2; };;
  *) echo 'mode must be truth, seg, text, news, news-layout or bulk' >&2; exit 2;;
esac
if [ -n "$hours" ]; then
  [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo '--hours must be positive' >&2; exit 2; }
  want="$(awk -v h="$hours" 'BEGIN {printf "%d", h*60}')"; [ "$want" -gt 0 ] || exit 2
else want="$default_min"; fi
IC_WALL_MIN=$((want < IC_MAXWALL_MIN ? want : IC_MAXWALL_MIN))
# Bulk needs time to drain before the limit; avoid a deadline already in the past.
[ "$IC_MODE" != bulk ] || [ "$IC_WALL_MIN" -gt 15 ] || { echo 'bulk wall time must exceed its 15-minute drain period' >&2; exit 2; }
export IC_DIR IC_MODE IC_PRESET_NAME IC_WALL_MIN IC_PACK IC_IN IC_OUT IC_SHARDS IC_CHAIN=0
slurm_args
if [ -n "$after" ]; then
  # A real ID, or in a dry-run the placeholder wave.py prints for a job not yet submitted.
  [[ "$after" =~ ^[0-9]+(_[0-9]+)?$ ]] || { [ -n "$dry" ] && [[ "$after" =~ ^\<[a-z]+\>$ ]]; } || { echo "--after needs a job ID" >&2; exit 2; }
  extra+=("--dependency=afterok:$after")
fi
array=(); [ "$IC_MODE" != bulk ] || array=("--array=0-$((IC_SHARDS - 1))")
printf 'cluster=%s; %s; %s GPU(s), %s GB/card\n' "$CLUSTER_NAME" "$IC_MODEL" "$IC_GPUS" "$IC_GPU_MEMORY_GB"
printf '%q ' sbatch --export=ALL "${SBATCH_ARGS[@]}" ${extra[@]+"${extra[@]}"} ${array[@]+"${array[@]}"} job.sbatch; printf '\n'
[ -z "$dry" ] || exit 0
if [ "$IC_MODE" = news-layout ]; then
  [ -x "$IC_ROOT/npo-venv/bin/python" ] || { echo 'news-layout needs setup-layout.sh' >&2; exit 2; }
fi
if [ "$IC_MODE" = news ] || [ "$IC_MODE" = news-layout ]; then
  [ -d "$IC_ROOT/newsbench" ] || { echo 'fetch NewsBench first (setup-layout.sh); submit never downloads data' >&2; exit 2; }
fi
mkdir -p "$IC_ROOT/logs"; [ "$IC_MODE" != bulk ] || mkdir -p "$IC_OUT"
sbatch --export=ALL "${SBATCH_ARGS[@]}" ${extra[@]+"${extra[@]}"} ${array[@]+"${array[@]}"} job.sbatch
