#!/bin/bash
# W46.ocr-regions-cells-bank: Qwen3.6-27B alone on the whole frozen nine-page bank
# (9 whole + 9 table + 72 cell requests), two jobs: CPU stage + one GPU job.
# Owner-started Sherlock session only: bash regions-cells-bank-submit.sh GROUP_PACK [--dry-run]
set -euo pipefail
SOURCE="${1:?GROUP_PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
exec bash "$(dirname "${BASH_SOURCE[0]}")/regions-cells-submit.sh" "$SOURCE" --phase all --routes qwen3.6-27b ${DRY:+"$DRY"}
