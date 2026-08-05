#!/usr/bin/env bash
# lint-write-surface.sh — enforce the Core Directive (ArchiveReader/CLAUDE.md) at the source level,
# across BOTH the Reader app target AND the shared ArchiveCore package it delegates its writes to.
#
#   1) A Finder-tag write API (setResourceValue(s) / setxattr) may appear ONLY at the audited
#      write choke-point — ArchiveCore's `CoordinatedTagWriter` (Tags/TagWrite.swift).
#   2) NO file in either tree may call a move / rename / delete / trash / content-write API,
#      except at the individually audited sites in the ALLOW list below.
#
# Run before every commit; exit non-zero on violation. ⚠️ NOTHING invokes this automatically —
# the header used to claim "also invoked by the autonomous build" and that was measured false on
# 2026-08-05 (no caller anywhere in `ops/`, `.claude/hooks/`, or any script). Wiring it into the
# health gate is filed as `W26.lint-fu`; until then it is a manual gate.
#
# ── SCOPE (W26.lint, 2026-08-05) ─────────────────────────────────────────────────────────────
# `SRC` used to be just `macOS/Sources/ArchiveReader`, which left `packages/ArchiveCore`
# — where the actual write choke-point lives — entirely unlinted. That is where the Core
# Directive violation fixed in W26.deny sat. And because the Reader's own `TagWriter` is now a
# *delta adapter* over `CoordinatedTagWriter`, the app target has ZERO tag-write hits of its own:
# rule 1 was passing VACUOUSLY. Both trees are linted now, and the whole permitted tag-write
# surface of the suite is the three exact lines allowed below.
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

SRCS=(
  "ArchiveReader/macOS/Sources/ArchiveReader"
  "packages/ArchiveCore/Sources/ArchiveCore"
)

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

scan() {   # <rule> <message> <extended regex>
  scan_stream "$1" "$2" < <(grep -rnE "$3" "${SRCS[@]}" --include='*.swift' 2>/dev/null || true)
}

# Every `.enumerator(` call whose OWN argument list — balanced parens, however many lines it spans —
# does not mention `errorHandler:`. Emits the line the call starts on, so an allowance pins that line
# like every other rule here.
enumerators_without_error_handler() {
  find "${SRCS[@]}" -name '*.swift' -type f -print0 2>/dev/null \
    | xargs -0 /usr/bin/perl -0777 -ne '
        while (/\.enumerator\s*(\((?:[^()]++|(?1))*\))/gs) {
          next if $1 =~ /errorHandler\s*:/;
          my $lineno = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
          my @lines = split /\n/, $_, -1;
          print "$ARGV:$lineno:$lines[$lineno-1]\n";
        }
      '
}

# 1) tag-write APIs — only the audited choke-point, only the exact allowed lines.
scan tagwrite \
  "tag-write API outside ArchiveCore's audited CoordinatedTagWriter (or an allowed line that changed):" \
  'setResourceValue|setResourceValues|setxattr'

# 2) destructive / content-write APIs — nowhere, except the allowed lines above.
scan destructive \
  "destructive / content-write API in the linted trees (or an allowed line that changed):" \
  '\.(removeItem|moveItem|trashItem|replaceItem|replaceItemAt|createFile)\(|FileHandle[^)]*forWriting|PDFDocument[^)]*\.write\(|\.write\(to:'

# 3) FileManager.enumerator without an errorHandler: — a silent skip of what it cannot read.
scan_stream enumerator \
  "FileManager.enumerator without errorHandler: — it SILENTLY skips directories it cannot read:" \
  < <(enumerators_without_error_handler)

if [ "$fail" -eq 0 ]; then echo "✓ write-surface lint clean (${SRCS[*]})"; fi
exit $fail
