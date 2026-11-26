#!/usr/bin/env bash
# lint-write-surface.sh — Processor's source-level tripwire for direct Finder-tag writes and PDF output.
#
# Processor's `MacOSTagger` is deliberately only a fresh-write adapter over ArchiveCore's audited
# `CoordinatedTagWriter`; a direct setResourceValue/setxattr call here would bypass its coordinated
# read/verify path. Direct calls to the PDF/A-2b writers are pinned to audited lines
# because later callers decide whether a source may be retired. PDFDocument.write is forbidden.
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
  # W42.int-s5: generated pages use the Quartz PDF/A writer or the stream-preserving writer for a compressed
  # searchable page. Merges use the stream-preserving writer when available and stage on the destination volume.
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}try Self.writeArchival(pdfDocument, to: outputURL, pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}try SearchableArchival.write([page], pageHeaders: [header], to: url, budget: budget, catalogueIdentity: catalogueIdentity)"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}try writeArchival(document, to: url, pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}try SearchableArchival.write(sourcePDFs, pageHeaders: pageHeaders, to: outputURL, budget: budget,"
  # Publication only after candidate read-back, plus Process Files' guard after the worker returns.
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift${SEP}try installArchival(candidate, at: url)"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/SearchableArchival.swift${SEP}try PDFGenerator.installArchival(candidate, at: url)"
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift${SEP}try PDFGenerator.installArchival(candidate, at: mergedURL, replacingExisting: false)"
  # W49.storage-processor: the DEBUG recovery driver stages a synthetic PDF carrying the companion's
  # catalogue identity. All calls write under its UUID-named test directory with isolated backup enabled.
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/Capture/LiveCaptureRecoveryFinalizeTests.swift${SEP}try? PDFGenerator.writeArchival(document, to: pdf, catalogueIdentity: identity)"
  # W49.proc-reocr-preservation: the Improve OCR input test (DEBUG only) writes a two-page PDF standing in for a
  # scanner's intake original, under its scratch folder. It is a fixture input, never app output.
  "pdfwrite${SEP}macOS/Sources/ArchiveProcessor/ReOCR/ReOCRImageInputTestDriver.swift${SEP}guard original.write(to: scan) else { throw CocoaError(.fileWriteUnknown) }"
  # W44.reocr-processor: the Improve OCR publication test (DEBUG only) puts a custom attribute and a resource fork on
  # its scratch fixtures, so it can prove publication keeps them. Tags and label go through CoordinatedTagWriter.
  "tagwrite${SEP}macOS/Sources/ArchiveProcessor/ReOCR/ReOCRFileWriterTestDriver.swift${SEP}let rc = value.withUnsafeBytes { setxattr(url.path, name, \$0.baseAddress, \$0.count, 0, XATTR_NOFOLLOW) }"
  # W46.date-route-header: the dating-route test (DEBUG only) puts a custom attribute on its scratch output, so it
  # can prove OutputFileSafety.replaceGeneratedOutput keeps it. Its Finder tags go through MacOSTagger.
  "tagwrite${SEP}macOS/Sources/ArchiveProcessor/Tagging/DateRouteTestDriver.swift${SEP}_ = setxattr(pdf.path, \"com.archivesuite.test\", \"kept\", 4, 0, XATTR_NOFOLLOW)"
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
    echo "✗ STALE write allowance — this audited write no longer exists as written"
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
      # Any binding annotated as PDFDocument: let/var, stored property, and function or closure parameter
      # (incl. `_ doc:`, `inout`). W9.e3 planted `func f(_ d: PDFDocument, _ u: URL) { d.write(to: u) }`
      # and the let/var-only form passed it. Still unseen: a type inferred from elsewhere (`for d in docs`).
      while ($source =~ /\b([A-Za-z_]\w*)\s*:\s*(?:inout\s+)?(?:PDFKit\.)?PDFDocument\b/g) {
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

# Every call of the Quartz PDF/A writer or the shared publication function, except definitions and comments. A new caller is a new PDF
# output site and must be audited (and allowed by its exact line).
archival_write_hits() {
  grep -rnE '\b(writeArchival|installArchival)[[:space:]]*\(' "$SRC" --include='*.swift' 2>/dev/null \
    | /usr/bin/perl -ne 'next if /^[^:]+:\d+:\s*(?:\/\/|\/\*|\*)/; next if /\bfunc\s+(?:writeArchival|installArchival)\b/; print' || true
}

# The stream-preserving PDF/A writer is subject to the same call-site audit as Quartz's writer above.
searchable_write_hits() {
  grep -rnE '\bSearchableArchival[[:space:]]*\.[[:space:]]*write[[:space:]]*\(' "$SRC" --include='*.swift' 2>/dev/null \
    | /usr/bin/perl -ne 'next if /^[^:]+:\d+:\s*(?:\/\/|\/\*|\*)/; print' || true
}

scan_stream tagwrite \
  'direct Finder-tag write API in Processor source (use ArchiveCore.CoordinatedTagWriter through MacOSTagger):' \
  < <(tag_write_hits)
scan_stream pdfwrite \
  'PDFDocument.write in Processor source (PDF output goes through PDFGenerator.writeArchival):' \
  < <(pdf_document_write_hits)
scan_stream pdfwrite \
  'SearchableArchival.write outside its audited output sites:' \
  < <(searchable_write_hits)
scan_stream pdfwrite \
  'PDFGenerator write or publication outside its audited output sites (or an allowed line changed):' \
  < <(archival_write_hits)

if [ "$FAIL" -eq 0 ]; then
  echo "✓ Processor write-surface lint clean ($SRC; direct tag writes forbidden; ${#ALLOW[@]} audited write lines)"
fi
exit "$FAIL"
