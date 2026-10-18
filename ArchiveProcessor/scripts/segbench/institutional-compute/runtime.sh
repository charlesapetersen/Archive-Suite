# Cluster-specific modules and CUDA setup, shared by install and jobs. Source after profile/compute.env.
load_cluster_modules() {
  local m
  if [ -n "$IC_MODULES" ]; then
    command -v module >/dev/null 2>&1 || { echo 'profile requires environment modules; initialize module first' >&2; return 1; }
    for m in $IC_MODULES; do module load "$m" || return; done
  fi
}
configure_cluster_cuda() {
  if [ "$IC_CUDA_MODE" = modules ]; then
    [ -z "$IC_CUDA_HOME" ] || export CUDA_HOME="$IC_CUDA_HOME" PATH="$IC_CUDA_HOME/bin:$PATH"
  else
    local cuda
    cuda="$("$IC_PY" -c 'import torch, nvidia, os; print(os.path.join(list(nvidia.__path__)[0], "cu" + torch.version.cuda.split(".")[0]))')"
    [ -x "$cuda/bin/nvcc" ] || { echo "no nvcc in torch's CUDA toolkit: $cuda" >&2; return 1; }
    export CUDA_HOME="$cuda" PATH="$cuda/bin:$PATH"
    mkdir -p "$IC_ROOT/cuda-link"
    local libs=("$cuda"/lib/libcudart.so.*)
    [ -e "${libs[0]}" ] || { echo "no libcudart in $cuda/lib" >&2; return 1; }
    ln -sf "${libs[0]}" "$IC_ROOT/cuda-link/libcudart.so"
    export FLASHINFER_EXTRA_LDFLAGS="-L$cuda/lib -L$IC_ROOT/cuda-link"
  fi
  command -v nvcc >/dev/null 2>&1 || { echo 'CUDA compiler missing; check runtime profile' >&2; return 1; }
  nvcc --version | tail -1
}
