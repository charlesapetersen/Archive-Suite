#!/bin/bash
# test-archivecore-cache.sh — proves archivecore-cache.sh reuses a build only for identical inputs.
# Scratch only: a fake suite with a two-file ArchiveCore, a scratch cache; nothing in the real tree is built or
# written. Each case compiles a few lines with swiftc (seconds), so it takes the heavy lock like its caller.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ARCHIVECORE_CACHE="$T/cache"
SUITE="$T/suite with space"; mkdir -p "$SUITE/packages/ArchiveCore/Sources/ArchiveCore"
printf 'public func coreAnswer() -> Int { 41 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"
printf 'public let coreName = "core"\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/B.swift"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok  $1"; }; bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
run() { bash "$HERE/archivecore-cache.sh" "$SUITE" "$@" 2>"$T/err"; }

d1="$(run -Onone)" && [ -f "$d1/libArchiveCore.a" ] && grep -q 'building' "$T/err" && ok "first call builds" || bad "first build: $(cat "$T/err")"
case "$d1" in "$ARCHIVECORE_CACHE"/core-*) ok "the entry lives in the cache, outside the suite" ;; *) bad "entry at $d1" ;; esac
d2="$(run -Onone)" && [ "$d2" = "$d1" ] && grep -q 'reusing' "$T/err" && ok "identical inputs reuse the entry" || bad "no reuse: $d2 / $(cat "$T/err")"
d3="$(run -O)" && [ "$d3" != "$d1" ] && ok "other flags build another entry" || bad "flags ignored"
printf 'public func coreAnswer() -> Int { 42 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"
d4="$(run -Onone)" && [ "$d4" != "$d1" ] && grep -q 'building' "$T/err" && ok "a changed source builds another entry" || bad "stale reuse after a source edit"
mv "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/B.swift" "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/C.swift"
d5="$(run -Onone)" && [ "$d5" != "$d4" ] && ok "a renamed source builds another entry" || bad "stale reuse after a rename"
rm "$d5/COMPLETE"
d6="$(run -Onone)" && [ "$d6" = "$d5" ] && grep -q 'building' "$T/err" && [ -f "$d6/COMPLETE" ] && ok "an incomplete entry is rebuilt, never reused" || bad "incomplete entry reused: $(cat "$T/err")"
printf 'public func broken( {\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/D.swift"
if run -Onone >/dev/null; then bad "a broken source passed"; else ok "a compile error fails the call"; fi
rm "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/D.swift"
[ -z "$(find "$SUITE" -newer "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/C.swift" -type f ! -name '*.swift')" ] \
  && ok "nothing is written into the suite tree" || bad "files written into the suite: $(find "$SUITE" -type f ! -name '*.swift')"
[ -z "$(ls -A "$ARCHIVECORE_CACHE" | grep -v '^core-')" ] && ok "no temporary build directory is left behind" || bad "leftovers: $(ls -A "$ARCHIVECORE_CACHE")"
echo "archivecore-cache: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
