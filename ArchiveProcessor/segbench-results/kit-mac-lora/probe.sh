#!/bin/bash
label="$1"; shift
"$HOME/Claude/vision-ocr/ops/ocrlab/run-guarded.sh" --label "kit-mac-lora-$label" --rss-gb "${RSS:-8}" -- bash "/Users/cp1/Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora/py.sh" "$@" > "/Users/cp1/Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora/logs/$label.txt" 2>&1
rc=$?; grep '^{\|Error\|GUARD' "/Users/cp1/Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora/logs/$label.txt" | cut -c1-170; echo "rc=$rc"
