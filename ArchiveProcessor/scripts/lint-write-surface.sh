#!/usr/bin/env bash
# lint-write-surface.sh — Processor's source-level tripwire for direct Finder-tag writes and PDF output.
#
# Processor's `MacOSTagger` is deliberately only a fresh-write adapter over ArchiveCore's audited
# `CoordinatedTagWriter`; a direct setResourceValue/setxattr call here would bypass its coordinated
# read/verify path. PDF output is likewise centralised in PDFGenerator: its two exact write sites are
# reviewed because later callers decide whether a source may be retired. This lint makes both boundaries loud.
#
# Run before Processor commits. It and its scratch-only mutation proof are health-gate steps, so this is a
# backstop rather than a promise someone has to remember. `PROCESSOR_LINT_ROOT` is test-only and must point at
# an ArchiveProcessor-shaped scratch tree; it lets the proof plant files without ever touching real sources.
set -uo pipefail

APP_ROOT="${PROCESSOR_LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$APP_ROOT" 2>/dev/null || { echo "✗ cannot enter Processor root: $APP_ROOT"; exit 2; }
SRC="macOS/Sources/ArchiveProcessor"

SEP=$'\x1f'
# rule<SEP>relative path<SEP>exact trimmed source line. Never allow a whole file: an added PDF write in
# PDFGenerator must be re-audited just as surely as one in a new source file.
ALLOW=(
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}guard pdfDocument.write(to: outputURL) else {"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}guard merged.write(to: outputURL) else { throw PDFError.writeFailed }"
)

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() { FAIL=$((FAIL + 1)); }

is_allowed() { # <rule> <path> <trimmed line>
  local want="$1${SEP}$2${SEP}$3" allowed
  for allowed in "${ALLOW[@]}"; do
    [ "$allowed" = "$want" ] && return 0
  done
  return 1
}

if [ ! -d "$SRC" ]; then
  echo "✗ linted source root is missing (renamed? moved?): $SRC"
  exit 1
fi
if ! find "$SRC" -name '*.swift' -type f -print -quit | grep -q .; then
  echo "✗ linted source root contains no Swift files: $SRC"
  exit 1
fi

# A stale allowance is an unreviewed hole: the writer was moved, changed, or deleted and a future matching
# write could inherit an approval that nobody revisited.
for allowed in "${ALLOW[@]}"; do
  allowed_path="${allowed#*"$SEP"}"; allowed_path="${allowed_path%%"$SEP"*}"
  allowed_line="${allowed##*"$SEP"}"
  if [ ! -f "$allowed_path" ] || ! grep -qF -- "$allowed_line" "$allowed_path"; then
    echo "✗ STALE PDF-write allowance — this audited write no longer exists as written"
    echo "    $allowed_path"
    echo "    $allowed_line"
    no
  fi
done

# Reads `path:line:content` hits, drops exact audited allowances, and retains failures in this shell (not a
# pipeline subshell) so the script's exit status cannot accidentally stay green.
scan_stream() { # <rule> <message>
  local rule="$1" message="$2" line path rest content hits=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%:*}"
    rest="${line#*:}"
    content="${rest#*:}"
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    is_allowed "$rule" "$path" "$content" || hits="${hits}${line}"$'\n'
  done
  if [ -n "$hits" ]; then
    echo "✗ $message"
    printf '%s' "$hits"
    no
  fi
}

# Direct Finder metadata APIs are never acceptable in Processor source. Ignore only a line whose first code
# token is a comment — the implementation map intentionally documents the API spelling it forbids.
tag_write_hits() {
  grep -rnE 'setResourceValue|setResourceValues|setxattr' "$SRC" --include='*.swift' 2>/dev/null \
    | /usr/bin/perl -ne 'next if /^[^:]+:\d+:\s*(?:\/\/|\/\*|\*)/; print' || true
}

# Swift offers no source spelling for an instance's static type at its `.write(to:)` call. Find local variables
# constructed or declared as PDFDocument, then inspect their calls across the file (including multiline calls).
# This catches a new `let rogue = PDFDocument(); rogue.write(...)` outside PDFGenerator without treating the
# many Data.write scratch/report sites as PDF output. Direct `PDFDocument(...).write(...)` is covered too.
pdf_document_write_hits() {
  local file
  while IFS= read -r -d '' file; do
    LINT_REL="$file" /usr/bin/perl -0777 -ne '
      my $source = $_;
      my @lines = split /\n/, $source, -1;
      my %variables;
      while ($source =~ /\b(?:let|var|guard\s+let)\s+([A-Za-z_]\w*)\s*(?::\s*(?:PDFKit\.)?PDFDocument\??)?\s*=\s*(?:PDFKit\.)?PDFDocument\b/g) {
        $variables{$1} = 1;
      }
      while ($source =~ /\b(?:let|var|guard\s+let)\s+([A-Za-z_]\w*)\s*:\s*(?:PDFKit\.)?PDFDocument\??/g) {
        $variables{$1} = 1;
      }
      my @starts;
      for my $name (keys %variables) {
        while ($source =~ /(?<![A-Za-z0-9_])(?:self\s*\.\s*)?\Q$name\E\s*(?:[?!]\s*)?\.\s*write\s*\(\s*to\s*:/gs) {
          push @starts, $-[0];
        }
      }
      while ($source =~ /\b(?:PDFKit\.)?PDFDocument\s*\([^()\n]*\)\s*\??\s*\.\s*write\s*\(\s*to\s*:/g) {
        push @starts, $-[0];
      }
      my %seen;
      for my $start (sort { $a <=> $b } @starts) {
        next if $seen{$start}++;
        my $line_number = 1 + (substr($source, 0, $start) =~ tr/\n//);
        my $line = $lines[$line_number - 1] // q{};
        next if $line =~ /^\s*(?:\/\/|\/\*|\*)/;
        print "$ENV{LINT_REL}:$line_number:$line\n";
      }
    ' "$file"
  done < <(find "$SRC" -name '*.swift' -type f -print0)
}

scan_stream tagwrite \
  'direct Finder-tag write API in Processor source (use ArchiveCore.CoordinatedTagWriter through MacOSTagger):' \
  < <(tag_write_hits)
scan_stream pdfwrite \
  'PDFDocument.write outside the two audited PDFGenerator output sites (or an allowed line changed):' \
  < <(pdf_document_write_hits)

if [ "$FAIL" -eq 0 ]; then
  echo "✓ Processor write-surface lint clean ($SRC; direct tag writes forbidden; ${#ALLOW[@]} PDF output writes audited)"
fi
exit "$FAIL"
