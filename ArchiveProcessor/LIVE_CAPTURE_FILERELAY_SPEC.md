# Live Capture FileRelay — Implementation Spec (design complete, adversarially reviewed)

**Created 2026-07-06.** Buildable spec for step 2 of the Google Drive cloud relay: `FileRelayTransport`
(phones) + `FileRelayReceiver` + a `CaptureReceiver` abstraction (Mac) + an offline Swift invariant test +
a cross-platform golden — a local-shared-directory relay that proves the cloud-transport CONTRACT offline,
so the Drive backend later swaps only the storage layer. Strategy: `LIVE_CAPTURE_CLOUD_TRANSPORT_PLAN.md`.

**Provenance:** produced by a multi-agent design workflow (run `wf_d079ce85-b44`) — 3 agents grounded the
actual Mac/iOS/Android code, 5 independent design lenses, then 3 adversarial critics stress-tested the
synthesis. **11 holes were found (2 data-loss-critical).** The automatic final-fold agent died on a network
error, so the **v2 amendments below were authored directly and BIND OVER the v1 base** where they conflict.

**Read order: the v2 amendments first (they override), then the v1 base spec.**

---

# FileRelay spec — v2 amendments (adversarial holes folded)

The v1 spec below was stress-tested by 3 adversarial critics; 11 holes surfaced. `synth:final` (which was to
fold them) died on a network error, so these binding amendments are authored directly. **Each amendment
OVERRIDES the v1 body where they conflict.** Severity from the critique in brackets.

## A1 — Receipt carries a metadata fingerprint `fp`; `validReceipt` matches it [H3, CRITICAL]
Resolves the D4/D5/D8 contradiction. The photo sidecar gains `fp` = a stable hash (e.g. SHA-256 hex, first 16
chars) over the **ingest-relevant metadata** `{type, priority, year, month, replaces}` (NOT device/seq/group,
which don't change OCR/tag output). The **receipt echoes `fp`** (`{"epoch","fp","group","kind":"receipt",
"received":"true","seq","token"}`). `validReceipt` returns true **only if** the receipt exists, parses, and
`kind==receipt && token && epoch && group && seq && fp == fingerprint(currentMeta)`. Effect: `postPhoto` step
(a) receipt-first short-circuits **only** when the receipt acks the *current* metadata; a post-upload P10
toggle (new `fp`) falls through to step (b), rewrites the sidecar, and waits for a receipt carrying the new
`fp`. The Mac's processed-set `Entry.fp` and the receipt `fp` are the **same** fingerprint — re-ingest fires
iff `fp` differs (identical re-send skipped; real metadata change re-ingested). D4's "no rev on the FileRelay"
is amended: the FileRelay uses this fingerprint on **both** sides now; the Drive backend may upgrade to a
monotone `rev` only if coexisting objects ever demand it.

## A2 — Epoch is PUBLISHED-AND-ADOPTED, not pairing-fixed [H6, CRITICAL]
Fixes the silent post-restart stall. The Mac writes `<relayRoot>/<token>/_epoch.json` =
`{"epoch": <sessionId>, "token": <token>}` (atomic temp→rename) in `FileRelayReceiver.start()`. The phone, at
the top of every `postPhoto`/control write, **reads `_epoch.json` and adopts its `epoch`** for all objects it
writes and all receipts it trusts this cycle. If `_epoch.json` is absent (Mac relay not started yet),
`postPhoto` returns `false` immediately (→ safe auto-retry) rather than writing an un-ackable object. A prior
run's stale receipt carries a different epoch than the currently-published one, so it is never trusted
(preserves D10's protection). The Mac still ignores/sweeps mismatched-epoch objects (from older runs). After a
Mac restart with a fresh `sessionId`, the phone reads the new `_epoch.json`, adopts it, and re-enqueue/retry
rewrites pending objects under the new epoch → uploads resume automatically, no re-pair. Phone local copies are
retained until a matching-epoch receipt, so nothing is lost across the epoch change. (Offline test: writer +
receiver share a fixed epoch via the published marker.)

## A3 — `replaces` carries the FULL reclassify chain, not just the last group [H4, HIGH]
Because relay objects persist until the Mac drains them, a chained reclassify G→H→I can leave G's object with
nothing pointing at it. Add `replacedGroups: [String]` to `CapturedItem` (Codable-safe append; the existing
scalar `replacesGroupId` stays for the **HTTP** `X-Replaces` path, which is behavior-identical and can't strand
intermediates). On every reclassify, **append the current group id to `replacedGroups`** before changing
`groupId`. The relay sidecar's `replaces` = `replacedGroups` comma-joined (e.g. `"g0,gH"`). The Mac tombstones
**every** listed `(group, seq)` after ingesting the new object (global seq is unique per page, §12, so this is
safe). HTTP `X-Replaces` remains the single immediate-prior group (unchanged wire behavior).

## A4 — Tombstones are durability-critical, not optimization state [H5, HIGH]
Amends the v1 §7 claim. Gate the tombstone-branch **delete** on a **confirmed `persistProcessed()` success**
(mirroring how `ingest` gates on `writeManifest`, `CaptureSession.swift:215`): tombstone → persist → only then
delete the superseded object. **Never** epoch-discard or `prune` a processed-set entry while any relay object
for that `(group, seq)` may still exist on disk. Defense-in-depth with A3: even if a tombstone is lost, the
phone retries the page (until a receipt) re-carrying the full `replacedGroups` chain, so the Mac re-tombstones
every prior group. v1 §7 is corrected: **safety-critical state = {phone copy, atomic renames, Mac manifest,
persisted tombstones}**; only plain (non-tombstone) processed entries and the receipt are re-derivable.

## A5 — `seqs` is snapshotted at End-segment and persisted; never recomputed from live `items` [H2, HIGH]
`applyTagsAndContinue` prunes uploaded pages from `items`, so recomputing `seqs` at the deferred flush yields a
subset on whichever platform does so — reopening straggler-omission asymmetrically. Both companions capture
`seqs = {all page seqs of the group}` **at End-segment**, store it in the persisted pending-segment-complete
record, and the deferred flush writes that stored snapshot verbatim. Forbid recomputation from live `items`.
Add a cross-platform test: a still-PENDING page in the segment ⇒ the Mac DEFERs on **both** platforms.

## A6 — Mac reader coerces number-or-string; string-typedness enforced by a byte check [H7, MEDIUM]
`org.json`'s `put("seq", 7)` emits a bare number; a strict Swift `[String:String]` decode throws → that page is
skipped every scan → permanent silent stall for one platform. The Mac reader parses via `JSONSerialization` to
`[String:Any]` and **stringifies each value** (number-or-string tolerated). Separately, string-typedness is a
**writer** contract enforced by the golden's byte assertion (A7), not by the reader.

## A7 — Golden adds BYTE-equality against committed golden byte files (+ nasty device fixture) [H8, MEDIUM]
Map-equality can't see escaping/hex-case/UTF-8 divergence — the very thing `canonicalJSON` exists to prevent.
Keep the map-equality (lenient-read contract) AND add: each platform's `canonicalJSON(map)` must equal the
committed golden **byte** files for sidecar/segment/session/receipt. Include a fixture whose `device` contains a
non-ASCII char (U+2019), an astral emoji (surrogate pair), and a C0 control (U+0001) — so Swift-over-scalars vs
Kotlin-over-UTF-16 escaping divergence is actually caught. Assert values are raw JSON **string tokens** via a
byte/regex check (NOT `org.json.getString`, which coerces numbers), run against all three writers.

## A8 — Same-language round-trip tests (transport ⇄ receiver), not just format-module goldens [H1, HIGH]
Add: (iOS XCTest) run the **real** `FileRelayTransport.postPhoto`/`segmentComplete` into a temp dir + a **real**
`FileRelayReceiver.scanOnce()` on the same dir; assert `postPhoto` blocks and returns `true` **only after**
`scanOnce` writes a matching-`(epoch,fp)` receipt, and that `scanOnce` ingested the transport-written bytes;
assert `false` on timeout when the receipt's epoch/fp mismatches. (Android JVM) run the real
`FileRelayTransport` writer, byte-compare its output to the golden, and have Kotlin `validReceipt` parse the
Mac's committed golden receipt. The Mac driver already round-trips writer→receiver.

## A9 — Orphan sweep: age-gate the jpeg-orphan clause; symmetric for media-less sidecars [H9, MEDIUM]
The jpeg-then-sidecar write has a sub-second window where the `.jpg` exists without its sidecar; an ungated
"delete sidecar-less .jpg" clause races it. Only delete a sidecar-less `.jpg` **older than `sweepRetention`**
(trivially covers the write gap), and symmetrically reclaim a media-less sidecar after the same grace.

## A10 — Filename/body identity cross-check [H11, LOW]
`scanOnce` validation parses the filename's leading `<group>__<seq>` and **quarantines** the object if it does
not exactly equal the sidecar body's `(group, seq)`. Body stays authoritative; closes the divergence with one
comparison.

## A11 — Reclassify-after-finalize duplicate: DOCUMENTED RESIDUAL, not fixed this milestone [H10, MEDIUM]
`removePhotoIfSafe` no-ops when the old group `isFinalized` (`CaptureSession.swift:231`); relay lag makes the
"reclassify a page whose original group already finalized" path reachable → the photo can appear in both the
finalized document output AND the new marker. This is a relay-amplified version of a latent HTTP edge, and the
real fix (remove the page from the finalized group's staged output + renumber, or refuse + signal the phone)
touches the Tier-2 finalize/staging path and needs a phone-signal channel. **Deferred to the Drive milestone;
tracked in `KNOWN_ISSUES.md`.** For the FileRelay milestone the Mac logs the collision and does not expand the
no-op (no *new* silent duplication beyond today's behavior).

## Open-question resolutions
- **iOS XCTest target:** add a unit-test target to `ArchiveCaptureiOS/project.yml` (needed for A8 + the golden);
  run `xcodegen generate`, and the harness gains an `xcodebuild test -sdk iphonesimulator` invocation.
- **Golden location:** commit `SPEC/relay-golden/` **inside the Archive Processor repo** (all three platforms
  are subdirs of this one git repo, so a repo-relative path reaches them and stays version-controlled with the
  code). The Suite-root `SPEC/` (CLAUDE.md `../SPEC`) is a separate concern; note the eventual reconciliation.
- **Receipt cleanup:** the Mac orphan sweep deletes receipts older than `sweepRetention` whose `(group,seq)` ∈
  processed — bounded, no unbounded accumulation.
- **Hermetic testing:** simulating Mac-restart by rebuilding `FileRelayReceiver` (reloads `relay-processed.json`)
  is sufficient for the receiver's dedup/tombstone logic; no `backupRoot` injection needed for these cases.
- **`seqs` shared-hotspot churn:** accepted — additive `seqs` (default empty → HTTP identical), defense-in-depth
  atop the phone-side defer.

---

# ── v1 BASE SPEC (synthesis, pre-critique — amendments above override) ──

# FileRelay implementation spec (synth v1 from design workflow)


# Implementation Spec — FileRelayTransport + FileRelayReceiver + CaptureReceiver abstraction + offline test + golden cross-check

Repo root (absolute): `/Users/<user>/Desktop/Claude/Archive Processor`

This is a **design-only** spec (no code edits). It synthesizes the five design lenses into one non-contradictory
plan for the **local-shared-directory relay** that proves the cloud-transport contract offline. The Drive backend
later swaps only the storage layer behind the same seams. Two hard constraints govern every decision:
**(1) never lose a photo** — the phone deletes its only local copy of a page ONLY after the Mac holds it durably;
**(2) `CaptureServer` / HTTP behavior stays byte-for-byte identical.**

---

## 0. The one rule everything derives from

`FileRelayTransport.postPhoto` returns `true` **iff and only after** the phone reads a valid **receipt object**
that the Mac wrote, and the Mac writes that receipt **only after** `CaptureSession.ingest(...)` returned non-nil.
`ingest` returns non-nil only when BOTH the JPEG temp→rename AND `writeManifest()` succeeded
(`Capture/CaptureSession.swift:184-189` + `guard writeManifest() else { return nil }` at `:215`). Therefore a receipt
existing is a phone-observable proxy for "the Mac durably holds this page." Writing the relay object successfully
is **not** a `true`.

---

## 1. Conflict resolutions (decisions + why)

The lenses diverge on several concrete points. These are the binding decisions:

| # | Conflict | Decision | Why |
|---|---|---|---|
| D1 | Sidecar name: `<group>__<seq>.json` (4 lenses) vs `<group>__<seq>.jpg.json` (idempotency lens) | **`<group>__<seq>.json`** | Majority; `.` is not in the group charset (`isSafeGroupId`, `Net/CaptureServer.swift:283-286`), so `.` as kind-delimiter classifies every filename unambiguously without body reads. |
| D2 | Metadata values: JSON strings (on-disk-format lens) vs JSON numbers (streaming lens) | **All values are JSON strings**; nil fields OMITTED (never `null`/`""`) | Drive `appProperties` is a string→string map, so all-strings maps 1:1 with zero transform; the HTTP receiver already parses Int from string headers (`Int($0)` at `CaptureServer.swift:224-225`); all-strings makes byte-for-byte cross-platform canonical serialization tractable. Golden asserts string types. |
| D3 | Commit-marker ordering | **JPEG first (temp→rename), sidecar second (temp→rename) = commit marker. Delete sidecar first, JPEG second.** | 4 lenses; receiver enumerates by sidecar (the identity source) so a visible sidecar guarantees a complete JPEG; deleting the sidecar first un-commits the object from the watcher's view (symmetry). Mirrors Drive committing `appProperties` at resumable-upload finalize. |
| D4 | Metadata-change dedup: monotone `rev`/`uploadRev` (idempotency lens) vs nothing | **Mac-side metadata FINGERPRINT in the processed-set for the FileRelay; NO `rev` in the protocol now.** Document that the Drive backend upgrades this to a monotone `rev`. | The idempotency lens rejected the fingerprint only because two objects can coexist on Drive (fileId loss) and be processed newest-then-oldest. On the FileRelay the object name is deterministic and overwrite is in-place, so **two objects for one `(group,seq)` can never coexist** → the order hazard cannot occur → the fingerprint is correct here and needs zero phone/protocol churn. Adding `rev` to the `SegmentTransport` signature is deferred to when Drive introduces coexisting objects. |
| D5 | Swallowed P10-toggle / reclassify while `UPLOADING` | **Add phone-side `needsResend: Bool` + drain it in the enqueue completion handler.** No `rev` needed. | The receipt-wait makes `postPhoto` block up to 20 s, widening the window where the `inFlightUploads` guard swallows a mutation — so this residual (KNOWN_ISSUES, plan §13) becomes materially worse with the relay. `needsResend` re-enqueues the current metadata after the in-flight upload finishes; the Mac fingerprint (D4) then re-ingests and the new priority lands. |
| D6 | Partial-segment finalization guard | **Add optional `seqs` (comma-joined string) to the segment-complete object; Mac applies `markSegmentComplete` only when every listed seq is processed, else defers. Fallback when `seqs` absent: apply only when NO unprocessed photo object for the group remains.** Phone also defers writing segment-complete until all its pages are `UPLOADED`. | The fallback trusts the phone; `seqs` gives the Mac an **independent** backstop that detects a page still on the phone (not yet in the folder) — the exact case the fallback cannot see. Additive protocol param (default empty → backward-compatible). |
| D7 | Watch strategy: FSEvents/DispatchSource vs poll timer | **Poll timer (1 s file / 2–4 s Drive), single-flight.** | Only a poll generalizes to Drive (`changes.list` polling; webhooks need a public endpoint the NAT'd Mac lacks). FSEvents/kqueue do not fire on network/remote volumes (the shared dir may be a mount) → a correctness trap. Poll is deterministic + trivially CI-testable. |
| D8 | Receipt object: optional (`appProperties.received` and/or file) per plan §4 | **Standalone `<group>__<seq>.receipt.json` is REQUIRED, with NO timestamp field.** | The phone must observe the receipt **after** the Mac deletes the photo object, so a receipt living on the (deleted) photo cannot work with delete-after-receipt ordering. No timestamp → a Mac-restart re-write is byte-identical = a true no-op (no spurious watcher churn); orphan-sweep age uses filesystem mtime. |
| D9 | Session-complete / receipt file extensions | **`_session.complete.json` and `<group>__<seq>.receipt.json`** (deviates from plan's `_session.complete` / `<group>__<seq>.receipt`) | Uniform JSON bodies + uniform `.json` extension keeps classification a pure suffix test. Deviation flagged in §11 for the plan text. |
| D10 | Cross-run receipt collision (never-lose lens's highest-severity item) | **Per-run `epoch` nonce (the Mac's `sessionId`, `CaptureSession.swift:132`) in the pairing config + every sidecar + every receipt. Phone trusts a receipt only if `epoch` matches; Mac ignores/sweeps mismatched-epoch objects; the processed-set is epoch-scoped.** | `sessionToken` is stable across launches (`CaptureSession.swift:79-86`) so the token folder is reused; a stale prior-run receipt for the same `(group,seq)` could false-positive `postPhoto` and delete a page the Mac does not hold this run. Epoch defeats this. On crash-recovery the Mac reuses the recovered `sessionId` so in-flight objects stay valid; on a fresh run the epoch differs so stale objects are correctly ignored. Phone local copies are retained (never deleted without a matching-epoch receipt), so a re-pair (new epoch) safely re-uploads — no loss. Offline test uses a fixed epoch. |

---

## 2. On-disk object format (single source of truth: `SPEC/relay-object-format.md`)

Session folder (the Mac creates it on relay start): `<relayRoot>/<sessionToken>/`.
`sessionToken` = the existing stable 6-char `CaptureSession.token`. All objects written **temp→rename**
(`.<name>.<uniq>.part` → `<name>`), atomic on one filesystem — mirroring `ingest` (`CaptureSession.swift:185-189`)
and the phone `SessionStore` atomic writes.

**Object kinds** (`.` never appears in a group id, so suffix classification is unambiguous):

| Object | Filename | Written by | Kind |
|---|---|---|---|
| Photo media | `<group>__<seq>.jpg` | phone | — (paired with its sidecar) |
| Photo sidecar (commit marker) | `<group>__<seq>.json` | phone | `photo` |
| Segment-complete | `<group>.segment.json` | phone | `segment-complete` |
| Session-complete | `_session.complete.json` | phone | `session-complete` |
| Receipt | `<group>__<seq>.receipt.json` | **Mac** | `receipt` |
| In-progress temp | `.<name>.<uniq>.part` | both | (ignored by readers) |

**Canonical JSON, all-string values, keys pre-sorted, nil-omitted:**

- Photo sidecar `<group>__<seq>.json`:
  `{"device":?,"epoch","group","kind":"photo","month":?,"priority":?,"replaces":?,"seq","token","type","year":?}`
  Fields are 1:1 with the HTTP `X-*` headers (`CaptureServer.swift:220-230`): `type` ∈ `document|box|folder`
  (`CaptureGroupType` rawValues), `seq/year/month` are stringified ints, `replaces` = the reclassify old group.
- Segment-complete `<group>.segment.json`:
  `{"epoch","group","kind":"segment-complete","month":?,"priority":?,"seqs":?,"token","year":?}`
  `seqs` (optional) = comma-joined seqs of the segment, e.g. `"0,1,7"`.
- Session-complete `_session.complete.json`: `{"epoch","kind":"session-complete","token"}`
- Receipt `<group>__<seq>.receipt.json`: `{"epoch","group","kind":"receipt","received":"true","seq","token"}`
  (no timestamp — see D8).

**`canonicalJSON(map: [String:String]) -> [UInt8]`** — a ~15-line shared function on each platform (do NOT trust
built-in encoders: Swift `JSONEncoder` escapes `/`→`\/` unless `.withoutEscapingSlashes`, `org.json` escapes `/`
only in `</`, and neither guarantees identical key sort + control-char casing):
1. Drop nil-valued entries. 2. Sort keys ascending (keys are fixed lowercase ASCII → Swift/Kotlin sorts agree with
byte order). 3. Emit `{"k":"v",...}` — no spaces, no newline, UTF-8, no BOM. 4. Escape by **string replacement**
(build the String, encode to UTF-8 **once** at the end so astral/emoji device names stay identical 4-byte
sequences): `"`→`\"`, `\`→`\\`, U+0008→`\b`, U+0009→`\t`, U+000A→`\n`, U+000C→`\f`, U+000D→`\r`, other C0→`\u00xx`
(lowercase hex); everything else (incl. `/` and non-ASCII) verbatim.
**Reading is lenient** (parse to `[String:String]`); parse is order-independent. On Drive the map becomes
`appProperties` and byte-order is a non-issue, so `canonicalJSON` is FileRelay/CI-internal.

**Classification (suffix test, in order; skip dotfiles + `*.part`):** exact `_session.complete.json` →
session-complete; `*.receipt.json` → receipt (Mac ignores its own); `*.segment.json` → segment-complete; `*.jpg`
→ media; remaining `*.json` → photo sidecar. Identity `(group,seq)` is read **authoritatively from the sidecar
body**, never parsed from the filename (`<group>__<seq>` is ambiguous because `isSafeGroupId` permits `_`).

---

## 3. `CaptureReceiver` abstraction (Mac) — zero HTTP behavior change

New `Net/CaptureReceiver.swift`:
```
protocol CaptureReceiver: AnyObject, Sendable { func start(); func stop() }
enum CaptureTransport: String { case lan, fileRelay, cloud }   // cloud unbuilt
```
`CaptureServer` already has `start()`/`stop()` with these signatures and is `@unchecked Sendable`
(`Net/CaptureServer.swift:17,32`). Conformance is a **one-token class-line edit**
(`final class CaptureServer: @unchecked Sendable, CaptureReceiver {`) — no routing/parsing/auth/ack change.

**Extract the traversal guard** to a shared `Net/CaptureValidation.swift`
(`enum CaptureValidation { static func isSafeGroupId(_:) -> Bool }`) with the predicate copied **char-for-char**
from `CaptureServer.swift:283-286`. Replace the 3 private call sites in `CaptureServer` (`:215`, `:229`, `:246`)
with `CaptureValidation.isSafeGroupId`, delete the private method. Behavior-preserving; both receivers now share
one validator (no drift). This is load-bearing: `ingest` interpolates `groupId` straight into a path component
(`CaptureSession.swift:183`) with no validation of its own.

---

## 4. Session wiring (`Capture/CaptureSession.swift`)

Sibling receiver at `:112`, transport-gated lifecycle, portless status — the HTTP `serverRunning`/`serverDidStart`
path is untouched:
```
private lazy var server = CaptureServer(session: self)
private lazy var fileRelay = FileRelayReceiver(session: self, relayRoot: Self.relayRoot(for: token),
                                               epoch: sessionId)
private var transport: CaptureTransport { .init(rawValue: UserDefaults.standard.string(forKey:
    DefaultsKeys.liveTransport) ?? "") ?? .lan }   // env override for CI: LIVECAPTURE_TRANSPORT

func start() {
    switch transport {
    case .lan:               guard !serverRunning else { return }; server.start()   // BYTE-IDENTICAL to today
    case .fileRelay, .cloud: fileRelay.start()                                       // own idempotency guard
    }
}
func stop() { server.stop(); fileRelay.stop() }   // both idempotent no-ops if never started
```
- `Self.relayRoot(for:)` reads a new `DefaultsKeys.liveRelayDir` (env `LIVECAPTURE_RELAYDIR` for CI) and appends
  the token namespace.
- **Portless readiness** (added alongside the untouched `serverDidStart(port:)`/`serverDidStop()`/`serverDidFail`
  at `:150/:165/:171`, because `serverDidStart` is portful — sets `listenPort`, writes a port-bearing READY line,
  asserts `USBBridge.startReverse` at `:151-162` — none of which a directory watcher has):
  `@Published private(set) var relayRunning = false`; `relayReceiverDidStart(status:)` sets
  `relayRunning=true`+`statusMessage` and, under `LIVECAPTURE_AUTOSTART=1`, writes a portless
  `LIVECAPTURE_READY transport=fileRelay token=… relayDir=… folder=…` line to `LIVECAPTURE_READYFILE`/stderr;
  `relayReceiverDidStop()`/`relayReceiverDidFail(_:)` clear it.
- Transport-agnostic gate seam for the Settings/UX lens (not built here):
  `var receiverActive: Bool { serverRunning || relayRunning }`.
- **Gotcha honored:** the relay start must NOT be swallowed by `guard !serverRunning` at `:141` (that flag is
  set only by the HTTP `serverDidStart`). The switch above keeps the LAN guard exactly where it is and gives the
  relay its own flag — otherwise no receipts are ever written and every `postPhoto` times out (data-safe but a
  total functional stall).

---

## 5. `FileRelayReceiver` (Mac) — `Net/FileRelayReceiver.swift`

```
final class FileRelayReceiver: @unchecked Sendable, CaptureReceiver {
    private weak var session: CaptureSession?          // @MainActor, reached only via a hop (like CaptureServer)
    private let token: String; private let epoch: String
    private let store: RelayObjectStore                // backend seam
    private let processedURL: URL                      // = session.incomingFolder/"relay-processed.json"
    private let queue = DispatchQueue(label: "capture.filerelay")   // serial; all mutable state confined here
    private var timer: DispatchSourceTimer?
    private var processed: [GroupSeq: Entry] = [:]     // in-memory; persisted to processedURL
    private var draining = false                       // single-flight guard
    // test injection points, production defaults:
    var deleteSourceAfterReceipt = true
    var persistProcessedSet = true
}
struct GroupSeq: Hashable, Codable { let group: String; let seq: Int }
struct Entry: Codable { var fp: String; var tombstoned: Bool }   // fp = ingest-metadata fingerprint (D4)
```
`store` conforms to a backend seam so the Drive backend reuses this loop verbatim:
```
protocol RelayObjectStore: Sendable {
    func ensureSessionFolder() throws
    func listReady() throws -> [RelayObject]     // photo ready only if BOTH .jpg and sidecar exist
    func readPhotoBytes(_ handle: String) throws -> Data
    func writeReceipt(_ r: RelayReceipt) throws  // atomic temp→rename
    func delete(_ handle: String) throws         // sidecar FIRST, then .jpg (D3)
    func quarantine(_ handle: String) throws     // move to <sessionDir>/.rejected/
}
```
`LocalDirectoryStore` implements it over `<relayRoot>/<token>/`; `DriveObjectStore` later implements it over
`changes.list`/`files.get`/`files.delete`/`appProperties`.

**`start(pollInterval:)`** (default 1 s file / 2–4 s Drive): on `queue` — `store.ensureSessionFolder()`,
`loadProcessed()` (empty if the persisted file's `token`/`epoch` ≠ current), `session.relayReceiverDidStart(...)`,
then a `DispatchSourceTimer` that runs a single-flight `scanOnce()`.

**`@discardableResult func scanOnce() async -> ScanReport`** — the deterministic test unit; mirrors
`CaptureServer.process` (`:192`) and the ingest-then-ack block (`:232-240`). **Photos before controls** each pass:

```
PHOTOS (glob sidecars, ready = sidecar + paired .jpg both present):
  meta = parse(sidecar); if invalid → skip (leave, log once)
  guard CaptureValidation.isSafeGroupId(meta.group), meta.seq >= 0, meta.token == token, meta.epoch == epoch,
        (meta.replaces == nil || isSafeGroupId(meta.replaces))  else → store.quarantine(handle); record rejected
  key = GroupSeq(meta.group, meta.seq); fp = fingerprint(meta)   // fp over {type,priority,year,month}
  if let e = processed[key], e.tombstoned → store.delete(handle); continue           // reclassified-away
  if let e = processed[key], e.fp == fp → ensureReceipt(key); store.delete(handle); continue  // durable, unchanged → NO re-ingest/re-OCR
  data = store.readPhotoBytes(handle); if empty/unreadable → skip (phone still holds copy)
  url = await MainActor.run { session?.ingest(jpeg:data, groupId:meta.group, seq:meta.seq,
             type: CaptureGroupType(rawValue: meta.type) ?? .document,
             priority:meta.priority, year:Int(meta.year), month:Int(meta.month), deviceName:meta.device) }
  if url == nil → record ingestFailedLeftForRetry; DO NOTHING (no receipt, no delete, no processed entry)  // invariant hinge
  else:
     processed[key] = Entry(fp: fp, tombstoned: false); if persistProcessedSet { persistProcessed() }   // PERSIST BEFORE delete
     store.writeReceipt(key, epoch)                                                                       // == HTTP "respond 200"
     if let r = meta.replaces, r != meta.group {
        await MainActor.run { session?.removePhotoIfSafe(groupId: r, seq: meta.seq) }                     // mirror CaptureServer :235-237
        processed[GroupSeq(r, meta.seq)] = Entry(fp:"", tombstoned:true); persistProcessed()              // tombstone (idempotency lens §7)
     }
     if deleteSourceAfterReceipt { store.delete(handle) }                                                 // sidecar then .jpg

CONTROLS (after photos):
  segment-complete: validate group/token/epoch; if seqs present and any seq ∉ processed → DEFER (leave);
     else if seqs absent and any unprocessed photo object for group remains → DEFER;
     else await MainActor.run { session?.markSegmentComplete(groupId:, priority:, year:, month:) } (:307); delete.
  session-complete: apply only when no unprocessed photos AND no un-applied segment-completes remain;
     await MainActor.run { session?.completeAllOpenDocGroups(); session?.statusMessage = "Phone finished…" } (:321,
     mirrors CaptureServer.swift:262-263); delete.
```

**Durable ordering:** persist-set → receipt → delete (sidecar, then .jpg). Byte read is on `queue` (off-main),
so a multi-MB read never hitches the live-OCR main actor; only `ingest`/`removePhotoIfSafe`/`markSegmentComplete`/
`completeAllOpenDocGroups` cross to `@MainActor`.

**Processed-set store** `relay-processed.json` in the Mac's **private `incomingFolder`** (`CaptureSession.swift:92`),
NOT the shared dir (keeps the ledger out of the phone's trust domain) and NOT the staging manifest (which is
segment-granular + `.live`-only — ground-map GAP). Shape:
`{ "version":1, "token", "epoch", "entries":[{"group","seq","fp","tombstoned"}] }`. Atomic temp→rename (like
`writeManifest`, `:388`). Self-cleans: a finalized session's folder loses its `.jpg` via `clearFiled` (`:252`) and
is pruned by `pruneEmptySessions` (`:441-450`) on the next launch, taking the stale processed file with it.

**Orphan sweep** (bounded background pass): delete a `.jpg` lacking a sidecar; delete session objects whose
`(group,seq)` ∈ processed and are older than `sweepRetention`. `sweepRetention = 10 min` — see the coupling
invariant in §7.

---

## 6. `FileRelayTransport` (phones) — the receipt-wait folds inside `postPhoto`

Signature UNCHANGED for `postPhoto` (the queue is transport-agnostic; `enqueueUpload` already equates
`postPhoto==true` with "durably received", iOS `SegmentTransport.swift:12-14` / Android `SegmentTransport.kt:13-15`).
- **iOS** `Net/FileRelayTransport.swift`: a `nonisolated`, `Sendable` struct `{ sharedDir: URL; token: String;
  epoch: String }` — like `MacClient`, so `await c.postPhoto` hops off `@MainActor`. Poll via `try? await
  Task.sleep`.
- **Android** `net/FileRelayTransport.kt`: implements the plain blocking `SegmentTransport`; called inside the
  existing `withContext(Dispatchers.IO)` (`CaptureViewModel.kt:396-403`), so `Thread.sleep` polling is idiomatic.
  On device it MUST write via SAF/`ContentResolver` (scoped storage; app-private `filesDir` is not a shared dir)
  and use sidecar-last as the completeness marker (no guaranteed atomic rename on SAF). For the offline/CI fixture
  both sides share a real filesystem (JVM), where rename is atomic.

**Algorithm (both platforms):**
```
dir = sharedDir/token; base = "<group>__<seq>"
rcpt = dir/(base + ".receipt.json"); obj = dir/(base + ".jpg"); side = dir/(base + ".json")

(a) if validReceipt(rcpt, token, epoch, group, seq) { return true }   // receipt-first: confirms a page the Mac
                                                                       // ingested during an offline/restart gap
(b) if !(obj exists && sidecarMatches(side, token, epoch, group, seq, currentMeta)) {   // write-once / confirm
        writeAtomic(obj, jpeg)              // JPEG first
        writeAtomic(side, sidecarJSON)      // sidecar LAST = commit marker (D3)
    }
(c) let deadline = now + receiptWaitTimeout
    while now < deadline {
        if validReceipt(rcpt, token, epoch, group, seq) { return true }
        sleep(receiptPollInterval)
    }
    return false                            // timeout → .failed → auto-retry (NOT a loss)
```
`validReceipt` = file exists, parses, and `kind=="receipt" && token==self.token && epoch==self.epoch &&
group==group && seq==seq`. **`true` is returned on nothing else.**
- `segmentComplete(group,priority,year,month,seqs)` → `writeAtomic(<group>.segment.json)`, return `true`.
- `sessionComplete()` → `writeAtomic(_session.complete.json)`, return `true`.
- `sessionDisconnect()` → `return true` no-op (plan §4: cloud has no connection to drop).

**Bounds:** `receiptPollInterval = 500 ms`; `receiptWaitTimeout = 20 s` per call. The existing 3-attempt loop
(`CaptureViewModel.swift:290`, Android `:396`) is unchanged; on attempts 2–3 step (b) finds the object present and
skips the multi-MB rewrite → ~60 s of continuous polling per enqueue, then `.failed`. `startAutoRetry` (every 8 s,
`:320`/`:139`) + `resumeUploads` (`:315`/`:129`) re-drive `.failed`/`.pending`; each re-entry hits receipt-first (a),
so the very next cycle after the Mac writes the receipt returns `true`. **Liveness:** because the wait is finite,
the spawned Task/coroutine always completes, so `defer { inFlightUploads.remove }` (`:283`, Android `:413`) always
runs and the id is always re-drivable — a slow/unreachable Mac degrades to an infinite safe retry, never a stuck
`.uploading`.

---

## 7. Never-lose invariant + coupling invariants

**INVARIANT:** at every instant, page `(group,seq)` exists in ≥1 of:
- **P** phone local file — deleted only by `removeConfirmed` gated on `state==.uploaded` (`CaptureViewModel.swift:338`,
  Android `:285-286`), i.e. only after a matching-epoch receipt was observed.
- **R** relay object `<group>__<seq>.jpg` — deleted by the Mac only at the `store.delete` step, i.e. only after
  `ingest` returned non-nil.
- **M** Mac durable holding — JPEG in `incomingFolder` + `manifest.json` entry, created atomically by `ingest`,
  crash-surviving via `latestUnprocessedSession` (`:127`,`:393-419`), removed only at finalize by `clearFiled`
  which KEEPS unfiled stragglers (`:252`).

R is removed only after M exists; P is removed only after the receipt (written after M) is observed. Both removals
happen with M provably present. **Safety-critical stores = {P, the atomic renames, M}. The receipt, the
processed-set, and the fingerprint are recoverable/optimization state** (a lost receipt is re-issued from the
processed-set or by re-ingest on re-upload; a lost processed-set only costs a redundant idempotent re-ingest + one
re-OCR).

**Coupling invariants (encode as asserts, not loose constants):**
1. `receiptWaitTimeout ≥ 4 × maxMacPollInterval` — else pages spuriously time out. (20 ≥ 4×1 file; 20 ≥ 4×4 Drive.)
2. `sweepRetention ≥ (receiptWaitTimeout × 3) + autoRetryGap` = 20×3 + 8 = 68 s — else the orphan sweep can race a
   phone still polling for that receipt. `sweepRetention = 10 min` satisfies it with margin.
3. Delete order is always sidecar-then-jpeg; write order is always jpeg-then-sidecar.

---

## 8. Phone-side residual wiring (D5, D6) — no protocol churn beyond the additive `seqs`

- **`CapturedItem`** (iOS `Capture/CaptureModels.swift`, Android `capture/CaptureModels.kt`): add
  `needsResend: Bool = false` (Codable-safe append, exactly like `replacesGroupId`). No `uploadRev`, no `fileId`
  (both deferred to the Drive backend).
- **`toggleP10`** (iOS `:160-168`, Android `:239`): flip priority, set `needsResend=true`, persist; if
  `state==.uploaded` re-enqueue immediately (existing behavior).
- **`reclassifySelected`** (iOS `:189-203`, Android `:298`): also set `needsResend=true` (in addition to the
  existing `replacesGroupId` + `.pending` + `enqueueUpload`).
- **Enqueue completion handler** (iOS `:297-307`, Android `:404-413`, after `inFlightUploads` is removed): if the
  item's current `needsResend` is set → clear it + `enqueueUpload(currentItem)` again. This drains a mutation the
  in-flight guard blocked; because the re-enqueue fires only after the prior `postPhoto` returned + its receipt was
  observed, a reclassify's new `(newGroup,seq)` object is written strictly after the old `(oldGroup,seq)` is durable
  — so the Mac's `replaces`-drop + tombstone can't be out-raced.
- **`sendSegmentComplete`** (iOS `:244`, Android `:355`) now passes `seqs =` the segment's page seqs
  (`items.filter{ groupId==g }.map(seq)`), and defers writing until every page of the group is `.uploaded`
  (KNOWN_ISSUES residual).
- **`SegmentTransport.segmentComplete`** gains an additive `seqs: [Int] = []` param (iOS `SegmentTransport.swift`,
  Android `SegmentTransport.kt`). `MacClient.segmentComplete` accepts it and sends `X-Seqs: "0,1,7"` (or omits if
  empty); `CaptureServer` ignores the unknown header → **HTTP behavior identical**. `FileRelayTransport` writes it
  into the segment sidecar's `seqs`.
- **Persistence:** iOS `SessionStore.Snapshot` is `Codable` → appending `needsResend` to `CapturedItem` is
  automatic (no edit). Android `SessionStore` serializes fields manually → add a `put`/`getBoolean` for
  `needsResend` (`data/SessionStore.kt`).
- **Transport selection seam:** at the two construction sites (iOS `:52` restore / `:80` connect; Android `:35` /
  `:161`) introduce a `makeTransport(for: config)` factory keyed on a persisted transport mode; the FileRelay
  "connect preflight" is "shared dir exists + writable" (not `MacClient.reachability()`, which is HTTP-only and off
  the protocol). For THIS milestone the on-device file-relay pairing UI is **not** wired (per plan §10.1 the
  FileRelay is the offline/CI contract fixture; the real on-device wireless transport is Drive) — `FileRelayTransport`
  is exercised by the unit/golden tests that construct it directly with a temp dir + token + epoch. The factory +
  mode-carrying config is where the Drive backend later plugs in.

---

## 9. Offline Swift test — `Capture/FileRelayTestDriver.swift` (Mac app target)

Follows the `LiveCaptureTestDriver` precedent (`Capture/LiveCaptureTestDriver.swift`, wired at
`ContentView.swift:33`), gated by `FILERELAY_TESTMODE=1`, added at `ContentView.onAppear` beside line 33. Runs in
`stageForLater` mode (default) so `ingest` never fires OCR (`:217` is `.live`-only) → **no Gemini key, $0**.
Deterministic: drives `scanOnce()` directly (never the timer, no sleeps). Ships a test-only `RelayObjectWriter`
(reusing `Net/RelayObjectFormat.swift`) so the test emits the exact bytes the phones must. Sandboxes only a
`mktemp -d` `relayRoot`; the `CaptureSession` uses its real `incomingFolder` (as `LiveCaptureTestDriver` does — no
`backupRoot` injection point exists; "Mac restart" is simulated by rebuilding `FileRelayReceiver`, which reloads
`relay-processed.json`). Emits `results.json` + a `DONE.txt` marker; a `ScanReport` gives OCR-free observables
(`ingested`, `skippedUnchanged`, `receiptsWritten`, `sourcesDeleted`, `segmentsApplied`, `segmentsDeferred`,
`rejectedUnsafe`, `ingestFailedLeftForRetry`).

---

## 10. Golden cross-check (three writers, one committed golden)

Factor a pure format module on each platform — Mac/iOS `RelayObjectFormat` (names + `canonicalJSON` + sidecar/
receipt/control encode + parse), Android `RelayObjectFormat` (pure Kotlin, no Android APIs → plain-JVM unit-testable).
Commit `SPEC/relay-golden/` (NOT `Test Files/`, which `CLAUDE.md` forbids touching): a fixed 1×1 `input.jpg` and,
for fixed inputs `(token=TESTTK, epoch=EP1, group=g1, seq=7, type=document, priority=P8, year=1968, month=3,
device=X, replaces=nil)`, the expected `g1__7.jpg` (== input, byte-identical), canonical `g1__7.json`,
`g1.segment.json` (`seqs="6,7"`), `_session.complete.json`, and `g1__7.receipt.json`. Three independent tests each
diff their writer against the golden; **comparison is canonical** (parse JSON to maps, compare with sorted keys so
whitespace/order differ freely; assert values are STRING types; assert the nil-omit policy; assert the JPEG bytes +
filename). The JSON is the only fragile cross-platform surface, so those are the load-bearing assertions.

---

## 11. Deviations from the plan text (flag for the plan owner)

- Receipt is a **standalone** `<group>__<seq>.receipt.json` (plan §4: `<group>__<seq>.receipt` and/or
  `appProperties.received`) — required, not optional (D8).
- `_session.complete.json` (plan: `_session.complete`) (D9).
- All `appProperties`/sidecar values are **strings** (plan §4 shows numeric-looking `seq/year/month`; Drive
  `appProperties` are string-only anyway) (D2).
- Plan §5.7's "processed set persisted in the staging manifest" has no home — the receiver adds its own
  `relay-processed.json` (§5).
- New fields not in plan §4: `epoch` (D10), `seqs` on segment-complete (D6). `rev` is intentionally NOT added now
  (D4) — the Drive backend adds it.
- The processed-set uses a metadata **fingerprint** for the FileRelay, upgraded to a monotone `rev` for Drive (D4).

## 12. Inherited (not fixed here)

Idempotency keys on `(group,seq)`; the Mac backup filename is `%05d-<groupId>.jpg` (`CaptureSession.swift:183/188`),
so a phone reusing a global seq across two different pages would silently overwrite one. The never-lose invariant
assumes the phone assigns a unique global seq (`CaptureModels.swift` seq = global capture order). This transport
adds no guard against a phone that violates that.


## Files to create/edit
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Net/CaptureReceiver.swift — Define `protocol CaptureReceiver: AnyObject, Sendable { func start(); func stop() }` and `enum CaptureTransport: String { case lan, fileRelay, cloud }`. The minimal role both CaptureServer and FileRelayReceiver conform to.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Net/CaptureValidation.swift — `enum CaptureValidation { static func isSafeGroupId(_:) -> Bool }` — the traversal guard extracted char-for-char from CaptureServer.swift:283-286 so both receivers share one validator (ingest itself does none, interpolating groupId into a path at CaptureSession.swift:183).
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Net/RelayObjectFormat.swift — Shared format module: object names, suffix classification, canonicalJSON(map:) (sorted ASCII keys, fixed escape table, UTF-8-once, all-string values, nil-omit), and encode/parse for photo sidecar / segment-complete / session-complete / receipt. Reused by FileRelayReceiver and the test RelayObjectWriter.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Net/FileRelayReceiver.swift — The receiver: RelayObjectStore protocol + LocalDirectoryStore, 1s single-flight poll timer, scanOnce() (photos-before-controls; validate+quarantine; fingerprint-gated ingest via a MainActor hop; receipt->persist-processed->delete-sidecar-then-jpeg on non-nil, do-nothing on nil; replaces->removePhotoIfSafe+tombstone; seqs/no-unprocessed-photo deferral for controls), epoch-scoped relay-processed.json in incomingFolder, orphan sweep. @unchecked Sendable, all state on a serial queue.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Capture/FileRelayTestDriver.swift — FILERELAY_TESTMODE-gated offline driver (stageForLater, no key, $0): ships a test-only RelayObjectWriter, drives scanOnce() deterministically against a mktemp relayRoot, simulates Mac-restart by rebuilding the receiver, and writes results.json + DONE.txt with a ScanReport for the 9 invariant cases.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Capture/CaptureSession.swift — Add sibling fileRelay receiver at :112 (relayRoot from DefaultsKeys.liveRelayDir/env, epoch=sessionId); transport-gate start()/stop() so the LAN branch stays byte-identical and the relay start bypasses the HTTP-coupled `guard !serverRunning` at :141; add portless relayRunning + relayReceiverDidStart/Stop/Fail (no port/USBBridge) and a receiverActive seam; add relayRoot(for:) helper.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Net/CaptureServer.swift — One-token conformance CaptureServer: @unchecked Sendable, CaptureReceiver; replace the 3 private isSafeGroupId call sites (:215,:229,:246) with CaptureValidation.isSafeGroupId and delete the private method. Behavior-preserving — no route/parse/auth/ack change.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/Models/DefaultsKeys.swift — Add `liveTransport` and `liveRelayDir` string keys to the existing // Live Capture block.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveProcessor/Sources/ArchiveProcessor/ContentView.swift — Add FileRelayTestDriver.runIfRequested(session: capture) in .onAppear beside the existing LiveCaptureTestDriver call at :33.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/scripts/test-tier2.sh — Add a key-free relay run_case that launches the app with FILERELAY_TESTMODE/RELAYDIR/TESTOUT/TESTDONE, waits on DONE.txt, and asserts results.json via scripts/relay_assert.py (mirrors the existing Process-Files run_case pattern).
- [create] /Users/<user>/Desktop/Claude/Archive Processor/scripts/relay_assert.py — Thin checker of the driver results.json (all invariant cases PASS), emitting `RESULT: PASS/FAIL` like tier2_assert.py.
- [create] /Users/<user>/Desktop/Claude/SPEC/relay-object-format.md — Single-source-of-truth SPEC for the on-disk relay format (folder layout, object kinds, canonical all-string JSON, escape table, write/delete ordering, classification, epoch/token/seqs semantics) — sits alongside the existing SPEC/tag-format.md at the Suite root; all three writers + the receiver cite it.
- [create] /Users/<user>/Desktop/Claude/SPEC/relay-golden/ — Committed golden fixtures for the cross-platform check: input.jpg + expected g1__7.jpg, g1__7.json, g1.segment.json (seqs=6,7), _session.complete.json, g1__7.receipt.json for fixed inputs (token=TESTTK, epoch=EP1, group=g1, seq=7, type=document, priority=P8, year=1968, month=3, device=X).
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/FileRelayTransport.swift — iOS SegmentTransport impl: nonisolated Sendable struct { sharedDir, token, epoch }. postPhoto = receipt-first check -> write-once (jpeg then sidecar-last) -> bounded 20s/500ms receipt poll -> true only on a matching-epoch receipt. segmentComplete(seqs)/sessionComplete write control objects; sessionDisconnect is a true no-op.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/RelayObjectFormat.swift — iOS mirror of the Mac format module (names + canonicalJSON + sidecar/receipt encode/parse) — the single fragile cross-platform surface, bound to the golden.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/SegmentTransport.swift — Add an additive `seqs: [Int] = []` parameter to segmentComplete(...) (backward-compatible default).
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/MacClient.swift — segmentComplete accepts seqs and sends X-Seqs: 0,1,7 (omit if empty); CaptureServer ignores the unknown header so HTTP behavior is identical.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Capture/CaptureModels.swift — Add `var needsResend: Bool = false` to CapturedItem (Codable-safe append like replacesGroupId; auto-persisted via the Codable Snapshot). No uploadRev/fileId (deferred to Drive).
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Capture/CaptureViewModel.swift — Set needsResend in toggleP10/reclassifySelected; drain it in the enqueueUpload completion handler (re-enqueue after in-flight completes); pass seqs from sendSegmentComplete and defer it until the group's pages are .uploaded; add the makeTransport(for:config) selection seam at the two construction sites (:52,:80) — file-relay UI wiring deferred to the Drive milestone.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/Tests/RelayObjectFormatTests.swift — XCTest that diffs RelayObjectFormat output (and a direct FileRelayTransport receipt-wait round-trip against a fake receipt) versus SPEC/relay-golden/ using canonical map comparison + string-type + nil-omit assertions. Requires a test target in project.yml (flagged); a --emit-golden debug-arg fallback is acceptable if the target is out of scope.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCaptureiOS/project.yml — Add a unit-test target wiring Tests/RelayObjectFormatTests.swift (needed only for the iOS golden test; run xcodegen generate after). Flagged as the one scaffolding addition — no XCTest target exists today.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/net/FileRelayTransport.kt — Android SegmentTransport impl: blocking postPhoto (write-once jpeg-then-sidecar, bounded Thread.sleep receipt poll, true only on matching-epoch receipt) called inside the existing withContext(Dispatchers.IO). On device writes via SAF/ContentResolver with sidecar-last completeness; the CI/JVM fixture uses a real shared FS.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/net/RelayObjectFormat.kt — Pure-Kotlin (no Android API) mirror of the format module: names + canonicalJSON + sidecar/receipt encode/parse. JVM-unit-testable and bound to the golden.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/net/SegmentTransport.kt — Add an additive `seqs: List<Int> = emptyList()` parameter to segmentComplete(...).
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/net/MacClient.kt — segmentComplete accepts seqs and sends X-Seqs (omit if empty); Mac ignores it -> HTTP identical.
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureModels.kt — Add `val needsResend: Boolean = false` to CapturedItem (mirrors iOS).
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureViewModel.kt — Set needsResend in toggleP10/reclassifySelected; drain it in the enqueueUpload completion (viewModelScope, after inFlightUploads removed); pass seqs from sendSegmentComplete + defer until pages UPLOADED; add the transport-mode branch at the two client-construction sites (:35,:161) and a dir-exists/writable preflight in place of MacClient.reachability() for file-relay mode (UI wiring deferred to Drive).
- [edit] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/data/SessionStore.kt — Persist the new needsResend field (add put/getBoolean in save/load) — Android SessionStore serializes fields manually, unlike iOS's Codable Snapshot.
- [create] /Users/<user>/Desktop/Claude/Archive Processor/ArchiveCapture/app/src/test/java/com/archiveprocessor/capture/net/RelayObjectFormatTest.kt — Plain-JVM JUnit test (no emulator) diffing RelayObjectFormat output against the committed golden via canonical map comparison + string-type + nil-omit assertions. Resolves the golden fixtures via a Gradle test resource copied/linked from SPEC/relay-golden/ (cross-repo path flagged as an open question).

## Test plan
OFFLINE MAC DRIVER (FileRelayTestDriver, FILERELAY_TESTMODE=1, stageForLater, $0 — asserts on ScanReport + session.photos + completedDocGroups + filesystem, driving scanOnce() directly):
1. Happy path + (group,seq) idempotency: write (g0,0),(g0,1) -> scanOnce -> ingested==2, receipts present, sources deleted. Re-write (g0,0) identical AND a corrupted-bytes variant -> skippedUnchanged, session.photos still has exactly one (g0,0) (idempotent replace CaptureSession.swift:198-204), receipt+delete.
2. Metadata change (fingerprint): re-write (g0,0) with priority flipped to P10 -> fingerprint differs -> re-ingest, session.photos[(g0,0)].priority=="P10". Confirms the fingerprint (D4) does NOT suppress a real metadata update (no HTTP regression) while an identical re-send is skipped (case 1).
3. Receipt-before-delete / nil ingest: force ingest->nil (unwritable/zero-length target) -> NO receipt, source NOT deleted, ingestFailedLeftForRetry nonempty; fix + re-scan -> receipt + delete appear.
4. No double-ingest across Mac restart (ingest-before-delete): pass 1 with deleteSourceAfterReceipt=false -> ingests, persists set, writes receipt, leaves source. Rebuild FileRelayReceiver (reloads relay-processed.json) with defaults -> ingested==[], skippedUnchanged==[key], sourcesDeleted==1.
5. Backstop when processed-set lost (ingest-before-persist): pass 1 with persistProcessedSet=false; rebuild receiver (empty set) -> re-ingests but session.photos still has exactly one, JPEG byte-identical.
6. reclassify/replaces: write (g0,5); scan. Write (g1,5, replaces=g0); scan -> photos has (g1,5) not (g0,5) (removePhotoIfSafe :231), (g0,5) tombstoned, stale g0__5.* deleted; a third scan does not resurrect g0.
7. segment-complete deferral (seqs): write g2.segment.json (seqs=0,1) BEFORE page (g2,1) -> segmentsDeferred contains g2, completedDocGroups excludes g2. Write (g2,1); scan -> segmentsApplied contains g2, markSegmentComplete applied. Repeat once with seqs absent to exercise the no-unprocessed-photo fallback.
8. Traversal guard + epoch: sidecars with group ../evil, a 130-char group, a wrong-token, and a wrong-epoch -> each rejectedUnsafe/ignored, ingest never called, quarantined to .rejected/, no file escapes relayRoot/incomingFolder, no receipt written.
9. Composite no-loss: interleave writes with fresh-receiver rebuilds at crash points 3/4/5 and assert the union of session.photos + surviving source objects always covers every unique (group,seq).

GOLDEN CROSS-CHECK (three independent tests, one committed SPEC/relay-golden/):
- iOS XCTest: RelayObjectFormat.sidecar/segment/session/receipt parsed == golden parsed (canonical map compare) AND filename + JPEG bytes match; a FileRelayTransport.postPhoto round-trip returns true only after a fake matching-epoch receipt is dropped in, and false on timeout with the wrong epoch.
- Android JVM JUnit: same assertions in pure Kotlin (no emulator).
- Mac driver: RelayObjectWriter output == golden AND FileRelayReceiver round-trips the golden (ingest + receipt). All three assert values are STRING types and nil fields are OMITTED.

HARNESS: extend scripts/test-tier2.sh with a key-free relay run_case (FILERELAY_TESTMODE) waiting on DONE.txt, asserted by scripts/relay_assert.py (RESULT: PASS/FAIL). The golden step runs as a second run_case or pre-build hook (Mac driver + Android JVM test; iOS XCTest if the test target is scaffolded). Cost: $0, no OCR, no network, no auth.

BUILD-VERIFY: `cd ArchiveProcessor && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build` (new Swift files are globbed by XcodeGen — no project.yml edit for the Mac target); iOS xcodegen generate (project.yml gains the test target) + xcodebuild -sdk iphonesimulator; Android ./gradlew testDebugUnitTest. Tier-1 no-new-warnings + Tier-2 adversarial review (Net/ + phone<->Mac contract + never-lose path) per CLAUDE.md before shipping.

## Invariant checklist
- [ ] postPhoto returns true iff a valid matching-(token,epoch,group,seq) receipt object exists; never on write success alone.
- [ ] The Mac writes a receipt only after CaptureSession.ingest returns non-nil (JPEG temp->rename AND writeManifest both succeeded, guard at CaptureSession.swift:215).
- [ ] The Mac deletes a source object only after ingest returned non-nil AND the receipt was written; delete removes the sidecar FIRST then the .jpg.
- [ ] The phone writes the .jpg first (temp->rename) then the sidecar (temp->rename) as the commit marker; a receiver acts on a photo only when both exist.
- [ ] The phone deletes its only local copy only via removeConfirmed gated on state==.uploaded (CaptureViewModel.swift:338 / Android :285), i.e. only after a matching-epoch receipt.
- [ ] At every instant page (group,seq) exists in at least one of {phone local file, relay .jpg, Mac incomingFolder+manifest}; both deletions occur only with the Mac durable holding provably present.
- [ ] Every relay object name is classified by suffix only (. is not in the isSafeGroupId charset); identity (group,seq) is read from the sidecar body, never parsed from the filename.
- [ ] Both receivers validate CaptureValidation.isSafeGroupId(group) + seq>=0 + token + epoch (and replaces if present) BEFORE ingest; an invalid object is quarantined, never ingested and never deleted.
- [ ] CaptureServer routing/parsing/auth/ack and the LAN start()/serverRunning path are byte-for-byte unchanged; the relay start bypasses guard !serverRunning and uses portless relayRunning (no listenPort, no USBBridge).
- [ ] ingest==nil leaves the object untouched (no receipt, no delete, no processed entry); the phone still holds the only copy and retries.
- [ ] The processed-set (relay-processed.json in the private incomingFolder, epoch-scoped) is persisted BEFORE the source is deleted; a lost/empty processed-set is a safe backstop (idempotent (group,seq) re-ingest, only cost is re-OCR).
- [ ] Re-ingest fires only when the sidecar ingest-metadata fingerprint differs from the stored one, so an identical re-send skips (no double-OCR) but a P10/tag change re-ingests (no metadata regression vs HTTP).
- [ ] markSegmentComplete is applied only when every seqs entry is processed (or, absent seqs, when no unprocessed photo object for the group remains); a partial segment is never finalized.
- [ ] receiptWaitTimeout is finite (20s), so the enqueue Task/coroutine always completes and inFlightUploads is always cleared (defer/finally) -> a slow/unreachable Mac is an infinite safe retry, never a stuck .uploading item.
- [ ] Coupling asserts hold: receiptWaitTimeout >= 4x maxMacPollInterval; sweepRetention >= receiptWaitTimeout*3 + autoRetryGap.
- [ ] needsResend re-enqueues a P10/reclassify mutation that the inFlightUploads guard swallowed, only after the prior postPhoto returned + its receipt was observed (so reclassify's new object lands strictly after the old is durable).
- [ ] New CapturedItem fields (needsResend) are Codable-safe appends with safe defaults; no persisted-settings/enum rawValue is renamed (CLAUDE.md shared-hotspot rule).

## Open questions
- Where does the per-run epoch come from in a REAL on-device relay pairing (vs the offline fixture's fixed value)? Design uses the Mac sessionId conveyed via the pairing config/QR; the QR schema + phone re-pair flow that refreshes epoch is the Settings/UX + pairing lens's territory and is not wired in this milestone.
- iOS has NO XCTest target today (Tests/ empty, project.yml wires none). The golden test needs either new project.yml test-target scaffolding + an xcodebuild test invocation the harness doesn't currently use, or a --emit-golden debug-arg fallback the shell script diffs. Which path?
- Cross-repo golden resolution: SPEC/relay-golden/ lives at the Suite root, but the Android Gradle module and the iOS project are separate checkouts. How should each test resolve the fixtures (committed copy per repo, a Gradle test-resource copy/symlink, or a relative path)? Risk of the copies drifting.
- Receipt cleanup ownership: after the phone marks UPLOADED, who deletes the receipt object — the Mac orphan sweep (assumed here, keyed on mtime + processed-set membership) or the phone? Left to the sweep; confirm no unbounded receipt accumulation in the shared dir.
- Confirm the additive seqs param on segmentComplete is acceptable churn on the SegmentTransport shared hotspot (touches both companions + MacClient), given the phone-side defer already largely prevents partial segments and seqs is defense-in-depth rather than a never-lose requirement.
- Confirm the D4 decision to use a Mac-side metadata fingerprint now and defer the monotone rev/uploadRev to the Drive backend — the plan §4 has no version field and the ground maps only anticipated a fileId append; adding rev to the protocol later is a coordinated cross-lane change.
- CaptureSession hardcodes backupRoot with no injection point (CaptureSession.swift:98-102), so the offline test cannot fully sandbox the Mac-side session folder (only relayRoot is a temp dir); is simulating Mac-restart by rebuilding FileRelayReceiver sufficient, or should an injectable backupRoot be added for hermetic testing?
- Plan text deviations (standalone .receipt.json, _session.complete.json, all-string values, epoch, seqs, processed-set home) should be reflected back into LIVE_CAPTURE_CLOUD_TRANSPORT_PLAN.md sections 4/5.7 and the new SPEC/relay-object-format.md before the Drive backend inherits them.
