#!/usr/bin/env bash
# mutation-sample.sh — W40.e7: plant mutants in the irreversible paths, one at a time, and check the tests kill them.
# USAGE: ops/verify/mutation-sample.sh <core|processor|notes|reader> [--check] [--only ID[,ID…]]
# The mutant list, verdicts and the "landed" proof are documented in mutation-sample.py. This wrapper only takes
# the Mac-wide heavy lock, so one area's run (a baseline plus ~12 rebuild-and-test rounds) holds it once.
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
exec python3 "$(cd "$(dirname "$0")" && pwd)/mutation-sample.py" "$@"
