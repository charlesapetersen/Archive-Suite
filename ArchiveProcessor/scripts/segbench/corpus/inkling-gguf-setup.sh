#!/bin/bash
# Build an isolated pinned upstream contributor branch; never patch shared vLLM.
set -euo pipefail
ROOT="$1"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME HF_HUB_DOWNLOAD_TIMEOUT=90
unset HF_HUB_OFFLINE
CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
export CUDA_HOME="$CUDA" CUDACXX="$CUDA/bin/nvcc" PATH="$CUDA/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA/lib:$CUDA/lib64:$FS_ROOT/cuda-link:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$CUDA/lib:$FS_ROOT/cuda-link:${LIBRARY_PATH:-}"
# CPU build nodes have no NVIDIA driver. Link with NVIDIA's checked SDK stub;
# never install it or place it on the inference runtime's library search path.
printf '%s  %s\n' '25b8071951baba827be1580b841d363464f6ee6c39f48d33a81646f90cc95ed1' "$ROOT/recovery/cuda-cudart.tar.xz" | sha256sum -c -
mkdir -p "$ROOT/cuda-stub"
tar -xJf "$ROOT/recovery/cuda-cudart.tar.xz" -C "$ROOT/cuda-stub" --strip-components=3 \
  cuda_cudart-linux-x86_64-13.0.96-archive/lib/stubs/libcuda.so
REVISION=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["runtime_revision"])' "$ROOT/candidate.json")
if [ ! -e "$ROOT/src" ]; then
  git init "$ROOT/src"
  git -C "$ROOT/src" remote add origin https://github.com/danielhanchen/llama.cpp.git
  git -C "$ROOT/src" fetch --depth 1 origin "$REVISION"
  git -C "$ROOT/src" checkout --detach FETCH_HEAD
fi
test "$(git -C "$ROOT/src" rev-parse HEAD)" = "$REVISION"
cmake -S "$ROOT/src" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCUDAToolkit_ROOT="$CUDA" \
  -DCMAKE_CUDA_FLAGS="-L$CUDA/lib" \
  -DCUDA_CUDART="$CUDA/lib/libcudart.so.13" -DCUDA_cudart_LIBRARY="$CUDA/lib/libcudart.so.13" \
  -DCUDA_cublas_LIBRARY="$CUDA/lib/libcublas.so.13" -DCUDA_cublasLt_LIBRARY="$CUDA/lib/libcublasLt.so.13" \
  -DCUDA_cuda_driver_LIBRARY="$ROOT/cuda-stub/libcuda.so" -DCMAKE_SKIP_RPATH=ON \
  -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF
cmake --build "$ROOT/build" --target llama-server -j "${SLURM_CPUS_PER_TASK:-8}"
"$FS_PY" - "$ROOT" <<'PY'
from pathlib import Path
import hashlib,json,sys
from huggingface_hub import snapshot_download,HfApi
r=Path(sys.argv[1]);c=json.loads((r/'candidate.json').read_text())
info=HfApi().model_info(c['model'],revision=c['revision'],files_metadata=True)
assert not info.gated and not info.private and info.sha==c['revision']
sizes={f.rfilename:f.size for f in info.siblings}
assert all(sizes.get(n) for n in c['files'])
assert sum(sizes[n] for n in c['files'])<175_000_000_000
snapshot=snapshot_download(c['model'],revision=c['revision'],allow_patterns=c['files'],max_workers=4)
binary=r/'build/bin/llama-server'
c.update(state='ready',snapshot=snapshot,binary=str(binary),binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),weight_bytes=sum(sizes[n] for n in c['files']))
p=r/c['key']/'prepared.json';tmp=p.with_suffix('.part');tmp.write_text(json.dumps(c,indent=2)+'\n');tmp.replace(p)
print(json.dumps(c),flush=True)
PY
