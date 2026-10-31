#!/usr/bin/env bash
# prove-docsync-packages.sh — prove the doc-sync Stop hook catches a real ArchiveCore source-only commit.
#
# The hook compares the session's origin/main range rather than a path allow-list, so a root-only fixture
# could pass while `packages/ArchiveCore` silently falls outside its matcher. This creates an isolated Git
# history with a Swift change exactly under that package, runs the REAL hook against it, and then adds the
# tracker touch that must make the same range pass. It then lands commits from a second worktree (standing in for
# the engine or another session) mid-session, and checks that only the session's own commits are judged: an
# engine code commit does not block, an engine tracker touch does not excuse the session's own code commit, and a
# commit made in the worktree the session cd'd into (the hook's stdin cwd) is counted. No remote, source checkout,
# or live hook state is changed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/docsync-guard.sh"
GATE="$ROOT/ops/autonomous/health-gate.sh"
[ -f "$HOOK" ] && [ -f "$GATE" ] || { echo "FATAL: doc-sync hook or health gate missing" >&2; exit 1; }

T="$(mktemp -d)"
W="$(mktemp -d)"
trap 'rm -rf "$T" "$W"' EXIT

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

# run_guard HEAD [STDIN_JSON] — the hook's stdin is what Claude Code would send (only its "cwd" is read).
run_guard() {
  set +e
  OUT="$(printf '%s' "${2:-}" | CLAUDE_PROJECT_DIR="$T" DOCSYNC_TEST_BASE="$BASE" DOCSYNC_TEST_HEAD="$1" bash "$HOOK" 2>&1)"
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

echo '== doc-sync counts only this session'"'"'s own commits =='
swift() { printf 'public enum DocSyncProofFixture { static let v = %s }\n' "$2" > "$1/packages/ArchiveCore/Sources/ArchiveCore/DocSyncProofFixture.swift"; }
BASE="$TRACKED_HEAD"
git -C "$T" worktree add -q -b engine "$W/engine" "$BASE"

# The engine lands a code-only commit; the session pulls it by fast-forward and has made nothing itself.
swift "$W/engine" 1; git -C "$W/engine" commit -qam 'engine ArchiveCore source only'
git -C "$T" merge -q --ff-only engine
ENGINE_HEAD="$(git -C "$T" rev-parse HEAD)"
run_guard "$ENGINE_HEAD"
[ "$RC" = 0 ] && ok "another worktree's code-only commit landing mid-session does not block" || no "engine-only range should pass, got rc=$RC: $OUT"

# The session's own code-only commit on top of it still blocks, and counts only itself.
swift "$T" 2; git -C "$T" commit -qam 'session ArchiveCore source only'
run_guard "$(git -C "$T" rev-parse HEAD)"
[ "$RC" = 2 ] && ok "the session's own code-only commit still blocks after an engine commit" || no "own commit should block with rc=2, got rc=$RC: $OUT"
case "$OUT" in *'landed 1 commit(s)'*) ok 'the block counts only the session'"'"'s own commit' ;; *) no "block miscounted the session's commits: $OUT" ;; esac

# The engine touches a tracker while the session's code commit waits; the session rebases onto it. The engine's
# tracker touch must not excuse the session's code.
BASE="$(git -C "$T" rev-parse HEAD)"
git -C "$W/engine" merge -q --ff-only "$BASE"
printf -- '- [ ] engine tracker touch\n' >> "$W/engine/SUITE_TODO.md"; git -C "$W/engine" commit -qam 'engine tracker touch'
swift "$T" 3; git -C "$T" commit -qam 'session ArchiveCore source, rebased'
git -C "$T" rebase -q engine
run_guard "$(git -C "$T" rev-parse HEAD)"
[ "$RC" = 2 ] && ok "an engine tracker touch does not excuse the session's own rebased code commit" || no "rebased own commit should block with rc=2, got rc=$RC: $OUT"

# A session launched in the primary checkout that commits in a worktree it cd'd into: counted via stdin cwd.
BASE="$(git -C "$T" rev-parse HEAD)"
git -C "$T" worktree add -q -b session "$W/session" "$BASE"
swift "$W/session" 4; git -C "$W/session" commit -qam 'session commit from its own worktree'
SESSION_HEAD="$(git -C "$W/session" rev-parse HEAD)"
run_guard "$SESSION_HEAD" "{\"session_id\":\"x\",\"cwd\":\"$W/session\",\"hook_event_name\":\"Stop\"}"
[ "$RC" = 2 ] && ok "a commit made in the session's cwd worktree is counted" || no "cwd-worktree commit should block with rc=2, got rc=$RC: $OUT"
run_guard "$SESSION_HEAD"
[ "$RC" = 0 ] && ok 'the same commit is not counted without that cwd (it is read from stdin)' || no "without cwd the worktree commit is not this checkout's, got rc=$RC: $OUT"

steps="$(grep -Ec '^step docsync-packages-proof[[:space:]]+bash "\$ROOT/ops/autonomous/tests/prove-docsync-packages.sh"$' "$GATE" || true)"
[ "$steps" = 1 ] && ok 'the proof is wired exactly once into the health gate' || no "expected one docsync-packages-proof gate step, found $steps"

echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
