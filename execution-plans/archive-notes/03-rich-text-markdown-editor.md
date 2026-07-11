# Archive Notes — W3: Rich-text editor over Markdown (WYSIWYG + raw toggle, inline images)
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 3

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Build the core editing surface locked in 00-overview §D6/§6: a rich-text **WYSIWYG** editor where the user never sees Markdown syntax unless they ask, backed by an `NSTextView`/TextKit 2 view wrapped in `NSViewRepresentable`, with a formatting toolbar + keyboard shortcuts, inline images written into the item's own `assets/`, non-editable **source-block header chips** rendered above each sourced block, and a per-note **raw-Markdown toggle (⌘/)** that swaps the same view between styled and monospaced modes over one underlying Markdown string with **zero data loss**. Markdown is the saved format (00-overview §D1); the editor's write path — attributed→CommonMark — is **net-new** and must be provably idempotent for the supported subset. Rich text is **greenfield in this repo**: no existing code edits or persists attributed strings; the Reader/Processor `NSTextView` usages are plain single-line token fields (`SubjectTokenField`, `KeyboardTokenField`) and read-only diff rendering (`OCRView+WordDiff`), so every rich-text/TextKit-2 concern below is being introduced for the first time.

## Dependencies
- **W1 (`01`) must land first**: the `ArchiveNotes/` third-app scaffold (bundle `com.archivenotes.app`), `project.yml`, `./launch.sh notes`, the app skeleton + empty 3-pane shell, and the `ArchiveCore` package. W3 adds views into that target and a `Format` menu into the W1 `ArchiveNotesCommands`.
- **W2 (`02`) for persistence** (soft dependency — the editor can be built and GUI-verified against an in-memory `body: String` binding, then wired to the store when W2 lands): W3 consumes W2's `NotesStore` for two things only — (a) loading/saving the item body Markdown string, and (b) an asset-write API `addAsset(itemID:data:preferredName:) -> String` (returns the `assets/…` relative path) used by inline-image paste/drag. W3 **defines no file writers of its own** beyond calling that store API; all atomic-write / `NSFileCoordinator` safety lives in W2 (00-overview §9, `02`).
- **W4 (`04`) is downstream, not a dependency**: W3 builds the block-chip *rendering + Markdown serialization/parse* and exposes an `insert(block:)` seam; the actual **paste-from-Reader pasteboard payload → SourceAnchor** hand-off is W4. W3 exercises the seam with a test/stub anchor. `SourceAnchor` itself (00-overview §3.3) is materialized in ArchiveCore/W2/W4; W3 treats it as an opaque `Sendable` value carried on a chip attribute and never re-decides its shape.

Tier: **Tier-1** for all of W3 (pure UI/editor/bridge; no irreplaceable-data surface — it never touches the Reader corpus and writes only the app's own store via W2's audited writers). Always: clean build, **no new warnings**, unit tests, GUI verification (00-overview §12).

## Design

### 0. Module layout (all NEW, in `ArchiveNotes/macOS/Sources/ArchiveNotes/`)
```
Editor/
  MarkdownEditorView.swift        NSViewRepresentable<NSScrollView> + @MainActor Coordinator (two-way binding, undo, find, raw toggle)
  EditorTextView.swift            NSTextView subclass (TextKit 2): shortcut routing, paste/drag intake, attachment view providers
  MarkdownBridge.swift            PURE, nonisolated: parse(markdown)->AttributedModel, serialize(AttributedModel)->markdown  (NET-NEW write path)
  MarkdownAttributes.swift        Custom NSAttributedString.Key definitions + the semantic↔visual Styler
  NoteBlock.swift                 NoteBlock / NoteBody value types (Sendable) — the body-as-ordered-blocks model (00-overview §3.2/§6)
  BlockHeaderAttachment.swift     NSTextAttachment subclass + NSTextAttachmentViewProvider chip (TextKit 2)
  InlineImageAttachment.swift     Inline pasted-image attachment (thumbnail + assets path attribute)
  EditorFormatting.swift          Toolbar actions: applyBold/Italic/InlineCode/Link/Heading/List/Quote/CodeBlock on a selection
  FormattingToolbar.swift         SwiftUI toolbar bound to the Coordinator's format commands
Views/
  NoteEditorPane.swift            SwiftUI host: toolbar + MarkdownEditorView + raw-toggle affordance (the center pane of the 3-pane shell)
```

### 1. The editor view — `MarkdownEditorView: NSViewRepresentable`
Wraps `NSScrollView(documentView: EditorTextView)`, following the shipped wrapper pattern in `AppKitTableView` (NSViewRepresentable over `NSScrollView`, `@MainActor` on `makeNSView`/`updateNSView`/`Coordinator`) and `SubjectTokenField` (the *freeze-during-edit* guard).

```swift
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var markdown: String          // the saved-format source of truth (Markdown)
    @Binding var isRaw: Bool               // ⌘/ raw-Markdown toggle
    let assetStore: EditorAssetStore       // W2 seam: addAsset(...)->relativePath, resolveAsset(rel)->URL?
    let onRevealBlock: (SourceAnchor) -> Void   // W4 seam (stub in W3): reveal-in-Reader
    var fontSize: CGFloat = 14

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor func makeNSView(context: Context) -> NSScrollView { … }
    @MainActor func updateNSView(_ sv: NSScrollView, context: Context) { … }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextContentStorageDelegate {
        var parent: MarkdownEditorView
        weak var textView: EditorTextView?
        private var isApplyingProgrammaticChange = false   // suppress re-entrant model writes
        private var serializeDebounce: Task<Void, Never>?
        …
    }
}
```

- **TextKit 2 is mandatory and fragile.** Create the view via `EditorTextView(usingTextLayoutManager: true)` (or `NSTextView.scrollableTextView()` which is TextKit 2 by default on macOS 14). **Never access `textView.layoutManager`** — touching it silently downgrades the view to TextKit 1 and disables `NSTextAttachmentViewProvider` (our chips). Do all work through `textLayoutManager`/`textContentStorage`/`textContentManager`. Add a unit-testable assertion + a `scripts/lint-editor.sh` grep that fails on `\.layoutManager` in `Editor/`.
- **Two-way binding.** External change (`markdown` binding changes while the view is *not* first responder, e.g. loading a different note) → in `updateNSView`, re-render. **Freeze during edit** exactly like `SubjectTokenField.updateNSView` (SubjectTokenField.swift:52-64): if `textView.window?.firstResponder === textView` (user is typing), do **not** reset the text storage — only sync external fields (font size, `isRaw` toggle handled explicitly). This prevents a SwiftUI re-render from clobbering an in-progress edit.
- **Model write-back is debounced, not per-keystroke.** `textDidChange(_:)` schedules a 400 ms `Task` (cancel-and-replace) that serializes the current attributed storage (styled mode) or reads the raw string (raw mode) back into `parent.markdown`. Serialization is pure and can run off-main on the value model, but reading `NSTextStorage` must stay `@MainActor` (see §8). Immediate flush on blur (`textDidEndEditing`) and on an explicit `flush()` the host calls before save.
- **Undo & Find** are native: `textView.allowsUndo = true` (⌘Z/⌘⇧Z work automatically over `NSTextStorage` edits); `textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true` gives ⌘F/⌘G/⌘E over the whole note (works across blocks because it is one continuous text view). Toolbar formatting actions wrap their storage mutations in `textView.undoManager?.beginUndoGrouping()/endUndoGrouping()` so a format toggle is one undo step.
- **Focus** on appear / on programmatic request uses the focus-token pattern from `TagFilterField.swift:38-41` (`DispatchQueue.main.async { window?.makeFirstResponder(textView) }`).

### 2. The single-text-view block model (architecture decision, not re-deciding the on-disk format)
The whole note is **one** `NSTextView` / one text storage (not one editor per block). Rationale: continuous cross-block selection, undo, and ⌘F "just work"; block boundaries are represented *inside* the storage by **atomic chip attachments**, and the block list is *derived* on serialize. This is the only viable way to satisfy "non-editable header chip above its editable text" while keeping find/undo whole-note.

`NoteBody`/`NoteBlock` (NET-NEW, `Sendable` value types) are the serialize/parse intermediate, matching 00-overview §3.2/§6:
```swift
struct NoteBody: Sendable, Equatable { var blocks: [NoteBlock] }
struct NoteBlock: Sendable, Equatable {
    var source: SourceAnchor?            // nil ⇒ freeform (00-overview §3.2); opaque Sendable value (W4 owns its fields)
    var bodyMarkdown: String             // block body WITHOUT the <!-- block --> header / thumb line
    var unknownHeaderFields: [(String,String)]   // preserved verbatim per 00-overview §6 round-trip rule
}
```
In the text storage a sourced block is: `[BlockHeaderAttachment char]` (one glyph, atomic) `\n` `<block body attributed text>`. A freeform block is just body text with no preceding chip. On serialize we walk the storage; each chip flushes the prior block and starts a new one.

### 3. The attributed↔Markdown BRIDGE (`MarkdownBridge`)

**READ path (Markdown → attributed) — may use `NSAttributedString(markdown:)` (macOS 12+).**
1. **Split blocks ourselves first.** Scan for `<!-- block: <kind> … -->` HTML-comment headers (00-overview §6 grammar). Everything between two headers (or before the first / after the last) is a block body. Parse each header into `(kind, link, display, page, thumb, zotero, note)` + `unknownHeaderFields`; tolerate missing optionals; absent header ⇒ one `freeform` block (00-overview §6 graceful-degradation rule). The `![alt](thumb)` image line **immediately following** a sourced header whose target equals the header's `thumb:` field is consumed into the chip (not rendered as an inline image).
2. **Parse each block body's inline+block structure with Apple's CommonMark parser:**
   `try NSAttributedString(markdown: body, options: opts, baseURL: nil)` with
   `opts = .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)`.
   **What `.full` gives us:** semantic attributes only — `presentationIntent` (block: `.header(level)`, `.orderedList`/`.unorderedList` + `.listItem(ordinal)` with nesting depth encoded as nested intents, `.blockQuote`, `.codeBlock(languageHint:)`, `.thematicBreak`, `.paragraph`), `inlinePresentationIntent` (`.emphasized`, `.stronglyEmphasized`, `.code`, `.strikethrough`, `.lineBreak`), `.link`, `.languageIdentifier`. **What it does NOT do:** it applies **no visual styling** (no fonts/sizes/colors — you must style it), and it does **not** load images (`![]()` is recognized but produces no populated `NSTextAttachment`). It **strips raw HTML** (fine — we removed the `<!-- block -->` comments in step 1). We therefore treat **images as a first-class case we handle ourselves** (step 3), independent of the parser.
   *S2 must empirically confirm the image behavior on macOS 14 and pin the exact `presentationIntent` shape via a snapshot test; if any construct round-trips lossily through Apple's parser we fall back to our own line-based block scan for that construct — the bridge is defined so either source of block structure feeds the same Styler.*
3. **Extract inline images ourselves.** Before/after parsing, resolve `!\[(?<alt>[^\]]*)\]\((?<path>[^)]+)\)` spans in body text into `InlineImageAttachment` characters, loading a downsampled thumbnail from `assetStore.resolveAsset(path)` (nil-safe: missing asset → a "missing image" placeholder attachment carrying the path, so the path is never lost on re-serialize).
4. **Style pass (`MarkdownAttributes.Styler`).** Convert the semantic attributed string into the **visual** attributed string TextKit renders, and simultaneously **stamp our own custom attributes** so the write path reads reliable semantics instead of reverse-engineering fonts. This is the same semantic→visual mapping idiom shipped in `OCRView+WordDiff.swift:186-224` (build runs, set `.font`, bold/mono via traits, `.foregroundColor`), extended to paragraph styles.

**WRITE path (attributed → CommonMark) — NET-NEW `serialize()`.** Walk the storage:
- On a `BlockHeaderAttachment`: flush the current block; emit `<!-- block: <kind>` + present optional fields + `unknownHeaderFields` verbatim + ` -->\n` + (if `thumb`) `![display](thumb)\n`.
- Otherwise group text into **logical lines** (split on `\n`, attachments interrupt). Each paragraph's kind comes from our stamped paragraph-level custom attribute (heading/quote/list/codeBlock/plain) — emit prefix: `#`×level+space; `> ` (blockquote, one level); `- `/`N. ` for lists with `depth × 4` spaces indent (CommonMark-safe) and correct renumbering of ordered items; fenced ```` ``` ````+languageHint for code blocks (body emitted verbatim, no inline escaping).
- Serialize inline runs: strong→`**…**`, emphasis→`*…*`, inline-code→`` `…` `` (choose ``` `` ``` fence if the run contains a backtick), `.link`→`[text](url)`, `InlineImageAttachment`→`![alt](relativePath)`. Escape CommonMark metacharacters (`\`, `*`, `_`, `` ` ``, `[`, `]`, `#` at line start) in *plain* text runs; do not escape inside code.

**Round-trip / idempotency policy (00-overview §6 ethos):**
- **Supported subset is idempotent:** `serialize(parse(md))` == `normalize(md)` and `parse(serialize(attr))` is attribute-equal to `attr` for: headings 1–6, bold, italic, bold+italic, inline code, fenced code block, unordered list, ordered list, nested lists (both kinds, ≥2 deep), blockquote, link, image, and any mix. `normalize` = canonical spacing/marker choice (`-` for ul, `1.`/`2.` renumbered, 4-space nesting) so the fixed-point is reached after **one** round trip (tested by asserting the *second* round trip is a no-op).
- **Unknown/complex styling policy (graceful degradation):** any visual attribute we do not model (arbitrary foreground color, underline, strikethrough authored outside the toolbar, custom font family/size beyond bold/italic/mono) has **no CommonMark representation and is dropped on serialize** — **text is never dropped, only styling.** The toolbar deliberately exposes **only** the serializable subset (§5) so a user can never author unsaveable formatting through the UI, and the raw toggle (§6) lets them verify exactly what will be saved. `unknownHeaderFields` in block headers are the one thing preserved *verbatim* (structured provenance must never be lost). Tables, footnotes, task-lists, HTML blocks: **deferred** (Open questions).

### 4. Custom attributes (`MarkdownAttributes.swift`, NET-NEW)
```swift
extension NSAttributedString.Key {
    static let noteBlockKind      = NSAttributedString.Key("an.blockKind")      // paragraph: heading/quote/listItem/codeBlock/plain (+ level/depth/ordered/ordinal)
    static let noteInlineCode     = NSAttributedString.Key("an.inlineCode")     // Bool run
    static let noteImageRelPath   = NSAttributedString.Key("an.imageRelPath")   // String on an InlineImageAttachment char
    static let noteBlockSource    = NSAttributedString.Key("an.blockSource")    // SourceAnchorBox on a chip char
}
```
Inline **bold/italic** are read back from the run's `NSFont` traits (`NSFontManager.traits(of:)` → `.boldFontMask`/`.italicFontMask`) — reliable and matches how `OCRView+WordDiff` builds bold/mono runs; we do not need a custom attr for them. Inline **code** uses a monospaced font **and** the `noteInlineCode` flag (belt-and-suspenders so an incidental mono run isn't mis-serialized).

### 5. Formatting toolbar + keyboard shortcuts
`FormattingToolbar` (SwiftUI, above the editor) mirrors the shortcuts; the **menu is the single source of shortcuts** (Reader convention) via a new **Format** menu in `ArchiveNotesCommands` (W1). Actions live in `EditorFormatting` and mutate the selection's attributes inside one undo group, then re-run the debounced serialize.

| Action | Shortcut | Effect on selection (WYSIWYG) → serialized |
|---|---|---|
| Bold | ⌘B | toggle bold trait → `**…**` |
| Italic | ⌘I | toggle italic trait → `*…*` |
| Inline code | ⌘⌥C | toggle mono+`noteInlineCode` → `` `…` `` |
| Link… | ⌘K | prompt URL (sheet); set `.link` → `[text](url)` |
| Heading 1–6 | ⌘⌥1…⌘⌥6 | set paragraph `noteBlockKind=.heading(n)` → `#`×n |
| Body/paragraph | ⌘⌥0 | clear paragraph kind → plain |
| Unordered list | ⌘⇧U | `noteBlockKind=.listItem(ordered:false,depth)` → `- ` |
| Ordered list | ⌘⇧O | `.listItem(ordered:true)` → `1. ` |
| Indent/Outdent list | ⇥ / ⇧⇥ (when in a list) | change depth → indentation |
| Blockquote | ⌘⌥Q | `.blockQuote` → `> ` |
| Code block | ⌘⌥K | `.codeBlock` → fenced |
| Toggle raw Markdown | ⌘/ | §6 |

Keystroke interception (⇥ for list indent, Return-splitting a list item, Backspace-at-start outdenting) uses the `doCommandBy:` override pattern from `KeyboardTokenField.swift:63-81`, implemented on `EditorTextView`; unhandled selectors fall through to default `NSTextView` behavior. Heading/list state is reflected as toolbar highlight by reading the caret paragraph's `noteBlockKind`.

### 6. Raw-Markdown toggle (⌘/)
One `NSTextView`, two presentation modes over **one** underlying Markdown string (the source of truth):
- **Enter raw:** `flush()` styled storage → `markdown`; replace the text storage with the plain `markdown` string in a monospaced font (`.monospacedSystemFont`), disable attachment view providers, keep undo/find. The user now edits the exact bytes that will be saved (including verbatim `<!-- block -->` headers and `![](assets/…)` lines).
- **Leave raw:** read the plain string → `parse()` → styled storage.
- **No data loss** because both directions go through the bridge and the raw view *is* the serialized form; a construct we cannot render still survives (it's in the Markdown, shown verbatim in raw). **Undo does not cross the toggle:** switching mode replaces the storage, so we `removeAllActions()` on the undo manager at the swap and treat the swap as a hard boundary (documented; simplest correct behavior). If parse fails on leaving raw (malformed Markdown the user typed), stay in raw and surface a non-destructive banner ("couldn't render — fix the Markdown or keep editing raw"), never silently discarding text.

### 7. Inline images + paste
`EditorTextView` overrides `readSelection(from:)`/`performDragOperation(_:)` and the paste path (`paste(_:)` / `readablePasteboardTypes`):
- **Image on pasteboard/drag** (`.png`, `.tiff`, file-URL image): encode to PNG (`NSBitmapImageRep.representation(using:.png)`), call `assetStore.addAsset(itemID:data:preferredName:"pasted-<date>-<n>.png")` (W2 writes atomically into the item's own `<store>/items/<uuid>/assets/` — **never the corpus**; returns the `assets/…` rel path), build an `InlineImageAttachment` (downsampled thumbnail via `CGImageSourceCreateThumbnailAtIndex`, `noteImageRelPath = relPath`), and insert at the caret. Serializes to `![](assets/…)` (00-overview §5). Very large images are downsampled for the *thumbnail only*; the full PNG stays on disk.
- **Plain/rich text on pasteboard** (from Reader or anywhere): insert as a paragraph in the **current block** at the caret (mandate 3). Prefer `.string`; if RTF/attributed is present we accept only the styling subset we model (bold/italic/links) and drop the rest (§3 policy).
- **Reader "Copy Archive Link(s)" custom-UTI payload** (00-overview §8.4): W3 detects the UTI and calls the `insert(block:)` seam to create a sourced block, but the payload *decoding* and thumbnail transfer are **W4**. In W3 this seam is exercised by a stub anchor + a test-menu "Insert test source block".

### 8. Block header chips (non-editable, TextKit 2)
`BlockHeaderAttachment: NSTextAttachment` stores the `SourceAnchor` + optional thumbnail; it overrides `viewProvider(for:location:textContainer:)` to return a `BlockHeaderViewProvider: NSTextAttachmentViewProvider` whose `loadView()` builds a SwiftUI-in-`NSHostingView` (or AppKit) chip: **thumbnail + `display` label + a "Reveal in Reader" button** calling `onRevealBlock(anchor)` (W4 wires the actual reveal; W3 stub logs/no-ops). `attachmentBounds(...)` sizes the chip to a fixed height row. Because the chip is a single atomic attachment character, it is inherently **non-editable inside** and deletes as a unit; its following paragraph text is normally editable. In **raw mode** the chip is absent — the `<!-- block: … -->` header + `![](thumb)` line show verbatim (§6). `SourceAnchorBox` is a small `final class` reference wrapper (so it can ride on an attribute) holding the `Sendable` `SourceAnchor` value.

### 9. Performance (mandate 7)
- **TextKit 2 viewport layout** handles long single notes without laying out the whole document; the hard rule is *never touch `layoutManager`* (§1) or we lose it.
- **Lazy attachment loading:** `NSTextAttachmentViewProvider` instantiates chip/image views only for on-screen fragments; decoded thumbnails are cached in a bounded `NSCache<NSString, NSImage>` keyed by asset rel-path (evictable; re-decoded on demand). Full-resolution PNGs are never loaded into the editor — only downsampled thumbnails.
- **Debounced serialize** (§1, 400 ms) keeps typing off the parse/serialize path; only blur/save force a flush.
- **Parse/serialize are pure & `nonisolated`** over `String`/`NoteBody` (`Sendable`), so a large paste can parse off-main; the *result must be applied to `NSTextStorage` on `@MainActor`* (NSAttributedString/NSTextStorage are not `Sendable`). Concurrency shape: `Task.detached` parse → hop to `@MainActor` to build/apply attributed storage.

### Edge cases + graceful degradation
- Missing `assets/` image on load → placeholder attachment that **preserves the rel-path** so re-save doesn't lose the reference.
- Malformed block header → treat region as `freeform`, keep the raw header text as body (never crash) (00-overview §6).
- Empty note / note with only a chip / chip as first char / consecutive chips → serialize/parse must all be idempotent (test fixtures).
- Backspace that would merge across a chip boundary is allowed (deletes chip = removes the block's source, demoting it to freeform) — a *deliberate* user edit, undoable.
- Ordered-list renumbering: serializer always renumbers from the first item (input `3.`/`3.`/`3.` → `1.`/`2.`/`3.`).

## Reuse from the existing codebase
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/SubjectTokenField.swift:52-64`** — the `updateNSView` **freeze-during-edit** guard (`currentEditor()`/first-responder check → don't clobber the in-progress edit or repoint the target). Adapt verbatim as the editor's "don't reset text storage while the user is typing" rule.
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/AppKitTableView.swift:10-22,112-113,185-202`** — `NSViewRepresentable` over `NSScrollView`, `@MainActor` on `makeNSView`/`updateNSView`/`Coordinator`, `parent`-back-reference + `makeCoordinator(self)` idiom. Copy the scaffold shape for `MarkdownEditorView`.
- **`AppKitTableView.swift:292-321`** — building an `NSAttributedString` with per-run fonts/colors/traits (`NSMutableAttributedString.append`, `NSFontManager.convert(_:toHaveTrait:)`). Same idiom drives the Styler's semantic→visual mapping.
- **`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/OCRView+WordDiff.swift:186-224`** — `buildAttributedString(from:)`: run-by-run `AttributedString` with `.font(.system(size:design:).bold())`, `.foregroundColor`, mono design. Direct template for mapping bold/italic/inline-code/heading runs to visual attributes.
- **`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/KeyboardTokenField.swift:63-81`** — `control(_:textView:doCommandBy:)` selector interception (Return/Tab/Backspace/Escape). Adapt for the editor's ⇥ list-indent, Return list-continue, Backspace-outdent, ⌘/ etc. on `EditorTextView`.
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/TagFilterField.swift:38-41`** — the focus-token `DispatchQueue.main.async { makeFirstResponder }` pattern for programmatic focus of the editor.
- **NET-NEW (nothing in the repo does this today):** any `NSTextView`/TextKit-2 rich text, attributed-string *persistence*, `NSTextAttachment`/`NSTextAttachmentViewProvider`, `NSAttributedString(markdown:)`, and the attributed→Markdown serializer. All existing `NSTextView` use is plain single-line token entry or read-only diff display — call this out so no one assumes an editor exists to extend.

## Bounded sub-tasks
Each is one fresh overnight session: worktree → build clean/no new warnings → unit tests + GUI via `./launch.sh notes` → docs-in-same-commit → push → remove worktree (00-overview §14). All **Tier-1** (00-overview §12).

- **S1 — Editor shell, plain-Markdown editing, two-way binding, undo/find, raw-toggle mechanism.**
  Files: `Editor/MarkdownEditorView.swift`, `Editor/EditorTextView.swift`, `Views/NoteEditorPane.swift`; wire into the W1 center pane. No rich rendering yet — both styled and raw modes show the plain Markdown string (establishes the swap + no-loss plumbing + debounced write-back). TextKit 2 enforced; `scripts/lint-editor.sh` added (fails on `\.layoutManager`).
  Steps: build the `NSScrollView`+`EditorTextView`; `@Binding markdown`; freeze-during-edit guard; `allowsUndo`/find bar; ⌘/ swaps storage and clears undo; 400 ms debounce → binding.
  Verify: clean build/no new warnings; `EditorBindingTests` (binding round-trip, debounce flush on blur); GUI — type, ⌘Z, ⌘F, ⌘/ swap preserves text byte-for-byte. Done: editor edits + persists a plain-Markdown string; flips SUITE_TODO → Archive Notes → W3 → **S1** and the S1 box here.
- **S2 — The bridge: parse + serialize for inline + block formatting, with idempotency tests.**
  Files: `Editor/MarkdownBridge.swift`, `Editor/MarkdownAttributes.swift`, `Editor/NoteBlock.swift`. Read path via `NSAttributedString(markdown: .full)` + Styler; write path net-new serializer. Covers headings, bold/italic, inline code, code block, ul/ol/nested, blockquote, links (images stubbed to S4). Empirically pin Apple-parser behavior; fall back to line-based block scan where lossy.
  Verify: `MarkdownBridgeTests` (per-construct + mixed idempotency; second-round-trip no-op; unknown-styling drop-preserves-text); GUI — styled mode now renders formatting, ⌘/ shows correct Markdown and back.
  Done: bridge idempotent for the supported subset; flips **S2**.
- **S3 — Formatting toolbar + Format menu + keyboard shortcuts.**
  Files: `Editor/EditorFormatting.swift`, `Editor/FormattingToolbar.swift`, Format menu in `ArchiveNotesCommands` (W1). Implements the §5 table; list indent/Return/Backspace behavior via `doCommandBy:`; toolbar reflects caret state; one-undo-group per action.
  Verify: `FormattingActionTests` (apply-then-serialize yields expected Markdown for each action; toggle-twice is a no-op); GUI + cliclick — ⌘B/⌘I/⌘K/⌘⌥1../⌘⇧U/⌘⇧O/⌘⌥Q/⌘⌥K produce correct rendering + Markdown.
  Done: full toolbar drives serializable formatting; flips **S3**.
- **S4 — Inline images: paste/drag → assets → attachment; paste text.**
  Files: `Editor/InlineImageAttachment.swift`, paste/drag intake in `EditorTextView`, bridge image cases in `MarkdownBridge`. Uses W2 `assetStore.addAsset` (if W2 not yet landed, use a scratch-temp `EditorAssetStore` impl for GUI/tests). Missing-asset placeholder preserves rel-path.
  Verify: `ImageSerializationTests` (attachment↔`![](assets/…)`; missing asset preserves path; downsample doesn't touch on-disk PNG); GUI — paste screenshot → thumbnail appears + `assets/…` file written to the **scratch** store, Markdown shows `![](assets/…)`; paste text inserts a paragraph. File-safety: assert writes land only under the temp store, never any corpus path.
  Done: inline images + text paste working; flips **S4**.
- **S5 — Source-block chips: non-editable header rendering, block serialize/parse, reveal seam.**
  Files: `Editor/BlockHeaderAttachment.swift`, block-header parse/serialize in `MarkdownBridge`, `insert(block:)` seam + a debug "Insert test source block" menu item, `onRevealBlock` stub. Chip = TextKit-2 view attachment (thumbnail + display + Reveal button). Raw mode shows `<!-- block --> / ![](thumb)` verbatim. Preserves `unknownHeaderFields`.
  Verify: `BlockParsingTests` (multi-block bodies incl. reader-page/freeform/zotero; unknown fields preserved; absent header → freeform; malformed tolerated; chip-first/consecutive-chips idempotent); GUI — insert test block → non-editable chip above editable text; ⌘/ shows verbatim header; delete-chip demotes to freeform.
  Done: block chips render + round-trip; W4 seam exposed; flips **S5**.
- **S6 — Performance, lazy loading, large-note hardening, polish.**
  Files: thumbnail `NSCache`, lazy view-provider verification, off-main parse for large paste, debounce tuning; expand tests. Add a 50k-word fixture.
  Verify: `EditorPerfTests` (parse/serialize time bound on the fixture; no `layoutManager` access via lint); GUI — open 50k-word note with images + chips, scroll/type stays smooth; instrument that only visible chips instantiate views.
  Done: large notes usable; W3 complete; flips **S6** + the W3 roll-up box; fold durable editor notes toward `ArchiveNotes/CLAUDE.md` (per §14, at app ship).

## Tests
Unit (XCTest, `ArchiveNotes/macOS/Tests/ArchiveNotesTests/`):
- **`MarkdownBridgeTests`** — per-construct idempotency (`heading1..6`, `bold`, `italic`, `boldItalic`, `inlineCode`, `codeBlock`, `unorderedList`, `orderedList`, `nestedListMixed`, `blockquote`, `link`, `mixedDocument`); `secondRoundTripIsNoOp`; `unknownVisualStylingIsDroppedTextPreserved`; `applesParserSemanticSnapshot` (pins `presentationIntent` shape).
- **`BlockParsingTests`** — `multiBlockBody`, `unknownHeaderFieldsPreservedVerbatim`, `absentHeaderBecomesFreeform`, `malformedHeaderTolerated`, `chipFirstChar`, `consecutiveChips`, `thumbLineConsumedIntoChip`.
- **`ImageSerializationTests`** — `attachmentRoundTrip`, `missingAssetPreservesPath`, `inlineImageDoesNotDowngradeSource`.
- **`FormattingActionTests`** — apply-then-serialize per action; toggle idempotence; list indent/renumber.
- **`EditorBindingTests`** — external-binding change re-renders only when not first responder; debounce flushes on blur.
- **`EditorPerfTests`** — bounded parse/serialize on the 50k-word fixture; lint asserts no `layoutManager` reference in `Editor/`.
GUI/behavioral (via `./launch.sh notes`, cliclick; formalized in W8 XCUITest): typing + all §5 shortcuts, ⌘/ no-loss swap, image paste writing to the scratch store, source-chip non-editability + Reveal button present, 50k-word note smoothness.

## Risks & file-safety
- **Round-trip data loss** is the headline risk. Mitigations: strict supported-subset idempotency tests (incl. second-round-trip no-op), toolbar exposes **only** serializable formatting, `unknownHeaderFields` preserved verbatim, serializer **never drops text** (only unmodeled styling), and the raw toggle lets the user *see* exactly what saves. Malformed raw on toggle-back stays in raw with a banner — never discards text.
- **TextKit 2 downgrade:** any stray `.layoutManager` access silently kills chips/perf → `scripts/lint-editor.sh` + an `EditorPerfTests` assertion guard it.
- **`NSAttributedString(markdown:)` surprises** (image handling, whitespace collapsing, HTML stripping): handled by owning images/blocks ourselves and pinning parser behavior with a snapshot test in S2; a per-construct fallback to our line-based scan is designed in.
- **File-safety — confirmed no corpus writes.** The editor's *only* write is inline-image PNGs, and those go **exclusively** through W2's `assetStore.addAsset` into the app's own `<store>/items/<uuid>/assets/` — never the Reader/Processor corpus (00-overview §12). All dev/test asset writes use a `mktemp` scratch store; `ImageSerializationTests` asserts the written URL is under the temp root. The editor reads the corpus only via the W4 Reveal seam (a stub in W3), and never opens or mutates a corpus file. No Finder-tag writes occur in W3 (the `NotesTagProjector` of 00-overview §9 is W2), so W3 does not touch the tag-safety envelope at all.
- **Concurrency (Swift 6 strict):** view/coordinator/attachment providers are `@MainActor`; `NoteBody`/`NoteBlock`/`SourceAnchor` are `Sendable` value types; `MarkdownBridge` parse/serialize are pure `nonisolated` over `String`/value AST; `NSAttributedString`/`NSTextStorage` work stays on `@MainActor` (they are not `Sendable`) — the detached-parse→MainActor-apply hop is the only cross-actor boundary.

## Open questions (non-blocking)
1. **Undo across the raw⇄styled toggle** is intentionally severed for correctness/simplicity — revisit if users want continuous undo (would require re-parsing undo into either representation).
2. **Tables, footnotes, task lists, strikethrough authoring, HTML blocks** — deferred; they'd expand both toolbar and serializer and complicate idempotency.
3. **Syntax highlighting in raw mode** (colorized Markdown) — nice-to-have, not needed for no-loss.
4. **Per-block vs single-storage** — chose single storage (whole-note find/undo). If per-block find/replace or block reordering-by-drag becomes a requirement (W6/W7), revisit.
5. **External `.md` edits while a note is open** (Obsidian/TextEdit) — conflict detection/merge is a W2/W6 concern; W3 assumes it owns the open buffer.
6. **Concrete `EditorAssetStore` API shape** must be agreed with W2 (`addAsset`/`resolveAsset` signatures) — W3 uses a scratch implementation until then.
