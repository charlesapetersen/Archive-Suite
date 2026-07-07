# Live Capture — Cloud Transport (Google Drive relay) — Implementation Plan

**Created 2026-07-06. Status: in progress.** ✅ Step 1 (phone `SegmentTransport` seam) shipped &
build-verified on iOS + Android. ✅ The make-or-break **`drive.file` cross-client spike PASSED**
(2026-07-06, §6) — the auth model is validated, no fallback needed. Next: step 2 (`FileRelayTransport`).
Durable engineering plan for a **cloud relay** transport:
the phone uploads each captured photo to the user's **Google Drive**, and the Mac watches/pulls and feeds
the same `CaptureSession.ingest` path. This is the **wireless alternative to the wired (USB) transport** —
the two transports we commit to maintaining. Read `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` for the connectivity
history and the shipped LAN/USB/diagnostics work; read **this** to build the cloud path.

This file is **Tier-2** (`Net/` + the phone↔Mac contract + the never-lose-a-photo path) per `CLAUDE.md` —
adversarial review before shipping, both companions kept in sync.

---

## 0. Strategic decision (2026-07-06) — consolidate to two fallback transports

Live Capture's **happy path stays LAN Wi-Fi** (QR pairing, phone → Mac `CaptureServer` directly) — it needs
no network switching and keeps the Mac on venue Wi-Fi, so **when the venue network permits device-to-device
it "just works" and nothing here is needed** (see the connectivity plan's "assume-not-hostile" analysis).
The problem is only **client/AP isolation** — common on guest/managed institutional Wi-Fi — which blocks two
clients from reaching each other. For that case we commit to **exactly two fallbacks, no more**:

1. **USB (`adb reverse`)** — *already shipped.* Wired, Android-only, local, fast; Mac stays on venue Wi-Fi.
2. **Google Drive cloud relay** — *this plan.* Wireless, both platforms, works even off-site; Mac stays on
   venue Wi-Fi.

**Explicitly rejected (do not build / maintain), with the reason each fails our constraints:**
- **Mac personal hotspot** — the Mac becomes the AP and **loses its own venue Wi-Fi + internet** (a
  Wi-Fi-only Mac can't be client and AP on one radio). Showstopper: no live OCR.
- **Phone personal hotspot** — forces the **Mac off venue Wi-Fi onto the phone's cellular**; reading rooms
  frequently have **terrible cell coverage**, so the Mac's internet (OCR) becomes unreliable. Poor fit.
- **iOS MultipeerConnectivity / Network.framework AWDL P2P** — iOS-only, and adds a *specialized* transport
  to build and maintain for one platform. We chose to **not** carry a peer-to-peer stack; cloud covers iOS
  too. (If a future reason demands a local infra-less iPhone path, prefer **Network.framework
  `includePeerToPeer`** over MultipeerConnectivity — same AWDL radio, standard socket — but it is **out of
  scope here**.)
- **Bluetooth** — far too slow for full-res photos (~150–250 KB/s Classic; BLE worse → tens of seconds per
  multi-MB image) and third-party iOS apps can't use Bluetooth Classic to a non-MFi Mac at all.

**Guiding priorities (owner, 2026-07-06):** reliability first; **the Mac must not lose venue Wi-Fi for
extended periods**; cellular data cost is **not** a concern; **privacy is not a concern** for this data path;
minimize the number of options to maintain.

---

## 1. Why cloud relay satisfies every constraint

Client isolation blocks **device-to-device**, but it does **not** block **device-to-internet**. So:
- The **phone uploads to Drive over its own internet** (venue Wi-Fi if present, else cellular) — no
  connection to the Mac required.
- The **Mac pulls from Drive over venue Wi-Fi** and runs OCR there.
- **Neither device leaves venue Wi-Fi, neither depends on the other's radio, and client isolation is
  irrelevant** because nothing goes directly between the two devices.
- Bonus: it is the **only** option that also works when the two devices aren't co-located at all (off-site
  capture, later processing).

The cost is a cloud round-trip (added latency + one-time auth setup), addressed below. Because per-capture
streaming (Workstream S, shipped) uploads in the background as you shoot, the operator is not blocked waiting.

---

## 2. Backend choice — Google Drive (default), with an escape hatch

**Default: Google Drive**, per the owner decision. Rationale: users already have Google accounts; it fits
the existing **BYO-Google-key** onboarding (Gemini) and the "managed access / BYO keys" initiative; 15 GB
free is ample for a *transient* relay buffer (the Mac deletes each object after durable receipt, so
steady-state storage is tiny); and the least-privilege **`drive.file`** scope avoids Google's sensitive-scope
security audit. No infrastructure for the owner to run.

**Assumption — a Google *account*, not the Drive *desktop app*.** This design uses the **Google Drive REST
API** (OAuth 2.0 + HTTPS: `files.create` resumable upload, `changes.list`, media `files.get`, `files.delete`)
embedded in the app on **every** platform. It does **NOT** require "Google Drive for desktop," a mounted
Drive volume, or any synced local Drive folder on the Mac — nothing is installed or synced. The only
requirement on each device (Mac + phone) is a **signed-in Google account** (an in-app OAuth sign-in; token in
the Keychain). This keeps the footprint to an embedded API client and is what makes the same design work
identically on Mac, iOS, and Android.

**Honest wrinkles vs. an S3-compatible object store — and how each is handled (all reduce to *latency/code*,
not *data loss*):**

| Drive limitation | Impact | Mitigation in this design |
|---|---|---|
| **Listing is eventually consistent** (a new file may not appear in `files.list` immediately) | The Mac might not see a just-uploaded photo for a few seconds | Use the **Changes feed** (`changes.getStartPageToken` → poll `changes.list`), not raw `files.list`; poll-until-visible. Never-lose holds because the phone keeps its local copy until receipt — lag ≠ loss. |
| **No atomic key-overwrite** (`files.create` always makes a *new* file) | A naive re-send would duplicate | Idempotent re-send = **query-or-update**: the phone stores the returned `fileId` in its durable queue and uses `files.update` (media) on re-send; on crash-recovery it queries by `appProperties`. **The Mac dedups by `(group,seq)` in `ingest` regardless**, so a stray duplicate is absorbed. |
| **No native TTL / lifecycle** | Orphaned objects could accumulate | The Mac **deletes each source object after durable ingest + receipt**; plus a periodic **orphan sweep** (age + sessionToken). |
| **OAuth per platform + consent screen** | Real setup effort | One-time; `drive.file` keeps the app out of sensitive-scope verification. See §6. |
| **API quotas / rate limits** | 403 on bursts | Exponential backoff (the phone's existing auto-retry already backs off); poll the changes feed at a modest interval. |

**Escape hatch (design for it, don't build it now):** put the backend behind a **`CloudBackend` interface**
(§3) so a **small S3-compatible store (Cloudflare R2 / Backblaze B2 / GCS)** can be swapped in without
touching the transport, queue, or ingest logic. An object store removes *all four* wrinkles above (atomic PUT
overwrite, strong read-after-write, native lifecycle TTL, presigned URLs → no OAuth). **Reconsider trigger:**
if Drive's consistency/idempotency handling proves fragile in the §10 tests, or Google's app-verification/
quota blocks the intended distribution, switch the default `CloudBackend` to R2/B2. Until then, Drive is the
default and the only backend we build.

---

## 3. Architecture — reuse the existing durable seam (don't reinvent it)

The relay is a **new transport behind the abstraction the connectivity plan already specifies** — the
durable disk queue, retry, and `ingest` durability contract are reused **unchanged**.

**Prerequisite refactor (not yet built — do this first, it's independently reviewable):**
- **Phones:** introduce `SegmentTransport` with the methods the queue already calls —
  `ping`, `postPhoto`, `sessionComplete`, `sendSegmentComplete` — and make `CaptureViewModel.client` that
  type. Today's direct-HTTP `MacClient` (Android `net/MacClient.kt`, iOS `Net/MacClient.swift`) becomes the
  `HttpTransport` implementation; `DriveRelayTransport` is a second implementation. The durable queue
  (`enqueueUpload` / `resumeUploads` / `startAutoRetry`) is transport-agnostic and untouched.
- **Mac:** define a `CaptureReceiver` role. `Net/CaptureServer.swift` (HTTP/`NWListener`) is the existing
  receiver; add `Net/CloudRelayReceiver.swift` as a second. **Every receiver calls `CaptureSession.ingest(...)`
  and only acks on a non-nil return** — inheriting the durable-manifest-before-ack, idempotent-`(group,seq)`,
  backup-folder, and `clearFiled`-on-finalize behavior for free.

**Data flow:**
```
 phone shutter ─▶ durable disk queue ─▶ SegmentTransport = DriveRelayTransport
                                              │  (resumable upload of JPEG + appProperties)
                                              ▼
                                    ┌──────────────────────┐
                                    │  Google Drive folder  │  Archive Processor Live Capture/<token>/
                                    │  <group>__<seq>.jpg   │
                                    └──────────┬───────────┘
                                               │ Changes feed (poll)
                                               ▼
 Mac CloudRelayReceiver ─▶ download media ─▶ CaptureSession.ingest(...)  (temp→rename, idempotent (group,seq),
                                               │   durable manifest BEFORE ack)
                                               ├─ ingest returns non-nil (durable) ─▶ write receipt ─▶ delete source object
                                               └─ phone observes receipt ─▶ mark item UPLOADED (safe to delete local copy)
```

---

## 4. Object model & key scheme (in the user's Drive)

- **Session folder:** `Archive Processor Live Capture/<sessionToken>/` — created by the Mac in cloud mode.
  User-visible on purpose (mirrors the app's user-visible backup-folder philosophy; the operator can see the
  relay staging and recover from it). `<sessionToken>` is the existing stable 6-char session token, reused as
  the namespace.
- **Photo object:** name `<group>__<seq>.jpg`. Metadata in **`appProperties`** (private to the app):
  `{ kind:"photo", token, group, seq, type, priority, year, month, device, replaces }` — the same fields the
  HTTP `X-*` headers carry today, so the receiver's mapping into `ingest` is identical.
- **Segment-complete control object:** `<group>.segment.json` with
  `appProperties { kind:"segment-complete", token, group, priority, year, month }` — the cloud equivalent of
  `POST /segment/complete`. Carries the segment's tags and signals completion (drives the Mac's
  `completedDocGroups` gate so the tag card appears only for a finished segment — same as HTTP today).
- **Session-complete control object:** `_session.complete` with `appProperties { kind:"session-complete",
  token }` — cloud equivalent of `POST /session/complete` (marks all open doc groups complete).
- **Receipt:** the Mac, after a durable ingest, sets `appProperties.received="true"` on the photo object
  **and/or** writes `<group>__<seq>.receipt` (tiny, `appProperties { kind:"receipt", token, group, seq }`).
  The phone observes the receipt to mark the item `UPLOADED`. The Mac then deletes the photo object; a sweep
  later removes stale receipts.

(No `session/disconnect` analog is needed — cloud has no "connection" to drop; Re-pair just switches config.)

---

## 5. Lifecycle & protocol (streaming preserved end-to-end)

**Per photo (as shot — streaming, from Workstream S):**
1. Shutter → item enqueued in the durable disk queue (unchanged).
2. `DriveRelayTransport.postPhoto` performs a **resumable upload** (`files.create` with
   `uploadType=resumable`) of the JPEG + `appProperties`. Resumable upload survives a network drop mid-file
   (resume the same session URI). Store the returned `fileId` on the queue item.
3. The item stays `PENDING/UPLOADING` — **not** `UPLOADED` — until the Mac's receipt is observed (step 8).

**End segment:** `sendSegmentComplete` writes the `<group>.segment.json` control object (tags). Idempotent —
re-writing the same segment-complete is a safe no-op replace. (Per the shipped residual-refinement plan,
defer this until every page of the segment is confirmed `UPLOADED` so the Mac never finalizes a partial
segment — same rule as HTTP.)

**Finish session:** `sessionComplete` writes `_session.complete`.

**Mac receiver loop (`CloudRelayReceiver`):**
4. On cloud-mode start: `changes.getStartPageToken`, persist it (survives Mac restart → resumable).
5. Poll `changes.list` (interval ~2–4 s) for new/changed files under the session folder with matching
   `appProperties.token`. For each **photo** object not already processed:
6. Download media → map `appProperties` → `CaptureSession.ingest(...)`.
7. **If `ingest` returns non-nil (durable):** write the **receipt** (§4), record `(group,seq)` (and `fileId`)
   in a **processed set** persisted in the staging manifest, then **delete** the source photo object. If
   `ingest` returns nil, **do not** receipt/delete — leave it for the next poll (the phone still holds its
   copy). For **segment-complete / session-complete** control objects: apply to the session
   (`markSegmentComplete` / `completeAllOpenDocGroups`), then delete.
8. **Phone** observes the receipt (its own poll, or piggy-backed on its retry loop) → marks the item
   `UPLOADED` → safe to delete its local copy.

**Idempotency & double-processing guards:**
- Re-sent photo → phone `files.update` on the stored `fileId` (or the Mac dedups by `(group,seq)` if a
  duplicate object appears).
- Mac restart after ingest-but-before-delete → the persisted **processed set** prevents a second `ingest`;
  the Mac just re-writes the receipt and re-attempts the delete (delete is idempotent).
- Orphan sweep: periodically delete session objects older than a threshold whose `(group,seq)` is in the
  processed set (covers receipts and any objects whose delete failed).

---

## 6. Auth & pairing

**Both devices authenticate to the *same Google account* independently** (no credential ever travels between
them or sits in the QR). Scope: **`drive.file`** (per-file; app sees only what it created — the relay
objects). Tokens live in **Keychain** (Mac, iOS) / **EncryptedSharedPreferences or AccountManager**
(Android). Refresh tokens handled by the platform Google auth libs.
- **Android:** Google Sign-In / AppAuth + the Drive REST client.
- **iOS + Mac:** `GoogleSignIn` SDK or `ASWebAuthenticationSession` (PKCE) + the Drive REST endpoints.

**Cloud pairing (works with zero device-to-device connectivity — the whole point):**
1. Mac in **cloud mode**: sign in to Google, create `…/<sessionToken>/`, and display a **cloud QR** encoding
   **non-secret** coordination only: `{ mode:"cloud", token:<sessionToken>, folderId:<driveFolderId>,
   account:<email hint> }`.
2. Phone: scan the QR (a purely *visual* channel — needs no network), then sign in to Google **as the same
   account** (the email hint disambiguates), and begin uploading into `folderId`.
3. Re-pair simply re-scans / re-selects the mode; no disconnect signal needed.

**✅ VALIDATED 2026-07-06 (spike passed — no longer a risk).** A two-Desktop-client loopback-OAuth spike
(project `YOUR_GCP_PROJECT`, single test-user account, `drive.file` scope) confirmed that a **different OAuth
client** can **`get` metadata, `list` by `appProperties`, download media, and `delete`** a file **created by
another client** in the same project — all HTTP 200/204. So `drive.file` access is **per-project, not
per-client**: the Mac's Desktop client can fully manage what the phone's iOS/Android client uploads. **No
fallback needed** (the app stays on the non-sensitive `drive.file` scope; no `drive.appdata`, no full `drive`).
_Fallbacks retained for reference only, should Google ever change this: (a) Mac creates the folder, phone
writes inside it; (b) `drive.appdata`; (c) full `drive` scope (sensitive → verification)._

---

## 7. Never-lose-a-photo — invariant mapping & recovery matrix

The invariant is preserved by the **same rule as HTTP**: *the phone deletes its only local copy of a photo
only after the Mac is durably holding it.* Concretely:
- Phone keeps the local copy until it observes the **receipt** (Mac's durable ack). Drive PUT success alone is
  **not** sufficient (the object could be lost/deleted before the Mac pulls).
- Mac writes the manifest **before** acking (inside `ingest`), and **deletes the source object only after**
  `ingest` returns non-nil.
- Idempotent `(group,seq)` replace + the Mac's persisted processed-set make every step safely retryable.

| Failure | What happens | Why nothing is lost |
|---|---|---|
| Phone crash mid-upload | Resumable session incomplete | Local copy intact; queue re-uploads on relaunch |
| Phone loses the stored `fileId` | Can't `files.update` | Re-`create`; Mac dedups by `(group,seq)` |
| Network drop (phone) | Upload stalls | Durable queue + auto-retry (existing); resumable upload resumes |
| Drive object deleted before receipt | Mac never pulled it | Phone hasn't seen a receipt → still holds local copy → re-uploads |
| Mac crash after `ingest`, before delete | Object still in Drive | Processed-set (persisted) prevents double-ingest; re-writes receipt + retries delete |
| Mac crash after receipt, before delete | Object + receipt in Drive | Phone already safe (saw receipt); orphan sweep deletes later |
| Both offline | Nothing moves | Phone queue holds everything; resumes when either reconnects |
| Drive storage quota full | Uploads 403 | Backoff + surface a clear "Drive full" error; **buffer stays on the phone (not lost)**; Mac keeps draining, freeing space |
| OAuth token expired | 401 | Silent refresh; if refresh fails, prompt re-sign-in; queue holds items meanwhile |

---

## 8. Consistency, rate limits, quota

- **Detection:** persist the Changes-feed `startPageToken` (it doesn't expire → resumable across Mac
  restarts). Poll `changes.list` every ~2–4 s while a cloud session is active; on each response advance to
  `newStartPageToken`. (`changes.watch` webhooks are unusable — they need a public HTTPS endpoint the Mac
  behind NAT can't provide.)
- **Consistency lag:** if a segment-complete arrives before all its photos are visible, **wait** — don't
  finalize until the expected `(group,seq)` set is present (the phone also defers segment-complete until its
  pages are `UPLOADED`, per §5). Poll-until-visible; lag is latency, never loss.
- **Rate limits (403 userRateLimitExceeded/rateLimitExceeded):** exponential backoff with jitter (the phone's
  auto-retry already does this; mirror it in the Mac poller).
- **Storage quota:** steady-state is small because the Mac deletes after receipt. Guard the pathological case
  (Mac offline/slow, buffer grows): cap the phone's in-flight-to-cloud count and **warn** when the buffer or
  Drive nears full; the Mac frees space as it drains. Surface Drive-quota errors explicitly.

---

## 9. Settings & UX (per the `settings-ux-convention`)

- **Transport selection** in the Live Capture pane / Settings: LAN (default) · USB · **Cloud (Google Drive)**.
  Each control gets a **`?` help popover** and **grays out when irrelevant** (e.g. cloud controls disabled
  until signed in), per the project convention.
- **Google sign-in** button + **signed-in account** display; **relay-folder** display with an **"Open in
  Drive"** affordance that opens the folder's `webViewLink` in the **browser** (drive.google.com) — not a
  local Drive app — mirroring the intent of the Mac's existing "Backup Folder" reveal.
- **Live status:** queued / uploading / received counts, so the operator can see the relay draining (mirrors
  the existing progress UI; keep it live — see the stale-status `KNOWN_ISSUES` entry).
- **Explicit copy (privacy transparency, even though privacy isn't a blocker here):** *"Photos are uploaded to
  your Google Drive and deleted automatically once the Mac confirms it has them."* Default **OFF / opt-in**.
- Mac **Settings pane** for the backend + credentials in **Keychain**, mirroring the existing gateway/BYO-key
  UX.

---

## 10. Testing (Tier-2) — build the contract auth-free first

1. **`FileRelayTransport` + `FileRelayReceiver` FIRST (no cloud auth).** The "cloud" is a **local shared
   directory** implementing the same `CloudBackend` contract: the phone-side writes objects + control files
   + reads receipts; the Mac-side watches the directory, ingests, receipts, deletes. This exercises the
   **entire** key scheme, idempotency, ordering, receipt/ack, and delete-on-durable logic with **zero
   external dependencies** — and doubles as the offline unit test + a CI-able Tier-2 fixture (extend
   `scripts/test-tier2.sh`).
2. **`drive.file` cross-device spike** (§6 VALIDATE-FIRST) before writing the Drive backend.
3. **Drive integration** on a throwaway test Google account: upload/download roundtrip; **resumable-upload
   interruption**; **listing-lag** (poll-until-visible); **idempotent re-send** (no duplicate after the Mac's
   `(group,seq)` dedup); **receipt-before-delete**; **orphan sweep**; **token refresh**.
4. **Invariant interrupt matrix (§7)** run against both `FileRelayReceiver` and the real Drive backend:
   interrupt after PUT-before-receipt (phone retries, Mac dedups); after Mac-ingest-before-delete (no
   double-ingest); Drive object deleted out from under the phone before receipt (phone re-uploads).
5. **Both companions match**, and **Tier-2 adversarial review** (find→refute) before shipping — `Net/` +
   the phone↔Mac contract + the never-lose-a-photo path.

---

## 11. Effort & risk

- **Effort: L–XL.** The transport/receiver refactor is Medium; the `CloudBackend` + `FileRelayTransport` is
  Medium; **per-platform Google OAuth + the Drive resumable-upload/changes-feed client is the real schlep**
  (three platforms). Settings/UX + tests round it out.
- **Risk: high surface** (`Net/` + protocol + data-safety) → **Tier-2**. De-risked by (a) building the whole
  contract behind `FileRelayTransport` with zero auth, and (b) the Mac-side `(group,seq)` dedup as a backstop
  that makes duplicate/late cloud objects harmless.

---

## 12. Sequencing & concrete first step

1. ✅ **`SegmentTransport` (phones) refactor — DONE** (`74ed9f0`, build-verified iOS + Android). The Mac-side
   `CaptureReceiver` role is folded into step 2 (below), where `FileRelayReceiver` gives it a real second
   implementation. (Still to do while in `Net/`: reconcile the Bonjour service-name mismatch.)
2. **`CloudBackend` interface + `FileRelayTransport` + `FileRelayReceiver`** → full relay flow validated
   **offline** (§10.1).
3. ✅ **`drive.file` cross-device spike — DONE, PASSED** (2026-07-06, §6). Auth model validated; proceed.
4. **`DriveBackend`** — OAuth (per platform), resumable upload, Changes-feed poller, receipts, delete + sweep.
5. **Settings/UX** — transport selector, Google sign-in, folder display, status, opt-in copy (§9).
6. **Tier-2 review + integration/invariant tests** (§10), both companions, then ship behind the opt-in.

**Concrete first step:** the **`SegmentTransport` refactor + `CloudBackend`/`FileRelayTransport`** (steps 1–2).
That makes the entire relay contract — key scheme, idempotency, receipts, delete-on-durable, the never-lose
invariant — **testable end-to-end with no Google account and no network**, and is the seam the Drive backend
simply drops into. Prove the contract locally before spending a line on OAuth.

---

## 13. Cross-references
- `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` — connectivity history; shipped LAN/USB/P0/P1; the rejected-transport
  analysis this plan acts on. (Its P2/P3 sections are **superseded** by this decision: P2 dropped; P3
  concretized here as Google-Drive-specific.)
- `KNOWN_ISSUES.md` — the residual Workstream-S refinements (defer segment-complete until pages `UPLOADED`;
  `needsResend`; `completedDocGroups` persistence) apply to the cloud transport too.
- `CLAUDE.md` — Tier-2 review policy, shared-hotspot rules (change the protocol on all sides together),
  XcodeGen/Gradle build notes, `settings-ux-convention`.
- `NEXT_STEPS.md` — roadmap index.

---

## Implementation status — Drive backend (2026-07-06)

The FileRelay contract (the offline stand-in) is fully proven (see `LIVE_CAPTURE_FILERELAY_SPEC.md`: Mac
receiver 8/8 invariants, iOS+Android golden byte-match, iOS transport contract 6/6). The **real Google Drive
backend (Mac side) is now built and compile/mock-verified**, behind the same proven `RelayObjectStore` seam:

- **`Net/DriveClient.swift`** — Drive REST v3 client behind an injectable `HTTPExecuting` seam (mockable).
- **`Net/DriveObjectStore.swift`** — `RelayObjectStore` over Drive (name↔fileId via `appProperties.relayName`,
  create-or-update idempotent overwrite, list/delete/quarantine, dedup-reap of coexisting same-name files by
  rev). Drops into `FileRelayReceiver` UNCHANGED, so the never-lose contract is inherited. **Unit-tested vs a
  mock Drive: `scripts/test-drive-store.sh` — 10/10.** **✅ LIVE-VALIDATED against real Google Drive
  (2026-07-07): `scripts/test-drive-live.sh` — 10/10** (OAuth bearer, multipart create, files.list appProperties
  queries, media get, delete, quarantine, overwrite, epoch, dedup-reap; auto-cleans up). So the Drive REST
  integration + auth are proven, not just mocked — the mock matched reality.
- **`Net/DriveAuth.swift`** — OAuth: autonomous access-token refresh + owner-gated loopback `signIn` (PKCE).
- **`CaptureSession`** — `.cloud` transport wired (lazy `cloudRelay`); LAN path byte-identical.
- Adversarial review of this code: `Workflow` run `wf_2b89755d-278` (Drive-quirk lenses).
- **Note:** `listNames` uses `files.list` (eventually consistent); the plan's Changes-feed optimization
  (`DriveClient.startPageToken`/`listChanges` are implemented) can replace it later. Multipart upload is used
  (not resumable) — the receipt-wait + idempotent retry already give interruption-resilience.

### Remaining — OWNER-GATED (needs a browser + a live Google account; not automatable/testable headless)
1. **Configure the OAuth client in-app.** Set `DefaultsKeys.driveClientId` = the Desktop client id and store
   the Desktop client secret in the Keychain (account `DriveClientSecret`). (Project `YOUR_GCP_PROJECT`; the
   `drive.file` cross-client spike already PASSED.)
2. **Sign in once** (`DriveAuth.signIn`) — a browser opens; approve; the refresh token persists in the Keychain.
   Fix the PKCE note if the loopback server needs the exact registered port (Desktop clients accept loopback).
3. **Phone `DriveRelayTransport` (iOS + Android)** — DEFERRED: needs an on-device Google OAuth SDK
   (GoogleSignIn / AppAuth) added to each project + a phone Drive REST client. Mirror `FileRelayTransport`
   (swap the shared dir for Drive REST). Not built overnight (untestable + external deps).
4. **Live integration test** — with a real account: set `liveTransport=cloud`, capture, confirm each page
   round-trips Drive → the Mac's `ingest` + backup folder, receipts appear, sources auto-delete after durable,
   and the never-lose invariants (Run C) hold end-to-end. This is the real verification the headless work defers.
