# Archive Notes — W5: Zotero integration (local API / Better BibTeX metadata + citations)
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 5

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Let a note (and individual blocks) cite Zotero library items durably. When Zotero is running, Notes probes its localhost server, reads item metadata over Better BibTeX's JSON-RPC (with the Zotero 7 built-in local API as fallback), and offers to auto-fill the note's `authors`/`date`/`title` plus a formatted citation (per 00-overview §3.4, §D8). A `zotero://select/…` link (item **or** attachment) can be pasted for one-click attach; refs render as clickable chips that open Zotero via `NSWorkspace`. Everything degrades gracefully: with only a select link we store the link (and any previously-fetched citation) and never block the UI on Zotero being reachable. All Zotero data persists in front-matter (00-overview §5) so a fetched citation survives Zotero later being unavailable.

## Dependencies
- **W2 (`02`) must land first** — the front-matter reader/writer (`NoteFrontMatter` round-trip, unknown-key preservation per 00-overview §5/§6) and the atomic note store are the only write path W5 uses. W5 adds a typed `zotero:` array to that schema and calls the store's existing save; it introduces **no** new file-write choke-point. Zotero refs are explicitly **not** projected to Finder tags (the `NotesTagProjector` of §9 handles only `tags` + `ArchiveSuite`), so W5 adds nothing to the file-safety surface.
- **W3 (`03`) for the editor/block plumbing** — per-block chip rendering and the `<!-- block: … zotero: <select-link> -->` header (00-overview §6) hang off the block model W3 defines. S1–S3 (model/client/mapping) do **not** need W3 and can run once W2 exists; only S4 (UI chips/paste) needs W3.
- W1 already added `com.apple.security.network.client` to `ArchiveNotes.entitlements` (00-overview §D10); W5 only *uses* it.

## Design

### Net-new statement
No Zotero code exists anywhere in the repo (grep for `zotero`/`23119`/`better-bibtex` is empty). Everything below is net-new under `ArchiveNotes/macOS/Sources/ArchiveNotes/Zotero/`, reusing only the *patterns* (Codable→JSON store, actor-confined off-main I/O) cited under "Reuse".

### D.1 Value types (NEW — `Zotero/ZoteroRef.swift`)
All `Sendable`/`Codable`, UI-free (candidate for `ArchiveNotes` app module, not ArchiveCore — Zotero is Notes-only per D10).

```swift
enum ZoteroLibrary: Equatable, Sendable, Hashable {
    case user               // front-matter "library"; API path users/0
    case group(Int)         // front-matter the numeric gid; API path groups/<gid>
}
enum ZoteroRefKind: String, Codable, Sendable { case item, attachment }

struct ZoteroRef: Codable, Equatable, Sendable, Identifiable {
    var selectLink: String         // canonical "zotero://select/library/items/ABCD1234"
    var itemKey: String            // "ABCD1234" (8-char base32-ish Zotero key)
    var library: ZoteroLibrary
    var kind: ZoteroRefKind        // best-effort; refined to .attachment after fetch if itemType==attachment
    var parentKey: String?         // for attachments, resolved parent item key (nil until fetched)
    var citation: String?          // fetched formatted citation — the durable survivor (§5)
    var fetchedAt: Date?           // last successful metadata fetch; nil = link-only
    var id: String { selectLink }
}
```

`ZoteroLibrary` gets a hand-written `Codable` that maps `.user`→`"library"` and `.group(n)`→`String(n)` (matching the §5 example `library: library`) so front-matter stays legible; decode accepts `"library"` (case-insensitive) or an integer string. `ZoteroRef` order in the `zotero:` array is preserved verbatim by W2's front-matter writer (unknown/extra keys tolerated per §6 round-trip rule).

### D.2 Select-link parser (NEW — `Zotero/ZoteroSelectLink.swift`)
Pure, total, no throw — returns `ZoteroRef?` (nil ⇒ not a recognized zotero link, never a crash). Grammar handled (00-overview §D8 requires item + attachment + group forms; the URL alone cannot distinguish item vs attachment, so `kind` starts `.item` and is refined after a fetch):

```
zotero://select/library/items/<KEY>            → library=.user
zotero://select/groups/<GID>/items/<KEY>       → library=.group(GID)
zotero://select/items/<libID>_<KEY>            → legacy; libID 0/1 ⇒ .user, else .group(libID)
zotero://select/items/<KEY>                    → assume .user
```
Algorithm: require scheme `zotero`, host `select`; split remaining path components; match the tables above; validate `<KEY>` against `^[A-Z0-9]{8}$` (reject otherwise → nil). Always re-emit a **canonical** `selectLink` (the `library/items` or `groups/<gid>/items` form) so the stored link is stable regardless of which variant was pasted. Attachment select links share the same path shape; they are recognized identically and only differentiated post-fetch. Edge cases: trailing slash, url-encoded components (percent-decode `<KEY>`), extra query/fragment (ignored). `zotero://open-pdf/…` and non-select zotero links → nil (not attachable as refs this run; open questions).

### D.3 Availability probe + transport (NEW — `Zotero/ZoteroClient.swift`)
An `actor` (runs entirely off the main actor; the only network surface). Testability via an injected transport so **no test ever touches a real Zotero or the network**:

```swift
protocol ZoteroTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionZoteroTransport: ZoteroTransport {
    let session: URLSession   // ephemeral config, timeoutIntervalForRequest = cfg.timeout
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) { … }
}

actor ZoteroClient {
    struct Config: Sendable { var host = "127.0.0.1"; var port = 23119; var timeout: TimeInterval = 1.5 }
    enum Backend: Sendable { case betterBibTeX, localAPI, unavailable }

    private let transport: ZoteroTransport
    private var config: Config
    private var cachedBackend: (Backend, Date)?          // TTL 30s so a closed Zotero isn't re-probed per keystroke
    private var metaCache: [String: ZoteroCSLItem] = [:] // key = "<libToken>/<itemKey>"
    private var citationCache: [String: String] = [:]    // key = "<libToken>/<itemKey>|<styleID>"

    func availability() async -> Backend           // probe with TTL
    func fetchCSL(_ ref: ZoteroRef) async throws -> ZoteroCSLItem
    func fetchCitation(_ ref: ZoteroRef, styleID: String) async throws -> String
}
```

**Probe cascade** (short timeout, cheapest first; result cached with a 30 s TTL):
1. **Better BibTeX** — `POST http://127.0.0.1:23119/better-bibtex/json-rpc`, body a JSON-RPC 2.0 ping using a method known to exist, e.g.
   `{"jsonrpc":"2.0","method":"item.search","params":[""],"id":1}`. HTTP 200 with a JSON-RPC envelope ⇒ `.betterBibTeX`. (A `-32601 method not found` still proves BBT is up; treat any well-formed JSON-RPC reply as "BBT present" and record which methods 404.)
2. **Zotero 7 built-in local API** — `GET http://127.0.0.1:23119/api/users/0/items?limit=1`. 200 ⇒ `.localAPI`.
3. Connection refused / timeout / non-2xx on both ⇒ `.unavailable` (Zotero not running or port closed).

Timeouts use `URLSession`'s `timeoutIntervalForRequest`; the whole probe is wrapped so a hung socket cannot exceed `cfg.timeout`. Errors are swallowed into `.unavailable` — the probe never throws to the UI.

### D.4 Metadata fetch — exact JSON-RPC / API shapes
Zotero select links carry the **Zotero item key**, but Better BibTeX operates on **citation keys**, so the BBT path is a two-step. The concrete payloads (field names to be confirmed against the running BBT during S2 by probing — see Risks; the code treats a `-32601`/shape mismatch as "fall through to local API"):

**Step A — itemKey → citekey** (BBT identifies items as `"<libraryID>:<itemKey>"`; user library id = 1):
```
POST /better-bibtex/json-rpc
{"jsonrpc":"2.0","method":"item.citationkey","params":[["1:ABCD1234"]],"id":1}
→ {"jsonrpc":"2.0","result":{"1:ABCD1234":"moore2001"},"id":1}
```

**Step B — citekey → CSL-JSON** (`item.export` with the CSL-JSON translator; translator accepted by display name or ID — pass the ID, fall back to name):
```
{"jsonrpc":"2.0","method":"item.export",
 "params":[["moore2001"], "Better CSL JSON"], "id":2}
→ {"jsonrpc":"2.0","result":"[{\"type\":\"document\",\"title\":\"Oral History\",\"author\":[{\"family\":\"Moore\",\"given\":\"Gordon E.\"}],\"issued\":{\"date-parts\":[[2001]]}}]","id":2}
```
`result` is the exporter's **string** output (a CSL-JSON array text); parse it, take element 0. (Translator IDs to try, most-specific first: Better CSL JSON `f4b52ab0-f878-4556-85a0-c7aeedd09dfc`, CSL JSON `bc03b4fe-436d-4a1f-ba59-de4d2d7d63f7` — verify in S2; if the ID errors, retry with the display name.)

**Step C — formatted citation** (user-chosen CSL style). Preferred BBT path: `item.export` with a CSL **style** translator id/name; if BBT does not expose bibliography formatting on this install, fall through to the local-API bib below.

**Local API fallback** (Zotero 7, robust for both CSL-JSON and a formatted citation in one call):
```
GET /api/users/0/items/ABCD1234?include=csljson,bib&style=chicago-note-bibliography&linkwrap=0
→ [{ "key":"ABCD1234", "csljson": {…CSL item…}, "bib": "<div class=\"csl-bib-body\">…</div>" }]
```
For groups: `/api/groups/<GID>/items/<KEY>`. The `bib` value is HTML → strip tags (a tiny `NSAttributedString(html:)`→`.string` or a regex tag-strip; prefer the former on `@MainActor`-free `Data`, but `NSAttributedString(html:)` must run on the main actor — so do a lightweight regex strip in the actor instead to stay off-main). CSL-JSON comes from `csljson`.

**CSL model + mapping** (NEW — same file):
```swift
struct ZoteroCSLItem: Codable, Sendable {
    var type: String?
    var title: String?
    var author: [CSLName]?
    var issued: CSLDate?
    var itemType: String?          // Zotero "attachment" detection (from local API / raw item)
    struct CSLName: Codable, Sendable { var family: String?; var given: String?; var literal: String? }
    struct CSLDate: Codable, Sendable {
        var dateParts: [[Int]]?    // CodingKeys: dateParts = "date-parts"
        var raw: String?
    }
}
```
Map to front-matter (used by auto-fill, D.5):
- `authors` = `author.map { $0.literal ?? [$0.given, $0.family].compactMap{$0}.joined(separator:" ") }`, dropping empties.
- `date`/`date_precision`: from `issued.dateParts[0]` length → `[y]`⇒`.year`, `[y,m]`⇒`.month`, `[y,m,d]`⇒`.day`; `date` = the SPEC-shaped value reused by W6/W7 (00-overview §7). If only `raw`, attempt a 4-digit-year regex → `.year`; else leave date untouched and flag in the confirmation sheet. CSL never yields a decade → never emit `.decade` from Zotero.
- `title`: `title` (only offered as a fill, never silently overwrites — D.5).
- Attachment detection: if `itemType == "attachment"` (BBT `item.attachments`/local API), set `ref.kind = .attachment` and resolve `parentKey`.

### D.5 UI (NEW SwiftUI, `Zotero/…View.swift`; needs W3)
`@MainActor final class ZoteroStatusModel: ObservableObject` bridges the actor to SwiftUI: `@Published var backend: ZoteroClient.Backend = .unavailable`, refreshed by a cancellable `Task` on a timer/onAppear. Never blocks; a stale/unavailable backend just disables the "auto-fill" affordance while leaving link-only attach fully available.

- **Paste Zotero link** — a menu command (`Note ▸ Attach Zotero Link…`) + a small toolbar/inspector button. It reads `NSPasteboard.general.string(forType: .string)`, runs `ZoteroSelectLink.parse`; if it yields a ref, attach at note level (or the focused block). If the clipboard is not a zotero link, show a text field to paste one.
- **Clipboard detection** — a lightweight banner/affordance ("Zotero link on clipboard — Attach") shown when `ZoteroSelectLink.parse(NSPasteboard.general.string…)` succeeds and that link isn't already attached. Poll the pasteboard `changeCount` only while the note editor is frontmost (no background polling).
- **Chips** — `ZoteroChipView` renders a ref as a pill (Zotero-blue, book/paperclip glyph for item/attachment, truncated `citation ?? itemKey`). Click → `NSWorkspace.shared.open(URL(string: ref.selectLink)!)` (opens Zotero and selects the item; works even when our metadata is stale). Chips appear (a) note-level in the inspector, from `frontMatter.zotero`; (b) per-block, from the block header's `zotero:` field (00-overview §6). A trailing spinner shows while a fetch Task for that ref is in flight; a small ⚠︎ if the last fetch failed (link still opens).
- **Auto-fill from Zotero** — an explicit action (button on the chip / `Note ▸ Auto-fill from Zotero`). Because it **overwrites** `authors`/`date`/`title`, it opens a **confirmation sheet** showing current vs fetched values with per-field checkboxes (default: fill empty fields, ask before replacing non-empty ones). On confirm, it writes via W2's note store (atomic front-matter save) and stamps `ref.citation`/`ref.fetchedAt`. Cancel writes nothing.

### D.6 Caching & persistence
- **In-memory** per-item caches in the actor (D.3) coalesce repeated fetches within a session.
- **Disk cache** (NEW — `Zotero/ZoteroCacheStore.swift`): a Codable dict persisted to `~/Library/Application Support/ArchiveNotes/zotero-cache-v1.json` (atomic write), keyed by `"<libToken>/<itemKey>"` → `{ csl: ZoteroCSLItem, citation: String?, styleID: String?, fetchedAt: Date }`. This mirrors `SavedSearchStore`'s `JSONEncoder/JSONDecoder` load/save (see Reuse) but file-backed (potentially large) rather than `UserDefaults`. Cache is a **disposable** accelerator; the authoritative survivor is `ZoteroRef.citation` in front-matter.
- **Front-matter is the durable home** (00-overview §5): the fetched `citation` and `fetchedAt` live in the note's `zotero:` array and the block header's `zotero:` field, so a citation formatted while Zotero was up remains readable after Zotero is uninstalled/closed. Nothing here is required to re-derive from Zotero on load.

### D.7 Concurrency / Swift 6 notes
- `ZoteroClient` is an `actor`; `ZoteroTransport`, `URLSession`, and all value types are `Sendable`. All network calls are `async` inside the actor, hence off the main actor.
- Cancellation: every UI-initiated fetch is a `Task` stored on the view/model and cancelled `onDisappear`/on re-issue; `URLSession` respects `Task.cancel()`.
- The only `@MainActor` types are the SwiftUI views + `ZoteroStatusModel`; they `await` actor methods. HTML→text stripping stays in the actor via regex (avoids main-actor-only `NSAttributedString(html:)`).
- No global mutable state; settings read at point of use (D.8).

### D.8 Settings (NEW keys)
Reuse the `AppSettings`/`SettingsKey` pattern (Reuse) for a Notes-side settings enum: `zoteroEnabled` (Bool, default true), `zoteroHost`/`zoteroPort` (advanced), `zoteroCSLStyleID` (String, default `"chicago-note-bibliography"`), `zoteroClipboardDetect` (Bool, default true). Read at point of use so the Options window needs no observation plumbing.

## Reuse from the existing codebase
- `ArchiveReader/macOS/Sources/ArchiveReader/Search/SavedSearch.swift:5-10` — copy the `Codable, Identifiable, Equatable, Sendable` struct shape for `ZoteroRef`.
- `SavedSearch.swift:71-79` — copy the `JSONDecoder().decode(...)` / `JSONEncoder().encode(...)` load/save idiom for `ZoteroCacheStore` (adapt from `UserDefaults` to an atomic file write, since the cache can be large).
- `SavedSearch.swift:13` — the `@MainActor final class …: ObservableObject` + `@Published private(set)` store shape for `ZoteroStatusModel`.
- `ArchiveReader/macOS/Sources/ArchiveReader/Core/AppSettings.swift:5-21,25-33` — copy the `enum SettingsKey` + `enum AppSettings` point-of-use `UserDefaults` accessor pattern for the Notes Zotero settings (D.8).
- `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndexer.swift` (per Reader CLAUDE.md Implementation Map) — reference for the app's **off-main-actor async** posture (detached work, actor-confined I/O, cancellable tasks); adapt the actor pattern for `ZoteroClient` (no line cite — consult before S2).
- W2's `NoteFrontMatter` reader/writer (00-overview §5/§6) — reuse its unknown-key-preserving round-trip; W5 only adds the typed `zotero:` array and never bypasses it. (Net-new in W2; do not re-implement here.)

## Bounded sub-tasks
Tier per 00-overview §12: **W5 is Tier-1** (pure network read + writes only via W2's already-audited store; no new irreplaceable-data surface). Every sub-task: own worktree, `xcodegen generate`, clean build with **no new warnings**, `./launch.sh notes` smoke where a GUI surface exists.

**S1 — Ref model + select-link parser + front-matter round-trip.**
Scope: `ZoteroRef.swift`, `ZoteroSelectLink.swift`; extend W2's front-matter encode/decode to carry the typed `zotero:` array.
Steps: implement value types (D.1) incl. `ZoteroLibrary` Codable; implement the total parser (D.2); wire encode/decode through W2's front-matter I/O; add unit tests.
Verify: `xcodebuild … test` green; new tests `ZoteroSelectLinkTests`, `ZoteroFrontMatterRoundTripTests` pass; no GUI. Done-criteria: parser handles all four link forms + rejects junk; a note with a `zotero:` block written then re-read is byte-stable including citation. Flips the W5-S1 checkbox in `SUITE_TODO.md` / this plan.

**S2 — `ZoteroClient` actor: probe + fetch + cache, with injected transport.**
Scope: `ZoteroClient.swift`, `ZoteroCacheStore.swift`, `ZoteroTransport`. No UI.
Steps: implement probe cascade (D.3), BBT two-step + local-API fallback + offline degrade (D.4), CSL model + mapping, in-memory + disk cache (D.6). Confirm exact BBT method/field shapes against a running Zotero *manually* during dev, but keep the code shape-tolerant (`-32601`/decode-miss ⇒ next backend).
Verify: unit tests with a **stub `ZoteroTransport`** feeding canned JSON-RPC / local-API bodies (`ZoteroClientTests`: probe-selects-BBT, probe-falls-to-localAPI, probe-unavailable, csl-mapping-year/month/day/literal-author, citation-fetch, timeout→unavailable, cancellation). No real network. Done-criteria: all backends + degrade paths covered; cache hit avoids a second transport call (assert call count). Flip W5-S2.

**S3 — CSL→front-matter mapping + auto-fill action with confirmation.**
Scope: mapping helpers + an `AutoFillPlan` value + the confirmation sheet's view-model (`@MainActor`); wire the store save via W2.
Steps: build `AutoFillPlan` (current vs fetched per field, default-fill-empty policy, D.5); on confirm, call W2 store save + stamp `citation`/`fetchedAt`; no-write on cancel.
Verify: unit tests `ZoteroAutoFillTests` (fill-empty, replace-with-confirm, date-precision from date-parts, no-op on cancel). GUI: `./launch.sh notes`, attach a link to a test note, run auto-fill, confirm front-matter updates (inspect the scratch `.md`). Done-criteria: overwrites only confirmed fields; writes go only to the scratch store. Flip W5-S3.

**S4 — UI: chips (note + block), paste affordance, clipboard detection, open link.**
Scope: `ZoteroChipView.swift`, `ZoteroStatusModel.swift`, inspector + block-chip integration (needs W3), the paste command/menu, clipboard banner.
Steps: render chips from `frontMatter.zotero` and block `zotero:` headers; click→`NSWorkspace.open`; `Attach Zotero Link…` command; clipboard-detect banner (frontmost-only); spinner/⚠︎ states.
Verify: build + `./launch.sh notes`; drive with cliclick/XCUITest — copy a `zotero://select/library/items/ABCD1234`, see the banner, attach, chip appears, click opens Zotero (or no-ops harmlessly if Zotero absent — assert UI never blocks). Add `ZoteroClipboardDetectTests` for the pure parse-clipboard logic. Done-criteria: chips clickable at note + block level; paste/attach works; UI responsive with Zotero down. Flip W5-S4.

**S5 — Settings, degrade-gracefully polish, integration.**
Scope: `AppSettings` Zotero keys + Options UI row; end-to-end wiring; TTL/backoff on repeated probes.
Steps: add settings (D.8); ensure a closed Zotero never re-probes faster than the TTL; ensure a fetch failure leaves `citation` intact; verify group-library links resolve via `/groups/<gid>`.
Verify: build; `./launch.sh notes` full flow with Zotero **running** (auto-fill + citation) and **quit** (link-only, chip still opens, no hang). `ZoteroSettingsTests`. Done-criteria: all §D8 acceptance behaviors met; W5 fully checked in `SUITE_TODO.md`; delete this plan only when the whole wave ships (00-overview §14).

## Tests
Unit (with stub transport / canned fixtures — never real Zotero or network):
- `ZoteroSelectLinkTests` — the four link forms, canonicalization, junk rejection, url-encoded keys, trailing slash, `open-pdf`→nil.
- `ZoteroFrontMatterRoundTripTests` — `zotero:` array + citation survive write→read; unknown keys preserved (§6).
- `ZoteroClientTests` — probe selects BBT / falls to local API / unavailable; `-32601`→fallback; CSL date-parts→precision; literal vs given/family author; citation fetch (BBT + local-API bib strip); timeout→unavailable; cancellation; cache-hit avoids second transport call.
- `ZoteroAutoFillTests` — fill-empty, replace-with-confirm, no-write-on-cancel, date precision.
- `ZoteroClipboardDetectTests`, `ZoteroSettingsTests`.
GUI/behavioral (`./launch.sh notes` + cliclick/XCUITest): paste→banner→attach→chip; chip click opens Zotero; auto-fill confirmation writes the scratch note; **Zotero-quit** path stays responsive and link-only.

## Risks & file-safety
- **No corpus writes, ever.** W5 only reads over localhost and writes Notes' *own* front-matter through W2's atomic store (Tier-2-audited there); it adds no move/rename/delete/content-write and does **not** route through `NotesTagProjector` (Zotero refs are never Finder tags). All dev/test note writes target scratch copies (`mktemp`), per 00-overview §12 / Reader Prime Directive.
- **BBT API shape drift.** The exact JSON-RPC method names/params/translator IDs vary across Better BibTeX versions. Mitigation: the code is shape-tolerant (any well-formed JSON-RPC reply proves BBT presence; `-32601`/decode failure falls through to the Zotero 7 local API; both failing ⇒ link-only). S2 confirms live shapes against a running Zotero but never hard-codes a single assumption.
- **UI blocking / hangs.** Mitigation: actor-confined async, short `URLSession` timeout, TTL-cached availability (no per-keystroke probing), cancellable tasks, and a UI that is fully usable (attach + open link) with Zotero down.
- **Privacy/entitlement.** Localhost only (`127.0.0.1:23119`); `com.apple.security.network.client` already granted in W1. No outbound internet, no telemetry.
- **Citation loss.** Because `citation`/`fetchedAt` live in front-matter, a later-unavailable Zotero cannot erase an already-fetched citation; the disk cache is disposable.

## Open questions
1. Whether to support `zotero://open-pdf/…` / page-anchored attachment links (jump into a Zotero PDF at a page) — deferred; parser returns nil for now.
2. Auto-refresh of a stored citation when the CSL style setting changes app-wide (re-fetch on demand vs. lazy on next open) — lazy for run 1.
3. Group-library `libraryID` resolution for the BBT `"<libID>:<key>"` step when only a group select link is known (may require `user.groups`) — the local-API path sidesteps this; revisit if BBT-only installs need it.
4. Zotero write-back (creating items from Notes) — explicitly out of scope (00-overview §15.5).
