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
# No flags at all: the usage line says they are optional, and bash 3.2's `set -u` must not abort on the empty array.
d7="$(run)" && [ -f "$d7/libArchiveCore.a" ] && ok "a call with no flags builds" || bad "no-flags call failed: $(cat "$T/err")"
# A lost race: another writer renames an identical, complete entry into place while this call builds. The loser
# must discard its copy, not nest it inside the winner as core-<key>/.building.* (BSD mv onto a directory).
REAL_XCRUN="$(command -v xcrun)"; mkdir -p "$T/shim"
cat > "$T/shim/xcrun" <<SHIM
#!/bin/bash
"$REAL_XCRUN" "\$@"; rc=\$?
case " \$* " in *" -emit-library "*) [ -n "\${RACE_WINNER:-}" ] && cp -R "\$RACE_WINNER" "\$RACE_ENTRY" ;; esac
exit \$rc
SHIM
chmod +x "$T/shim/xcrun"
cp -R "$d5" "$T/winner"; rm -rf "$d5"
d8="$(RACE_WINNER="$T/winner" RACE_ENTRY="$d5" PATH="$T/shim:$PATH" run -Onone)" && [ "$d8" = "$d5" ] \
  && [ -f "$d8/libArchiveCore.a" ] && [ -z "$(ls -A "$d8" | grep '^\.building')" ] \
  && ok "a build that loses the rename race leaves no copy inside the winning entry" \
  || bad "race loser: $d8 holds $(ls -A "$d8" 2>&1 | tr '\n' ' ') / $(cat "$T/err")"
# Pruning keeps the most recently USED entries: reuse an old one, build six newer keys, and it must survive.
OLD_CACHE="$ARCHIVECORE_CACHE"; export ARCHIVECORE_CACHE="$T/cache-prune"
printf 'public func coreAnswer() -> Int { 100 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"
used="$(run -Onone)"
for n in 101 102 103 104 105; do
  sleep 1; printf 'public func coreAnswer() -> Int { %s }\n' "$n" > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"; run -Onone >/dev/null
done
sleep 1; printf 'public func coreAnswer() -> Int { 100 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"
again="$(run -Onone)" && grep -q reusing "$T/err" || bad "the old entry was not reused: $(cat "$T/err")"
sleep 1; printf 'public func coreAnswer() -> Int { 106 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"; run -Onone >/dev/null
[ "$again" = "$used" ] && [ -d "$used" ] && [ "$(ls -1d "$ARCHIVECORE_CACHE"/core-* | wc -l | tr -d ' ')" = 6 ] \
  && ok "an entry reused just before a prune survives it" || bad "recently used entry pruned: $(ls "$ARCHIVECORE_CACHE")"
export ARCHIVECORE_CACHE="$OLD_CACHE"
printf 'public func coreAnswer() -> Int { 42 }\n' > "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/A.swift"
touch "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/C.swift"
[ -z "$(find "$SUITE" -newer "$SUITE/packages/ArchiveCore/Sources/ArchiveCore/C.swift" -type f ! -name '*.swift')" ] \
  && ok "nothing is written into the suite tree" || bad "files written into the suite: $(find "$SUITE" -type f ! -name '*.swift')"
[ -z "$(ls -A "$ARCHIVECORE_CACHE" | grep -v '^core-')" ] && ok "no temporary build directory is left behind" || bad "leftovers: $(ls -A "$ARCHIVECORE_CACHE")"
echo "archivecore-cache: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
