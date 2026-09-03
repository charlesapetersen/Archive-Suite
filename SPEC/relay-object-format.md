# Archive Suite — Live Capture Relay Object Format (`SPEC/relay-object-format.md`)

## Purpose & status

**This file is the single source of truth for the on-disk relay object format that the phone
transports (iOS + Android) _write_ and the Mac receiver _reads_ — and that the Mac _writes back_
(receipts, epoch marker) for the phones to read.** It is the offline, local-shared-directory stand-in
that proves the Google Drive cloud-transport contract without OAuth/network; the Drive backend later
swaps only the storage layer behind the same object shapes. Like `SPEC/tag-format.md`, it governs
**irreplaceable archival photos that cannot be re-taken** — a silent byte-level divergence between any
writer and the reader loses a page or double-ingests it.

**All three writers and the receiver MUST produce/parse every byte below identically.** When they
disagree, this spec plus the cited source files are authoritative — not prose in any plan doc. The
cross-platform golden (`ArchiveProcessor/SPEC/relay-golden/`) + `scripts/test-relay-golden.sh` are the
mechanical guard.

Extracted from the pre-merge FileRelay build spec (in git history) (its **v2 amendments A1–A11 bind over
the v1 base body** where they conflict) and reconciled against the shipped code (paths below). Status:
**settled for the FileRelay milestone.** The Drive backend inherits these shapes and may only *add* a
monotone `rev` when coexisting objects demand it (A1/D4).

---

## The one rule everything derives from

`FileRelayTransport.postPhoto` returns `true` **if and only if, after,** the phone reads a valid
**receipt object** the Mac wrote — and the Mac writes a receipt **only after** `CaptureSession.ingest`
returned non-nil (JPEG temp→rename **and** `writeManifest()` both succeeded). A receipt existing is thus
a phone-observable proxy for "the Mac durably holds this page." **Writing a relay object successfully is
never itself a `true`.**

---

## Session folder & atomic writes

- Session folder (Mac creates it on relay start): `<relayRoot>/<sessionToken>/`.
- `sessionToken` = the existing stable 6-char `CaptureSession.token` (reused across launches).
- **Every** object is written **temp→rename**: `.<name>.<uniq>.part` → `<name>`, atomic on one
  filesystem. On Android-on-device (SAF/`ContentResolver`, no guaranteed atomic rename) the sidecar-last
  write order is the completeness marker instead; the CI/JVM fixture uses a real POSIX filesystem where
  rename is atomic.

## Object kinds

`.` never appears in a safe group id (`CaptureValidation.isSafeGroupId`), so suffix classification is
unambiguous. Identity `(group, seq)` is **always read from the sidecar/receipt body, never parsed from
the filename** (a group id may contain `_`, so `<group>__<seq>` is ambiguous by name — A10 only
*cross-checks* the name against the body, it is not the source of truth).

| Object | Filename | Written by | `kind` |
|---|---|---|---|
| Photo media | `<group>__<seq>.jpg` | phone | — (paired with its sidecar) |
| Photo sidecar (commit marker) | `<group>__<seq>.json` | phone | `photo` |
| Segment-complete | `<group>.segment.json` | phone | `segment-complete` |
| Session-complete | `_session.complete.json` | phone | `session-complete` |
| Receipt | `<group>__<seq>.receipt.json` | **Mac** | `receipt` |
| Epoch marker | `_epoch.json` | **Mac** | `epoch` |
| In-progress temp | `.<name>.<uniq>.part` | both | (ignored by readers) |

## Canonical JSON

All object metadata is a **string→string map** (so it maps 1:1 onto Drive `appProperties` later),
serialized by a shared ~15-line `canonicalJSON` on each platform. **Do not** substitute a built-in
encoder (Swift `JSONEncoder` escapes `/`→`\/`; `org.json` escapes differently; neither guarantees the
same key sort or control-char casing).

1. **Drop nil-valued entries** (never emit `null` or `""` for an absent field).
2. **Sort keys ascending** (keys are fixed lowercase-ASCII → Swift `String` sort, Kotlin `sortedBy`,
   and byte order all agree).
3. Emit `{"k":"v",...}` — no spaces, no newline, UTF-8, no BOM.
4. **Escape by string replacement**, then encode to UTF-8 **once** at the end (so astral/emoji scalars
   stay identical multi-byte sequences on Swift-over-scalars and Kotlin-over-UTF-16):
   `"`→`\"`, `\`→`\\`, U+0008→`\b`, U+0009→`\t`, U+000A→`\n`, U+000C→`\f`, U+000D→`\r`, any other
   C0 (< 0x20)→`\u00xx` (**lowercase** hex); **everything else — including `/` and all non-ASCII —
   verbatim.**

**Reading is lenient (A6):** parse to `[String:String]` via `JSONSerialization`/manual, **stringifying
number-or-string values** so a non-canonical writer's bare `"seq":7` is tolerated rather than throwing
and silently stalling one platform. Parse is order-independent. On Drive the map becomes `appProperties`
and byte-order is a non-issue, so `canonicalJSON` is FileRelay/CI-internal.

## Object bodies (SHIPPED shapes — keys shown pre-sorted; `?` = nil-omittable)

- **Photo sidecar** `<group>__<seq>.json`
  `{"device"?,"epoch","fp","group","kind":"photo","month"?,"quality"?,"replaces"?,"seq","token","type","year"?}`
  Fields are 1:1 with the HTTP `X-*` headers: `type` ∈ `document|box|folder` (`CaptureGroupType`
  rawValues); `seq`/`year`/`month` are stringified ints; `quality` ∈ `Q1|Q2|Q3`; `replaces` = the
  reclassify chain (A3). Unrated omits `quality`; `Q0` is Mac-internal and any `P*` token is invalid at
  the public phone→Mac boundary. `fp` = the metadata fingerprint (below).
- **Segment-complete** `<group>.segment.json`
  `{"epoch","group","kind":"segment-complete","month"?,"quality"?,"seqs"?,"token","year"?}`
  `seqs` = comma-joined page seqs of the segment, e.g. `"6,7"` (A5: snapshotted at End-segment).
- **Session-complete** `_session.complete.json`
  `{"epoch","kind":"session-complete","token"}`
- **Receipt** `<group>__<seq>.receipt.json`
  `{"epoch","fp","group","kind":"receipt","received":"true","seq","token"}`
  **No timestamp** (D8) — a Mac-restart re-write is byte-identical = a true no-op; orphan-sweep age uses
  filesystem mtime. Echoes the sidecar's `fp` (A1).
- **Epoch marker** `_epoch.json`
  `{"epoch","kind":"epoch","token"}`

Golden byte examples (`ArchiveProcessor/SPEC/relay-golden/`, fixed inputs `token=TESTTK, epoch=EP1`):

```
g1__7.json          {"device":"X","epoch":"EP1","fp":"1f20bc45d93d2046","group":"g1","kind":"photo","month":"3","quality":"Q1","seq":"7","token":"TESTTK","type":"document","year":"1968"}
g1__7.receipt.json  {"epoch":"EP1","fp":"1f20bc45d93d2046","group":"g1","kind":"receipt","received":"true","seq":"7","token":"TESTTK"}
g1.segment.json     {"epoch":"EP1","group":"g1","kind":"segment-complete","month":"3","quality":"Q1","seqs":"6,7","token":"TESTTK","year":"1968"}
_session.complete.json  {"epoch":"EP1","kind":"session-complete","token":"TESTTK"}
_epoch.json         {"epoch":"EP1","kind":"epoch","token":"TESTTK"}
nasty__0.json       {"device":"X’😀",...,"fp":"3569ca955db85c80","group":"nasty","kind":"photo","seq":"0","token":"TESTTK","type":"document"}
```

`nasty__0.json` is the A7 escaping fixture: U+2019 (`’`) and an astral emoji emit **verbatim** UTF-8;
the C0 control U+0001 emits ``; nil `quality/year/month/replaces` are **omitted**.

## Metadata fingerprint `fp` (A1 / D4)

`fp` = **SHA-256 of `canonicalJSON` over the ingest-relevant metadata, first 8 bytes = 16 lowercase hex.**
The fingerprint map is exactly:

```
{"type","quality"?,"month"?,"year"?,"replaces"?}
```

- **Includes `replaces`; excludes `device`, `seq`, `group`, `token`, `epoch`** — i.e. exactly the
  fields that change OCR/tag output. A device-name change never forces a re-ingest.
- The **same** function + inputs on the phone and Mac yield the **same** `fp`. The sidecar carries it;
  the receipt **echoes** it.
- **Phone:** `postPhoto`'s receipt-first short-circuit fires **only** when the receipt's `fp` matches the
  *current* metadata; a post-upload Q3/reclassify change (new `fp`) falls through, rewrites the sidecar,
  and waits for a receipt carrying the new `fp`.
- **Mac:** the processed-set `Entry.fp` and the receipt `fp` are the same hash — re-ingest fires **iff
  `fp` differs**. Identical re-send is skipped (no double-OCR); a real metadata change is re-ingested (no
  regression vs the HTTP path).
- Verified: `fp` of `{month:"3",quality:"Q1",type:"document",year:"1968"}` (replaces omitted) =
  `1f20bc45d93d2046`, matching both the sidecar and receipt golden.

## Epoch (D10 / A2)

The `epoch` is a per-run nonce = the Mac's `sessionId`. It appears on **every** object and gates trust:

- The Mac writes `<relayRoot>/<token>/_epoch.json` (atomic temp→rename) at `FileRelayReceiver.start()`.
- The phone, before each `postPhoto`/control write, **reads `_epoch.json` and adopts its `epoch`** for
  every object it writes and every receipt it trusts this cycle. If the marker is absent (Mac relay not
  started), `postPhoto` returns `false` immediately (safe auto-retry) rather than writing an un-ackable
  object.
- The phone trusts a receipt **only if its `epoch` matches** the adopted one; the Mac ignores/sweeps
  mismatched-epoch objects; the processed-set is epoch-scoped. A stale prior-run receipt (different
  epoch) can never false-positive `postPhoto` and delete a page the Mac does not hold this run.
- After a Mac restart with a fresh `sessionId`, the phone adopts the new epoch and re-uploads pending
  objects under it → uploads resume with **no re-pair**; phone local copies are retained until a
  matching-epoch receipt, so nothing is lost across the epoch change.

## `replaces` reclassify chain (A3)

On the relay, objects persist until the Mac drains them, so a chained reclassify G→H→I could strand G.
The sidecar's `replaces` therefore carries the **full comma-joined reclassify chain** (e.g. `"g0,gH"`),
built from the phone's `replacedGroups` list. The Mac tombstones **every** listed `(group, seq)` after
ingesting the new object (global `seq` is unique per page, so this is safe). *(The HTTP `X-Replaces`
path stays the single immediate-prior group — behavior-identical there.)*

## Classification (suffix test, in order)

Skip dotfiles and `*.part`, then:

1. `_epoch.json` → epoch marker
2. `_session.complete.json` → session-complete
3. `*.receipt.json` → receipt (the Mac ignores its own)
4. `*.segment.json` → segment-complete
5. `*.jpg` → media
6. remaining `*.json` → photo sidecar

A photo is "ready" only when **both** the `.jpg` and its sidecar exist (the sidecar, written last, is the
commit marker). **A10:** the receiver cross-checks the filename's leading `<group>__<seq>` against the
body's `(group, seq)` and quarantines a mismatch; the body stays authoritative.

## Write / delete ordering (D3)

- **Write:** JPEG first (temp→rename), then sidecar (temp→rename) = the commit marker.
- **Delete (Mac):** sidecar **first**, then `.jpg` — deleting the sidecar un-commits the object from the
  watcher's view before the media disappears.

---

## Never-lose invariant (the reason this spec exists)

**INVARIANT — at every instant, page `(group, seq)` exists in ≥1 of:**

- **P** — the **phone local file**, deleted only by `removeConfirmed` gated on `state == .uploaded`, i.e.
  only after a matching-epoch receipt was observed.
- **R** — the **relay object** `<group>__<seq>.jpg`, deleted by the Mac only at the `delete` step, i.e.
  only after `ingest` returned non-nil.
- **M** — the **Mac durable holding**: JPEG in `incomingFolder` + a `manifest.json` entry, created
  atomically by `ingest`, crash-surviving, removed only at finalize (which keeps unfiled stragglers).

R is removed only after M exists; P is removed only after the receipt (written after M) is observed —
both deletions happen with M provably present. **Safety-critical stores = {P, the atomic renames, M,
and persisted tombstones (A4)}.** The receipt, the processed-set, and the fingerprint are recoverable
optimization state (a lost receipt is re-issued from the processed-set or by idempotent re-ingest on
re-upload).

**Durable ordering on the Mac:** persist-processed-set → write receipt → delete (sidecar, then `.jpg`).
`ingest == nil` leaves the object completely untouched (no receipt, no delete, no processed entry) — the
phone still holds the only copy and retries.

**Coupling invariants (encode as asserts, not loose constants):**

1. `receiptWaitTimeout ≥ 4 × maxMacPollInterval` (shipped: 20 s ≥ 4×1 s file; ≥ 4×4 s Drive) — else pages
   spuriously time out.
2. `sweepRetention ≥ (receiptWaitTimeout × 3) + autoRetryGap` = 20×3 + 8 = 68 s — else the orphan sweep
   races a phone still polling. Shipped `sweepRetention = 10 min` satisfies it with margin.
3. Delete order is always sidecar-then-jpeg; write order is always jpeg-then-sidecar.

---

## Adversarial amendments A1–A11 (the binding contract points)

These v2 amendments override the v1 base body of the pre-merge FileRelay build spec and define the shipped
contract. Severity in brackets.

| # | Rule | Where enforced |
|---|---|---|
| **A1** [CRITICAL] | Sidecar + receipt carry `fp`; `postPhoto` short-circuits and the Mac skips re-ingest **only** when `fp` matches. `fp` over `{type,quality,year,month,replaces}`. | `RelayObjectFormat.fingerprint`, receipt echo, `FileRelayReceiver` |
| **A2** [CRITICAL] | Epoch is **published (`_epoch.json`) and adopted**, not pairing-fixed; absent marker ⇒ `postPhoto` returns `false`. | `_epoch.json`, phone read-before-write |
| **A3** [HIGH] | `replaces` = the **full** comma-joined reclassify chain; Mac tombstones every listed `(group,seq)`. | sidecar `replaces`, `replacedGroups` |
| **A4** [HIGH] | Tombstones are **durability-critical**: gate the superseded-object delete on a confirmed `persistProcessed()`; never epoch-discard/prune an entry while a relay object for it may exist. | `FileRelayReceiver` |
| **A5** [HIGH] | `seqs` is **snapshotted at End-segment** and persisted; never recomputed from the pruned live `items`. A still-pending page ⇒ the Mac **defers** the segment. | segment `seqs`, phone defer |
| **A6** [MEDIUM] | Mac reader **coerces number-or-string** (lenient parse); string-typedness is a *writer* contract enforced by the golden, not a strict reader decode. | `RelayObjectFormat.parse`, golden |
| **A7** [MEDIUM] | Golden asserts **byte-equality** against committed files (+ the non-ASCII/astral/C0 `nasty` fixture); values must be raw JSON **string** tokens. | `SPEC/relay-golden/`, `test-relay-golden.sh` |
| **A8** [HIGH] | Same-language **round-trip** tests (real transport ⇄ real receiver), not only format-module goldens. | iOS XCTest, Android JVM, Mac driver |
| **A9** [MEDIUM] | Orphan sweep **age-gates** the jpeg-orphan clause (only delete a sidecar-less `.jpg` older than `sweepRetention`), symmetric for media-less sidecars. | `FileRelayReceiver` sweep |
| **A10** [LOW] | Filename `<group>__<seq>` is cross-checked against the body; mismatch ⇒ **quarantine**. Body authoritative. | `RelayObjectFormat.identityFromName` (Mac) |
| **A11** [MEDIUM] | Reclassify-after-finalize duplicate is a **documented residual**, deferred to the Drive milestone (tracked in `KNOWN_ISSUES.md`); the Mac logs the collision, no new silent duplication. | — (residual) |

---

## Where each side implements it

| Piece | Path |
|---|---|
| **Mac** format module (names, `classify`, `identityFromName`, `canonicalJSON`, `fingerprint`, encode sidecar/receipt/segment/session/**epoch**, lenient `parse`) | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/RelayObjectFormat.swift` |
| **Mac** receiver (poll, `scanOnce`, ingest-then-ack, tombstones, sweep, epoch-scoped `relay-processed.json`) | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/FileRelayReceiver.swift` |
| **Mac** group-id traversal guard (shared with `CaptureServer`) | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/CaptureValidation.swift` |
| **Mac** Drive backend (same object shapes over `appProperties`) | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/DriveObjectStore.swift` |
| **iOS** format module (names, `canonicalJSON`, `fingerprint`, encode sidecar/segment/session, lenient `parse` for receipt+epoch) | `ArchiveProcessor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/RelayObjectFormat.swift` |
| **Android** format module (pure Kotlin — names, `canonicalJson`, `fingerprint`, encode sidecar/segment/session) | `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/net/RelayObjectFormat.kt` |
| **Golden fixtures** (`input.jpg` + expected canonical bytes for fixed inputs; `nasty` unicode fixture) | `ArchiveProcessor/SPEC/relay-golden/*.json`, `.../input.jpg` |
| **Cross-platform guard** (swiftc-standalone iOS emit + Android JVM JUnit, byte-diffed vs golden) | `ArchiveProcessor/scripts/test-relay-golden.sh` |

> Module-surface asymmetry is intentional, not drift: only the **Mac** writes receipts + the epoch
> marker and does `classify`/`identityFromName`; the **phones** only write sidecar/segment/session and
> only *read* the receipt + epoch marker (Android does its receipt/epoch parsing in the transport, so its
> format module has no `parse`). The load-bearing shared surface is the **canonical bytes**, which the
> golden guards on all three.

---

## Change protocol & drift note

- **Any change to a byte on the wire is a coordinated four-way change:** Mac + iOS + Android
  `RelayObjectFormat` **plus** the golden fixtures (regenerate) **plus** this spec — in one batch. Never
  land one writer alone; run `scripts/test-relay-golden.sh` before commit. Treat as **Tier-2** (Net/ +
  never-lose path — adversarial review + tests on scratch copies, per `ArchiveProcessor/CLAUDE.md`).
- **Additive only, backward-compatible:** new fields default to nil-omitted (HTTP-identical); persisted
  enum rawValues (`CaptureGroupType`, etc.) are never renamed.
- **This doc lives at the Suite-root `SPEC/`** (beside `tag-format.md`); the **golden fixtures live under
  `ArchiveProcessor/SPEC/relay-golden/`** so they stay version-controlled with the code all three
  platforms build from. Reconciling the two `SPEC/` locations is a deferred cleanup.
- **Drift folded from the pre-merge FileRelay build spec** (documented here as the shipped
  reality):
  1. The v1 §2 sidecar/receipt bodies **omit `fp`**; A1 added it and the shipped code + golden carry it
     in **both**. This spec shows `fp`.
  2. The `_epoch.json` epoch marker (`kind":"epoch"`, A2) is shipped but is **absent from the v1 §2
     object-kinds table and classification list**. Added here.
  3. The fingerprint field set is `{type,quality,year,month,replaces}` (5 fields, per A1) — the v1 §5
     `scanOnce` parenthetical says `{type,quality,year,month}` (drops `replaces`). **Shipped includes
     `replaces`** (verified against the golden `fp` values).
  4. Old paths were pre-merge (`~/Desktop/Claude/Archive Processor/…`, `…/Claude/SPEC/…`);
     corrected throughout to the monorepo layout above.
