#!/bin/bash
# make-hands-runtime.sh — build the hand placer's download (W42.int-s5-hands): a standalone CPython with kraken
# 7.1.1 and PyTorch, kraken's own blla line detector inside it, and the McCATMuS recogniser the CTC alignment runs,
# in one directory that runs from any path. `HandPlacer` runs the kit's `place-hands.py` with it.
#
#   make-hands-runtime.sh <out dir>    writes <out dir>/hands/ and <out dir>/hands.tgz, prints sizes and the sha256
#
# The pins are the lab venv's (~/.local/share/visionocr-ocrlab/venv-kraken), the versions W46.place-hands-lines and
# W46.place-hands-cost measured the route on; change one and the route must be measured again. McCATMuS is
# Thibault Clérice's CATMuS medieval model, zenodo 13788177, CC BY 4.0: its licence travels in the archive.
# The pattern is the reading runtime's own build (Vision OCR's ops/ocrlab/make-runtime.sh).
set -eu
[ $# -eq 1 ] || { echo "usage: make-hands-runtime.sh <out dir>" >&2; exit 2; }
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
command -v uv >/dev/null || { echo "make-hands-runtime.sh: needs uv" >&2; exit 1; }
out="$1"
MCCATMUS="${MCCATMUS:-$HOME/Library/Application Support/htrmopo/78d7d26e-50b3-55f8-b839-c7a882ea2053/McCATMuS_nfd_nofix_V1.mlmodel}"
[ -f "$MCCATMUS" ] || { echo "make-hands-runtime.sh: no McCATMuS at $MCCATMUS (kraken get 10.5281/zenodo.13788177)" >&2; exit 1; }
{ [ -e "$out/hands" ] || [ -e "$out/hands.tgz" ]; } && { echo "make-hands-runtime.sh: $out already holds a hands runtime" >&2; exit 1; }
mkdir -p "$out"
work="$(mktemp -d -t visionocr-hands)"
ok=0
trap 'rm -rf "$work"; [ $ok = 1 ] || rm -rf "$out/hands" "$out/hands.tgz"' EXIT
trap 'exit 1' INT TERM
uv python install -q 3.12.13
base="$(dirname "$(dirname "$(VIRTUAL_ENV= uv python find --managed-python 3.12.13)")")"
[ -e "$base/pyvenv.cfg" ] && { echo "make-hands-runtime.sh: $base is a venv, not an install" >&2; exit 1; }
uv venv -q --python 3.12.13 "$work/env"
# kraken's closure as the lab venv holds it, every package pinned (kraken 7.1.1 pins nothing tightly itself).
cat > "$work/pins.txt" <<'PINS'
kraken==7.1.1
torch==2.14.0
torchvision==0.29.1
lightning==2.6.1
pytorch-lightning==2.6.6
torchmetrics==1.9.0
coremltools==9.0
numpy==2.4.6
scipy==1.15.3
scikit-image==0.25.2
scikit-learn==1.7.2
shapely==2.1.2
pillow==12.3.0
lxml==6.1.3
protobuf==7.36.2
pyarrow==26.0.0
htrmopo==0.6
regex==2026.9.29
safetensors==0.7.0
jsonschema==4.26.0
iso639-lang==2.6.3
click==8.2.1
rich==14.0.0
Jinja2==3.1.6
platformdirs==4.13.0
threadpoolctl==3.6.0
requests==2.34.2
PINS
uv pip install -q --python "$work/env/bin/python" -r "$work/pins.txt"
rsync -a --exclude __pycache__ --exclude 'lib/python3.12/site-packages/' "$base/" "$out/hands/"
rsync -a --exclude __pycache__ "$work/env/lib/python3.12/site-packages/" "$out/hands/lib/python3.12/site-packages/"
mkdir -p "$out/hands/models"
cp "$MCCATMUS" "$out/hands/models/McCATMuS_nfd_nofix_V1.mlmodel"
cat > "$out/hands/models/McCATMuS-LICENSE.txt" <<'LIC'
McCATMuS_nfd_nofix_V1 — Thibault Clérice et al., CATMuS Medieval, https://doi.org/10.5281/zenodo.13788177
Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
Redistributed unchanged.
LIC
[ -z "$(find "$out/hands" -type l -lname '/*' | head -1)" ] \
    || { echo "make-hands-runtime.sh: the runtime holds a symlink to an absolute path" >&2; exit 1; }
# What place-hands.py imports, and the two models it opens.
"$out/hands/bin/python3" -I -c '
import torch, kraken, PIL, numpy
from kraken.kraken import SEGMENTATION_DEFAULT_MODEL
from kraken.tasks import SegmentationTaskModel, ForcedAlignmentTaskModel
from kraken.tasks.align import get_trellis, backtrack, merge_repeats
import os, sys
assert os.path.exists(SEGMENTATION_DEFAULT_MODEL), SEGMENTATION_DEFAULT_MODEL
ForcedAlignmentTaskModel.load_model(sys.argv[1])
' "$out/hands/models/McCATMuS_nfd_nofix_V1.mlmodel" \
    || { echo "make-hands-runtime.sh: the built runtime cannot load the hand placer" >&2; exit 1; }
find "$out/hands" -name __pycache__ -type d -prune -exec rm -rf {} +
( cd "$out" && tar -czf hands.tgz hands )
du -sh "$out/hands" | awk '{print "on disk  " $1}'
ls -l "$out/hands.tgz" | awk '{print "archive  " $5 " B"}'
# tar keeps mtimes, so the hash differs on every build: the app must carry the hash of the archive published.
shasum -a 256 "$out/hands.tgz" | awk '{print "sha256   " $1}'
ok=1
