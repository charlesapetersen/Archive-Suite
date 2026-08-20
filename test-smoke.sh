#!/bin/bash
# test-smoke.sh — Archive Suite Tier-1 smoke-test dispatcher (mirrors launch.sh).
#
# Cheap, repeatable regression gate for the shared package and all three apps:
#   archivecore → shared Swift package unit tests       (free; no network/corpus)
#   reader      → build + unit-test suite               (free; no OCR/network/corpus)
#   notes       → build + unit-test suite               (free; no network/corpus)
#   processor   → headless OCR pipeline on 2 tiny images (a few cents; Gemini flash-lite)
#   all         → ArchiveCore, then all apps (default)
#
# Usage:  ./test-smoke.sh [archivecore|reader|notes|processor|all]
# Run from anywhere; it cd's to its own directory = repo root.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")"

run_archivecore(){ echo "──────── ArchiveCore ───────────"; (cd "./packages/ArchiveCore" && swift test); }
run_reader(){      echo "──────── Archive Reader ────────";    bash "./ArchiveReader/test-smoke.sh"; }
run_notes(){       echo "──────── Archive Notes ─────────";    bash "./ArchiveNotes/test-smoke.sh"; }
run_processor(){   echo "──────── Archive Processor ─────";    bash "./ArchiveProcessor/test-smoke.sh"; }

case "${1:-all}" in
  archivecore|core|ArchiveCore) run_archivecore ;;
  reader|r|ArchiveReader)         run_reader ;;
  notes|n|ArchiveNotes)           run_notes ;;
  processor|p|ArchiveProcessor)   run_processor ;;
  all|"")
    rc=0
    run_archivecore || rc=1      # shared dependency first — surface a Core break before its consumers
    echo ""
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
    echo "Usage: ./test-smoke.sh archivecore|reader|notes|processor|all"
    echo "  archivecore → shared Swift package unit tests (free)"
    echo "  reader     → build + unit tests (free)"
    echo "  notes      → build + unit tests (free)"
    echo "  processor  → headless OCR pipeline, 2 images (a few cents)"
    echo "  all        → ArchiveCore, then all three apps (default)"
    exit 2 ;;
esac
