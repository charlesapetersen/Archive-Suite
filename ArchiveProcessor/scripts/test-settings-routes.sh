#!/bin/bash
# Key-free ($0) drift test of the settings layer's rule table (W46.settings-routes-table). Checks that
# segbench-results/settings-routes.json is what settings_routes.py builds from the result files and the stage notes
# today, that every figure in it is found in the file its source names, that every rule and noise source names a file
# and section that exist, and that the settings-design prototype's figures.json is what build_figures.py makes from the
# table. No model call, no network, no app launch, never the corpus.
set -euo pipefail
cd "$(dirname "$0")/../.."

/usr/bin/python3 ArchiveProcessor/scripts/segbench/settings_routes.py --check

sd=execution-plans/processing-review/settings-design
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
/usr/bin/python3 "$sd/build_figures.py" . "$work/figures.json" >/dev/null
/usr/bin/python3 - "$sd/figures.json" "$work/figures.json" <<'EOF'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
for d in (a, b):
    d.pop("built", None)
if a != b:
    print("FAIL prototype: figures.json is not what build_figures.py makes from the table (rebuild it and prototype.html)")
    sys.exit(1)
print("PASS prototype: figures.json is what build_figures.py makes from settings-routes.json")
EOF
echo "ALL PASS"
