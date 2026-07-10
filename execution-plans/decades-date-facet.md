# Execution plan — Decade date facet (`1970s` / `1980s`)

**Status:** approved-pending (owner) · **Risk:** **Tier-2** · **Effort:** M · **Needs:** none (unit-testable; GUI smoke optional)

A NEW date facet — a decade tag `NNNNs` (e.g. `1970s`, medieval-friendly `970s`) — spanning **both apps + the shared SPEC**. Highest-risk class of change (the tag contract), but the code surface is small and almost entirely additive: the Processor already writes the Year field verbatim, so authoring a decade is a SPEC + affordance + test change; the Reader gains one parsed facet plus a write-path reconcile so the existing date editor can't orphan a decade.

## Goal
- **SPEC first:** add the `Decade` facet to `SPEC/tag-format.md` so both apps parse/write it identically.
- **Reader:** parse `NNNNs` → chronological **sortDate = start of the decade** (`1970s` sorts as 1970‑01‑01, interleaved with dated files) while the **Date column still displays `"1970s"`** (not a concrete date), rendered speculative (italic). Keep decades **out of the tag cloud and the tag filter**. Make the existing date editor decade-safe (never orphan a decade).
- **Processor:** the user tags a decade by typing `1970s` into the **Year** date field of the manual tagging dialog; it is written by the audited tag writer (already true — verbatim).

## Scope (files)
**SPEC (write both apps to this):**
- `SPEC/tag-format.md` — new facet row + sort-key + display rules + where-each-side-lives row.

**Reader (`ArchiveReader/macOS/Sources/ArchiveReader/`):**
- `Core/DocumentTags.swift` — new `decade`/`decadeToken` fields; `parseDecade`; parse-loop insertion; `sortDate`; `displayDate`; `dateIsSpeculative`; `topicalTags` exclusion.
- `Core/TagEditing.swift` — `.setYear` delta also removes any `decadeToken` (year supersedes decade; prevents an orphaned/hidden decade).
- `Views/InlineEditCells.swift` — `DateCell` shows the decade token in the Year field so a decade-dated file isn't a blank editor.
- Tests: `Tests/ArchiveReaderTests/DocumentTagsTests.swift`, `Tests/ArchiveReaderTests/TagEditingTests.swift`.

**Processor (`ArchiveProcessor/macOS/Sources/ArchiveProcessor/`):**
- `Views/ManualTaggingSheet.swift` (batch manual sheet) + `Views/ManualSegmentTagView.swift` (live/segment card) — Year field help/prompt text: "type a year (`1968`) or a decade (`1970s`)". No behavioral change to the write path.
- (verify-only, no edit expected) `OCR/OCRProcessor+Tagging.swift`, `Tagging/TagGenerator.swift`, `Tagging/MacOSTagger.swift` — confirm the verbatim pass-through.

**Docs:** `SUITE_TODO.md`, `ArchiveReader/CLAUDE.md`, `ArchiveProcessor/CLAUDE.md` (same commit).

## Grounding — how a decade already flows through the Processor
Confirmed by reading the code; **no numeric coercion strips the `s`**:
- Manual sheet Year field is free text: `dateField("Year", text: $segment.year …)` — `ManualTaggingSheet.swift:163`; segment card: `TextField("", text: $processor.manualSegDraftTags.year)` — `ManualSegmentTagView.swift:356`. Neither applies a digit filter. (The only `.filter(\.isNumber).prefix(4)` is the **phone** path `LiveCaptureView.swift:675`, whose value is `Int(yearText)` at `:835` — out of scope; decades are a Mac-side manual-tag affordance.)
- The field is a `String` end-to-end: `ManualTagSegment.year: String` (`OCRProcessor+Types.swift:~85`), `SegmentTagData.year: String` (`OCRProcessor+Types.swift:71`).
- Pass-through to the tag model verbatim: `tags.year = m.year.isEmpty ? nil : m.year` — `OCRProcessor+Tagging.swift:221` (batch) and `gtags.year = data.year.isEmpty ? nil : data.year` — `:465` (live segment).
- `GeneratedTags.allTags` appends `year` **verbatim** (no `capitalizeFirstLetters` — that's applied only to month/subjects): `if let y = year { tags.append(y) }` — `TagGenerator.swift:35`.
- `MacOSTagger.applyTags(_ generatedTags:)` → `applyTags(_:to:appColor:colorIsAuthoritative:)` writes the array via `setResourceValue(_, forKey: .tagNamesKey)` — `MacOSTagger.swift`. `"1970s"` is a plain text token (not `Red`/`Purple`/`Unread`), so it is written unchanged, with the trailing `Unread` appended last in real-tagging modes.

⇒ **Typing `1970s` into the Year field already produces a `1970s` Finder tag today.** The Processor work is: (a) tell the user they can (help/prompt), (b) SPEC it, (c) a test asserting the round-trip. Deliberately **no** hard validator (keeps the existing "writer writes intent, reader classifies best-effort" philosophy; a malformed `1975s` merely parses as a subject in the Reader).

## Approach

### 1) SPEC (`SPEC/tag-format.md`) — write this first, both apps conform to it
Add a **Decade** row to the facet table (§Tag facets), after **Day** / alongside **Year**:

> | **Decade** | `NNNNs`, e.g. `1970s` (a 3–4 digit run whose **last digit is `0`**, then a **lowercase** `s`; medieval-friendly `970s`) | 0–1 | An **approximate** date spanning ten years. **Mutually exclusive with Year** — a concrete Year supersedes a Decade. Recognized alongside the bare-number Year test (the trailing `s` means it can never match the digits-only Year test, so order is immaterial). Written by the Processor **only** when the user types it into the manual tag dialog's Year field; the LLM tagger never emits it. Reader parser: `DocumentTags.parseDecade`. |

Extend §Chronological sort key with:

> - A **Decade** tag with no Year sorts as the decade's first year, Jan 1: `sortDate = decadeStart * 10_000` (e.g. `1970s` → `19_700_000`), so it interleaves with dated files exactly where a year-only `1970` doc sorts. If a concrete **Year** is also present it takes precedence (Year supersedes Decade). The Date column **displays the verbatim decade token** (`"1970s"`), never a synthesized concrete date, and renders it **italic** (speculative), like `Date Uncertain`.

Add a **Decade** row to §Where each side lives:

> | Decade `NNNNs` | `Views/ManualTaggingSheet.swift` + `Views/ManualSegmentTagView.swift` (Year date field → verbatim via `GeneratedTags.allTags`/`MacOSTagger`) | `Core/DocumentTags.swift` (`parseDecade`/`sortDate`/`displayDate`) |

This is the coordinated three-way change §Divergence risk mandates — land SPEC + Reader + Processor in one batch.

### 2) Reader — `Core/DocumentTags.swift`
**Struct fields** (near `year`/`yearToken`, lines ~47 and ~60):
```swift
var decade: Int?          // decade START year, e.g. 1970 (from "1970s"); nil when absent
…
var decadeToken: String?  // the verbatim raw token consumed for the decade facet ("1970s")
```

**Parser** — new function (mirror `parseYear`'s strict, display-only contract, `:219`):
```swift
/// A decade token "NNNNs": 3–4 digits whose last digit is 0, then a lowercase 's'
/// (e.g. "1970s", medieval-friendly "970s"). Returns the decade START year (1970).
/// Display/sort-only — never drives a write; a malformed "1975s"/"1970S" returns nil
/// and falls through to a subject (acceptable, the user corrects it in the UI).
static func parseDecade(_ s: String) -> Int? {
    guard s.hasSuffix("s") else { return nil }
    let digits = s.dropLast()
    guard (3...4).contains(digits.count),
          digits.allSatisfy(\.isNumber),
          digits.last == "0",
          let start = Int(digits) else { return nil }
    return start
}
```

**Parse loop** — insert a decade check **immediately before** the Year test (`:166-171`), with the same last-one-wins demotion as the other single-valued facets:
```swift
// Decade — "NNNNs" (checked before the bare-number Year test; the trailing 's'
// means it can't collide with parseYear, so relative order is immaterial).
if let dec = parseDecade(s) {
    if let prev = decadeToken { subjects.append(prev) }   // demote a shadowed collision
    decade = dec; decadeToken = token
    continue
}
```
Declare `var decadeToken: String?` with the other winner locals (`:127-130`); pass `decade`/`decadeToken` into the `DocumentTags(...)` initializer (`:181-186`).

**sortDate** (`:68-71`) — Year still wins; Decade is the fallback:
```swift
var sortDate: Int? {
    if let year { return year * 10_000 + (month?.number ?? 0) * 100 + (day ?? 0) }
    if let decade { return decade * 10_000 }
    return nil
}
```

**displayDate** (`:100-106`) — show the verbatim decade token when there's no concrete year:
```swift
var displayDate: String? {
    if let year { … existing year/month/day formatting … }
    if let decadeToken { return decadeToken }   // verbatim "1970s"
    return nil
}
```

**dateIsSpeculative** (`:75`) — a decade-only date is approximate ⇒ italic:
```swift
var dateIsSpeculative: Bool { dateUncertain || (year == nil && decade != nil) }
```
(See Open question #1.)

**topicalTags** (`:80-96`) — add `decadeToken` to the excluded set so the decade doesn't show in the "File tags" column or the search-text join:
```swift
if let t = decadeToken { s.insert(t) }
```

**Tag cloud + tag filter exclusion (requirement c) — already satisfied by the above, do NOT touch NavigationModel.** The tag cloud (`NavigationModel.tagCloud`, `:382-388`) and the filter autocomplete (`allSubjectsCache`, `:373`; matching at `:217`,`:625`) both derive from `file.subjects`. Because the parse loop **consumes** the decade token (`continue`), it never lands in `subjects` — exactly the mechanism that already keeps Year/Month/Day out (see the comment at `NavigationModel.swift:379-381`). So the decade is excluded from the cloud + filter **for free**; the `topicalTags` edit only handles the File-tags column + `LibraryFilter.swift:169` search join. (State this explicitly so the overnight run doesn't add a redundant/incorrect exclusion in NavigationModel.)

Consumers already read the right derived values: `AppKitTableView.swift:243-245` (`displayDate ?? "—"`, primary color when `sortDate != nil`, italic when `dateIsSpeculative`) and `InlineEditCells.swift:61-63` — no change needed there for display.

### 3) Reader — write-path safety (`Core/TagEditing.swift`, `Views/InlineEditCells.swift`) — **Tier-2 core**
The Reader must never **author** a decade (Processor-only) but must never **orphan** one either. Today `.setYear` removes only `tags.yearToken` (`TagEditing.swift:28`), so setting a concrete year on a `1970s` file would leave BOTH `"1975"` and `"1970s"` — and since a decade is excluded from `subjects`/`topicalTags`, the stale `"1970s"` becomes an **invisible, unremovable orphan**. Fix by having a year edit reconcile the decade (Year supersedes Decade):
```swift
case .setYear(let y):
    return TagDelta(add: y.map { [String($0)] } ?? [],
                    remove: (tags.yearToken.map { [$0] } ?? []) + (tags.decadeToken.map { [$0] } ?? []))
```
This is a lossless delta that removes only the exact consumed tokens (`yearToken`/`decadeToken`) — the same discipline as every other facet edit; `TagWriter` still fresh-reads, multiset-verifies, and hashes the data fork. "Clear" (`.setYear(nil)`) therefore also clears a decade (the user cleared the date). "Set 1975" supersedes it.

`DateCell` (`InlineEditCells.swift:18`) — surface the decade so its editor isn't blank on a decade-dated file:
```swift
yearText = file.tags.year.map(String.init) ?? file.tags.decadeToken ?? ""
```
The Set button stays `Int`-gated (`:39-40`), so a decade **cannot be typed** here (`Int("1970s")` fails) — the field shows `1970s`, Set is disabled, and the user either types a concrete year (supersede) or Clears (remove). Consistent with "Processor authors decades." (See Open question #2 — no first-class decade editor in this pass.)

### 4) Processor — affordance only (write path unchanged)
- `ManualTaggingSheet.swift:163` — change the Year prompt/help so the decade is discoverable, e.g. keep placeholder `"1968"` and add a caption/`.help("Type a year (1968) or a whole decade (1970s).")` in the Date `GroupBox` (`:161`).
- `ManualSegmentTagView.swift:356` — same one-line hint under the Year field (there's already a caption row region at `:353-373`).
- **No** logic change to `OCRProcessor+Tagging.swift`, `TagGenerator.swift`, or `MacOSTagger.swift` — verify (don't edit) the verbatim pass-through above still holds after the build.

## Edge cases
- **`1970s` vs `1970`** — distinct tokens; a file with only `1970s` sorts at `19_700_000` (== year-only `1970`), so a `1970s` doc and a `1970` doc tie and fall back to the secondary sort (name). Acceptable/expected.
- **Both `1975` and `1970s` on one (legacy/hand-added) file** — Year wins sortDate + displayDate; the decade is parsed but excluded from cloud/filter/column (redundant, hidden). No new collision is created going forward because §3 reconciles. Note in tests.
- **Malformed `1975s` / uppercase `1970S` / `19700s`** — `parseDecade` returns nil → treated as a plain **subject** (visible, user-correctable). No write impact.
- **`800s` (century-style)** — parses as decade start `800` (3-digit, last digit 0). Sorts at `8_000_000`. Documented as the medieval-friendly form; the SPEC calls the digit run the "decade start."
- **Subject collision** — a genuine subject literally `"1970s"` (rare) would be classified as a decade (display-only) — same acceptable, non-destructive misclassification the SPEC already tolerates for `1984`/`P7`/`Red`. Never drives a removal.
- **Undated files** unchanged: `sortDate == nil` → sort to end, `displayDate == nil` → `"—"`.

## Test plan (scratch/pure ONLY — never the real corpus)
**Reader unit (`DocumentTagsTests.swift`):**
- `parseDecade`: `1970s`→1970, `970s`→970, `1980s`→1980; nil for `1975s`,`1970S`,`1970`,`19700s`,`s`,`""`.
- `parse(raw:)`: `["1970s","Economics","Unread"]` → `decade==1970`, `decadeToken=="1970s"`, `subjects==["Economics"]` (decade NOT in subjects), `topicalTags` excludes `1970s`.
- `sortDate`: `1970s`→`19_700_000`; equals year-only `1970`; Year+Decade → year wins.
- `displayDate`: `1970s` file → `"1970s"`; `dateIsSpeculative` true for decade-only, false when a concrete Year is present without `Date Uncertain`.
- Two decades on one file → last wins, previous demoted to `subjects`.

**Reader write-path unit (`TagEditingTests.swift`):**
- `.setYear(1975)` on a file whose `decadeToken=="1970s"` → `TagDelta(add:["1975"], remove:["1970s"])` (decade removed, no orphan).
- `.setYear(nil)` (Clear) on a decade file → `remove:["1970s"]`, no add.

**Processor unit (no file / scratch file only):**
- Pure: `GeneratedTags(year: "1970s").allTags` contains `"1970s"` verbatim (no capitalization/mangling).
- Optional round-trip: write `GeneratedTags(year:"1970s", …)` via `MacOSTagger.applyTags` to a **`mktemp` scratch file** in the session scratchpad, read `.tagNamesKey` back, assert `1970s` present + trailing `Unread` last. **Never** touch `Test Files/` or a real corpus.

## Verification
From an isolated worktree (root `CLAUDE.md` §Worktree-first), `xcodegen generate` in each app dir first (`.xcodeproj` gitignored):
- **Reader:** `cd ArchiveReader/macOS && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` (no new warnings) then `… test` (full suite green, incl. the new cases). Equivalent: `./test-smoke.sh reader` (build + unit tests, free).
- **Processor:** `cd ArchiveProcessor/macOS && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build` (no new warnings). The pure `allTags`/scratch-file test needs no OCR/network. **Do not** run the paid `./test-smoke.sh processor` for this change (it spends on OCR and this diff doesn't touch the OCR path) unless separately requested.
- **write-surface lint** (Reader): `scripts/lint-write-surface.sh` still green (no new tag-write spelling introduced; the only write remains `TagWriter`).
- **Adversarial review (Tier-2):** since this touches the shared SPEC + `TagEditing`/`MacOSTagger` write path, run a scoped find→refute review of the diff (the paced `REVIEW.md`/lean-review vehicle) — focus on: no path mangles the verbatim decade write; `.setYear` reconcile can't remove an unrelated token; decade is excluded from cloud/filter via `subjects`, not via a fragile NavigationModel edit.
- **GUI smoke (optional, `needs: gui`):** in the Reader, point at a **scratch copy** folder containing one file tagged `1970s`; confirm it lists at the right chronological position, Date column shows italic `1970s`, and it is absent from the tag cloud + tag filter. In the Processor manual sheet, type `1970s` into Year on a scratch input and confirm the output PDF carries the `1970s` tag. (GUI is owner-machine-gated per the GUI-availability memo — announce before driving.)

## Docs move with the code (SAME commit)
- `SPEC/tag-format.md` — the facet/sort/display/where-each-side-lives additions above (the authoritative change).
- `SUITE_TODO.md` — tick §"Archive Reader — dates & decades → Decade tags" `[x]` (cite the commit). For §"tag cloud & filters" → "No dates in the tag cloud" and "Remove date tags from the tag filter search": **verify** Year/Month/Day are already excluded (they are, via `subjects`); if decade was the only gap, tick both `[x]` — else annotate that only the decade portion shipped and leave them for the nav-chrome batch (Open question #4).
- `ArchiveReader/CLAUDE.md` — add **Decade** to the §Verified Facts "Tag facets" list + a §Edge-case/§Decisions line ("decade sorts at its first year, displays `1970s` italic; Reader never authors a decade — Processor-only; a year edit supersedes a decade").
- `ArchiveProcessor/CLAUDE.md` — under §Primary Function 2 "Date tags", note the user may enter a whole decade `1970s` in the manual Year field (written verbatim; LLM never emits it).
- Delete `execution-plans/decades-date-facet.md` on ship (git keeps history).

## Open questions for the owner
See the structured `openQuestions` — (1) decade italic/speculative default, (2) no first-class Reader decade editor, (3) no Processor hard-validator (help text + strict Reader parser), (4) whether this plan also ticks the two "tag cloud & filters" items in full or leaves them to the nav-chrome batch.
