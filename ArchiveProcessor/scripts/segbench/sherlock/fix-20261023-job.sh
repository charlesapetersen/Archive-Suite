#!/bin/bash
#SBATCH --job-name=w46-fix
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=01:00:00
# The 2026-10-22 night's failures other than the truth pack, one CPU job: Sherlock keeps installs and copies off its
# login nodes. (The truth pack, FarmShare's $HOME/fs-truthpack, is rebuilt on the Mac by cluster_ocr.py pack and
# copied to the same path here; its 99 images match every hash the packs record.)
#   sbatch --output=... fix-20261023-job.sh SH_DIR
# 1. enh-probe died importing scipy (ResShift's utils), and behind it albumentations (its basicsr), which FarmShare's
#    venv carried and the vLLM image does not. They go in a --system-site-packages venv over the image in $GROUP_HOME
#    ($SH_ENH_ENV, never $SCRATCH), as setup-ppocr-job.sh builds PP-OCRv6's, so pip adds only what the image lacks,
#    held to the image's own versions; enh-ocr-job.sh puts its site-packages ($SH_ENH_EXTRA) after the pack's pydeps.
#    The job imports both diffusion restorers as the arms import them, each in its own process, and installs each
#    module that is missing until both load, so a missing package fails here rather than on a GPU.
# 2. postcorrect's pack names six 895 images under interactive-20261019 that sit in FarmShare's 20261018 folder;
#    each is copied only when its hash is the one the pack's request records.
# 3. The night's outputs go to $GROUP_HOME/$USER/archive-suite/sherlock-results (scratch never holds the only copy),
#    without models, page images, weights or the restorers' clones. Rerunnable: rsync adds what changed.
set -euo pipefail
SH_DIR="$1"; source "$SH_DIR/sh.env"
SRC="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr"
ENH="$FS_ROOT/enh-ocr-input-20261022"
mkdir -p "$SCRATCH/cache/pip"
run() { local pp="$1"; shift; apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env PYTHONPATH="$pp" "$SH_IMG" "$@"; }

rm -rf "$GROUP_HOME/$USER/envs/enh-extra"     # the first attempt's pip --target folder (2026-10-23), replaced by the venv
[ -x "$SH_ENH_ENV/bin/python" ] || run "$SH_SHIM" python3 -m venv --system-site-packages "$SH_ENH_ENV"
rm -f "$SH_ENH_ENV/.imports-ok"
# The image's own versions bind everything pip resolves; only what it lacks is added.
run "$SH_SHIM" python3 -m pip freeze | grep -v -e ' @ ' -e '^-e ' > "$SH_ENH_ENV/image-constraints.txt"
# Module name -> package, for what the restorers' clones import (scanned 2026-10-23 from src/ResShift and src/NAF-DPM).
declare -A PKG=([scipy]=scipy [albumentations]=albumentations [imgaug]=imgaug [lmdb]=lmdb [cv2]=opencv-python-headless
  [yaml]=pyyaml [PIL]=pillow [matplotlib]=matplotlib [skimage]=scikit-image [omegaconf]=omegaconf [loralib]=loralib
  [timm]=timm [einops]=einops [loguru]=loguru [open_clip]=open_clip_torch [Levenshtein]=levenshtein
  [torchsummary]=torchsummary [tensorboard]=tensorboard)
check() {   # prints the first missing module of one arm's import chain, or nothing when it loads
  run "$SH_SHIM:$ENH/pydeps:$SH_ENH_EXTRA" python3 - "$ENH" "$1" <<'PY'
import sys, types
from pathlib import Path
base, arm = Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(base))  # the pack's enh_ocr_arms.py, the one the job runs
try:
    import numpy
    assert '/envs/' not in numpy.__file__, 'numpy came from the overlay, not the image'
    import enh_ocr_arms as A
    if arm == 'resshift':
        with A._inside(base / 'src' / 'ResShift'):
            from omegaconf import OmegaConf
            from sampler import ResShiftSampler
    else:
        with A._inside(base / 'src' / 'NAF-DPM'):
            for m in ('pyiqa', 'wandb'):
                sys.modules.setdefault(m, types.ModuleType(m))
            from Deblurring.schedule.schedule import Schedule
            from Deblurring.model.NAFDPM import NAFDPM
            from Deblurring.src.tester import dpm_solver
except ModuleNotFoundError as e:
    print(e.name.split('.')[0]); sys.exit(0)
print(arm, 'imports ok; numpy', numpy.__version__, file=sys.stderr)
PY
}
for arm in resshift nafdpm; do
  for _ in $(seq 1 12); do
    miss=$(check "$arm")
    [ -n "$miss" ] || continue 2
    pkg="${PKG[$miss]:-}"
    [ -n "$pkg" ] || { echo "$arm: no package known for module $miss"; exit 1; }
    echo "$arm: installing $pkg for $miss"
    run "$SH_SHIM" "$SH_ENH_ENV/bin/python" -m pip install -q --disable-pip-version-check \
      -c "$SH_ENH_ENV/image-constraints.txt" "$pkg"
  done
  echo "$arm: still missing modules after 12 installs"; exit 1
done
run "$SH_SHIM" "$SH_ENH_ENV/bin/python" -m pip freeze --local > "$SH_ENH_ENV/requirements-resolved.txt"
cat "$SH_ENH_ENV/requirements-resolved.txt"
touch "$SH_ENH_ENV/.imports-ok"

run "$SH_SHIM" python3 - "$FS_ROOT/postcorrect-20261022/requests.jsonl" "$SRC/interactive-20261018/ocr/images" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
reqs, alt = Path(sys.argv[1]), Path(sys.argv[2])
copied = 0
for line in reqs.read_text().splitlines():
    r = json.loads(line)
    pairs = list(zip(r.get('images') or [], r.get('image_sha256s') or [])) or [(r.get('image'), r.get('image_sha256'))]
    for im, digest in pairs:
        if not im:     # a text-only request
            continue
        im = Path(im)
        if im.exists():
            continue
        cand = alt / im.name
        if not cand.exists() or hashlib.sha256(cand.read_bytes()).hexdigest() != digest:
            raise SystemExit(f'no matching copy of {im}')
        shutil.copyfile(cand, im); copied += 1
print('postcorrect images copied:', copied)
PY

DEST="$GROUP_HOME/$USER/archive-suite/sherlock-results"
mkdir -p "$DEST"
rsync -a --prune-empty-dirs --exclude=hf/ --exclude=images/ --exclude=weights/ --exclude=src/ --exclude=pydeps/ \
  --exclude=paddlex-cache/ --exclude=__pycache__/ \
  "$FS_ROOT"/{capture-ladder-20261022,date-image-20261022,dewarp-20261022,enh-ocr-input-20261022,loop-rerun-20261021} \
  "$FS_ROOT"/{new-open-895,new-open-96,postcorrect-20261022,regions-20261021,logprob-20261022,logs,runs,text-kit,text-packs} \
  "$FS_ROOT"/*.tsv "$DEST/"
du -sh "$DEST"; echo "fix done"
