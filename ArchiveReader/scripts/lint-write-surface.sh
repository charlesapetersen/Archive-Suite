#!/usr/bin/env bash
# lint-write-surface.sh — enforce the Core Directive (ArchiveReader/CLAUDE.md) at the source level,
# across the Reader app target, shared ArchiveCore package, and the Notes rules it shares.
#
#   1) A Finder-tag write API (setResourceValue(s) / setxattr) may appear ONLY at the audited
#      write choke-point — ArchiveCore's `CoordinatedTagWriter` (Tags/TagWrite.swift).
#   2) NO file in either tree may call a move / rename / delete / trash / content-write API,
#      except at the individually audited sites in the ALLOW list below.
#   3) ArchiveCore must remain UI-free: no `import AppKit` or `import SwiftUI` in its sources.
#
# Run before every commit; exit non-zero on violation. It is ALSO run by the daemon's health gate
# (`ops/autonomous/health-gate.sh`, step `write-surface-lint`, with its self-test alongside as step
# `write-surface-lint-proof`) — wired there by `W26.lint-fu` on 2026-08-07. ⚠️ That sentence is only
# worth having because the previous one like it was FALSE: the header claimed "also invoked by the
# autonomous build" and on 2026-08-05 that was measured to have no caller anywhere in `ops/`,
# `.claude/hooks/`, or any script. If you move or rename the gate step, fix this line with it.
#
# ── SCOPE (W26.lint, 2026-08-05) ─────────────────────────────────────────────────────────────
# `SRC` used to be just `macOS/Sources/ArchiveReader`, which left `packages/ArchiveCore`
# — where the actual write choke-point lives — entirely unlinted. That is where the Core
# Directive violation fixed in W26.deny sat. And because the Reader's own `TagWriter` is now a
# *delta adapter* over `CoordinatedTagWriter`, the app target has ZERO tag-write hits of its own:
# rule 1 was passing VACUOUSLY. Both trees are linted now, and the whole permitted tag-write
# surface of the suite is the three exact lines allowed below. W26.lint-fu then added the Notes
# tag-write and enumerator scopes; W9.c3 adds the UI-free ArchiveCore import boundary.
#
# ── ALLOWANCES ARE (file, exact source line) PAIRS — never whole files ────────────────────────
# A file-level exemption inside ArchiveCore would be a permanent unchecked hole in the package
# that is about to host the corpus walker (`execution-plans/despotlight.md` §7a.8). So an
# allowance pins the exact source line, and *reformatting an allowed line trips the lint on
# purpose*: re-audit the write, then update the pair here.
#
# ArchiveCore is shared with the Processor and Notes, which legitimately write files. Adding such
# a write to the package is therefore a Tier-2 change: audit the call, then add its exact line
# below. Do not widen a rule, delete a rule, or exempt a file.
#
# Two guards below make "✓ clean" mean something: a renamed source root fails loudly instead of
# being silently skipped by grep, and an allowance whose line no longer exists is reported STALE
# rather than sitting there as a pre-approved hole. Honest limit of matching on line *content*:
# a byte-identical duplicate of an allowed line, in the same file, would also be allowed. The
# allowed lines all reference locals that exist only inside the writer's coordination block, so a
# copy elsewhere would not compile — but line numbers were rejected as the alternative (they churn
# on every edit above the site, which is how an allowlist stops being read).
#
# ── RULE 3: no `errorHandler:`-less FileManager.enumerator (W26.walk1, 2026-08-05) ────────────
# That overload SILENTLY skips any directory it cannot descend into — no error, no count, and the
# caller's scan still looks complete (plan §4a.2, confirmed by measurement: without the handler a
# sealed directory was listed but never descended; with it, code 257 fired). It is one of the two
# ways the de-Spotlight fix could have reproduced the incident it exists to end, so it is banned
# in the linted trees rather than left to reviewer memory.
#
# Known shape it does NOT understand: a TRAILING-closure spelling — `.enumerator(at: …) { url, err
# in … }` — puts the handler outside the parentheses, so the rule reports it. That direction is
# fail-safe (a false alarm on honest code, never a silent pass), and the fix is to write the
# `errorHandler:` label. Say so here rather than let someone rediscover it as a mystery failure.
#
# ⚠️ The rule CANNOT be a grep. Measured while writing it: `enumerator(at:` matches ZERO
# occurrences in this repo because every call is written across lines, so the obvious rule would
# have passed vacuously — the worst kind of green (plan §7a.8). It therefore balances parentheses
# with perl to isolate the whole call, across however many lines it spans, and asks whether THAT
# text contains `errorHandler:`.
set -uo pipefail

# Repo root, so violation paths read the same way everywhere. `LINT_WRITE_SURFACE_ROOT` is a
# TEST-ONLY override (see scripts/test-lint-write-surface.sh) — never set it in a real run.
REPO_ROOT="${LINT_WRITE_SURFACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_ROOT" || { echo "✗ cannot cd to $REPO_ROOT"; exit 1; }

# ── SOURCE LISTS ARE PER-RULE (W26.lint-fu, 2026-08-07) ───────────────────────────────────────
# One list shared by all three rules forced an all-or-nothing choice about Archive Notes, an app
# whose whole job is writing `.md` files. Measured against `ArchiveNotes/macOS/Sources/ArchiveNotes`
# on 2026-08-07: rule 1 → **0 hits**, rule 3 → **0 hits**, rule 2 → **11 hits** (six in `NoteStore`,
# the rest its Zotero cache, organization file, inline-image attachments and root marker). Auditing
# those eleven would mostly amount to writing "NoteStore writes notes" eleven times, and an allowance
# list that says nothing is how an allowlist stops being read. `W26.lint-fu` posed exactly this
# choice — audit the eleven, or split the lists — and preferred this shape.
#
# So rules 1 and 3 cover Notes and rule 2 does not. That is a DECISION, not an oversight:
#   * rule 1 (tag write) — Notes projects Finder tags too, and it has no business writing one outside
#     ArchiveCore's choke-point. Zero hits today, so this is a live tripwire, not inherited debt.
#   * rule 3 (silent enumerator) — `W26.notesabsence` fixed the single hit Notes had; the rule is what
#     stops it coming back. This is the coverage `W26.lint-fu` asked for by name.
#   * rule 2 (destructive / content write) — deliberately NOT extended. Adding the tree without first
#     auditing those eleven writes would simply turn this lint RED, and a RED lint nobody can fix in
#     one sitting is a lint that gets skipped.
# The Processor tree is in no list, also deliberately: its `MacOSTagger` is the suite's *fresh-write*
# tag adapter, so rule 1 there needs its own audit before the tree can be added.
SRC_READER="ArchiveReader/macOS/Sources/ArchiveReader"
SRC_CORE="packages/ArchiveCore/Sources/ArchiveCore"
SRC_NOTES="ArchiveNotes/macOS/Sources/ArchiveNotes"

SRC_TAGWRITE=(    "$SRC_READER" "$SRC_CORE" "$SRC_NOTES" )
SRC_DESTRUCTIVE=( "$SRC_READER" "$SRC_CORE" )
SRC_ENUMERATOR=(  "$SRC_READER" "$SRC_CORE" "$SRC_NOTES" )
SRC_UI_FREE=(     "$SRC_CORE" )

# The UNION — every tree any rule reads. Guard (a) below existence-checks exactly these, so a tree
# that appears in a rule list but not here would never be checked, and a rename would put that rule
# back to being silently skipped by grep. Guard (a2) checks for precisely that drift.
SRCS=( "$SRC_READER" "$SRC_CORE" "$SRC_NOTES" )

SEP=$'\x1f'   # unit separator — cannot occur in Swift source, so a code line can't forge a key

# rule<SEP>path<SEP>exact source line (whitespace-trimmed). Every entry is an audited write.
ALLOW=(
  # The audited Finder-tag write choke-point: CoordinatedTagWriter's coordinated, metadata-only
  # write, plus its label restore on unintended drift.
  "tagwrite${SEP}packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift${SEP}try (writeURL as NSURL).setResourceValue(intendedTags, forKey: .tagNamesKey)"
  "tagwrite${SEP}packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift${SEP}try (writeURL as NSURL).setResourceValue(intendedLabel ?? 0, forKey: .labelNumberKey)"
  "tagwrite${SEP}packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift${SEP}try (writeURL as NSURL).setResourceValue(beforeLabel ?? 0, forKey: .labelNumberKey)"

  # RootMarker: creates the archive root's identity file (a NEW sidecar, under NSFileCoordinator,
  # adopting a racing winner rather than overwriting it). It never writes an existing corpus file.
  "destructive${SEP}packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift${SEP}try data.write(to: coordURL, options: .atomic)"

  # PDFThumbnailer: its own disposable cache directory (write + LRU eviction). Outside the corpus.
  "destructive${SEP}packages/ArchiveCore/Sources/ArchiveCore/Thumbnails/PDFThumbnailer.swift${SEP}try data.write(to: fileURL, options: .atomic)"
  "destructive${SEP}packages/ArchiveCore/Sources/ArchiveCore/Thumbnails/PDFThumbnailer.swift${SEP}try? FileManager.default.removeItem(at: url)"

  # TagVocabulary: its own JSON cache of subject tag NAMES, at a URL the owning app injects (each app
  # keeps its own — the Reader is sandboxed, the Processor is not) and which is redirected to a scratch
  # directory under any self-test driver. The path is never a corpus path: nothing derives it from a
  # scanned file, the store holds strings rather than URLs, and it is never consulted by a write path.
  # Same shape of allowance as PDFThumbnailer above — a disposable, app-owned cache, rebuilt by walking
  # again. Introduced by `W26.vocab` (`a90bbc8`), which did not run this lint; the allowance is being
  # added in the same item's completing commit rather than left for someone to discover.
  "destructive${SEP}packages/ArchiveCore/Sources/ArchiveCore/Tags/TagVocabulary.swift${SEP}try? data.write(to: fileURL, options: .atomic)"

  # ── rule 3 (errorHandler:-less enumerator) ──────────────────────────────────────────────────
  # `ArchiveLibrary.swift`'s Spotlight-era fixture loader used to be allowed here. `W26.walk2`
  # deleted the call (discovery is `ArchiveCore.CorpusWalker` now, which passes an `errorHandler:`),
  # so the allowance went with it in the same commit — which is exactly what the STALE-allowance
  # guard below exists to force. The Reader app target now has NO rule-3 allowance at all.
  #
  # PDFThumbnailer walks its OWN disposable cache directory to rebuild the LRU index. An entry it
  # cannot read costs an under-counted byte total in a cache that is rebuilt on demand — not a
  # corpus file, and not an absence anything reports to the user.
  "enumerator${SEP}packages/ArchiveCore/Sources/ArchiveCore/Thumbnails/PDFThumbnailer.swift${SEP}guard let enumerator = fm.enumerator("
)

is_allowed() {   # <rule> <path> <trimmed line>
  local want="$1${SEP}$2${SEP}$3" a
  for a in ${ALLOW[@]+"${ALLOW[@]}"}; do
    [ "$a" = "$want" ] && return 0
  done
  return 1
}

fail=0

# ── Two guards against a VACUOUS pass ────────────────────────────────────────────────────────
# The whole point of this lint is that "✓ clean" means something. Both of these failure modes
# would otherwise print "✓ clean" while checking less than the header claims.

# (a) A source root that has been renamed or moved would just be skipped by grep (stderr is
#     suppressed so a missing path doesn't drown the report), and the remaining tree would pass.
for src in "${SRCS[@]}"; do
  if [ ! -d "$src" ]; then
    echo "✗ linted source root is missing (renamed? moved?): $src"; fail=1; continue
  fi
  if [ -z "$(find "$src" -name '*.swift' -print -quit)" ]; then
    echo "✗ linted source root contains no Swift files: $src"; fail=1
  fi
done

# (a2) With per-rule source lists, guard (a) only protects what the UNION names. A tree added to one
#      rule but not to `SRCS` would go unchecked, so a later rename of it would silently narrow that
#      rule back to nothing — the same vacuous pass, one indirection further away.
for src in "${SRC_TAGWRITE[@]}" "${SRC_DESTRUCTIVE[@]}" "${SRC_ENUMERATOR[@]}" "${SRC_UI_FREE[@]}"; do
  in_union=0
  for u in "${SRCS[@]}"; do [ "$u" = "$src" ] && in_union=1; done
  if [ "$in_union" -eq 0 ]; then
    echo "✗ a rule reads a source root missing from the union SRCS, so it is never existence-checked: $src"
    fail=1
  fi
done

# (b) An allowance whose line no longer exists is an unreviewed hole waiting to be re-filled —
#     the write was moved, reworded or deleted and nobody re-audited it. Say so.
for a in ${ALLOW[@]+"${ALLOW[@]}"}; do
  a_path="${a#*"$SEP"}"; a_path="${a_path%%"$SEP"*}"
  a_line="${a##*"$SEP"}"
  if [ ! -f "$a_path" ] || ! grep -qF -- "$a_line" "$a_path" 2>/dev/null; then
    echo "✗ STALE allowance — this audited write no longer exists as written; re-audit and update"
    echo "    $a_path"
    echo "    $a_line"
    fail=1
  fi
done

# Consumes `path:lineno:content` hits on stdin, drops the allowed ones, reports the rest. Runs in
# the CURRENT shell (no pipeline subshell) so `fail=1` survives.
scan_stream() {   # <rule> <message>
  local rule="$1" message="$2"
  local hits="" line path rest content
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%:*}"          # path:lineno:content, as grep -rn emits it
    rest="${line#*:}"
    content="${rest#*:}"
    content="${content#"${content%%[![:space:]]*}"}"   # ltrim (bash 3.2-safe)
    content="${content%"${content##*[![:space:]]}"}"   # rtrim
    is_allowed "$rule" "$path" "$content" || hits="${hits}${line}"$'\n'
  done

  if [ -n "$hits" ]; then
    echo "✗ $message"
    printf '%s' "$hits"
    fail=1
  fi
}

scan() {   # <rule> <message> <extended regex> <source root…>
  local rule="$1" message="$2" re="$3"; shift 3
  scan_stream "$rule" "$message" < <(grep -rnE "$re" "$@" --include='*.swift' 2>/dev/null || true)
}

# Every `.enumerator(` call whose OWN argument list — balanced parens, however many lines it spans —
# does not mention `errorHandler:`. Emits the line the call starts on, so an allowance pins that line
# like every other rule here.
#
# A COMMENT is prose, not a call site (W26.vocab-fu1, 2026-08-06). Documenting *why* the banned
# overload is banned means writing `FileManager.enumerator(at:)` in a doc comment, and the rule read
# that as the violation it describes — so the honest way to explain the rule was to trip it. The
# comment check is applied to the line the match STARTS on, which is exactly the line the rule
# reports, and only to a line whose first non-space characters open a comment; a real call sharing a
# line with a trailing comment is still caught. The only thing this can now miss is commented-out
# code, which does not compile and cannot walk anything.
enumerators_without_error_handler() {   # <source root…>
  find "$@" -name '*.swift' -type f -print0 2>/dev/null \
    | xargs -0 /usr/bin/perl -0777 -ne '
        while (/\.enumerator\s*(\((?:[^()]++|(?1))*\))/gs) {
          next if $1 =~ /errorHandler\s*:/;
          my $lineno = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
          my @lines = split /\n/, $_, -1;
          my $line = $lines[$lineno-1];
          next if $line =~ m{^\s*(?://|\*)};
          print "$ARGV:$lineno:$line\n";
        }
      '
}

# 1) tag-write APIs — only the audited choke-point, only the exact allowed lines.
scan tagwrite \
  "tag-write API outside ArchiveCore's audited CoordinatedTagWriter (or an allowed line that changed):" \
  'setResourceValue|setResourceValues|setxattr' \
  "${SRC_TAGWRITE[@]}"

# 2) destructive / content-write APIs — nowhere, except the allowed lines above.
scan destructive \
  "destructive / content-write API in the linted trees (or an allowed line that changed):" \
  '\.(removeItem|moveItem|trashItem|replaceItem|replaceItemAt|createFile)\(|FileHandle[^)]*forWriting|PDFDocument[^)]*\.write\(|\.write\(to:' \
  "${SRC_DESTRUCTIVE[@]}"

# 3) FileManager.enumerator without an errorHandler: — a silent skip of what it cannot read.
scan_stream enumerator \
  "FileManager.enumerator without errorHandler: — it SILENTLY skips directories it cannot read:" \
  < <(enumerators_without_error_handler "${SRC_ENUMERATOR[@]}")

# 4) ArchiveCore is a shared domain package, so app frameworks belong in the app targets. Anchor the
# import statement while accepting leading import attributes such as `@preconcurrency`: prose explaining
# this rule is not an import, and neither is a type name containing it.
scan ui-import \
  "UI-framework import in ArchiveCore (move the code behind an app boundary):" \
  '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)*import[[:space:]]+(AppKit|SwiftUI)($|[[:space:]])' \
  "${SRC_UI_FREE[@]}"

# The scopes are not uniform, so neither is the claim: naming only the union would report the
# destructive-write rule as covering a tree it deliberately does not read.
if [ "$fail" -eq 0 ]; then
  echo "✓ write-surface lint clean (${SRCS[*]}; destructive-write rule covers ${SRC_DESTRUCTIVE[*]})"
fi
exit $fail
