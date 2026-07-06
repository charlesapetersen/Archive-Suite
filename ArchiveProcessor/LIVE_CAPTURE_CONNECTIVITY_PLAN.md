# Live Capture Connectivity — Implementation Plan

**Created 2026-07-06. Status: not started.** Durable engineering plan for the two connectivity
threads flagged in `KNOWN_ISSUES.md` ("Wi-Fi pairing fails silently when the network blocks
device-to-device") and `POTENTIAL_FEATURES.md` ("Live Capture transport — bypass networks that block
device-to-device"). This file is the actionable expansion of those two entries — read them for the
motivation; read this to build.

**Scope:** (1) make the failure legible + actionable (near-term), and (2) add transport bypasses for
networks with client/AP isolation. Both companions must stay in sync. `Net/` and the phone↔Mac
protocol are **Tier-2 (adversarial review before shipping)** per `CLAUDE.md`. The **"never lose a
photo" invariant** (durable disk queue + idempotent re-upload) must hold for every new transport.

---

## 0. Current connect flow — ground truth (cite before you change)

### The QR / pairing payload (Mac → phone)
- The Mac builds a JSON payload `{host, port, token, name}` in
  `ArchiveProcessor/Sources/ArchiveProcessor/Views/LiveCaptureView.swift:179-188` (`pairingPayload`).
  `host` = `primaryIPv4()` (`LiveCaptureView.swift:343-363`), which returns **only** the `en0`/`en1`
  IPv4 (prefers `en0`). `port` = `session.listenPort`. `token` = `session.token` (stable 6-char code,
  `CaptureSession.swift:72-82`). Rendered as a QR at `LiveCaptureView.swift:331-340`; the raw
  `ip:port` is also shown as selectable text (`LiveCaptureView.swift:162-166`).
- Server: `Net/CaptureServer.swift` — `NWListener` on fixed port **48627** (`CaptureServer.swift:30`,
  falls back to a system port if busy). Routes `GET /ping`, `POST /photo`, `POST /session/complete`,
  all Bearer-authed (`CaptureServer.swift:192-249`). `GET /ping` calls `session.markPaired()` and
  returns `200 {ok:true}`; a bad token → `401`; unknown route → `404`.
- The Mac already advertises a Bonjour service `_archivecap._tcp` (`CaptureServer.swift:47`) but no
  companion browses it today (they dial the explicit IP from the QR).
- USB: `Net/USBBridge.swift` keeps `adb reverse tcp:<port> tcp:<port>` asserted on a 5 s timer
  (`USBBridge.swift:14-26`), so a USB-tethered Android phone reaches the Mac at `127.0.0.1:<port>`.
  Auto-started in `CaptureSession.serverDidStart` (`CaptureSession.swift:158`).

### Android connect flow
- `ui/ConnectScreen.kt`: `ModeChooser` (`:50-66`) asks **Wired vs Wi-Fi** first, then `Pairing`
  (`:68-120`) shows the camera + a one-shot `QrAnalyzer` (`net/QrAnalyzer.kt`). On decode →
  `vm.connectFromQr(payload, wired) { ok -> connecting = false; if (ok) onConnected() }`
  (`ConnectScreen.kt:90-95`).
- `capture/CaptureViewModel.kt`: `connectFromQr` (`:173-179`) parses via `MacEndpoint.fromQrPayload`
  and, if `wired`, rewrites host to `127.0.0.1` keeping the QR's port+token. `connect` (`:156-171`)
  does `withContext(Dispatchers.IO) { MacClient(ep).ping() }`; on success saves the endpoint
  (`Prefs`) + sets `client`; on failure sets `statusMessage = "Could not reach $host:$port"`.
- `net/MacClient.kt`: `ping()` (`:18-24`) uses OkHttp with **5 s connectTimeout / 30 s callTimeout**;
  returns `Boolean` (any exception → `false`).
- **The silent-failure trap (Android):** on AP isolation the TCP SYN is dropped → `ping()` times out
  at ~5 s → `statusMessage` shows a terse *"Could not reach host:port"* with **no cause, no fallback**.
  Worse, `QrAnalyzer.done` latches `true` on the first decode (`QrAnalyzer.kt:18,37-38`) and the
  analyzer is a single `remember { … }` instance (`ConnectScreen.kt:89`), so **re-pointing at the QR
  never re-fires** — the scanner is a dead end with no retry.
- Gate: `MainActivity.kt:24` shows `CaptureScreen` iff `vm.endpoint != null`. Re-pair =
  `vm.disconnect()` (`CaptureViewModel.kt:181-185`), reachable from `CaptureScreen.kt:126,238-246`.

### iOS connect flow
- `UI/ConnectScreen.swift`: "Scan QR code" presents `QRScannerView` (`:48-60`); on decode it
  **dismisses the sheet immediately** then `run { await vm.connectFromQR(payload) }` (`:51-52`).
  `run` (`:69-76`) shows `ProgressView("Connecting…")` and, on failure, sets
  `errorText = "Couldn't connect. Make sure your phone and Mac are on the same Wi-Fi network."`
- `Capture/CaptureViewModel.swift`: `connectFromQR` (`:60-63`) → `connect` (`:45-58`) →
  `await MacClient(endpoint: ep).ping()`; success saves endpoint + sets `client`.
- `Net/MacClient.swift`: `makeRequest` hardcodes **`timeoutInterval: 30`** (`:10`) for *every* request
  including `ping()` (`:20-24`); returns `Bool`.
- **The silent-failure trap (iOS):** on AP isolation the user watches a "Connecting…" spinner for
  **up to ~30 s**, then gets a **misleading** message telling them to check they're on the same Wi-Fi
  (they are — the AP is isolating clients). Re-scan works (the sheet is recreated each present, so
  `QRScannerView.Coordinator.handled` resets), but the guidance is wrong and the wait feels dead.
- Gate: `ContentView.swift:7` shows the scanner iff `vm.endpoint == nil`. Re-pair = `vm.disconnect()`
  (`CaptureViewModel.swift:65-69`), from `CaptureScreen.swift:48,123-128`.

### The Mac ingest path (why the invariant is transport-agnostic)
- Every received photo funnels through `CaptureSession.ingest(...)`
  (`Capture/CaptureSession.swift:177-215`): temp→rename write, **idempotent replace on (groupId, seq)**
  (`:194`), then `writeManifest()` — and it **withholds the success ack (returns nil → 500) until the
  grouping metadata is durably persisted** (`:211`), so the phone only deletes its sole copy of an
  un-retakeable photo after the Mac is durable. This is the invariant's linchpin and it is **not**
  HTTP-specific: any new receiver that calls `ingest` and only acks on a non-nil return inherits it.

### The transport seam that already exists (use it for P2/P3)
Both companions hold `client: MacClient?` and call **only three methods** — `ping`, `postPhoto`,
`sessionComplete` — from a transport-agnostic durable queue (`enqueueUpload` / `resumeUploads` /
`startAutoRetry`; Android `CaptureViewModel.kt:336-368`, iOS `CaptureViewModel.swift:204-256`). That
narrow surface is the natural seam: introduce a `SegmentTransport` protocol/interface with those three
methods and make `client` that type. HTTP stays the default impl; MC (P2) and cloud relay (P3) are
drop-in impls that leave the queue, retry, and dedup logic untouched.

---

## Cross-cutting decisions (apply to every phase)

- **Keep the two companions in sync.** Every user-visible string, timeout, and state machine below is
  specified once and implemented on **both** Android (`ArchiveCapture/`) and iOS
  (`ArchiveCaptureiOS/`). A change to the phone↔Mac contract touches `CaptureServer.swift` **and** both
  `MacClient`s in the same commit (`CLAUDE.md` shared-hotspot rule).
- **Tier-2 review.** Anything under `Net/` or the protocol gets adversarial review before shipping.
- **Never lose a photo.** New transports must (a) keep the phone's durable disk queue, marking an item
  `UPLOADED` **only** on confirmed receipt, and (b) deliver into `CaptureSession.ingest` (or an
  equivalent that writes the durable manifest *before* acking). Idempotent (group, seq) replace must
  survive resend.
- **Build.** Mac + iOS via XcodeGen (`xcodegen generate` after adding files; never hand-edit
  `.pbxproj`); Android via Gradle. Per-worktree DerivedData for concurrent work.

---

## Workstream S — Per-capture streaming (DATA SAFETY, HIGHEST PRIORITY)

**This is separate from connectivity (it's about *when* photos upload, not *how* devices connect) and it
outranks every phase below.** See the `[HIGH — data safety]` entry in `KNOWN_ISSUES.md`.

**Problem (verified 2026-07-06, USB Process-live):** a captured photo's **bytes stay on the phone until
the operator taps "End segment."** One shot did not reach the Mac (empty backup folder) until End segment;
box/folder markers, being 1-photo segments, *did* upload immediately. A document segment can be
**hundreds of photos** — so a phone crash / drop / dead battery / app-kill before End segment loses **all**
of them. That violates Live Capture's core "never lose a photo" promise.

**Required behavior:** each photo's bytes transfer to the Mac and land in the durable backup folder **as
it is captured** (streamed continuously), via the existing durable disk-queue + auto-retry + idempotent
`(group,seq)` re-upload. **"End segment" becomes purely the logical/visual grouping** — the moment the
on-phone thumbnails "leave" and the document boundary is confirmed — and must NOT gate byte transfer. By
End segment the Mac already holds every page; it just finalizes the segment.

**Where to change (find the current upload trigger first):** on each companion the capture VM currently
enqueues/POSTs on *segment finish* rather than per shutter — Android `capture/CaptureViewModel.kt`
(`finishDocumentSegment` path + the durable queue) and its `net/MacClient.postPhoto`; iOS
`Capture/CaptureViewModel.swift` + `Net/MacClient.postPhoto`. Move the enqueue-to-transport to the
shutter/capture callback (Android `addDocumentPhoto`, iOS equivalent), and keep the page's thumbnail in
the strip until End segment — in the Mac's `CaptureSession.ingest`, idempotent `(group,seq)` replace +
durable-manifest-before-ack already support mid-segment streaming.

**KEY DESIGN CORRECTION (verified in code 2026-07-06 — this is more than "tweak the UI"):** the Mac
presents the per-segment tag card via `pendingTagGroup = groups.first { .document && !resolvedGroupIds }`
(`CaptureSession.swift:279`). Today the whole segment arrives at End segment, so that group is already
complete when the card appears. **With streaming, a document group exists after page 1**, so the tag card
would pop **mid-segment**. Fix: the Mac must know when a document segment is *complete*. Add a tiny
**segment-complete signal** the phone sends at End segment — and have it **carry the segment's tags**
(priority/year/month) so it solves completion-timing *and* tag attachment in one message, with **no photo
re-upload**:
- **Protocol:** `POST /segment/complete` (auth) with `X-Group` + optional `X-Priority`/`X-Year`/`X-Month`.
  (Mirror on both companions' `MacClient`.)
- **Mac `CaptureSession`:** track `completedDocGroups: Set<String>`; on the signal, apply the tags to that
  group's already-received photos (update manifest metadata) and insert the group. Gate
  `pendingTagGroup` to `.document && completedDocGroups.contains(id) && !resolvedGroupIds.contains(id)` so
  the tag card appears **only** for a completed segment — preserving today's "card at End segment" UX.
  Also mark all still-open doc groups complete on `POST /session/complete` (Finish) so the last segment's
  card still shows if the operator finishes without ending it. `Net/CaptureServer.swift` routes the new
  endpoint.
- **Phone:** `applyTagsAndContinue` (End segment) → send the segment-complete signal (with tags) instead
  of re-uploading pages; remove the segment's icons once it's acked. `resumeUploads`/auto-retry now
  include document PENDING pages (they stream), and the segment-complete signal is itself
  retryable/idempotent (re-applying tags to the same group is a no-op-safe replace).
- **Crash recovery:** a page streamed but its segment-complete not yet sent → on the phone the pages are
  still shown (current group), operator ends the segment again → signal re-sent; on the Mac the pages are
  durable (bytes + manifest) and simply await the completion signal. Bytes are never lost either way.

**Rejected simpler alternatives:** (a) re-POST every page with tags at End segment — doubles the transfer
for a hundreds-of-photo segment; (b) infer completion from "a newer group started" — breaks for the last
segment and for old clients. The explicit signal is both necessary (tag-card timing) and cheapest.

**Effort: M. Risk: HIGH surface (Net/ + phone↔Mac protocol + the never-lose-a-photo path) → Tier-2
adversarial review; both companions must match.**

**Acceptance test:** during a 100+ shot segment the Mac backup folder fills **continuously** as shots are
taken (not in one burst at End segment); force-killing the phone mid-segment loses nothing already shot
(the already-captured pages are on the Mac + in the backup folder); re-connecting re-uploads only what
wasn't acked, with no duplicates. Sequence w.r.t. connectivity: do this **alongside P1** (both touch the
same upload/queue path) and before P2/P3, since any new transport must preserve it.

---

## Phase P0 — Personal-hotspot guidance + Mac-side hint (near-zero code)

**Goal:** give the operator a working escape hatch *today*, purely with copy + one Mac signal.
**Effort: S. Risk: very low (copy + a timer-driven label; no protocol change).**

### Changes
- **Mac hint (`LiveCaptureView.swift`).** In the *"Pair the phone"* GroupBox (`:152-171`), when
  `session.serverRunning && !session.paired`, add a caption after the `ip:port` line:
  > *"Phone not connecting? This Wi-Fi may block device-to-device connections (common on
  > public / guest / hotel networks). Fixes: use a **USB cable** (Android), or turn on a **personal
  > hotspot** (from the phone or the Mac) and join both devices to it."*
  Drive it off a "haven't paired within ~20 s of the server going ready" signal — `session.paired` is
  already set on first `/ping` or `/photo` (`CaptureServer.swift:204`, `CaptureSession.swift:206`), so
  add a `@Published serverReadyAt: Date?` set in `serverDidStart` and show the hint when
  `serverRunning && !paired && now - serverReadyAt > 20s`. No protocol change.
- **Mac: show all candidate IPs.** `primaryIPv4()` returns only `en0/en1`. On a hotspot the active
  interface may differ (e.g. `bridge100` when the Mac *is* the hotspot). Add a `allIPv4Candidates()`
  helper and, in the hint, list every non-loopback IPv4 so the operator can try an alternate in manual
  entry. (Keep the QR on the primary; this is a fallback affordance.)
- **Android copy (`ConnectScreen.kt`).** Extend the `ModeChooser` footnote (`:61-64`) and add a line
  under the Wi-Fi pairing screen: *"On public/guest Wi-Fi that hides devices from each other, use the
  USB cable, or turn on a personal hotspot and join both to it."*
- **iOS copy (`ConnectScreen.swift`).** Add the same one-liner under the subtitle (`:19`).
- **Docs.** Add a short "If the phone won't connect" subsection to `README.md` Live Capture (near
  `:205`) listing USB → personal hotspot → (future relay).

### Test (no blocked network needed)
- Mac: `session.start()`, never pair a phone, confirm the hint appears after ~20 s and disappears the
  instant a phone pings (drive with `curl -H "Authorization: Bearer <token>" http://<ip>:48627/ping`
  using the token printed by `LIVECAPTURE_READY`, see §Testing harness).
- Positive control: actually put a Mac + phone on the phone's personal hotspot and confirm the
  existing LAN path pairs — proves the guidance is correct, not just present.

---

## Phase P1 — Reachability preflight + honest diagnostics (the core near-term fix)

**Goal:** the phone never sits on a dead scanner; on failure it names the **cause** and the
**fallbacks**, and offers a clean **retry**. Implemented identically on both companions.
**Effort: M. Risk: medium — touches `Net/` client code (Tier-2), but the server is unchanged; only
the client's interpretation of the existing responses changes.**

### Design (shared state machine)
Introduce an explicit connect phase on each VM:
```
enum ConnectPhase {
  case idle
  case connecting(host: String, port: Int)      // "Found pairing code — connecting to <ip>:<port>…"
  case unreachable(host: String, port: Int)      // timeout / connection dropped  → isolation message
  case refused(host: String, port: Int)          // TCP RST (server down/wrong port) → "start server" msg
  case unauthorized(host: String, port: Int)     // reached Mac but 401 → "code rejected / re-scan QR"
  case connected
  case badQR                                     // payload didn't parse
}
```
The distinction matters: **unreachable** (drop/timeout) is the AP-isolation case that should show the
transport-fallback message; **refused** means the server isn't listening; **unauthorized** means the
token is stale. Today `ping()` collapses all of these to `false`.

### Changes — both companions
1. **Enrich `ping()` to a typed result** (client-only; server already returns the right status codes).
   - **iOS `MacClient.swift`:** add `func reachability() async -> ConnectResult` that inspects the
     thrown `URLError` (`.timedOut`/`.cannotConnectToHost`/`.networkConnectionLost` → unreachable vs
     refused) and the `HTTPURLResponse.statusCode` (200 → ok, 401 → unauthorized). Give the preflight
     a **short timeout (~3–4 s)** via a dedicated `URLRequest(timeoutInterval:)` — do **not** shorten
     the 30 s used for `postPhoto` uploads (`makeRequest` is shared; parametrize the timeout).
   - **Android `MacClient.kt`:** add a preflight `OkHttpClient` with `connectTimeout(3s)` +
     `callTimeout(4s)` and a `reachability()` returning the same result enum by catching
     `SocketTimeoutException` (→ unreachable) vs `ConnectException`/RST (→ refused) and checking
     `code == 401` (→ unauthorized).
2. **Drive the UI from `ConnectPhase`.**
   - Show *"Found pairing code — connecting to <ip>:<port>…"* the instant the QR decodes (before the
     network call), so there's immediate feedback.
   - On `.unreachable`: *"Can't reach the Mac at <ip>:<port>. This Wi-Fi may block device-to-device
     connections (common on public/guest/hotel networks). Try: a USB cable (Android), a personal
     hotspot, or check the Mac's Live Capture tab is listening."* Include the future-relay line once P3
     ships.
   - On `.refused`: *"Reached the network but nothing is listening at <ip>:<port>. Is Live Capture
     started on the Mac?"*
   - On `.unauthorized`: *"Reached the Mac but the pairing code was rejected. Re-scan the QR (it may be
     stale)."*
   - On `.badQR`: *"That QR isn't an Archive Processor pairing code."*
3. **Clean retry.**
   - **Android:** the one-shot `QrAnalyzer` must be resettable. Add `fun rearm() { done = false }`
     (`QrAnalyzer.kt`) and call it when the user taps a new **"Scan again"** button after a failure —
     otherwise the scanner stays dead (current bug). Alternatively recreate the analyzer via a
     `key(attempt)` on the `remember`.
   - **iOS:** keep the scanner sheet open (or re-present it) on failure and overlay the diagnostic +
     a **"Try again"** button, instead of dismissing to a bare error.
4. **iOS local-network-permission case.** iOS's first local-network connection triggers the system
   permission prompt; if the user denied it, connections fail like isolation. In the `.unreachable`
   branch add: *"If you tapped Don't Allow on the local-network prompt, enable it in Settings ▸ Archive
   Capture ▸ Local Network."* (No reliable API to read the grant; surface it as advice.)

### Test (simulate unreachability without a blocked network)
- **Unreachable / timeout (the AP-isolation case):** manual-connect the phone to
  **`192.0.2.1:48627`** (TEST-NET-1, RFC 5737 — guaranteed unroutable; SYN is black-holed → a real
  timeout, exactly like client isolation). Assert the phone reaches `.unreachable` in ~3–4 s and shows
  the isolation message + Scan-again.
- **Refused:** point at a reachable host on a closed port (e.g. the Mac's IP on `:1` or the Mac with
  the server **stopped**) → fast RST → assert `.refused`.
- **Unauthorized:** run the real server, manual-connect with the right host/port but a **wrong token**
  → `401` → assert `.unauthorized`.
- **Success + latency:** real pairing; assert the preflight resolves quickly and the "connecting…"
  string appears before the result.
- **Android retry regression:** scan once against `192.0.2.1` (fails), then tap Scan-again and scan a
  valid QR — assert it now connects (proves `rearm()` fixed the latched-`done` dead end).
- **Optional Mac-side block:** an `pfctl`/Application-Firewall rule dropping inbound `48627` reproduces
  isolation with a real server present, if you want an end-to-end drop rather than a bogus IP.

---

## Phase P2 — Peer-to-peer transport (no infrastructure Wi-Fi)

**Goal:** connect the two devices directly, independent of the access point, so AP isolation is moot.
**Effort: L. Risk: medium-high — new transport, new pairing path, Tier-2.**

### Critical asymmetry (decide before building)
- **iOS ↔ Mac: feasible** via **MultipeerConnectivity** (both are Apple; MC works on macOS + iOS over
  AWDL/peer-Wi-Fi/Bluetooth with no router). This is the real P2P win.
- **Android ↔ Mac: no shared framework.** Wi-Fi Direct and Nearby Connections are Google-only and have
  **no macOS peer** to talk to. The only Android bypasses that don't need infrastructure Wi-Fi are:
  (a) the phone's **personal hotspot** (already P0), or (b) Android **Wi-Fi Direct / Local-Only
  Hotspot as a soft-AP** that the *Mac joins as an ordinary Wi-Fi client* — which forces a manual Mac
  network switch and is essentially the hotspot UX with extra fragility.
- **Recommendation:** implement true P2P **for iOS only** (MultipeerConnectivity). For Android, make
  the personal-hotspot path (P0) first-class and *don't* invest in Wi-Fi Direct soft-AP unless a
  no-hotspot Android requirement appears. Document the asymmetry in-app so expectations match.

### Changes — the transport abstraction (prerequisite, do this first)
1. **iOS:** define `protocol SegmentTransport { func ping() async -> ConnectResult; func postPhoto(...)
   async -> Bool; func sessionComplete() async -> Bool }`. Make `MacClient` conform. Change
   `CaptureViewModel.client` to `SegmentTransport?`. The durable queue is now transport-agnostic.
2. **Android:** the mirror — an `interface SegmentTransport` with the same three methods; `MacClient`
   implements it; `CaptureViewModel.client` becomes `SegmentTransport?`.
3. **Mac:** define a `CaptureReceiver` role; `CaptureServer` is the HTTP receiver. All receivers call
   `session.ingest(...)` and only ack on a non-nil return (preserves the durability contract).

### Changes — iOS MultipeerConnectivity transport
- New `ArchiveCaptureiOS/.../Net/MultipeerTransport.swift`: an `MCSession` + `MCNearbyServiceBrowser`
  that finds the Mac's advertiser, invites, and sends each photo as a framed message
  (**metadata JSON header {group, seq, type, priority, year, month, device, replaces} + JPEG bytes**,
  or `MCSession.send(...)` with a small header then the resource). `ping` = "is a peer connected".
  `postPhoto` = send + await the Mac's per-photo ack message (mirror the HTTP 200/500 semantics so the
  queue only marks `UPLOADED` on ack). `sessionComplete` = a control message.
- New `ArchiveProcessor/.../Net/MultipeerReceiver.swift`: `MCNearbyServiceAdvertiser` +
  `MCSession` on the Mac; on each received framed message, call `session.ingest(...)` and send back an
  ack keyed by (group, seq) **only if `ingest` returned non-nil**. Authorize the invitation with the
  same 6-char `session.token` (carried in the MC discovery info / invitation context) so pairing still
  uses the QR-shown code.
- **Pairing:** reuse the QR — extend the payload with a `transport` hint and, for MC, a service name;
  the phone offers "Wi-Fi (LAN)" and "Direct (no network)" and picks the transport. Token unchanged.
- **Config:** iOS `project.yml` — MC needs a Bonjour service entry for the MC service type in
  `NSBonjourServices` and `NSBluetoothAlwaysUsageDescription`; `NSLocalNetworkUsageDescription` already
  present. **Note the latent bug to fix while here:** `NSBonjourServices` currently declares
  `_archiveproc._tcp` (`project.yml:36`) but the Mac advertises `_archivecap._tcp`
  (`CaptureServer.swift:47`) — harmless today (iOS dials the explicit IP, doesn't browse) but must be
  reconciled before any mDNS/MC discovery relies on it. Mac side: add the MC service type to the app's
  entitlements/Info if required and ensure the sandbox allows it (the Mac app is ad-hoc signed).

### Test (no blocked network needed)
- Two Apple devices (Mac + iPhone) with **Wi-Fi joined to a router that has client isolation OR with
  the router powered off entirely** — MC uses AWDL/Bluetooth and should still connect. The cheapest
  lab repro: turn the Mac + iPhone Wi-Fi **off** and rely on Bluetooth/AWDL, or use a phone hotspot
  that the Mac does *not* join (devices see each other via MC directly).
- Invariant test: kill the Mac app mid-transfer, relaunch, confirm the phone re-sends unconfirmed
  items over MC and the Mac dedups by (group, seq) — same manifest-recovery path as HTTP.
- Ack-loss test: drop the ack on the Mac for one photo, confirm the phone retries and the Mac replaces
  idempotently (no duplicate, no loss).

---

## Phase P3 — Cloud relay (works anywhere, incl. off-site)

**Goal:** phone uploads each segment to a cloud store; the Mac watches/pulls and feeds the same ingest
path. Works across any network and even when the devices aren't co-located.
**Effort: L–XL. Risk: high — third-party data path (privacy), new auth, Tier-2. Owner-gated.**

### Owner decision required before building
Archival photos would transit third-party storage. Per `POTENTIAL_FEATURES.md` this is a **privacy
call the owner must make** and it fits the existing **"managed access / BYO keys"** initiative. Ship it
**opt-in only**, with explicit copy: "Photos are uploaded to <your cloud> and deleted after the Mac
confirms it has them." Default OFF. Do not enable without the owner's decision.

### Design
- Relay = another `SegmentTransport` on the phone + a `CloudRelayReceiver` poller on the Mac. Object
  key scheme: `archivecap/<sessionToken>/<group>/<seq>.jpg` + a sidecar `<seq>.json`
  (group, seq, type, priority, year, month, device, replaces). **Idempotency:** re-upload overwrites
  the same key; the Mac dedups by (group, seq) — the existing `ingest` replace logic already handles
  this. **Never-lose-a-photo:** the phone marks `UPLOADED` only after the object store confirms the PUT
  *and* (ideally) the Mac writes a small receipt object the phone can observe; keep the local JPEG
  until then. The Mac deletes the cloud object only after `ingest` returns non-nil (durable locally).
- **Backend options, cheapest-integration first:**
  1. **User's own cloud (BYO):** Google Drive / Dropbox / iCloud Drive folder — a shared folder the
     phone writes to and the Mac watches. Fits BYO-keys; zero server to run. Downside: OAuth per
     provider, rate limits, eventual-consistency listing.
  2. **Small object store (S3/R2/GCS):** cleanest semantics (atomic PUT, strong-read-after-write,
     lifecycle TTL for auto-cleanup). Needs a bucket + scoped credentials the owner provisions.
- **Pairing:** the LAN QR can't carry cloud coordinates safely as plaintext; either (a) pair
  LAN-first then push relay config to the phone over the existing channel, or (b) encode a short relay
  handle + scoped token in a dedicated relay QR. Reuse the 6-char token as the namespace secret.

### Changes
- Phone: `CloudRelayTransport` (both companions) implementing `SegmentTransport`; a settings toggle +
  BYO-credential entry; the durable queue is reused unchanged.
- Mac: `Net/CloudRelayReceiver.swift` — poll/subscribe, pull new objects, call `session.ingest(...)`,
  ack via receipt object + delete source on durable success. A settings pane for the relay backend +
  credentials (Keychain), mirroring the existing gateway/BYO-key UX.
- Docs + privacy copy; App-Store data-safety implications noted in `POTENTIAL_FEATURES.md` Phase 4.

### Test (no cloud creds needed)
- Implement a **`FileRelayTransport`** first: the "cloud" is a local shared directory; the phone writes
  objects there and the Mac's receiver watches it. This exercises the entire key scheme, idempotency,
  ordering, ack/receipt, and delete-on-durable logic **with zero cloud auth** — and doubles as the
  offline unit test for the relay contract.
- Then swap in a local **MinIO** (S3-compatible) container to validate the real object-store path
  (atomic PUT, listing, TTL) before touching a hosted provider.
- Invariant tests: interrupt after PUT-but-before-receipt (phone must retry, Mac must dedup);
  interrupt after Mac-ingest-but-before-delete (must not double-ingest on the next poll).

---

## Recommended sequencing & first step

1. **Ship P1 + P0 together first** — highest value per unit effort. P1 turns both silent-failure
   traps into an actionable screen; P0's copy/Mac-hint ride along for free. Do the **iOS diagnostics
   first** (worst offender: ~30 s dead spinner + a *wrong* "same Wi-Fi" message), then Android
   (fix the latched-`QrAnalyzer` dead end + the terse message), keeping strings identical.
2. **Then the transport abstraction** (`SegmentTransport` on both phones, `CaptureReceiver` on the
   Mac) as a behavior-preserving refactor — it unblocks P2/P3 and is independently reviewable.
3. **P2 iOS MultipeerConnectivity** for true infra-less pairing; keep Android on hotspot/USB.
4. **P3 cloud relay** last, and only after the owner's privacy decision; build behind
   `FileRelayTransport` for testing.

**Concrete first step:** implement P1 on iOS — add `ConnectResult`/`ConnectPhase`, a short-timeout
`reachability()` in `MacClient.swift` that distinguishes timeout / refused / 401 / ok, and rework
`ConnectScreen.swift` to show *"connecting to <ip>:<port>…"* → a cause-named message + "Try again",
then mirror it on Android (including `QrAnalyzer.rearm()`), and add the Mac "not paired yet" hint in
`LiveCaptureView.swift`. Validate entirely with the `192.0.2.1` / wrong-port / wrong-token triad
described in P1 — no blocked network required. Tier-2 review before shipping.

---

## Testing harness reference (how to drive the Mac server headlessly)

- Launch the Mac app with `LIVECAPTURE_AUTOSTART=1`; `CaptureSession.serverDidStart`
  (`CaptureSession.swift:150-156`) writes a line `LIVECAPTURE_READY port=<p> token=<t> folder=<path>`
  to stderr and (if set) to `LIVECAPTURE_READYFILE`. Read the token+port from there to script
  `curl`/`nc` probes and to build a valid QR payload for a device test.
- `Capture/LiveCaptureTestDriver.swift` drives the live-staging path. Note the coverage gap called out
  in `CLAUDE.md`: the batch/instance GUI path isn't exercised by it — add targeted coverage if a
  change reaches into `startProcessing → finalize`.
- Simulated-unreachability cheat sheet: `192.0.2.1:<port>` = timeout (isolation); Mac IP + closed port
  or server stopped = refused (RST); real server + wrong token = 401 unauthorized; real server + right
  token = success.
