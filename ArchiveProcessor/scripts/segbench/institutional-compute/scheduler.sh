# Keep argv as an array, including when a bulk job requeues itself. Paths may contain spaces.
slurm_args() {
  local gres="gpu:${IC_GPU_GRES_TYPE:+$IC_GPU_GRES_TYPE:}$IC_GPUS"
  SBATCH_ARGS=("--partition=$IC_PARTITION" "--gres=$gres" "--cpus-per-task=$((8 * IC_GPUS))"
    "--mem=$((48 * IC_GPUS + 32))G" "--time=$IC_WALL_MIN" "--job-name=ic-ocr-$IC_MODE"
    "--output=$IC_ROOT/logs/%x-%j.out")
  [ -z "$IC_QOS" ] || SBATCH_ARGS+=("--qos=$IC_QOS")
  [ -z "$IC_ACCOUNT" ] || SBATCH_ARGS+=("--account=$IC_ACCOUNT")
}
