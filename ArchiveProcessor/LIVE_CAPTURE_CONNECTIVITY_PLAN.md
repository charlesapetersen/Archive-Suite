# Live Capture Connectivity — Implementation Plan

**Created 2026-07-06. Last updated 2026-07-06.** Durable engineering plan for the two connectivity
threads flagged in `KNOWN_ISSUES.md` ("Wi-Fi pairing fails silently when the network blocks
device-to-device") and `POTENTIAL_FEATURES.md` ("Live Capture transport — bypass networks that block
device-to-device"). This file is the actionable expansion of those two entries — read them for the
motivation; read this to build.

## Status (as of 2026-07-06)

Workstream **S**, **P0**, and **P1** shipped the same day this plan was written (commits `d7d2fc3` +
`c7ecc00`) — so this is **no longer a from-scratch plan**; it is now the record of what landed plus the
open work (P2/P3 + on-device verification). Each phase below carries a status banner.

| Phase | What | State |
|-------|------|-------|
| **S** | Per-capture streaming (data safety) | ✅ **Implemented** (`c7ecc00`) — build-verified on Mac + Android + iOS; Tier-2 adversarial review done (a **critical data-loss race** was found and guarded via `clearFiled`). Residual refinements tracked in `KNOWN_ISSUES.md`. |
| **P0** | Hotspot guidance + Mac hint + all-IPv4s | ✅ **Implemented** (`d7d2fc3`/`c7ecc00`). Deviation: the hint shows whenever the server is running, not on a 20 s "not paired yet" timer — see P0. |
| **P1** | Reachability preflight + honest diagnostics | ✅ **Implemented** (`c7ecc00`, Tier-2) — typed result on all companions; Android `QrAnalyzer.rearm()`; a `POST /session/disconnect` Re-pair signal was added too. |
| — | **On-device Wi-Fi + Run C walkthrough** | ⏳ **OWED — top remaining task.** S/P0/P1 are build-verified only, never run on a phone over Wi-Fi (`NEXT_STEPS.md`, `LIVE_CAPTURE_ANDROID_TEST.md`). |
| **P2** | Peer-to-peer transport | ❌ **Dropped (2026-07-06)** by the two-transport consolidation — iOS-only + a specialized stack to maintain. See `LIVE_CAPTURE_CLOUD_TRANSPORT_PLAN.md` §0. |
| **P3** | Cloud relay | 🔵 **Chosen & concretized as a Google Drive relay** in `LIVE_CAPTURE_CLOUD_TRANSPORT_PLAN.md`. Owner: privacy is **not** a concern for this path (was the gate). |

**"Use AirDrop / Quick Share instead?"** — evaluated 2026-07-06; **not a viable transport** (no automation
API, a manual per-file Accept, and Android has no macOS peer at all). See
[§ Evaluated & rejected: AirDrop / Quick Share](#evaluated--rejected-airdrop--quick-share-as-a-transport).

> **⭐ Transport decision (2026-07-06): consolidated to two fallbacks — USB (shipped) + a Google Drive cloud
> relay.** **P2 (peer-to-peer) is dropped**, and personal-hotspot is demoted to last-resort (it forces the
> Mac off venue Wi-Fi onto often-unreliable reading-room cell). The cloud path is specified in detail in
> **`LIVE_CAPTURE_CLOUD_TRANSPORT_PLAN.md`**, which **supersedes P2/P3 below**. Rationale: reliability first,
> few options to maintain, the Mac must keep venue Wi-Fi, privacy is not a concern. LAN Wi-Fi remains the
> zero-config happy path whenever the network permits device-to-device.

**Scope:** (1) make the failure legible + actionable (near-term) — **done (P0/P1)**; and (2) add transport
bypasses for networks with client/AP isolation — **now scoped to the Google Drive cloud relay** (see the
dedicated plan). Both companions must stay in sync. `Net/` and the phone↔Mac
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
  falls back to a system port if busy). Routes, all Bearer-authed: `GET /ping` (`:203`), `POST /photo`
  (`:207`), `POST /segment/complete` (`:242` — **added by Workstream S**, carries `X-Group` + tags),
  `POST /session/complete` (`:258`), `POST /session/disconnect` (`:267` — **added for the Re-pair
  signal**). `GET /ping` calls `session.markPaired()` and returns `200 {ok:true}`; a bad token → `401`;
  unknown route → `404`.
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
- **The silent-failure trap (Android) — ✅ FIXED by P1 (`c7ecc00`); retained here as the original diagnosis:** on AP isolation the TCP SYN is dropped → `ping()` times out
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
- **The silent-failure trap (iOS) — ✅ FIXED by P1 (`c7ecc00`); retained here as the original diagnosis:** on AP isolation the user watches a "Connecting…" spinner for
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

> ✅ **IMPLEMENTED 2026-07-06 (`c7ecc00`) — build-verified on Mac + Android + iOS; Tier-2 adversarial
> review done.** Pages stream as shot; End segment sends `POST /segment/complete` (`CaptureServer.swift:242`)
> carrying the tags; the Mac gates its tag card on `completedDocGroups` (`CaptureSession.swift:24`, computed
> `:299-301`, populated by `markSegmentComplete` `:315` / `completeAllOpenDocGroups` `:323`). The review found
> a **critical data-loss race** — a still-uploading page finalized out, then `session.clear()` deletes its
> only copy — now **guarded** by `CaptureSession.clearFiled` (`:252`), which deletes only pages actually filed
> into output and keeps any straggler. **Owed:** on-device Run C verification + the residual refinements now
> tracked in `KNOWN_ISSUES.md` ("Per-capture streaming — implemented; residual refinements": straggler
> omitted-from-output, `needsResend` for P10/reclassify in-flight, `completedDocGroups` persistence). The spec
> below is retained as the build reference.

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

> ✅ **IMPLEMENTED 2026-07-06 (`d7d2fc3`/`c7ecc00`).** Mac client-isolation hint + `allIPv4Candidates()`
> (`CaptureSession.swift:410`, shown in `LiveCaptureView.swift:177-195`) so the operator can try an alternate
> address in manual entry; hotspot/USB fallback copy on both companions. **Deviation from the spec below:** the
> hint shows whenever `session.serverRunning` (`LiveCaptureView.swift:213`), **not** gated on a 20 s
> `serverReadyAt` "haven't paired yet" timer — that `@Published serverReadyAt` was never added. Simpler; if the
> always-on hint proves noisy in practice, add the timer as originally specified.

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

> ✅ **IMPLEMENTED 2026-07-06 (`c7ecc00`, Tier-2).** Short-timeout reachability preflight returning a typed
> result on every companion — iOS `ConnectResult` (`MacClient.swift:8`) + `reachability(timeout:3.5)` (`:37`)
> and a `ConnectPhase` state machine (`CaptureViewModel.swift:8-15`, `@Published` `:34`); Android
> `Reachability { OK, UNAUTHORIZED, REFUSED, UNREACHABLE }` (`MacClient.kt:12`) + `reachability()` (`:38`).
> These drive cause-named messages (unreachable / refused / unauthorized) + a "Try again" retry
> (`ConnectScreen.swift:78,87,89,100`; Android `CaptureViewModel.kt:155,165-174`). Android `QrAnalyzer.rearm()`
> (`QrAnalyzer.kt:23`) fixes the latched-scanner dead end. A `POST /session/disconnect`
> (`CaptureServer.swift:267`) Re-pair signal was added alongside so the Mac re-shows its QR. **Companions
> diverged slightly:** iOS uses the full `ConnectPhase` enum; Android the flatter `Reachability` enum
> (functionally equivalent messages) — fine, but note it if you touch both. The iOS upload timeout stays 30 s;
> only the preflight is short (`MacClient.swift:15-17`). **Owed:** on-device Wi-Fi verification (the build-time
> check was the `192.0.2.1`/closed-port/wrong-token triad below). The spec + tests below are retained.

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

## Evaluated & rejected: AirDrop / Quick Share as a transport

**Question (2026-07-06):** "Mac and Android now have AirDrop / an AirDrop equivalent — could that work
around Wi-Fi that blocks device-to-device?" **Verdict: not as an automatable transport for Live Capture —
but the intuition about the *radio* is correct, and it is exactly what P2 harnesses.** Documented in full
here so the question doesn't get re-opened.

### What actually exists in 2026 (checked, not assumed)
- **AirDrop is Apple-only** and has **no third-party send API**. `NSSharingService`/`sendViaAirDrop` and
  `UIActivityViewController` can *offer* AirDrop, but there is **no API to pick the recipient** (the user
  taps a device in a picker) and **the recipient must manually Accept every transfer**. Custom app-to-app
  payloads open in **Files.app / Photos, not the sending app's peer** — bypassing the Mac's
  `CaptureSession.ingest` (the durable-manifest-before-ack path).
- **Quick Share (Android) now interoperates with AirDrop — and it *does* reach Macs.** Google shipped this on
  the **Pixel 10** series (Nov 2025), expanding to more Android devices through 2026 (Google reverse-engineered
  AirDrop's protocol; Apple made no changes). It works Pixel→Mac: on the phone *Share → Quick Share → pick the
  Mac*; on the Mac you must first set AirDrop to **"Everyone for 10 minutes"** (or be in contacts) and then
  **manually Accept** the incoming file. Crucially it is a **system share-sheet feature with no
  third-party/programmatic API** — an app cannot drive it. (There is still **no general Quick Share macOS
  client**; the only other Mac option is the unofficial, receive-only NearDrop.)

### Why it can't back Live Capture (either platform)
Live Capture streams pages **continuously and unattended**, and the Mac must ingest each into the durable
backup folder via `ingest` (idempotent `(group,seq)`, ack-on-durable) so "never lose a photo" holds.
AirDrop / Quick-Share-to-AirDrop fails every one of those:
1. **Manual, per-transfer.** A human tap-to-send on the phone **and** a tap-to-Accept on the Mac, for each
   transfer — impossible for a hundreds-of-photo segment streaming as it is shot. It reverts to a
   batch-at-End-segment hand-off — exactly the data-loss shape **Workstream S** removed.
2. **No API to drive it.** Neither platform exposes a programmatic send an app can call in a loop; both are OS
   share UIs.
3. **Lands in the wrong place.** Received files go to the Mac's **Downloads/Photos**, not into the app — so
   `ingest`, the `(group,seq)` dedup, the tag/priority metadata, and the ack contract are all bypassed. Back to
   loose files with no idempotency and no delivery guarantee.
4. **Device-limited on Android.** The interop is **Pixel-10-class / 2026 flagships**, not general Android — it
   can't be the companion's baseline transport.

### The kernel of truth: it *is* P2 (and it softens the Android asymmetry slightly)
AirDrop and Quick-Share-to-AirDrop ride a **peer-to-peer radio with no access point** (Apple AWDL / a
compatible P2P Wi-Fi link), so they genuinely **do** sidestep the client/AP isolation that breaks LAN pairing
— the instinct is right. The way to *program against that radio* on iOS↔Mac is **`MultipeerConnectivity`**
(the same AWDL/peer-Wi-Fi/Bluetooth stack, but with delivery callbacks, framed messages, and no manual
Accept) — i.e. **exactly Phase P2**. Building P2 is how we get AirDrop's bad-network immunity *without* its
un-automatable UX.

For **Android↔Mac**, the Quick-Share-to-AirDrop interop means newer Androids finally *have* a manual
peer-to-peer path to a Mac (previously there was none) — but with **no API it is still not a transport we can
build on**. The P2 recommendation is unchanged: **iOS gets true P2P via MultipeerConnectivity; Android stays
on USB + personal hotspot** for programmatic transfer.

### The one legitimate (manual, degraded) use — document, don't build
An operator on a hostile network *could* finish a segment and **manually Quick-Share/AirDrop the batch** to the
Mac, with the Mac watching `~/Downloads`. That is a hand-driven, local flavour of P3's watched-folder relay:
manual taps, skips the streaming + ingest invariant, Pixel-10-class-only on Android — an **emergency stopgap
worth a line in the docs**, not a transport to build. **Net: pursue P2 (MultipeerConnectivity) for the iOS
peer-to-peer win; do not build on AirDrop / Quick Share directly.**

_(Verified 2026-07-06 via Google Pixel "Quick Share to iPhone/Mac" pages + Pixel support threads, 9to5Google's
supported-device list, MacRumors/AppleInsider interop coverage, and Apple's `NSSharingService` docs.)_

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

## Recommended sequencing & next step

1. ~~**Ship P1 + P0 together first.**~~ ✅ **Done (`c7ecc00`)** — together with **Workstream S** streaming,
   build-verified on Mac + Android + iOS with a Tier-2 adversarial pass (which caught and guarded a critical
   data-loss race). The old "first step" (P1 on iOS + mirror on Android) is shipped.
2. **⏳ NEXT — on-device Wi-Fi + Run C walkthrough (no new code).** S/P0/P1 have never run on a phone over
   Wi-Fi — the original walkthrough was USB-only because the venue Wi-Fi had client isolation. Validate
   pairing + the "never lose a photo" failure cases on a **trusted network / personal hotspot** before
   building any new transport (a new transport must preserve exactly what this pass confirms). Script:
   `LIVE_CAPTURE_ANDROID_TEST.md` (Run A §A1 + Run C), then the iPhone walkthrough. In the same pass, close
   the **residual Workstream-S refinements** in `KNOWN_ISSUES.md` (straggler omitted-from-output;
   `needsResend` for per-page P10 / reclassify while a page is in-flight; `completedDocGroups` persistence).
3. **Then the transport abstraction** (`SegmentTransport` on both phones, `CaptureReceiver` on the Mac) as a
   behavior-preserving refactor — **still not started**; it unblocks P2/P3 and is independently reviewable.
   Reconcile the **Bonjour service-name mismatch** here (`ArchiveCaptureiOS/project.yml:36` `_archiveproc._tcp`
   vs Mac `_archivecap._tcp` at `CaptureServer.swift:47`) before any mDNS/MC discovery relies on it.
4. **P2 iOS MultipeerConnectivity** for true infra-less pairing (the real, automatable "AirDrop-like" win —
   see the AirDrop/Quick-Share evaluation above); keep Android on hotspot/USB.
5. **P3 cloud relay** last, and only after the owner's privacy decision; build behind `FileRelayTransport`.

**Concrete next step:** run the **on-device Wi-Fi + Run C walkthrough (#2)** to confirm S/P0/P1 on a real phone
over Wi-Fi — that is the gating item now, since the build-time validation (the `192.0.2.1`/closed-port/
wrong-token triad in P1) is already done. When ready to build again, start **P2 with the
`SegmentTransport`/`CaptureReceiver` refactor (#3)**.

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
