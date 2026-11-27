# Human Transcription Rules — Archive Suite 96-Page OCR Truth Set

**Purpose (`W46.truth-96-human-keyed`):** Guide for people keying archival pages blind from the page image alone (no model reading shown). Every rule below matches the conventions already used by `ocr_truth.py` and `ocr_panel_score.py` so human-keyed truth and saved model readings are scored on the exact same basis.

---

## 1. Core rules (what to type)

1. **Transcribe every word on the document page, in natural reading order.**
   - Multi-column pages (newspapers, clippings, two-column reports): read one complete column top to bottom, then move to the next column left to right.
   - Include headings, subheadings, dates, letterheads, page numbers, stamps, signatures, and handwritten annotations or marginalia. Put marginalia or stamps where they naturally fall in the reading order (usually beside the paragraph they refer to, or at the top/bottom if page-level).
2. **Leave out things that are not part of the document page.**
   - Omit text bleeding in from a neighbouring page at the edge of the photograph.
   - Omit archive table labels, rulers, colour bars, copyright slips, or fingers/clips holding the page.
   - Omit empty checkboxes (`☐`) and purely decorative symbols/rules that are not text.
3. **Keep original spelling, capitalisation, and punctuation.**
   - Do **not** fix typos, archaic spellings, or grammar (`recieve`, `meritocraty`, `N. Y.`, `to-day`).
   - Do **not** expand abbreviations (`Dept.`, `Jan.`, `Co.`, `&`).
   - Do **not** summarise, add commentary, or use Markdown formatting (no `#` headings, no `**bold**`, no code fences).
4. **Line breaks and end-of-line hyphenation.**
   - Press Return at each physical line break (or paragraph break) so your transcription stays easy to proofread against the image.
   - Keep hyphens as printed or written on the page (for example, `govern-` at the end of a line followed by `ment` on the next line stays `govern-\nment`; an unbroken compound `post-war` stays `post-war`). *Note:* On the 96-page set (`S0`), the scorer collapses line breaks to spaces and does **not** silently join line-end hyphens, so both readers should preserve visible hyphens consistently.
5. **Illegible, hidden, or cut-off words.**
   - Write `[illegible]` (lowercase, in square brackets) for any word you cannot read with confidence, or any word obscured by a fold, blot, shadow, stamp, or cropped edge.
   - Use one `[illegible]` per unreadable word (or per short unreadable stretch if word boundaries cannot be told apart). Never guess a word you cannot see.
6. **Struck-out (crossed-out) and inserted text.**
   - **Legible crossed-out words:** Transcribe them as plain text in the order they sit on the page (do not add strikethrough markup), and briefly mention them in the **Page note** box (e.g., `line 4: "earlier" crossed out`).
   - **Unreadable crossed-out words:** Write `[illegible]` where they sit.
   - **Handwritten insertions** (above a line with a caret `^` or squeezed between words): Type the inserted words at the point the caret indicates.
7. **Tables and forms.**
   - Type one row per line and separate cells with `" | "` (space, vertical bar, space).
   - Keep row headers, column headers, and filled-in values; leave out blank fill lines (`_______`) and empty checkboxes.
8. **Page metadata fields (below the text box).**
   - **Kind of writing:** Choose the writing that covers most of the page's main text: `typewritten`, `printed`, `handwritten`, or `mixed` (when no single kind covers most of the page).
   - **Table or form:** Check `yes` if the page is mostly a table or a structured form with fields; otherwise `no`.
   - **Page note (optional):** Flag anything unusual (rotated page, upside-down stamp, unreadable corner, crossed-out words, possible duplicate page).

---

## 2. What the scorer already normalises (do NOT waste time on these)

Before scoring (`ocr_panel_score.normal` on `S0`, and `ocr_truth.words` during two-reader comparison), the pipeline automatically folds all of the following. Type whatever is quickest on your keyboard:

- **Quotes and apostrophes:** Curly quotes (`‘ ’ “ ”`) and straight quotes (`' "`) are treated as identical.
- **Dashes:** En-dash (`–`), em-dash (`—`), minus (`−`), and plain hyphen (`-`) are treated as identical (`-`).
- **Whitespace and blank lines:** Single spaces, multiple spaces, tabs, line breaks, and blank lines all collapse to a single space.
- **Table bars (`|`):** Kept in your file for readability, folded to a space by the scorer.
- **Bullets:** `•`, `*`, and a standalone `- ` at the start of a line all fold to `*`.
- **Compatibility ligatures and spacing:** `ﬁ` → `fi`, `ﬂ` → `fl`, non-breaking spaces → regular spaces (Unicode NFKC).
- **Empty checkboxes and bullet symbols:** Stripped during two-reader comparison.

What the scorer **does keep distinct** (so get these right):
- **Case** (`Senate` vs `senate`) in NES and chrF,
- **Exact spelling and digits** (`1954` vs `1956`, `Eubank` vs `Ewbank`),
- **Punctuation** (commas, periods, hyphens, parentheses) in NES and chrF,
- **Word order** (column order and paragraph order),
- **The literal `[illegible]` marker** (matched literally in NES/chrF, excluded from word missed/added counts).

---

## 3. Worked examples (invented pages — one per kind)

All four examples below are **invented** pages illustrating the conventions above.

### Example 1 — Typewritten (`kind: typewritten`, `table_form: no`)

**What the invented page shows:**
- Printed letterhead at top: `MIDWEST REGIONAL PLANNING BOARD / CHICAGO 4, ILLINOIS`
- Diagonal rubber stamp at top right: `RECEIVED MAY 14 1953`
- Typewritten memo with a typo (`comittee`), a line-end hyphen (`reorgani-` / `zation`), a handwritten insertion `^ revised` above line 2, and a cropped margin word at the bottom.

**How to key it:**
```text
MIDWEST REGIONAL PLANNING BOARD
CHICAGO 4, ILLINOIS
RECEIVED MAY 14 1953

May 12, 1953

MEMORANDUM TO: Regional Directors

The comittee has reviewed the revised draft of the reorgani-
zation schedule and asks each district office to submit its
spring payroll figures before June 1.

Please retain the carbon copy for your [illegible] file.

A. R. Halvorsen
```
*Page note:* `line 2: "revised" inserted in pencil above "draft"; bottom right word cut off by photo edge.`

---

### Example 2 — Printed (`kind: printed`, `table_form: no`)

**What the invented page shows:**
- Two-column newspaper clipping (`THE DAILY CHRONICLE — Oct. 4, 1948`) with a small 2-row summary table inside column 2 and a blurred word at a fold crease.

**How to key it:**
```text
THE DAILY CHRONICLE - Oct. 4, 1948

FACTORY OUTPUT RISES IN THIRD QUARTER

Reports released yesterday by the State Labor
Bureau show steady gains across metalworking
and textile plants during the July-September
period.

Plant managers credited steadier rail ship-
ments and [illegible] seasonal demand for the
increase in weekly hours.

Quarterly Summary
Sector | Plants | Workers
Metalworking | 42 | 11,840
Textiles | 19 | 4,215
```
*Note:* Column 1 is transcribed completely before Column 2; the table uses `" | "` between cells; the em-dash in the masthead can be typed as `-`.

---

### Example 3 — Handwritten (`kind: handwritten`, `table_form: no`)

**What the invented page shows:**
- Cursive personal letter dated `Tues. Nov. 9`, with a legible crossed-out word (`would`), an unreadable blotched surname, and non-standard spelling (`untill`).

**How to key it:**
```text
Tues. Nov. 9

Dear Clara,

We arrived safely last evening though the train was
two hours late at Junction City. Mr. [illegible] met us
at the platform and said he would could hold the rooms
untill Friday morning.

Write soon,
H. M.
```
*Page note:* `line 3: "would" crossed out in ink before "could"; surname on line 2 obscured by ink blot.`

---

### Example 4 — Mixed (`kind: mixed`, `table_form: yes`)

**What the invented page shows:**
- Printed personnel survey card with half the page printed labels/table headers and half typewritten/handwritten entries, plus two empty checkboxes `[ ] Temporary  [x] Permanent`.

**How to key it:**
```text
DISTRICT OFFICE PERSONNEL RECORD
Form 14-B (Rev. 1951)

Employee Name | Department | Start Date | Grade
M. E. Kowalski | Accounting | 03/15/1949 | GS-7
R. T. Okafor | Field Audit | 11/02/1950 | GS-9

Status: Permanent
Supervisor remarks: Transferred from St. Louis branch, Oct. 1952.
```
*Note:* Empty checkboxes (`Temporary`) are omitted; the checked status value (`Permanent`) is kept; printed headers and typed/handwritten entries are roughly equal, so `kind` is `mixed` and `table_form` is `yes`.
