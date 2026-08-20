#!/usr/bin/env bash
# test-fixture-scripts.sh — prove the GUI fixture builders are corpus-free and need no Spotlight.
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
# Everything is built in a mktemp dir via the scripts' destination overrides — which is ALSO the
# unindexed volume the gate asks for, so layer 2 doubles as the real condition. The primary GUI
# builders use their generated-PDF default; an optional source corpus is never needed or touched.
#
# Usage: ArchiveReader/scripts/test-fixture-scripts.sh
#   exit 0 = every check passed · 1 = a check FAILED · 3 = a prerequisite is missing, nothing ran.
# Also run unattended by the daemon health gate, as the skippable step `fixture-scripts`
# (`ops/autonomous/health-gate.sh`) — wired there by `W26.lint-fu` on 2026-08-07.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUI_FIXTURE="$REPO/ArchiveReader/scripts/make-gui-fixture.sh"
NOTES_FIXTURE="$REPO/ArchiveNotes/scripts/make-notes-fixture.sh"
SMOKE="$REPO/ArchiveReader/scripts/smoke-setup.sh"
# smoke-setup.sh has no source override and remains a separate, corpus-backed smoke fixture.
SMOKE_SRC="$HOME/Claude/Archive Suite/Test files/Brown Gemini"

pass=0; failed=0
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fixture-scripts-test.XXXXXX")"
cleanup() { [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

ok()   { echo "✓ $1"; pass=$((pass+1)); }
bad()  { echo "✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; failed=$((failed+1)); }
# An absent PREREQUISITE is not a failed check. Exit 3 is the health gate's "ran nothing,
# inconclusive" code (`step_skippable` in `ops/autonomous/health-gate.sh`; wired by `W26.lint-fu`,
# 2026-08-07, which asked whether a missing `tag` CLI should RED the gate and answered
# no — for the same reason the VM lane skips, an absent prerequisite is not a regression, and a
# gate that parks over one teaches its reader to ignore parks). It is still NON-ZERO, so a human
# `if ./test-fixture-scripts.sh` reads it as "not proven" exactly as before; the `SKIPPED:` prefix
# is the line the gate quotes back in the "NOT VERIFIED:" tail of its summary. Only the two
# preflight cases may use this — a real check that fails is always exit 1.
skip() { echo "SKIPPED: $1"; echo "⊘ nothing was proven — prerequisite missing"; exit 3; }

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
if [ -x /opt/homebrew/bin/tag ]; then ok "tag CLI present"
else skip "tag CLI missing — brew install tag"; fi
if [ -d "$SMOKE_SRC" ]; then
  HAVE_SMOKE_CORPUS=1
  ok "optional smoke-setup corpus present: $SMOKE_SRC"
else
  HAVE_SMOKE_CORPUS=0
  echo "⊘ smoke-setup's separate corpus-backed portion will be skipped: $SMOKE_SRC"
fi

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
run_shimmed "AR_FIXTURE_SRC=" "AR_FIXTURE_DST=$GDST" -- "$GUI_FIXTURE"
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

if grep -aqF "Reader synthetic fixture page 1" "$GDST/00001 IMG — Brown.pdf"; then
  ok "default GUI PDFs carry synthetic text (no source corpus needed)"
else
  bad "default GUI PDF is not the text-bearing synthetic fixture"
fi
if command -v pdfinfo >/dev/null 2>&1; then
  reader_pages="$(pdfinfo "$GDST/00001 IMG — Brown.pdf" 2>/dev/null | awk '/^Pages:/ {print $2}')"
  if [ "$reader_pages" = 2 ]; then ok "default Reader PDF keeps the standard two-page shape"
  else bad "default Reader PDF is not two pages" "pdfinfo Pages: ${reader_pages:-unreadable}"; fi
else
  echo "⊘ pdfinfo unavailable — skipped the optional PDF page-count parse"
fi

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
  run_shimmed "AR_FIXTURE_SRC=" "AR_FIXTURE_DST=$mdir/out" -- "$mscript"
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

echo "── 2. Archive Notes synthetic fixture ───────────────────────────────────────"
NOTES_HOME="$SCRATCH/notes-home"
run_shimmed "HOME=$NOTES_HOME" "NOTES_FIXTURE_CORPUS=" -- "$NOTES_FIXTURE"
NDST="$NOTES_HOME/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"
if [ "$RC" -eq 0 ]; then ok "Notes fixture builds with no source corpus"
else bad "Notes fixture exited rc=$RC without a source corpus" "$OUT"; fi

last="$(printf '%s' "$OUT" | tail -1)"
if [ "$last" = "$NDST" ]; then ok "Notes fixture emits its scratch path on stdout"
else bad "Notes fixture stdout is not its scratch path" "got: $last"; fi

n_notes_pdfs="$(find "$NDST/reader-corpus" -type f -name '*.pdf' 2>/dev/null | wc -l | tr -d ' ')"
expected_notes_pdfs=$((8 + 1)) # N_PDFS generated PDFs + sample.pdf
if [ "$n_notes_pdfs" -eq "$expected_notes_pdfs" ]; then
  ok "Notes fixture has 8 generated reader PDFs plus sample.pdf"
else
  bad "Notes fixture PDF count is wrong" "expected $expected_notes_pdfs, got $n_notes_pdfs"
fi
if grep -aqF "Notes synthetic fixture page 1" "$NDST/reader-corpus/sample.pdf"; then
  ok "Notes durable-link sample is a text-bearing synthetic PDF"
else
  bad "Notes durable-link sample is not the synthetic text-bearing PDF"
fi
if command -v pdfinfo >/dev/null 2>&1; then
  notes_pages="$(pdfinfo "$NDST/reader-corpus/sample.pdf" 2>/dev/null | awk '/^Pages:/ {print $2}')"
  if [ "$notes_pages" = 2 ]; then ok "Notes durable-link sample keeps the standard two-page shape"
  else bad "Notes durable-link sample is not two pages" "pdfinfo Pages: ${notes_pages:-unreadable}"; fi
else
  echo "⊘ pdfinfo unavailable — skipped the optional Notes PDF page-count parse"
fi

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
  "AR_FIXTURE_SRC=" "AR_FIXTURE_DST=/tmp"
guard_refused "the fixture DST is \$HOME" "$GUI_FIXTURE" "" \
  "AR_FIXTURE_SRC=" "AR_FIXTURE_DST=$HOME"
# My first cut of the guard passed this one: "$HOME/" is the same directory but a different string,
# so the equality check missed it and the depth check was happy — i.e. the exact path the guard
# exists for was the one it let through.
guard_refused "the fixture DST is \$HOME with a trailing slash" "$GUI_FIXTURE" "" \
  "AR_FIXTURE_SRC=" "AR_FIXTURE_DST=$HOME/"
guard_refused "the smoke DST is /" "$SMOKE" "" "AR_SMOKE_DST=/"
guard_refused "the fixture DST is inside the source corpus" "$GUI_FIXTURE" "$SCRATCH/fakesrc" \
  "AR_FIXTURE_SRC=$SCRATCH/fakesrc" "AR_FIXTURE_DST=$SCRATCH/fakesrc/out"
if [ "$HAVE_SMOKE_CORPUS" -eq 1 ]; then
  guard_refused "the smoke DST is inside the real Test files corpus" "$SMOKE" "" \
    "AR_SMOKE_DST=$SMOKE_SRC/out"
fi

echo "── 2+3. smoke-setup.sh ─────────────────────────────────────────────────────"
if [ "$HAVE_SMOKE_CORPUS" -eq 1 ]; then
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
else
  echo "⊘ skipped smoke-setup's separate corpus-backed checks; GUI fixture coverage above is corpus-free"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "✓ fixture-scripts self-test: $pass/$pass checks passed"
  exit 0
fi
echo "✗ fixture-scripts self-test: $failed failed, $pass passed"
exit 1
