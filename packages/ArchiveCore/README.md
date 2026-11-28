# ArchiveCore

Shared Swift package consumed by **Archive Processor**, **Archive Reader**, and **Archive Notes** (`macOS 14+`, Swift 6).

## Products

- **`ArchiveCore`** (UI-free): shared data contracts and utilities that never link AppKit or SwiftUI.
  - `Appearance/` — shared appearance preference (`AppAppearance`)
  - `Calendars/` — Gregorian / Julian calendar arithmetic and display calendars
  - `Catalogue/` — per-PDF `.archivesuite.json` record schema, atomic reader/writer, edit/undo, XMP PDF identity (`CataloguePDFIdentity`), and export helpers
  - `Collections/` — layered collection settings records (`CollectionSettingsRecord`)
  - `Containers/` — box/folder container metadata store (`ContainerFileStore`) and folder date parsing
  - `Corpus/` — direct filesystem walker (`CorpusWalker`, dataless-safe) and JPEG original partner index (`JPEGPartnerIndex`)
  - `Links/` — durable cross-app source links (`archivereader://`, `archivenotes://`)
  - `PDF/` — shared page-2 / XMP header parser (`PDFHeaderParser`) and format status
  - `Preservation/` — preservation-copy payload paths and manifest helpers (`PreservationCopy`)
  - `Search/` — shared Advanced Search rule types, FTS5 query builder, and date-range parsing (`AdvancedSearchRules`)
  - `Tags/` — canonical Finder tag grammar (`DocumentTags`), `ArchiveDate`, `CoordinatedTagWriter` (`TagWrite.swift`), `FinderMirror`, `FieldStatusPolicy`, `TagChangeLog`, `TagVocabulary`, and `UserItemFields`
  - `Text/` — shared title-casing helpers (`TitleCase`)
  - `Thumbnails/` — shared PDF thumbnail rendering and cache-key helpers (`PDFThumbnailer`, `ThumbnailCacheKey`)
  - `Zotero/` — Zotero metadata and export helpers
- **`ArchiveCoreUI`** (AppKit/SwiftUI): shared UI controls and models (`TagEntry`, `SubjectEntryField`, `TagChip`/`TagChipsView`, `FilterBarLayout`, `FlowLayout`, `FieldStatusBadge`, `CollectionRecordView`, `TagsWindowModel`/`TagsWindowView`).

## Running tests

```bash
cd packages/ArchiveCore && swift test
```

Or from the repository root: `./test-smoke.sh archivecore`.
