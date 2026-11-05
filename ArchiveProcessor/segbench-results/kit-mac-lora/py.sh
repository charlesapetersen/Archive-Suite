#!/bin/bash
# py.sh ARGS — kit_mac_lora.py in the lab venv with mlx-vlm's train extra; probe.sh LABEL ARGS — the same under the guard
exec env PYTHONPATH="/Users/cp1/Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora/pylib" "$HOME/.local/share/visionocr-ocrlab/venv/bin/python" "${TRAINER:-/Users/cp1/Claude/.worktrees/archive-suite/suite-wt-20261104-124908-79933/ArchiveProcessor/scripts/segbench/kit_mac_lora.py}" "$@"
