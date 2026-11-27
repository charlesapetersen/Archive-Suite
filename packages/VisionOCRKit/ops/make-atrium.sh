#!/usr/bin/env bash
# make-atrium.sh — the mixed-page pre-flag's download (W47.wh-mixed-preflag): ATRIUM's page classifier
# (ufal/vit-historical-page v4.3; MIT, on CC BY-NC 4.0 base weights) converted to Core ML, which W46.kind-atrium measured as a mixed flag.
#
#   make-atrium.sh VENV_PYTHON WORKDIR
#
# VENV_PYTHON is the shared torch env (`ArchiveProcessor/scripts/segbench/torch-env.sh`, with `add timm coremltools`).
# WORKDIR gets the Core ML package, its compiled model and
#   WORKDIR/atrium-page-kind.tgz   the download (`ModelDownloads.Item.atrium`), its size and sha256 printed for the
#                                  plan; published to the visionocrkit-models-1 release by the owner
set -euo pipefail
PY="$1"; WORK="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK"; cd "$WORK"
rm -rf atrium.mlpackage compiled
"$PY" "$HERE/convert-atrium.py" atrium.mlpackage
mkdir compiled
xcrun coremlcompiler compile atrium.mlpackage compiled >/dev/null
mv compiled/atrium.mlmodelc compiled/atrium-page-kind.mlmodelc
# The archive holds the one folder `ModelDownloads.install` expects (`top`). The pinned hash is of this build's file,
# which is the one published: a rebuild gives new bytes (times), so it is re-pinned.
COPYFILE_DISABLE=1 tar --no-mac-metadata -C compiled -czf atrium-page-kind.tgz atrium-page-kind.mlmodelc
echo "atrium-page-kind.tgz $(stat -f %z atrium-page-kind.tgz) bytes, sha256 $(shasum -a 256 atrium-page-kind.tgz | cut -d' ' -f1)"
