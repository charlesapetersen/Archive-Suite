#!/usr/bin/env bash
# ArchiveNotes/scripts/make-notes-fixture.sh
# =============================================================================
# (Re)create a SCRATCH Archive Notes store for the XCUITest GUI harness (W8-S7 §3.5).
#
# Models `ArchiveReader/scripts/smoke-setup.sh`: `set -euo pipefail`, idempotent
# `rm -rf` + rebuild, and it emits the fixture path on stdout (for the app's
# `-ANUITestStorePath` launch argument). Everything else goes to stderr.
#
# WHAT IT BUILDS (all under a single scratch dir, never the real store/corpus):
#   <FIXTURE>/.archive-suite-root.json         RootMarker {kind:notes, known GUID}
#   <FIXTURE>/items/<uuid>/<Title>.md          one plain note, one reader-page
#                                              source-block note, one Zotero note,
#                                              one extract with a note-passage block
#   <FIXTURE>/items/<uuid>/assets/…            a placeholder page thumbnail
#   <FIXTURE>/Templates/                        (empty — parallel to items/)
#   <FIXTURE>/organization.json                system folders + two demo folders +
#                                              one REPLICATED item (member of both)
#   <FIXTURE>/reader-corpus/                    embedded scratch Reader corpus with
#                                              its own RootMarker {kind:reader} +
#                                              copied PDFs, so durable links resolve
#   …and the initial Finder-tag projection (title-cased subjects + ArchiveSuite)
#   applied to each note `.md` via the `tag` CLI, so the projector's starting
#   state is known (same reasoning as the Reader fixture: git can't store xattrs).
#
# SAFETY (Prime Directive #1 — file safety > everything):
#   * DST is a FIXED scratch subfolder `…/ArchiveNotes/AN-GUI-Fixture` — a sibling
#     of the real store `…/ArchiveNotes/Store`, NEVER it, and never the corpus. A
#     hard guard aborts if DST is not exactly that scratch path before any `rm -rf`.
#   * The source corpus is a READ-ONLY `ditto` source (copied out, never written).
#   * Tag writes here hit only the scratch `.md` COPIES via the `tag` CLI.
#   The sandboxed app reads this store via the UITest-only Route-B
#   temporary-exception entitlement (§3.2).
#
# INDEX-DB CAVEAT (for the W8-S8 GUI run, not this builder):
#   The Notes index DB lives at `.applicationSupportDirectory/notes-index-v1.sqlite3`,
#   which in the SANDBOXED app resolves to the app's *container* (isolated from the
#   owner's real store). `organization.json` is loaded only when that container DB
#   has no folders (NotesModel/OrganizationStore.load), so a deterministic GUI run
#   must launch against a FRESH container (or reset the container DB) — otherwise a
#   prior run's cached graph shadows this fixture's `organization.json`. This
#   builder never touches the container or the owner's real DB.
#
# Usage:  ./ArchiveNotes/scripts/make-notes-fixture.sh
#         NOTES_FIXTURE_CORPUS=/path/to/pdfs ./ArchiveNotes/scripts/make-notes-fixture.sh
# =============================================================================
set -euo pipefail

# --- Destination (SCRATCH ONLY) ---------------------------------------------
FIXTURE_NAME="AN-GUI-Fixture"
DST="$HOME/Library/Application Support/ArchiveNotes/$FIXTURE_NAME"

# HARD SAFETY GUARD — refuse anything that isn't exactly the scratch fixture path
# (a variable-expansion bug must never let `rm -rf` hit the real store or corpus).
case "$DST" in
  */"$FIXTURE_NAME") : ;;
  *) echo "make-notes-fixture: REFUSING — DST is not the scratch fixture path: $DST" >&2; exit 2 ;;
esac
case "$DST" in
  *"/ArchiveNotes/Store"|*"/ArchiveNotes/Store/"*|"$HOME/Desktop/"*)
    echo "make-notes-fixture: REFUSING — DST resolves to a protected location: $DST" >&2; exit 2 ;;
esac

# --- Source corpus (READ-ONLY ditto source; gitignored → primary checkout) ---
SRC="${NOTES_FIXTURE_CORPUS:-$HOME/Claude/Archive Suite/ArchiveProcessor/Test Files/DeaverLLM}"
TAG="${TAG:-/opt/homebrew/bin/tag}"
N_PDFS="${N_PDFS:-8}"

# --- Deterministic identity (fixed GUIDs/UUIDs → reproducible durable links) --
NOTES_ROOT_GUID="a11ce5e7-1000-4000-8000-000000000001"
CORPUS_ROOT_GUID="c07b0700-2000-4000-8000-000000000002"

ID_PLAIN="11111111-1111-1111-1111-111111111111"
ID_READER="22222222-2222-2222-2222-222222222222"
ID_ZOTERO="33333333-3333-3333-3333-333333333333"
ID_EXTRACT="44444444-4444-4444-4444-444444444444"

FOLDER_READING="f1f1f1f1-0000-0000-0000-0000000000f1"
FOLDER_IDEAS="f2f2f2f2-0000-0000-0000-0000000000f2"
# System folder IDs (must match OrganizationStore.swift §16.6, else the app re-seeds).
SYS_ALLNOTES="00000000-0000-0000-0000-000000000001"
SYS_INBOX="00000000-0000-0000-0000-000000000002"
SYS_EXTRACTS="00000000-0000-0000-0000-000000000003"

CREATED="2026-07-14T12:00:00Z"
# Epoch seconds for organization.json memberships (secondsSince1970). Compute from
# the fixed timestamp (deterministic); fall back to a known-good literal.
EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED" +%s 2>/dev/null || echo 1784030400)"

echo "make-notes-fixture: rebuilding $DST" >&2
rm -rf "$DST"
mkdir -p "$DST/items" "$DST/Templates" "$DST/reader-corpus"

# --- Root marker (Notes store) ----------------------------------------------
cat > "$DST/.archive-suite-root.json" <<EOF
{"guid":"$NOTES_ROOT_GUID","name":"$FIXTURE_NAME","kind":"notes","createdAt":"$CREATED"}
EOF

# --- Helper: write a note .md + its assets dir ------------------------------
# write_item <uuid> <filename.md>   (body is read from stdin)
write_item() {
  local uuid="$1" filename="$2" dir
  dir="$DST/items/$uuid"
  mkdir -p "$dir/assets"
  cat > "$dir/$filename"
}

# (1) Plain note ---------------------------------------------------------------
write_item "$ID_PLAIN" "My First Note.md" <<EOF
---
schema: 1
id: $ID_PLAIN
kind: note
title: My First Note
tags: [silicon valley, intel]
roundup: false
created: $CREATED
modified: $CREATED
---
A plain note with no source blocks. Hello, world.
EOF

# (2) Reader-page source-block note -------------------------------------------
# link resolves under the embedded scratch Reader corpus (CORPUS_ROOT_GUID) at
# rel=sample.pdf, page 1. The thumb is a placeholder PNG created below.
write_item "$ID_READER" "Moore on Intel culture.md" <<EOF
---
schema: 1
id: $ID_READER
kind: note
title: Moore on Intel culture
authors: [Gordon E. Moore]
date: 1968
date_precision: year
date_uncertain: false
quality: 4
tags: [intel, corporate culture]
roundup: false
created: $CREATED
modified: $CREATED
---
<!-- block: reader-page
     link: archivereader://reveal?root=$CORPUS_ROOT_GUID&rel=sample.pdf&page=1
     display: "sample.pdf — p. 1"
     page: 1
     thumb: assets/p1-thumb.png -->
![sample.pdf — p. 1](assets/p1-thumb.png)

Moore on Intel's early egalitarian culture.
EOF

# (3) Zotero-chip note ---------------------------------------------------------
write_item "$ID_ZOTERO" "Lovelace paper.md" <<EOF
---
schema: 1
id: $ID_ZOTERO
kind: note
title: Lovelace paper
authors: [Ada Lovelace]
tags: [computing history]
roundup: false
zotero:
  - selectLink: zotero://select/library/items/ABCD1234
    itemKey: ABCD1234
    library: library
    kind: item
    citation: Lovelace, 1843
created: $CREATED
modified: $CREATED
---
<!-- block: zotero-item
     display: "Lovelace, 1843"
     zotero: zotero://select/library/items/ABCD1234 -->
Notes on the Lovelace paper.
EOF

# (4) Extract with a note-passage block (links back to the reader-page note) ---
write_item "$ID_EXTRACT" "On egalitarian culture.md" <<EOF
---
schema: 1
id: $ID_EXTRACT
kind: extract
title: On egalitarian culture
date: 2026-07-14
date_precision: day
date_uncertain: false
roundup: false
created: $CREATED
modified: $CREATED
---
<!-- block: note-passage
     display: "Moore on Intel culture — 1968"
     note: archivenotes://open?id=$ID_READER#block-0 -->
Moore says he and Noyce were responsible for Intel's early egalitarian culture.
EOF

# --- Placeholder page thumbnail (1x1 PNG) for the reader-page block ----------
# base64 of a minimal valid 1x1 transparent PNG.
printf '%s' \
'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' \
  | base64 --decode > "$DST/items/$ID_READER/assets/p1-thumb.png"

# --- organization.json (system + 2 demo folders; ID_READER replicated) -------
# parentId/queryJSON are OMITTED when nil (matches the encoder's encodeIfPresent).
cat > "$DST/organization.json" <<EOF
{
  "schema" : 1,
  "assignments" : [],
  "folders" : [
    { "id" : "$SYS_ALLNOTES", "kind" : "smart",  "name" : "All Notes", "sortOrder" : 0 },
    { "id" : "$SYS_INBOX",    "kind" : "normal", "name" : "Inbox",     "sortOrder" : 1 },
    { "id" : "$SYS_EXTRACTS", "kind" : "normal", "name" : "Extracts",  "sortOrder" : 2 },
    { "id" : "$FOLDER_READING", "kind" : "normal", "name" : "Reading", "sortOrder" : 3 },
    { "id" : "$FOLDER_IDEAS",   "kind" : "normal", "name" : "Ideas",   "sortOrder" : 4 }
  ],
  "memberships" : [
    { "addedAt" : $EPOCH, "folderId" : "$FOLDER_READING", "itemId" : "$ID_PLAIN" },
    { "addedAt" : $EPOCH, "folderId" : "$FOLDER_READING", "itemId" : "$ID_READER" },
    { "addedAt" : $EPOCH, "folderId" : "$FOLDER_IDEAS",   "itemId" : "$ID_READER" },
    { "addedAt" : $EPOCH, "folderId" : "$FOLDER_IDEAS",   "itemId" : "$ID_ZOTERO" },
    { "addedAt" : $EPOCH, "folderId" : "$SYS_EXTRACTS",   "itemId" : "$ID_EXTRACT" }
  ]
}
EOF

# --- Embedded scratch Reader corpus (for durable-link reveal) ----------------
cat > "$DST/reader-corpus/.archive-suite-root.json" <<EOF
{"guid":"$CORPUS_ROOT_GUID","name":"AN-GUI-Fixture Corpus","kind":"reader","createdAt":"$CREATED"}
EOF

if [ -d "$SRC" ]; then
  count=0
  while IFS= read -r f; do
    [ "$count" -ge "$N_PDFS" ] && break
    ditto "$SRC/$f" "$DST/reader-corpus/$f"     # ditto preserves the tag xattr
    count=$((count + 1))
  done < <(cd "$SRC" && ls *.pdf 2>/dev/null | sort)
  # A simply-named copy so the reader-page rel=sample.pdf resolves without encoding.
  first_pdf="$(cd "$SRC" && ls *.pdf 2>/dev/null | sort | head -1 || true)"
  if [ -n "$first_pdf" ]; then
    ditto "$SRC/$first_pdf" "$DST/reader-corpus/sample.pdf"
  fi
  echo "make-notes-fixture: copied $count PDFs into reader-corpus/ (+ sample.pdf)" >&2
else
  echo "make-notes-fixture: WARNING — corpus source not found ($SRC); reader-corpus has no PDFs." >&2
  echo "make-notes-fixture:   the notes store is still valid; the reveal (G6) check needs real PDFs." >&2
fi

# --- Initial Finder-tag projection (title-cased subjects + ArchiveSuite) ------
# Mirrors what NotesTagProjector would write, so the projector's starting state
# is known. Read-only source corpus is never tagged; only the scratch note copies.
if [ -x "$TAG" ]; then
  "$TAG" -a "Silicon Valley,Intel,ArchiveSuite"     "$DST/items/$ID_PLAIN/My First Note.md"
  "$TAG" -a "Intel,Corporate Culture,ArchiveSuite"  "$DST/items/$ID_READER/Moore on Intel culture.md"
  "$TAG" -a "Computing History,ArchiveSuite"        "$DST/items/$ID_ZOTERO/Lovelace paper.md"
  "$TAG" -a "ArchiveSuite"                           "$DST/items/$ID_EXTRACT/On egalitarian culture.md"
  echo "make-notes-fixture: applied initial Finder-tag projection to 4 notes" >&2
else
  echo "make-notes-fixture: WARNING — tag CLI not found at $TAG; skipped initial tag projection." >&2
fi

echo "make-notes-fixture: ready ($DST)" >&2
# The fixture path on stdout, for `-ANUITestStorePath`.
echo "$DST"
