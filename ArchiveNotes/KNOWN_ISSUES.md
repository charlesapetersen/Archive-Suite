# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

Fixed, changed and verified entries, and the 2026-07 build-out logs, are archived in
[`KNOWN_ISSUES_HISTORY.md`](KNOWN_ISSUES_HISTORY.md) (W49.notes-docs-hygiene, 2026-11-25). This file keeps the
open limits, any entry whose disposition is still `(queued: …)` or `(asked: …)`, and the build/test gotchas.

## ⚠️ LIMIT (W40.fix-notes-choose-store, 2026-10-29; narrowed by W49.notes-store-format, 2026-11-20) — a library inside an archive no Suite app has used is not recognised

The store is an `.archivenotes` library (File ▸ New Library… / Open Library…, owner call 24). Both refuse a
Reader archive, any place inside one, a place inside another library, and anything that is not a library
(`StoreFolderChooser.check` / `placeCheck`; the next launch checks again). A place counts as inside an archive
when a parent holds an `.archive-suite-root.json`, or when it is under an archive granted with Choose Archive
Folder…. Measured 2026-11-20 with the production entitlements: the sandbox will not list an ungranted parent but
lets `stat` see the marker in it, on the Desktop too, so an archive the Reader or Notes has opened (both write
the marker) is recognised without a grant. The earlier entry's "the parents are usually unreadable" was wrong.
What is left: an archive whose top carries no marker, because no Suite app has used it, has nothing to recognise,
so a library can be made inside it. Nothing already in the archive is changed then; the package is added beside
it. When a parent cannot be looked at at all (`stat` fails other than "not found"), Notes asks "Is it inside an
archive?" and offers Choose Archive Folder… first (accepted: owner, 2026-11-20, call 24, chose this question as
the remedy; a folder with no marker anywhere above it carries no sign to detect).

## ⚠️ LIMIT (W40.root-marker-auto, 2026-11-06) — Choose Archive Folder… gives a plain folder an archive identity

File ▸ Choose Archive Folder… now writes `.archive-suite-root.json` (kind `reader`) into a folder that has none,
as the Reader does when a folder is chosen, so the two apps agree on a folder with no step to know. It is
created once and never rewritten. It is refused, with nothing written, for a folder that holds the notes store
or is inside it, one inside or holding an archive already granted to Notes, one named like the Reader layout's
`Archival Photos` or `Archival Photos JPEGS` folder (the Reader's root is the folder holding them), one whose
parent carries a marker, and one that cannot be written. The bookmark is made before the file, so a refused
grant writes nothing. With a link in hand (the preview popover) Notes never creates one: a fresh identity
could not be the one the link names, so a folder without one is "not the archive this link was copied from".
A subfolder of an archive whose top carries a marker is refused, even when the archive was never granted
(`stat` sees the marker; measured, W49.notes-store-format). A subfolder of an archive with no marker anywhere
above it cannot be recognised, so picking one gives that subfolder an identity of its own; when a parent cannot
be looked at, Notes first asks "Is it the top folder of its archive?". No existing file is changed; the small
file can be deleted. Tests: `ReaderRootChooserTests` (scratch folders) (accepted: owner, 2026-11-20, call 24,
chose the question as the remedy; an unmarked archive carries no sign to detect).

## ⚠️ LIMIT (W49.storage-notes-zotero, 2026-11-27) — a source whose PDF cannot be read exports no tags

Copy for Zotero, Add to Zotero and the year suggestion read a source's catalogue record (SPEC/containers.md §Zotero
"Catalogue sources"), and gather an old file's tags, header and sidecar only when its PDF provably carries no
catalogue identity, so that a PDF separated from its record never exports an earlier correction as current. A PDF
whose content cannot be read cannot be shown to be old: a cloud file not downloaded, a PDF locked with a password,
or one Core Graphics cannot open or whose metadata is not XML. Such a source exports its file name, container and
link with the line `Catalogue record unavailable: …`, and offers no year. Downloading the file, or opening it
without a password, makes it readable. (accepted: the identity is in the file's content, and catalogue reads never
download, SPEC/catalogue.md §Scoped reads)

## ✅ FIXED (W49.notes-lines-after-html, 2026-11-19) — Returns after raw HTML are kept

Owner call 20: keep what I type. Returns typed after text ending in raw HTML read from a file were dropped on save:
- **After an HTML block** (`<div>…</div>`, `<!-- … -->` on its own line), the Returns are kept at the end of the note,
  before a block or a chip, before text, and in a quote. The block ends at a blank line, which is written first, and
  each further Return is a line break (`</div>`, a blank line, `\` lines, then `&nbsp;`). (accepted: fixed,
  W49.notes-lines-after-html).
- **An HTML block is one newline from what follows it** in the editor, as other blocks are. The blank line that ends it
  in the file showed as an empty line, so one Return typed after it came back as two. (accepted: fixed,
  W49.notes-lines-after-html).
- **After HTML inside a paragraph** (`a <b>x</b>`), Returns are written as after any text. (accepted: fixed,
  W49.notes-lines-after-html).
- **Still dropped after an HTML block that a blank line does not end:** an unclosed `<!--`, `<pre>`, `<script>`, `<?`
  or `<![CDATA[`, or a headerless chip's opener. The block runs to the end of the text, so a Return cannot be written
  outside it. (accepted: platform fact, CommonMark ends these blocks only at their closing marker).
- **Also dropped after a `<div>` block that holds such an opener line** (`<div>`, `<!-- x`, `</div>`), which a blank
  line does end. Apple gives adjacent HTML blocks as one run, without the blank lines between them (measured), so the
  editor cannot tell that block from a closed one followed by an open comment, and treats any opener line with no end
  after it as open. Reading the block starts from the file's lines would lift it. (queued:
  W49.notes-html-block-starts).

Evidence: `verification/evidence/notes/W49.notes-lines-after-html.md`.

## Build/test gotchas (XcodeGen + Swift Testing, 2026-07-13)

- **`xcodegen generate` must run AFTER adding files.** XcodeGen expands the globbed source dirs into an
  explicit file list at *generation* time (not synchronized groups). If you add a `.swift` file to
  `Sources/`/`Tests/` **after** generating, the `.xcodeproj` won't reference it — it silently isn't
  compiled, and `-only-testing:…/NewSuite` matches 0 tests. In a fresh worktree: write your files first,
  *then* `xcodegen generate`, then build/test. (Confirmed: 0 → N pbxproj refs only after re-generating.) (accepted: build-tool behaviour to know, not an app defect).
- **`-only-testing:` / `-skip-testing:` don't select Swift-Testing suites here** (Xcode w/ MacOSX26.2 SDK).
  A `Target/SuiteType` (or `Target/SuiteType/func`) filter selects 0 for `@Suite`/`@Test` types; the XCTest
  "Executed N tests" summary also excludes Swift-Testing results (those print as `✔ Test "…"` lines). Read
  the `✔ Test`/`✔ Suite`/`Test run with N tests` lines to confirm a Swift-Testing suite ran, not the XCTest
  summary. A bare `-only-testing:<Target>` runs everything — this is the headless smoke path (the
  `performClick:` abort that used to make it red is fixed; see the RESOLVED note in `KNOWN_ISSUES_HISTORY.md`). (accepted: build-tool behaviour to know, not an app defect).
