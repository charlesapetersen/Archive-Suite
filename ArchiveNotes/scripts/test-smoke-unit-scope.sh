#!/bin/bash
# test-smoke-unit-scope.sh — prove the free Notes smoke command can never select the GUI target.
#
# Hermetic: the real smoke wrapper runs its normal XcodeGen step, but a temporary xcodebuild records its
# arguments instead of compiling or launching anything. This covers the INTERACTIVE/default environment;
# the previous bug hid there because only ARCHIVE_UNATTENDED selected the unit bundle.
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/archive-notes-smoke-scope.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
FAKE_BIN="$SCRATCH/bin"
ARGS="$SCRATCH/xcodebuild-args"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
: "${SMOKE_XCODEBUILD_ARGS:?}"
printf '%s\n' "$@" >"$SMOKE_XCODEBUILD_ARGS"
echo "TEST SUCCEEDED"
SH
chmod +x "$FAKE_BIN/xcodebuild"

ARCHIVE_UNATTENDED=0 SMOKE_XCODEBUILD_ARGS="$ARGS" PATH="$FAKE_BIN:$PATH" \
  bash "$APP_ROOT/test-smoke.sh" >"$SCRATCH/smoke.out" 2>&1

grep -Fx -- 'ArchiveNotesUnit' "$ARGS" >/dev/null
grep -Fx -- '-only-testing:ArchiveNotesTests' "$ARGS" >/dev/null
if grep -q 'ArchiveNotesUITests' "$ARGS"; then
  echo "FAIL: ordinary Notes smoke selected ArchiveNotesUITests" >&2
  exit 1
fi
grep -F 'SMOKE (notes): PASS' "$SCRATCH/smoke.out" >/dev/null

echo "✓ Notes smoke scope: normal invocation selects ArchiveNotesTests only"
