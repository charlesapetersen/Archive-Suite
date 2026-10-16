#!/usr/bin/env bash
# The newspaper-ocr venv for news-layout mode (login node, after setup.sh). Its own venv, so the layout detectors'
# dependencies (paddlepaddle, paddlex, doclayout-yolo, their torch) can never disturb the vLLM venv the job serves from.
#   bash setup-layout.sh
# Then warms the detectors' weight caches on one page, here on the login node, because the GPU job runs offline.
set -euo pipefail
cd "$(dirname "$0")"
source fs.env
NPO_COMMIT="${NPO_COMMIT:-1d5c878}"   # the newspaper-ocr commit measured on 2026-10-15
if [ ! -d "$FS_ROOT/newspaper-ocr" ]; then
  git clone -q https://github.com/nealcaren/newspaper-ocr.git "$FS_ROOT/newspaper-ocr"
fi
git -C "$FS_ROOT/newspaper-ocr" checkout -q "$NPO_COMMIT"
if [ ! -x "$FS_ROOT/npo-venv/bin/python" ]; then
  python3 -m venv "$FS_ROOT/npo-venv"
fi
"$FS_ROOT/npo-venv/bin/pip" install -q --upgrade pip
"$FS_ROOT/npo-venv/bin/pip" install -q -e "$FS_ROOT/newspaper-ocr[paddlex,doclayout,api]"
# paddlepaddle 3.3.1 fails PP-DocLayout on the CPU in its oneDNN path ("ConvertPirAttribute2RuntimeAttribute not
# support"), with or without FLAGS_use_mkldnn=0; 3.2.2 runs it (2026-10-15).
"$FS_ROOT/npo-venv/bin/pip" install -q "paddlepaddle==3.2.*"
"$FS_ROOT/npo-venv/bin/python" -c 'import newspaper_ocr, paddlex, doclayout_yolo, httpx; print("newspaper-ocr ready")'
if [ ! -d "$FS_ROOT/newsbench" ]; then
  git clone -q https://github.com/nealcaren/newsbench.git "$FS_ROOT/newsbench"
  git -C "$FS_ROOT/newsbench" checkout -q 2372b6b6c63e71c7eb43e34ef655c8f5c4f1620b
fi
# Detection only, no reader: fetches each detector's weights into the caches the job will read.
HF_HOME="$HF_HOME" "$FS_ROOT/npo-venv/bin/python" - "$FS_ROOT/newsbench" <<'EOF'
import sys
from pathlib import Path
from newspaper_ocr.detectors import DETECTORS
from PIL import Image
img = Image.open(sorted((Path(sys.argv[1]) / 'images').glob('*.jpg'))[0]).convert('RGB')
for name in ('doclayout_yolo', 'paddlex'):
    layout = DETECTORS.get(name)().detect(img)
    print(name, len(getattr(layout, 'regions', [])), 'regions on the first page')
EOF
