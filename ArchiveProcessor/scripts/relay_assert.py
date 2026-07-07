#!/usr/bin/env python3
"""Assert the FileRelay offline invariant driver's results.json.

Prints one line per case and a final `RESULT: PASS/FAIL (n/total)` (mirrors tier2_assert.py's contract
so the runner can grep for it). Exit 0 iff every case passed.
"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "results.json"
try:
    data = json.load(open(path))
except Exception as e:
    print(f"RESULT: FAIL (couldn't read {path}: {e})")
    sys.exit(1)

cases = data.get("cases", [])
for c in cases:
    print(f"  [{'PASS' if c.get('pass') else 'FAIL'}] {c.get('name')}: {c.get('detail', '')}")

ok = bool(cases) and data.get("allPass", False) and all(c.get("pass") for c in cases)
n = sum(1 for c in cases if c.get("pass"))
print(f"RESULT: {'PASS' if ok else 'FAIL'} ({n}/{len(cases)})")
sys.exit(0 if ok else 1)
