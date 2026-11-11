# Keep argv as an array, including when a bulk job requeues itself. Paths may contain spaces.
slurm_args() {
  local gpus="--gres=gpu:${IC_GPU_GRES_TYPE:+$IC_GPU_GRES_TYPE:}$IC_GPUS"
  # A cluster that picks cards by feature (Sherlock: -G N -C GPU_MEM:...) asks by count and constraint instead.
  [ "${IC_GPU_REQUEST:-gres}" != gpus ] || gpus="--gpus=$IC_GPUS"
  SBATCH_ARGS=("--partition=$IC_PARTITION" "$gpus" "--cpus-per-task=$((8 * IC_GPUS))"
    "--mem=$((48 * IC_GPUS + 32))G" "--time=$IC_WALL_MIN" "--job-name=ic-ocr-$IC_MODE"
    "--output=$IC_ROOT/logs/%x-%j.out")
  [ -z "${IC_GPU_CONSTRAINT:-}" ] || SBATCH_ARGS+=("--constraint=$IC_GPU_CONSTRAINT")
  [ -z "$IC_QOS" ] || SBATCH_ARGS+=("--qos=$IC_QOS")
  [ -z "$IC_ACCOUNT" ] || SBATCH_ARGS+=("--account=$IC_ACCOUNT")
}
