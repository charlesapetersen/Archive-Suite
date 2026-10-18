#!/bin/bash
# W41.app-local-seg: publish the corpus-trained 2B segmenter (8-bit MLX) to Hugging Face, the repository the Processor's
# `local` approach downloads by default (`LocalSegmenter.defaultModelID`). The owner approved publishing on 2026-10-17.
# It is a public release, so the OWNER runs this, signed in to Hugging Face (`hf auth login`, a write token).
#
#   ArchiveProcessor/scripts/segbench/publish-seg-model/publish.sh [repo] [build-dir]
#
# repo defaults to the app's default; if you publish under another name, change LocalSegmenter.defaultModelID to match.
# build-dir defaults to the Vision OCR lab's conversion (W41.seg-mac-model). The model card is this folder's README.md,
# which replaces the converter's own. Nothing else is uploaded: only the build's weights, config and tokenizer files.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${1:-charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit}"
build="${2:-$HOME/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit}"
command -v hf >/dev/null || { echo "Install the Hugging Face CLI first: pip install -U huggingface_hub" >&2; exit 1; }
hf auth whoami >/dev/null || { echo "Sign in first: hf auth login" >&2; exit 1; }
for f in config.json model.safetensors tokenizer.json chat_template.jinja; do
    [ -f "$build/$f" ] || { echo "$build has no $f" >&2; exit 1; }
done
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
for f in "$build"/*; do
    [ "$(basename "$f")" = README.md ] || ln -s "$f" "$stage/"
done
cp "$here/README.md" "$stage/README.md"
hf repo create "$repo" --repo-type model --exist-ok
hf upload "$repo" "$stage" . --repo-type model --commit-message "Archive Suite segmenter, 8-bit MLX (W41.app-local-seg)"
echo "Published https://huggingface.co/$repo"
