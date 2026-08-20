#!/usr/bin/env bash
# prove-docsync-packages.sh — prove the doc-sync Stop hook catches a real ArchiveCore source-only commit.
#
# The hook compares the session's origin/main range rather than a path allow-list, so a root-only fixture
# could pass while `packages/ArchiveCore` silently falls outside its matcher. This creates an isolated Git
# history with a Swift change exactly under that package, runs the REAL hook against it, and then adds the
# tracker touch that must make the same range pass. No remote, source checkout, or live hook state is changed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/docsync-guard.sh"
GATE="$ROOT/ops/autonomous/health-gate.sh"
[ -f "$HOOK" ] && [ -f "$GATE" ] || { echo "FATAL: doc-sync hook or health gate missing" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

git -C "$T" init -q
git -C "$T" config user.email 'doc-sync-proof@example.invalid'
git -C "$T" config user.name 'doc-sync proof'
mkdir -p "$T/.claude" "$T/packages/ArchiveCore/Sources/ArchiveCore"
printf 'public enum DocSyncProofFixture {}\n' > "$T/packages/ArchiveCore/Sources/ArchiveCore/DocSyncProofFixture.swift"
git -C "$T" add packages
git -C "$T" commit -qm 'fixture baseline'
BASE="$(git -C "$T" rev-parse HEAD)"

printf 'public enum DocSyncProofFixture { static let changed = true }\n' > "$T/packages/ArchiveCore/Sources/ArchiveCore/DocSyncProofFixture.swift"
git -C "$T" add packages
git -C "$T" commit -qm 'fixture ArchiveCore source only'
SOURCE_ONLY_HEAD="$(git -C "$T" rev-parse HEAD)"

run_guard() {
  set +e
  OUT="$(CLAUDE_PROJECT_DIR="$T" DOCSYNC_TEST_BASE="$BASE" DOCSYNC_TEST_HEAD="$1" bash "$HOOK" 2>&1)"
  RC=$?
  set -e
}

echo '== doc-sync ArchiveCore package proof =='

run_guard "$SOURCE_ONLY_HEAD"
[ "$RC" = 2 ] && ok 'a packages/ArchiveCore Swift-only range is blocked' || no "source-only range should block with rc=2, got rc=$RC: $OUT"
case "$OUT" in *'doc-sync backstop'*) ok 'the block identifies the doc-sync backstop' ;; *) no "block omitted its identity: $OUT" ;; esac
case "$OUT" in *'NEITHER SUITE_TODO.md NOR KNOWN_ISSUES.md'*) ok 'the block names the missing tracker requirement' ;; *) no "block omitted the tracker requirement: $OUT" ;; esac
[ ! -e "$T/.claude/.docsync-baseline" ] && ok 'a blocked range does not advance the session baseline' || no 'a blocked range advanced the session baseline'

printf -- '- [ ] fixture tracker touch\n' > "$T/SUITE_TODO.md"
git -C "$T" add SUITE_TODO.md
git -C "$T" commit -qm 'fixture tracker touch'
TRACKED_HEAD="$(git -C "$T" rev-parse HEAD)"
run_guard "$TRACKED_HEAD"
[ "$RC" = 0 ] && ok 'the same package range passes once a tracker is touched' || no "tracked range should pass, got rc=$RC: $OUT"
[ "$(cat "$T/.claude/.docsync-baseline")" = "$TRACKED_HEAD" ] && ok 'a synced range advances the session baseline' || no 'a synced range did not record its head as the baseline'

steps="$(grep -Ec '^step docsync-packages-proof[[:space:]]+bash "\$ROOT/ops/autonomous/tests/prove-docsync-packages.sh"$' "$GATE" || true)"
[ "$steps" = 1 ] && ok 'the proof is wired exactly once into the health gate' || no "expected one docsync-packages-proof gate step, found $steps"

echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
