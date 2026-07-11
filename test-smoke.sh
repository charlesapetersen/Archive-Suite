#!/bin/bash
# test-smoke.sh — Archive Suite Tier-1 smoke-test dispatcher (mirrors launch.sh).
#
# Cheap, repeatable regression gate for BOTH apps:
#   reader     → build + unit-test suite               (free; no OCR/network/corpus)
#   processor  → headless OCR pipeline on 2 tiny images (a few cents; Gemini flash-lite)
#   all        → both (default)
#
# Usage:  ./test-smoke.sh [processor|reader|all]
# Run from anywhere; it cd's to its own directory = repo root.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")"

run_reader(){    echo "──────── Archive Reader ────────";    bash "./ArchiveReader/test-smoke.sh"; }
run_notes(){     echo "──────── Archive Notes ─────────";    bash "./ArchiveNotes/test-smoke.sh"; }
run_processor(){ echo "──────── Archive Processor ─────";    bash "./ArchiveProcessor/test-smoke.sh"; }

case "${1:-all}" in
  reader|r|ArchiveReader)         run_reader ;;
  notes|n|ArchiveNotes)           run_notes ;;
  processor|p|ArchiveProcessor)   run_processor ;;
  all|"")
    rc=0
    run_reader    || rc=1        # cheap/free first — surface a build break before spending
    echo ""
    run_notes     || rc=1        # free/no-network (like Reader)
    echo ""
    run_processor || rc=1
    echo ""
    [ "$rc" -eq 0 ] && echo "SUITE SMOKE: PASS ✅" || echo "SUITE SMOKE: FAIL ❌"
    exit "$rc" ;;
  *)
    echo "Archive Suite smoke tests"
    echo "Usage: ./test-smoke.sh reader|notes|processor|all"
    echo "  reader     → build + unit tests (free)"
    echo "  notes      → build + unit tests (free)"
    echo "  processor  → headless OCR pipeline, 2 images (a few cents)"
    echo "  all        → all three (default)"
    exit 2 ;;
esac
