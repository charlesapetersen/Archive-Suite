#!/usr/bin/env bash
# test-fixture-scripts.sh — prove the two Reader fixture builders need no Spotlight (W26.scripts).
#
# `make-gui-fixture.sh` and `smoke-setup.sh` used to `mdimport` their output and then poll `mdfind`
# for up to 60 s / 40 s waiting for the tags to appear in the index. Reader discovery is a
# filesystem walk now (ArchiveCore `CorpusWalker`), so that wait is not merely slow — it is
# UNSATISFIABLE wherever the GUI lane actually runs: a `mktemp` dir is never indexed, and the Tart
# guest boots with a cold index. Both scripts only WARNED when the poll timed out, so the failure
# mode was a fixture that shipped looking fine and made its UITests fail later for an unrelated-
# sounding reason.
#
# The gate this file enforces (SUITE_TODO W26.scripts): *both scripts produce a usable fixture on a
# volume with indexing disabled.* Three layers, because any one alone can pass vacuously:
#
#   1. STATIC — neither script mentions `mdimport`/`mdfind`/a `kMDItem*` QUERY. (The xattr NAME
#      `com.apple.metadata:_kMDItemUserTags` is not a Spotlight query and must survive.)
#   2. DYNAMIC — run both with `mdimport`/`mdfind` shimmed to a tripwire that records the call and
#      exits 1. A script that still reached for Spotlight leaves the tripwire behind even if it
#      swallowed the error with `2>/dev/null || true`, which the old code did.
#   3. MUTATION — the on-disk verification that REPLACED the poll must be able to fail. Each mutant
#      breaks the fixture in one specific way and must be caught by name; a verification nobody can
#      make fail is the same vacuous pass in a new place.
#
# Everything is built in a mktemp dir via the scripts' `AR_FIXTURE_DST` / `AR_SMOKE_DST` overrides —
# which is ALSO the unindexed volume the gate asks for, so layer 2 doubles as the real condition.
# The owner's real fixture at ~/Library/Application Support/ArchiveReader is never touched, and the
# source corpus is only ever read.
#
# Usage: ArchiveReader/scripts/test-fixture-scripts.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUI_FIXTURE="$REPO/ArchiveReader/scripts/make-gui-fixture.sh"
SMOKE="$REPO/ArchiveReader/scripts/smoke-setup.sh"
CORPUS="${AR_FIXTURE_SRC:-$HOME/Claude/Archive Suite/Test files/Brown Gemini}"
# smoke-setup.sh has no SRC override — it hardcodes this. Spelled out rather than reusing $CORPUS so
# an AR_FIXTURE_SRC in the environment cannot silently point the smoke cases somewhere else.
SMOKE_SRC="$HOME/Claude/Archive Suite/Test files/Brown Gemini"

pass=0; failed=0
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fixture-scripts-test.XXXXXX")"
cleanup() { [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

ok()   { echo "✓ $1"; pass=$((pass+1)); }
bad()  { echo "✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; failed=$((failed+1)); }

# --- the Spotlight tripwire ------------------------------------------------------------------
# Not just a failing stub: a stub that RECORDS being called. The old code piped both tools to
# /dev/null and `|| true`-ed the poll, so a non-zero exit alone would have proved nothing.
TRIPWIRE="$SCRATCH/spotlight-was-called"
SHIMDIR="$SCRATCH/bin"
mkdir -p "$SHIMDIR"
for tool in mdimport mdfind mdls mdutil; do
  cat > "$SHIMDIR/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$TRIPWIRE"
exit 1
EOF
  chmod +x "$SHIMDIR/$tool"
done

# run_shimmed <env assignments…> -- <script> [args…]  → stdout+stderr in \$OUT, rc in \$RC
run_shimmed() {
  local envs=() ; while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT="$(env PATH="$SHIMDIR:$PATH" "${envs[@]}" bash "$@" 2>&1)"; RC=$?
}

echo "── preflight ───────────────────────────────────────────────────────────────"
if [ -d "$CORPUS" ]; then ok "source corpus present: $CORPUS"
else bad "source corpus missing: $CORPUS (set AR_FIXTURE_SRC)"; echo; echo "✗ aborting"; exit 1; fi
if [ -x /opt/homebrew/bin/tag ]; then ok "tag CLI present"
else bad "tag CLI missing — brew install tag"; echo; echo "✗ aborting"; exit 1; fi

echo "── 1. static: no Spotlight query left in either script ─────────────────────"
for s in "$GUI_FIXTURE" "$SMOKE"; do
  name="$(basename "$s")"
  # `kMDItem` on its own is allowed (it names the xattr); a QUERY is what is banned, and the two
  # spellings of one are the tools themselves and a `kMDItem… ==` predicate.
  hits="$(grep -nE 'mdimport|mdfind|mdls[[:space:]]|kMDItem[A-Za-z]*[[:space:]]*==' "$s" \
          | grep -v 'W26.scripts' | grep -v '^[0-9]*:#')"
  if [ -z "$hits" ]; then ok "$name has no Spotlight query"
  else bad "$name still queries Spotlight" "$hits"; fi
done

echo "── 2+3. make-gui-fixture.sh ────────────────────────────────────────────────"
GDST="$SCRATCH/AR-GUI-Fixture"
run_shimmed "AR_FIXTURE_SRC=$CORPUS" "AR_FIXTURE_DST=$GDST" -- "$GUI_FIXTURE"
if [ "$RC" -eq 0 ]; then ok "builds on an unindexed volume with Spotlight shimmed out"
else bad "exited rc=$RC on an unindexed volume" "$OUT"; fi

if [ ! -f "$TRIPWIRE" ]; then ok "never invoked mdimport/mdfind"
else bad "reached for Spotlight" "$(cat "$TRIPWIRE")"; fi

# stdout contract: FixtureUITestCase's caller passes this straight to -ARUITestRootPath.
last="$(printf '%s' "$OUT" | tail -1)"
if [ "$last" = "$GDST" ]; then ok "emits the fixture path on stdout"
else bad "stdout is not the fixture path" "got: $last"; fi

n_files=$(ls "$GDST" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_files" -eq 12 ]; then ok "12 fixture files"
else bad "expected 12 fixture files, got $n_files"; fi

if [ -f "$GDST/.archive-suite-root.json" ]; then ok "root marker written (W23.m4 — durable links)"
else bad "root marker .archive-suite-root.json missing"; fi

# Exact-token count, the same trap the script itself avoids: "Read" is a substring of "Unread".
count_read_state() {
  local n=0 t
  for p in "$1"/*; do
    [ -f "$p" ] || continue
    t=$(/opt/homebrew/bin/tag -lN "$p" 2>/dev/null || true)
    case ",$t," in *,Read,*|*,Unread,*) n=$((n+1)) ;; esac
  done
  echo "$n"
}
n_tagged="$(count_read_state "$GDST")"
if [ "$n_tagged" -eq 11 ]; then ok "11 of 12 carry Read/Unread on disk"
else bad "expected 11 files with a read state, got $n_tagged"; fi

t9=$(/opt/homebrew/bin/tag -lN "$GDST/00009 IMG — Brown.pdf" 2>/dev/null || true)
case ",$t9," in
  *,Read,*|*,Unread,*) bad "file 9 must have NEITHER read state (tri-state bucket)" "tags: $t9" ;;
  *) ok "file 9 has neither Read nor Unread" ;;
esac

# THE GATE, stated directly: the fixture is complete and correct, and Spotlight — the real one, not
# the shim — can see none of it. Anything that waited on the index here would wait for ever.
if command -v /usr/bin/mdfind >/dev/null 2>&1; then
  indexed=$(/usr/bin/mdfind -onlyin "$GDST" 'kMDItemUserTags == "Unread" || kMDItemUserTags == "Read"' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$indexed" -eq 0 ]; then ok "Spotlight indexes 0 of the 12 — a usable fixture on an unindexed volume"
  else bad "expected an UNindexed scratch volume; mdfind saw $indexed (the negative control is void)"; fi
else ok "(no /usr/bin/mdfind on this machine — unindexed by construction)"; fi

# --- mutants: the replacement verification must be able to fail --------------------------------
# expect_mutant <name> <sed-program> <needle the failure must name>
expect_mutant() {
  local name="$1" prog="$2" needle="$3" mdir mscript
  mdir="$SCRATCH/mutant-$RANDOM"; mkdir -p "$mdir"
  mscript="$mdir/make-gui-fixture.sh"
  sed "$prog" "$GUI_FIXTURE" > "$mscript"
  if cmp -s "$mscript" "$GUI_FIXTURE"; then
    bad "mutant '$name' changed NOTHING — the sed no longer matches, so this case is vacuous"; return
  fi
  run_shimmed "AR_FIXTURE_SRC=$CORPUS" "AR_FIXTURE_DST=$mdir/out" -- "$mscript"
  if [ "$RC" -eq 0 ]; then bad "mutant '$name' PASSED — the on-disk check does not catch it" "$OUT"; return; fi
  if ! printf '%s' "$OUT" | grep -qF "$needle"; then
    bad "mutant '$name' failed, but never said '$needle'" "$OUT"; return
  fi
  ok "mutant caught: $name"
}

expect_mutant "file 9 gains a read state (retires the tri-state test)" \
  's/^set_tags "00009 IMG — Brown.pdf" "1979,Budget Policy"$/set_tags "00009 IMG — Brown.pdf" "1979,Budget Policy,Read"/' \
  "must have NEITHER"

expect_mutant "file 1 loses its read state" \
  's/^set_tags "00001 IMG — Brown.pdf" "1980,03 March,Jerry Brown,P9,Read"$/set_tags "00001 IMG — Brown.pdf" "1980,03 March,Jerry Brown,P9"/' \
  "no Read/Unread on disk"

# The PNG that `sips` converts to the fixture JPEG is scratch and is deleted right after. Skipping
# that cleanup leaves a 13th, untagged file in the fixture — the realistic version of "the count
# drifted", and the only one of the three mutants that reaches the TOTAL half of the check. (A
# mutant that removes a file EARLIER never gets there: `tag` fails on the missing path and `set -e`
# aborts first — which is correct, just not this check's doing.)
expect_mutant "the scratch PNG is left behind (a file too many)" \
  's/^rm -f "\$TMPPNG"$/: rm -f "$TMPPNG"/' \
  "want 12"

echo "── 4. the DST override cannot aim rm -rf somewhere that matters ────────────"
# AR_FIXTURE_DST / AR_SMOKE_DST are new (W26.scripts) and they feed a `rm -rf`, so the guard that
# came with them is tested here rather than trusted. Each case must be refused BEFORE the delete —
# proven for the corpus case by a sentinel that has to survive.
guard_refused() {  # guard_refused <name> <script> <sentinel-dir-or-empty> <env…>
  local name="$1" script="$2" sentinel="$3"; shift 3
  [ -z "$sentinel" ] || { mkdir -p "$sentinel"; : > "$sentinel/DO-NOT-DELETE"; }
  run_shimmed "$@" -- "$script"
  if [ "$RC" -eq 0 ]; then bad "guard '$name' did NOT refuse" "$OUT"; return; fi
  if ! printf '%s' "$OUT" | grep -q 'refusing\|must be an absolute path'; then
    bad "guard '$name' failed for some other reason" "$OUT"; return
  fi
  if [ -n "$sentinel" ] && [ ! -f "$sentinel/DO-NOT-DELETE" ]; then
    bad "guard '$name' refused but the rm had already run"; return
  fi
  ok "refused: $name"
}

guard_refused "a one-component fixture DST" "$GUI_FIXTURE" "" \
  "AR_FIXTURE_SRC=$CORPUS" "AR_FIXTURE_DST=/tmp"
guard_refused "the fixture DST is \$HOME" "$GUI_FIXTURE" "" \
  "AR_FIXTURE_SRC=$CORPUS" "AR_FIXTURE_DST=$HOME"
# My first cut of the guard passed this one: "$HOME/" is the same directory but a different string,
# so the equality check missed it and the depth check was happy — i.e. the exact path the guard
# exists for was the one it let through.
guard_refused "the fixture DST is \$HOME with a trailing slash" "$GUI_FIXTURE" "" \
  "AR_FIXTURE_SRC=$CORPUS" "AR_FIXTURE_DST=$HOME/"
guard_refused "the smoke DST is /" "$SMOKE" "" "AR_SMOKE_DST=/"
guard_refused "the fixture DST is inside the source corpus" "$GUI_FIXTURE" "$SCRATCH/fakesrc" \
  "AR_FIXTURE_SRC=$SCRATCH/fakesrc" "AR_FIXTURE_DST=$SCRATCH/fakesrc/out"
guard_refused "the smoke DST is inside the real Test files corpus" "$SMOKE" "" \
  "AR_SMOKE_DST=$SMOKE_SRC/out"

echo "── 2+3. smoke-setup.sh ─────────────────────────────────────────────────────"
SDST="$SCRATCH/AR-Smoke"
rm -f "$TRIPWIRE"
run_shimmed "AR_SMOKE_DST=$SDST" -- "$SMOKE" 5
if [ "$RC" -eq 0 ]; then ok "builds on an unindexed volume with Spotlight shimmed out"
else bad "exited rc=$RC on an unindexed volume" "$OUT"; fi

if [ ! -f "$TRIPWIRE" ]; then ok "never invoked mdimport/mdfind"
else bad "reached for Spotlight" "$(cat "$TRIPWIRE")"; fi

n_smoke=$(ls "$SDST" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_smoke" -eq 5 ]; then ok "5 copies made"
else bad "expected 5 copies, got $n_smoke"; fi

# The one claim the old poll never checked: ditto carried the tag xattr across.
n_smoke_tagged="$(count_read_state "$SDST")"
if [ "$n_smoke_tagged" -eq 5 ]; then ok "all 5 copies kept their Finder tags"
else bad "expected 5 tagged copies, got $n_smoke_tagged"; fi

# Mutant: `cp -X` copies the bytes but drops extended attributes. The copy still looks right — same
# names, same sizes — and only the xattr comparison can tell. If this passes, the verification is
# decorative and the scratch corpus could go untagged unnoticed, which is the whole failure this
# script exists to prevent.
mdir="$SCRATCH/mutant-smoke"; mkdir -p "$mdir"
sed 's|^  ditto "\$SRC/\$f" "\$DST/\$f".*$|  cp -X "$SRC/$f" "$DST/$f"|' "$SMOKE" > "$mdir/smoke-setup.sh"
if cmp -s "$mdir/smoke-setup.sh" "$SMOKE"; then
  bad "smoke mutant changed NOTHING — the sed no longer matches, so this case is vacuous"
else
  run_shimmed "AR_SMOKE_DST=$mdir/out" -- "$mdir/smoke-setup.sh" 5
  if [ "$RC" -eq 0 ]; then bad "mutant 'cp -X drops the tag xattr' PASSED — the copy check is decorative" "$OUT"
  elif ! printf '%s' "$OUT" | grep -qF "tags did not survive the copy"; then
    bad "mutant 'cp -X' failed, but never named the surviving tags" "$OUT"
  else ok "mutant caught: cp -X drops the tag xattr"; fi
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "✓ fixture-scripts self-test: $pass/$pass checks passed"
  exit 0
fi
echo "✗ fixture-scripts self-test: $failed failed, $pass passed"
exit 1
