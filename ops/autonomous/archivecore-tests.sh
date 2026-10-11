#!/usr/bin/env bash
# archivecore-tests.sh (W40.a2) — the health gate's `archivecore` step: `swift test` for packages/ArchiveCore.
#
# The shared package carries the tag writer, the PDF header parser and the corpus walker that every app reads
# through, and until 2026-10-11 nothing in the gate ran its own suite — the app bundles reach it only through
# their own call sites.
#
# Why a script and not an inline `step … swift test`: the gate quotes a failing step's last 40 lines, and
# `swift test` prints the Swift Testing run AFTER XCTest's. A planted XCTest failure measured a RED report of
# 40 lines of "✔ … passed" that never named the failing case. So on failure this re-prints the failure lines
# last, where the gate's tail picks them up.
#
# `swift test` is not xcodebuild, so the PATH shim does not lock it; heavy-enter.sh takes the Mac-wide lock.
# The scale cases skip without ARCHIVE_SCALE_*_ROOT; those are unset so a value left in the caller's env cannot
# point them at a tree. The scratch path is a gitignored `.build-gate/`, apart from a session's `.build/`.
# Measured 21-37 s on 2026-10-11 (264 XCTest with 4 skipped scale cases, plus 110 Swift Testing).
set -uo pipefail
. "$(dirname "$0")/heavy-enter.sh"
PKG="$(cd "$(dirname "$0")/../../packages/ArchiveCore" && pwd)" || exit 2
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
env -u ARCHIVE_SCALE_ROOT -u ARCHIVE_SCALE_HOSTILE_ROOT \
  swift test --package-path "$PKG" --scratch-path "$PKG/.build-gate" >"$out" 2>&1
rc=$?
cat "$out"
if [ "$rc" != 0 ]; then
  echo "--- ArchiveCore failures (rc=$rc) ---"
  grep -E 'error:|: failed|✘|Executed .* with [1-9][0-9]* failure' "$out" | head -30
fi
exit "$rc"
