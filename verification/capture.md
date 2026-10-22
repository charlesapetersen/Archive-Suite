# Capture companions — Android and iOS

Format and statuses: [`README.md`](README.md). The parity comparison below was written by `W40.i2`, 2026-10-21;
the feature ledger (`C-` rows, [§Feature ledger](#feature-ledger) at the end) by `W40.b4`, the same day.

- **What was compared:** the Android companion (`ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/`,
  with its JVM tests) and the iOS companion (`ArchiveProcessor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/`), each
  read in full. Below, `A/` is the Android path and `I/` the iOS one.
- **Read at:** `b26e6cf5`. Nothing was run: the iOS app builds (`W40.i1`), but no simulator runtime is installed, so
  the iOS behaviour below is from reading the code. That is enough for a *missing* feature, because the absence can
  be seen in the code. Behaviour that depends on the platform and needs a device or simulator to confirm went to
  [`SUSPECTS.md`](SUSPECTS.md) (S-021 to S-023), not to the queue (rule 5).
- **Promises it was measured against:** `ArchiveProcessor/README.md` §Live Capture and `ArchiveProcessor/CLAUDE.md`
  §Primary Function 3 both say the two phones offer the same workflow over the same protocol ("pick whichever phone
  you have"), and both promise that a photo is never lost before the Mac's durable ack. `SPEC/relay-object-format.md`
  is the wire contract for both.
- **Result:** the two phones put **the same bytes on the wire**. The gaps are all on the phone side, and nearly all
  of them are in iOS: it has **none of the data-safety fixes Android got while iOS was parked** (2026-07-18 to
  2026-10-21). Three of the gaps can lose an unsent photo (S1). Eleven gaps were filed as `W40.i-fix-*` items.
  One Android defect turned up as well (S-021).

## Wire contract — the same on both

Checked constant by constant, because a divergence here would corrupt data on the Mac.

| Item | Android | iOS | Verdict |
|---|---|---|---|
| Relay object names (`<g>__<seq>.jpg/.json/.receipt.json`, `<g>.segment.json`, `_session.complete.json`, `_epoch.json`) | `A/net/RelayObjectFormat.kt:14-19` | `I/Net/RelayObjectFormat.swift:11-16` | same |
| Canonical JSON (nil dropped, keys sorted, the same escape set, `\u%04x` lowercase) | `kt:23-52` | `swift:19-49` | same |
| Fingerprint (SHA-256 of `{type,quality,year,month,replaces}`, first 8 bytes in hex) | `kt:56-60` | `swift:52-56` | same |
| Sidecar, segment and session object fields | `kt:62-76` | `swift:59-76` | same |
| Receipt acceptance (kind, token, epoch, group, seq, fp must all match) | `FileRelayTransport.kt:42-51`, `DriveRelayTransport.kt:54-61` | `FileRelayTransport.swift:35-42`, `DriveRelayTransport.swift:40-44` | same |
| Drive folder and file lookup by `appProperties` (`relayToken`, `relayName`) | `DriveRelayTransport.kt:26-40` | `DriveRelayTransport.swift:22-31` | same |
| HTTP routes and headers (`/ping`, `/photo` + `X-Group/Seq/Type/Device/Quality/Year/Month/Replaces`, `/segment/complete` + `X-Seqs`, `/phone/status` + `X-Pending`, `/session/complete`, `/session/disconnect`) | `A/net/MacClient.kt:30-126` | `I/Net/MacClient.swift:29-113` | same |
| Quality values (`Q1`–`Q3`, none for Unrated, long-press sends `Q3`) | `SegmentTagSheet.kt:103` | `SegmentTagSheet.swift:61` | same |
| Group id | `g` + 8 lowercase hex | `g` + 8 lowercase hex (was uppercase) | **aligned** by `W40.i-fix-ios-polish` (2026-10-21) |
| `segmentComplete` when the Drive write fails | returns `true`: `upsert` swallows the error | returns `false` and retries | **Android defect**, S-021 |

The guards already covering this: Android `RelayObjectFormatTest` (golden bytes); on iOS,
`scripts/test-relay-golden.sh` and `scripts/test-relay-fuzz.sh` (Mac against iOS bytes).

## Fixes made on Android only while iOS was parked

The parked rule (`SUITE_TODO.md` §iOS parity) was "fix Android only and record the iOS twin". `W23.m1` is the one
fix recorded that way; the others below were Android-only fixes from the same period whose records do not mention
iOS, so each was checked against the iOS code.

| Android fix | What it did | iOS today | Filed as |
|---|---|---|---|
| `W23.m1` (2026-07-30) | a pairing generation on every send, so a reply from the Mac just unpaired from cannot mark a page delivered and delete the phone's copy | absent: `disconnect()` (`I/Capture/CaptureViewModel.swift:148`) leaves uploads running, and their reply still marks the page uploaded | `W40.i-fix-ios-pairing-generation` |
| `W23.m8` (2026-07-30) | `SessionStore.save` reports failure; a durable stale marker; pages recovered against a stale session are held for review | was absent (`SessionStore.save` ignored errors); now `save` returns whether the snapshot landed, a `capture-session.stale` flag is set before each write, and pages recovered against a stale session are held for review (`SessionStore.swift`, `CaptureQueue.adoptOrphans`) | **fixed** by `W40.i-fix-ios-session-durability` (2026-10-21) |
| manifest fallback (2026-07-12) | a fallback no longer deletes the last good session before the new one is written | iOS writes `.atomic` and has no fallback path, so this case does not arise | none |
| pending count (2026-07-12) | auto-retrying FAILED pages count as pending, so they hold the Mac's Finish | was absent (the heartbeat counted only pending and uploading, though auto-retry resends FAILED pages); now it counts every page the Mac must still receive, failed and pending-resend included (`CaptureQueue.heartbeatCount`) | **fixed** by `W40.i-fix-ios-heartbeat-count` (2026-10-21) |
| Clear race (2026-07-12) | Clear cancels and joins uploads, and item ids are never reused | was absent (`nextId = 1`, uploads left running); now Clear moves a generation on, cancels the sends and never reuses an id, and a reply from an older generation records nothing (`CaptureQueue.clear`, `CaptureViewModel.clearSession`) | **fixed** by `W40.i-fix-ios-clear-generation` (2026-10-21) |
| thumbnails off the UI thread (2026-07-12) | | already off the main thread (`I/UI/CaptureScreen.swift:225`) | none |
| Quality `Q1`–`Q3` cutover (2026-09-03) | | iOS sends the same values | none |
| `W23.h4` (2026-07-30) | delete confirmation for an unsent page, and a recoverable save-and-delete | **iOS had the guard first** (2026-07-09); Android caught up. The parts Android added beyond it were not on iOS; now they are (`CaptureQueue.requiresDeleteConfirmation`, `stopUploadThenRetire`, `CaptureViewModel.performDelete`) | **fixed** by `W40.i-fix-ios-delete-confirm` (2026-10-21) |

## Feature by feature

| Area | Android | iOS | Verdict |
|---|---|---|---|
| Where photos are kept | `filesDir/capture/` (`A/capture/CaptureViewModel.kt:33`) | was `cachesDirectory/capture/`, which iOS may empty when storage runs low; now Application Support/`capture/`, excluded from backup (`SessionStore.swift`) | **fixed** by `W40.i-fix-ios-photo-storage` (2026-10-21) |
| Restoring the session after the app is killed | skips items whose file is gone (`A/data/SessionStore.kt:124`); a pending resend is kept over an uploaded state | stored each photo's absolute file URL (the container path changes on reinstall, every seven days on a free account), never checked the file, and pruned a page whose resend was pending. Now stores the file name only, skips and reports a missing file with a "Photos missing" alert, and restores a pending resend as pending (`CaptureQueue.restore`) | **fixed** by `W40.i-fix-ios-photo-storage` (2026-10-21) |
| Clear session | bumps a session generation, cancels and waits for uploads, never reuses ids (`CaptureViewModel.kt:876-899`) | reset ids to 1 with uploads still running, so a late reply marked a *new* photo with the same id as uploaded; now bumps a generation, cancels the sends (without awaiting: the main actor serialises, and the generation check drops a late reply) and never reuses an id | **fixed** by `W40.i-fix-ios-clear-generation` (2026-10-21) |
| Re-pairing while uploads run (`W23.m1`) | see above | see above | **gap, S2** → `W40.i-fix-ios-pairing-generation` |
| "Phone still has N to send" heartbeat | counts every unconfirmed page; one ordered, conflated writer (`CaptureViewModel.kt:736-740`) | excluded FAILED pages and sent one unordered `Task` per report, so the Mac could be told 0 early; now counts every unconfirmed page through one ordered, conflated writer (`HeartbeatMailbox`, 5 s report timeout) | **fixed** by `W40.i-fix-ios-heartbeat-count` (2026-10-21) |
| Photos on disk the session does not list | adopted into a recovery segment, held for review if the session was stale (`CaptureModels.kt:184-215`) | were never seen again (a crash between writing the photo and saving the session stranded them); now adopted at launch into a recovery segment, held behind a Review button when the session was stale or unreadable (`CaptureQueue.adoptOrphans`, `CaptureViewModel.restore`). A session file that can't be read is moved aside as `capture-session.unreadable-*.json` rather than overwritten | **fixed** by `W40.i-fix-ios-session-durability` (2026-10-21) |
| Session file writes | off the main thread, temp + fsync + atomic move, reports failure (`A/data/ManifestFileWriter.kt`) | was an `.atomic` write on the main thread on every change, failure ignored; now one ordered, conflated writer off the main thread (`SessionWriteMailbox`, Clear ordered with it), temp + fsync + rename (`SessionStore.replaceDurably`), and a "Session not saved" line while the latest write has failed | **fixed** by `W40.i-fix-ios-session-durability` (2026-10-21) |
| Pending resend (a Q3 toggle or reclassify during an upload) | included in auto-retry and resume | was not in the auto-retry or resume filters; now it is, and a confirmed send with a resend pending goes straight back to pending (`CaptureQueue.prepareDeferredResend`) | **fixed** by `W40.i-fix-ios-heartbeat-count` (2026-10-21) |
| Google Drive sign-in | client id from `local.properties`; empty disables sign-in with a message (`A/net/DriveAuth.kt:105-113`) | was a hard-coded placeholder id with the sign-in button always shown; now the id comes from the gitignored `Config/DriveLocal.xcconfig` into Info.plist, and with none set sign-in is hidden and the screen says Drive is not configured (`I/Net/DriveOAuthConfig.swift`) | **fixed** by `W40.i-fix-ios-drive-oauth-client` (2026-10-21); a real sign-in still needs the owner's iOS OAuth client (`W40.i5`) |
| Drive tokens | private SharedPreferences, `allowBackup=false` | was plain `UserDefaults`, which goes into device backups; now one Keychain item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, dropped on the first launch after a reinstall (`I/Net/DriveTokenStore.swift`) | **fixed** by `W40.i-fix-ios-drive-token-keychain` (2026-10-21) |
| Cloud pairing | an explicit Cloud mode with no LAN probe; relay token from the QR or typed in; Google sign-in launched with the QR's `account` as the login hint (`A/ui/ConnectScreen.kt:183-249`) | had no Cloud choice: Drive was used only after a LAN ping, a refused connection never fell back, a working LAN was passed over for Drive when signed in, a `mode:"cloud"` QR was refused, and there was no typed relay token. Now an explicit Wi-Fi/Cloud choice (`I/UI/ConnectScreen.swift`); Cloud takes the combined QR's `relay`, a cloud QR, or a typed relay token, signs in with the QR's `account` as `login_hint`, and pairs with no LAN probe; Wi-Fi never switches to Drive by itself and names a cloud-only QR (`CaptureViewModel.connectCloud`, `MacEndpoint.fromQRPayload`) | **fixed** by `W40.i-fix-ios-cloud-pairing` (2026-10-21); a real sign-in still needs the owner's iOS OAuth client (`W40.i5`) |
| Deleting a page | confirms whenever the page is unsent *or* has a pending resend; cancels and waits for its upload; "Save to gallery & delete" or "Delete permanently" (`CaptureViewModel.kt:477-563`) | confirmed only when the page was unsent, so a pending resend was deleted unasked; no cancel; "Delete permanently" only. Now confirms on the heartbeat's own condition, cancels and awaits the upload, and offers "Save to Photos & delete" (kept and re-queued if the copy fails) or "Delete permanently" | **fixed** by `W40.i-fix-ios-delete-confirm` (2026-10-21) |
| Tests | ten JVM test files over the queue, delete, recovery, orphans, pairing generation, QR parsing, the Drive transport, relay bytes and the session writer | no test target; four `swiftc` scripts cover only the network layer. None of the view model's safety logic is tested, and there is no runtime to host an XCTest bundle | **gap, S3** → `W40.i-fix-ios-testable-core`, which the S1 and S2 fixes wait on so each lands with a failing test first (rule 8) |
| Small differences | `savedToPhone` badge; "Segment ended · N" and "No pages in this segment yet"; ended segments kept in order; accessibility labels | all of these now: a persisted `savedToPhone` (teal dot + ✓), both status lines, ended segments in insertion order (`EndedSegments`), VoiceOver labels on the strip and Box/shutter/Folder; the QR sheet says why when camera access is off, with Open Settings; the recent-year chips wrap | **fixed** by `W40.i-fix-ios-polish` (2026-10-21) |
| Wired (USB) transport | `adb reverse` to `127.0.0.1` | absent; the iOS screen says USB is not available | not a gap: the guides promise USB for Android only |
| E2E inject seam | DEBUG `files/test_inject.jpg`, used per shutter tap (`A/ui/CaptureScreen.kt:396-411`) | absent | belongs to `W40.i3`, which builds it |
| Pairing, manual entry, reachability probe | host/port/token, digits-only port; probe reports OK, unauthorised, refused or unreachable | host/port/token with a 1–65535 port check; a refused connection reports as unreachable | same (iOS checks the port better) |
| Saved endpoint and reconnect at launch | `Prefs` | `UserDefaults`, including the relay token | same |
| Timeouts and retries | 3 tries, then an 8 s auto-retry loop | the same | same |
| Segment model, reclassify chain (`X-Replaces`), segment-complete gated on every page | `CaptureViewModel.kt` | `CaptureViewModel.swift:186-386` | same |
| Tag sheet (Quality 0–3, five recent years, 4-digit year, 12 months, Skip/Apply/Cancel, no swipe-dismiss) | `SegmentTagSheet.kt` | `SegmentTagSheet.swift` | same |
| Phone backup of unsent photos | MediaStore album `Pictures/Archive Capture` | Photos library, add-only, no album | same in effect |
| Capture thumbnails | decoded off the UI thread | decoded off the main thread | same |
| Camera format and orientation | CameraX writes a JPEG | `AVCapturePhotoSettings()` defaults, no codec set | suspect S-022 |
| Uploads while the app is in the background | keep going while the process lives | no `beginBackgroundTask` | suspect S-023 |
| Plain HTTP to the Mac | `usesCleartextTraffic=true` | no ATS keys; ATS exempts IP addresses and `.local` names, which are what pairing uses | same in effect |

## Filed

| Tag | Severity | Gap |
|---|---|---|
| `W40.i-fix-ios-testable-core` | S3 (enabler) | a host-testable core for the view model's queue and session logic |
| `W40.i-fix-ios-photo-storage` | S1 · Tier-2 | photos in Caches; absolute paths restored without a check |
| `W40.i-fix-ios-clear-generation` | S1 · Tier-2 | Clear reuses ids while uploads run |
| `W40.i-fix-ios-pairing-generation` | S2 · Tier-2 | `W23.m1` not on iOS |
| `W40.i-fix-ios-heartbeat-count` | S2 · Tier-2 | FAILED pages left out of "still to send"; unordered reports; pending resends not retried |
| `W40.i-fix-ios-session-durability` | S2 · Tier-2 | `W23.m8` and orphan adoption not on iOS; silent save failures |
| `W40.i-fix-ios-drive-oauth-client` | S2 | placeholder Google client id |
| `W40.i-fix-ios-cloud-pairing` | S3 | no Cloud mode, cloud QR refused, no typed relay token — fixed 2026-10-21 |
| `W40.i-fix-ios-drive-token-keychain` | S3 | Drive tokens in `UserDefaults` — fixed 2026-10-21 |
| `W40.i-fix-ios-delete-confirm` | S3 · Tier-2 | a pending resend deleted unasked; no cancel; no save-and-delete |
| `W40.i-fix-ios-polish` | S4 | the small differences above — fixed 2026-10-21 |

**Doc drift** for `W40.b5`: `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md` still says the iPhone is deferred, and
`ArchiveProcessor/README.md` §Transports still says the phone side of the Drive relay is owner-gated on OAuth.
`ArchiveProcessor/CLAUDE.md` calls the iOS Drive transport "built + mock-tested", which is true of the transport but
not of sign-in, which cannot work with the placeholder client id.

---

## Feature ledger

Written by `W40.b4`, 2026-10-21.

- **Sources the promises were written from (rule 3):** `ArchiveProcessor/README.md` §Live Capture (On the phone,
  Pairing, Transports); `ArchiveProcessor/CLAUDE.md` §Primary Function 3 (Streaming + never-lose-a-photo, Two
  transports, Pairing + connect flow, On the phone); `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md` Runs A-C, phone
  side only; `ArchiveProcessor/ArchiveCapture/README-oauth.md`; `SPEC/relay-object-format.md` (§The one rule,
  §Epoch, §Never-lose invariant, A5). The Mac side of the same features is the Processor ledger's
  ([`processor.md`](processor.md) P-43 to P-52).
- **Sources read at:** `e14c5adc`; code traced at the same commit.
- **Count:** `unproven 27 · works 1` (works: C-02, on `W40.a3`'s emulator round trip).

**Order of work (rule 3).** The *Promise* and *Promised in* of every row were committed first (`77bdc91c`), from
the guides alone. The parity comparison above had already been written from the code by `W40.i2`, so the code was
not unseen; the trace below re-read each entry point at `e14c5adc`.

**One row per phone.** Each phone is shown working or not on its own, so each feature has an Android row (`C-01` to
`C-14`) and an iOS row numbered thirty higher (`C-31` to `C-44`). USB is promised for Android only, so there is no
`C-43`. `C-15` is the wire contract, one promise about both phones' bytes.

**Runtime evidence.** One run has driven a phone through a promise: `W40.a3`'s Android emulator round trip
([`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md)). It pairs by manual entry, takes
three shutter taps through the DEBUG inject seam (`A/ui/CaptureScreen.kt:389-411`, which swaps the camera frame for
a fixture), ends each segment with Skip, and screenshots the drained phone; the Mac then files three PDFs. It moves
`C-02` to `works` and is partial evidence for `C-05`, `C-07`, `C-09` and `C-10`. The iOS app has never run: it builds
(`W40.i1`), but there is no simulator runtime, so every iOS row is `unproven` and waits on `W40.i3` (the iPhone in the
E2E) and the owner's borrowed-phone pass (`W40.i4`). The iOS gaps `W40.i2` filed are read from the code, not
reproduced, so they make no iOS row `broken` (rule 5); each row names its fix item.

**Tests.** Android's ten JVM test files (`app/src/test/java/com/archiveprocessor/capture/`, below `AT/`) test the
policy helpers the view model calls (`CaptureModels.kt`, `SessionStore`, the transports), not a user's tap; no
`androidTest` set exists, so nothing renders a Compose screen. iOS has no test target; four `swiftc` scripts test the
network layer only. `scripts/test-relay-transport.sh` and `scripts/test-drive-transport.sh` were run for this ledger
on 2026-10-21 and passed (`TRANSPORT ROUND-TRIP: PASS`, `DRIVE TRANSPORT (mock): PASS`).

**Drift.** Where the code does not do what the promise says, *Notes* starts with **Drift** (C-01, C-11, C-34, C-44).
Input for `W40.b5`; not a reproduced bug. No new suspects; S-021 to S-023 from `W40.i2` are cited where they apply.

Paths: `A/` and `I/` as in the parity comparison above; `scripts/` is `ArchiveProcessor/scripts/`.

### Android

### C-01 · Android · Pairing by QR scan

- **Promise:** with no saved endpoint the app opens on a QR scanner; scanning the Mac's QR (host, port, token, name,
  optional relay code) shows connecting…, then the capture screen. A random QR is refused without a crash and the
  scanner stays up.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow; `LIVE_CAPTURE_ANDROID_TEST.md`
  A1.
- **Reached by:** launch with no endpoint (`A/MainActivity.kt:34`, `:47`) → `ConnectScreen` (`A/ui/ConnectScreen.kt:48`)
  → Wi-Fi or Wired (`:66-67`) → scanner (`QrAnalyzer`, `:115-127`) → `vm.connectFromQr` (`A/capture/CaptureViewModel.kt:319`)
  → `MacEndpoint.fromQrPayload` (`A/net/MacEndpoint.kt`) → `connect` (`:292`). A payload that does not parse returns
  `false` (`:321`) and the analyzer re-arms (`A/ui/ConnectScreen.kt:124`).
- **Real-path test:** `AT/net/MacEndpointQrTest` (five QR shapes: legacy LAN, combined with relay, string port and
  unknown keys, legacy cloud). The scan itself has no test.
- **Runtime evidence:** none. The `W40.a3` E2E pairs by manual entry.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** **Drift.** The app opens on a "How is this phone connected?" chooser (Wired, Wi-Fi, Cloud;
  `A/ui/ConnectScreen.kt:58-68`), not on the scanner as A1 says. A non-pairing QR is refused silently: no message is set
  on that path (`A/capture/CaptureViewModel.kt:321`). The emulator's virtual-scene camera could show a scan.

### C-02 · Android · Manual entry of host, port and token

- **Promise:** instead of scanning, host, port and token can be typed in, and the phone pairs the same way.
- **Promised in:** `README.md` §Live Capture (Pairing).
- **Reached by:** "Enter manually instead" (`A/ui/ConnectScreen.kt:151`) → `ManualConnect` (`:160`; the port field keeps
  digits only, `:167`) → Connect (`:171`) → `vm.connect` (`A/capture/CaptureViewModel.kt:292`).
- **Real-path test:** `scripts/e2e-phone-mac.sh`, through `scripts/android-ui-drive.sh` `pair` (taps Wi-Fi, Enter
  manually, types the three fields, taps Connect; `android-ui-drive.sh:160-176`).
- **Runtime evidence:** 2026-10-11 · `0511d85c` · [`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md)
  (pairing screenshot `05-connected.png` inspected; the run went on to file three PDFs).
- **Status:** `works`
- **History:**
  - 2026-10-21 W40.b4 — row written; `works` on the emulator, taken in from `W40.a3`'s evidence.
- **Notes:** shown on the `ap_test36` emulator over the LAN route; a physical phone is the owner's pass.

### C-03 · Android · Honest connect diagnostics

- **Promise:** a short reachability check before pairing reports unreachable, refused or unauthorised, so pairing
  never fails silently; a stale QR (old token) or the wrong Mac gives a clear failure and a way to Re-pair, with no
  crash and no hang.
- **Promised in:** `CLAUDE.md` §Pairing + connect flow (P0/P1); `LIVE_CAPTURE_ANDROID_TEST.md` C6.
- **Reached by:** any connect → `MacClient(ep).reachability()` (`A/capture/CaptureViewModel.kt:295`) → one message per
  cause (`:304-312`), shown on the connect screen.
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** the C6 case (stale token on a saved endpoint, after pairing) has no preflight: uploads simply fail and
  auto-retry, so what the operator sees then is the upload summary, not the unauthorised message. Cloud pairing skips
  the probe by design (`:327-330`). All four causes can be staged on the emulator (Mac stopped, wrong port, wrong token).

### C-04 · Android · Saved endpoint and Re-pair

- **Promise:** once paired, the app opens straight to the capture screen; Re-pair (with a confirmation) is the only
  way back to the scanner, tells the Mac to show its QR again (`POST /session/disconnect`), and clears the saved
  endpoint, so a USB pairing at `127.0.0.1` can move to Wi-Fi or another Mac. Captured, unsent photos are kept across
  it and upload to the new endpoint, with no duplicates on the Mac.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow; `LIVE_CAPTURE_ANDROID_TEST.md`
  A5, B2, C5.
- **Reached by:** saved endpoint → `CaptureScreen` (`A/MainActivity.kt:46`); Re-pair (`A/ui/CaptureScreen.kt:171-172`)
  → confirm (`:362-366`) → `vm.disconnect()` (`A/capture/CaptureViewModel.kt:343`: `sessionDisconnect`, then
  `retirePreviousPairing` `:360`, `clearEndpoint`). A new connect calls `resumeUploads` (`:301`).
- **Real-path test:** `AT/capture/CapturePairingGenerationTest` (eight tests: a reply from the unpaired Mac never
  confirms a page; the pre-fix disposition is shown to differ) — the policy helper `sendAck`, not a tap.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** "no duplicates" is the Mac's `(group, seq)` replace (P-44). The re-pair path is the `W23.m1` fix.

### C-05 · Android · Full-resolution shutter

- **Promise:** the shutter takes a full-resolution photo of the page; the phone confirms it (thumbnail, counter).
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone; `LIVE_CAPTURE_ANDROID_TEST.md` A2.
- **Reached by:** shutter (`A/ui/CaptureScreen.kt:272`) → `takePicture` (`:372`, CameraX `controller.takePicture`
  `:413`) → `vm.addDocumentPhoto` (`A/capture/CaptureViewModel.kt:372`).
- **Real-path test:** the E2E taps the shutter, but the DEBUG inject seam replaces the camera's frame
  (`A/ui/CaptureScreen.kt:389-411`).
- **Runtime evidence:** partial. 2026-10-11 · `0511d85c` · [`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md):
  three taps reached the Mac and were screenshotted on the phone, but the pixels were the fixture, not the camera.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** "full resolution" depends on the device's camera. The emulator's virtual-scene camera can show the CameraX
  path; the resolution on a real phone is the owner's pass.

### C-06 · Android · Box and Folder markers

- **Promise:** dedicated Box (red) and Folder (purple) buttons mark the next photo as a box label or a folder, and
  the Mac registers it as such.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone; `LIVE_CAPTURE_ANDROID_TEST.md` A3.
- **Reached by:** Box (`A/ui/CaptureScreen.kt:262`) / Folder (`:282`) → `vm.captureMarker` (`A/capture/CaptureViewModel.kt:393`),
  a one-photo group of that type; with a page selected the same buttons reclassify it (`reclassifySelected`, `:583`).
- **Real-path test:** none against the real Mac. `scripts/android-ui-drive.sh` `flow` taps Box against a fake stub
  (`:211`).
- **Runtime evidence:** none (the `W40.a3` E2E captures documents only).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.

### C-07 · Android · End segment

- **Promise:** End segment is the only "done" action: it closes the document, sends its tags and the list of its
  pages as taken at that moment, and does not hold back the photos, which have already streamed. While a page of the
  segment is still unsent, the Mac defers the segment.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo;
  `LIVE_CAPTURE_ANDROID_TEST.md` A2 step 7; `SPEC/relay-object-format.md` A5.
- **Reached by:** End segment (`A/ui/CaptureScreen.kt:188`) → `finishDocumentSegment` (`A/capture/CaptureViewModel.kt:611`)
  → tag sheet (`A/ui/CaptureScreen.kt:306`) → Apply or Skip → `finalizeSegment` (`:658`) → `trySendSegmentComplete`
  (`:701`), which waits until every page of the group is uploaded (`:705`) and is retried from the upload's success
  (`:820`) and from `resendEndedSegments` (`:728`).
- **Real-path test:** the E2E (End segment, then Skip, per document).
- **Runtime evidence:** partial. 2026-10-11 · `0511d85c` · [`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md):
  three single-page segments ended and were filed. The deferral of a segment with a page still unsent was not shown.
  2026-10-21 · W40.d5 · [`evidence/processor/W40.d5-live-capture.md`](evidence/processor/W40.d5-live-capture.md): seven more single-page segments of real photos ended, each raising its Mac tag card.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-21 W40.d5 — more partial evidence; deferral still not shown.
- **Notes:** the phone holds the segment-complete until its pages are sent; the Mac's own deferral is P-47's. With no
  page captured, End segment says so instead of doing nothing (`:615-622`).

### C-08 · Android · On-phone tagging: Quality and date

- **Promise:** per segment, Quality (Unrated or Q1-Q3) and year/month; a long-press on a page sets Q3 for that page
  alone. The values stick on the item and reach the Mac as `Q1`-`Q3` (nothing for Unrated) and the date.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone; `LIVE_CAPTURE_ANDROID_TEST.md` A4.
- **Reached by:** tag sheet (`A/ui/SegmentTagSheet.kt`; Quality values `:103`) → `applyTagsAndContinue`
  (`A/capture/CaptureViewModel.kt:627`); long-press on a strip thumbnail (`A/ui/CaptureScreen.kt:246`, `:483`) →
  `toggleQ3` (`A/capture/CaptureViewModel.kt:416`), which resends the page if it was already sent (`resendOrEnqueue`
  `:433`).
- **Real-path test:** `AT/capture/CaptureQueuePolicyTest` covers a metadata change during an upload (the deferred
  resend); nothing drives the sheet.
- **Runtime evidence:** none. The E2E taps Skip, so no phone tag was sent; its year tags came from OCR.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.

### C-09 · Android · Uploads as shot, through a durable auto-retrying queue

- **Promise:** each photo and its grouping and tags are written to disk at once and uploaded as it is shot, through
  a queue that retries on its own. With the network off, or the Mac app quit, the phone keeps shooting and queueing
  and shows that it is retrying; when the Mac is back, everything queued arrives.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo;
  `LIVE_CAPTURE_ANDROID_TEST.md` C1, C2.
- **Reached by:** `addDocumentPhoto` (`A/capture/CaptureViewModel.kt:372`) → `persist` (`:235`) → `enqueueUpload`
  (`:758`; three tries, `:779-786`); `startAutoRetry` (`:262`) re-sends FAILED and PENDING every 8 s; Retry button
  (`A/ui/CaptureScreen.kt:184` → `retryFailed` `:841`).
- **Real-path test:** `AT/capture/CaptureQueuePolicyTest` (what counts as unsent and retryable); `AT/data/ManifestFileWriterTest`
  (the session write). No test takes the network away.
- **Runtime evidence:** partial: the `W40.a3` E2E uploaded three photos as shot on a healthy network. No drop or Mac
  quit was staged.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** C1 and C2 can both be staged on the emulator (`adb shell svc wifi disable`, or stop the headless Mac).

### C-10 · Android · The phone's copy is deleted only after the Mac's durable ack

- **Promise:** a page is marked sent only after the Mac's durable ack (over Drive, a valid receipt), and only then
  does the phone delete its copy; as each segment is confirmed its photos leave the phone with a transfer animation,
  so photos do not pile up on the device.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo;
  `SPEC/relay-object-format.md` §The one rule, §Never-lose invariant.
- **Reached by:** `postPhoto` returns `true` (`A/net/MacClient.kt`; `A/net/FileRelayTransport.kt:42-51` for a receipt)
  → `setState(UPLOADED)` only for the current pairing (`A/capture/CaptureViewModel.kt:793-794`) → after 650 ms
  `removeConfirmed` (`:567`), which deletes only the same, still-UPLOADED file and keeps document pages until their
  segment ends (`:577`).
- **Real-path test:** `AT/capture/CaptureDeletePolicyTest`, `AT/capture/CapturePairingGenerationTest`,
  `AT/net/DriveRelayTransportTest` (receipt acceptance over a mock Drive).
- **Runtime evidence:** partial: the `W40.a3` E2E screenshot `zz-drained` shows the phone emptied after the Mac
  confirmed. That a failed or stale ack keeps the photo was not shown.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.

### C-11 · Android · The queue survives the app being killed

- **Promise:** after the app is force-stopped or crashes with unsent photos, reopening it shows them still there, and
  they upload once connected.
- **Promised in:** `README.md` §Live Capture (On the phone, "even across an app crash"); `LIVE_CAPTURE_ANDROID_TEST.md` C3.
- **Reached by:** launch → `store.load()` (`A/capture/CaptureViewModel.kt:181`, `A/data/SessionStore.kt:115`; a file that
  is gone is skipped, `:124`) → confirmed items pruned (`:193-197`), the rest re-sent; untracked photos adopted into a
  recovery segment (`A/capture/CaptureModels.kt:184-215`).
- **Real-path test:** `AT/data/SessionStoreTest` (twelve tests: save reports failure, the stale marker survives a
  restart), `AT/capture/CaptureRecoverySequenceTest` (a lost snapshot holds its photos), `AT/capture/CaptureOrphanAdoptionTest`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** **Drift.** Recovered pages against a stale session are held for the operator's review rather than sent
  (`W23.m8`); the guides promise only that they upload. `adb shell am force-stop` stages C3 on the emulator.

### C-12 · Android · Queue-depth heartbeat

- **Promise:** the phone tells the Mac how many photos it still has to send (`POST /phone/status`, `X-Pending`), which
  is what the Mac's Finish waits on.
- **Promised in:** `CLAUDE.md` §On the phone, §On the Mac.
- **Reached by:** every enqueue and settle (`A/capture/CaptureViewModel.kt:772`, `:824`), each reconnect (`:256`) and the 8 s loop (`:278`) →
  `sendStatusReport` (`:736`: `pendingReportCount`, one conflated channel) → `reportStatus` (`:178-179`,
  `A/net/MacClient.kt`).
- **Real-path test:** `AT/capture/CaptureQueuePolicyTest` (the count includes every unconfirmed state; a retryable
  failure blocks "drained"), `AT/capture/CaptureOrphanAdoptionTest` (a held page still counts).
- **Runtime evidence:** none. The E2E finished through `/session/complete` and did not show the Mac waiting.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** Drive carries no heartbeat (suspect S-038, Mac side).

### C-13 · Android · USB with no shared Wi-Fi

- **Promise:** with the phone on a USB cable, it pairs to `127.0.0.1` through the Mac's `adb reverse` and captures with
  no shared network; an unplugged cable loses nothing.
- **Promised in:** `README.md` §Live Capture (Pairing, On the phone); `CLAUDE.md` §USB local relay;
  `LIVE_CAPTURE_ANDROID_TEST.md` B1.
- **Reached by:** Wired (USB cable) (`A/ui/ConnectScreen.kt:66`) → scan → `connectFromQr` replaces the host with
  `127.0.0.1` (`A/capture/CaptureViewModel.kt:323`).
- **Real-path test:** `scripts/usb-reverse-probe.sh` checks the tunnel with an in-device ping, not the app.
- **Runtime evidence:** none for the phone app. The tunnel itself is P-45 (`works`, [`evidence/processor/W40.d6-usb-transport.md`](evidence/processor/W40.d6-usb-transport.md)).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** Wired manual entry fills `127.0.0.1` too (`ManualConnect(vm, wired, …)`). The emulator can show the app over
  the tunnel; a real cable and its unplug is the owner's pass.

### C-14 · Android · Google Drive cloud relay, phone side

- **Promise:** signed in to Google (on-device sign-in, `drive.file`), the phone uploads each object to the user's Drive
  for a client-isolated or off-site session; it adopts the Mac's published epoch, so uploads resume after a Mac restart
  with no re-pair, and trusts a receipt only when it matches. A build with no client id still works for LAN and USB,
  with Drive sign-in disabled and a message saying why.
- **Promised in:** `README.md` §Live Capture (Transports); `CLAUDE.md` §Google Drive cloud relay, §Cloud-relay OAuth
  setup; `ArchiveCapture/README-oauth.md`; `SPEC/relay-object-format.md` §Epoch.
- **Reached by:** Cloud (Google Drive) (`A/ui/ConnectScreen.kt:68`) → `CloudPairing` (`:183`; QR or typed relay token
  `:244`, Sign in & connect `:245`) → `DriveAuth.authorizeIntent` (`A/net/DriveAuth.kt:44`) → `vm.connectCloud`
  (`A/capture/CaptureViewModel.kt:331`) → `DriveRelayTransport` (`:289`). Unconfigured: `CLIENT_ID` empty and
  `UNCONFIGURED_MESSAGE` (`A/net/DriveAuth.kt:105-113`).
- **Real-path test:** `AT/net/DriveRelayTransportTest` (the transport over a mock Drive); `scripts/test-relay-golden.sh`
  (bytes). Nothing covers sign-in or epoch adoption against a real receiver.
- **Runtime evidence:** none. `CLAUDE.md` says the Android relay was "verified end-to-end" over a real Drive account on
  2026-07-07; there is no evidence file for it.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** a real run needs the owner's Google account and an Android OAuth client in `local.properties`, so the
  sign-in half is `unverifiable-here` until those exist on this machine; the transport half can be shown against
  `FileRelay` (a directory store) with no account. Suspect S-021: a failed Drive write of the segment-complete is
  reported as success.

### C-15 · Both phones · The same bytes on the wire

- **Promise:** both companions speak the same protocol and write every relay object byte for byte as the SPEC
  defines, so the Mac cannot tell which phone sent a page.
- **Promised in:** `README.md` §Live Capture; `CLAUDE.md` §Primary Function 3, §Google Drive cloud relay;
  `SPEC/relay-object-format.md` §Purpose & status.
- **Reached by:** every send; `A/net/RelayObjectFormat.kt` and `I/Net/RelayObjectFormat.swift`, HTTP headers in
  `A/net/MacClient.kt:30-126` and `I/Net/MacClient.swift:29-113` (compared constant by constant above).
- **Real-path test:** `AT/net/RelayObjectFormatTest` (Android against the committed golden files);
  `scripts/test-relay-golden.sh` (iOS, Android and Mac against the same files, in the gate); `scripts/test-relay-fuzz.sh`.
- **Runtime evidence:** none for the promise. [`evidence/capture/W40.a3-relay-golden.md`](evidence/capture/W40.a3-relay-golden.md)
  is a gate run of the byte comparison, a test of the writer code, not a run of either phone.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** the group id was uppercase hex on iOS (lowercase on Android); both are lowercase since
  `W40.i-fix-ios-polish` (2026-10-21). A real iOS photo reaching the Mac would make this row's evidence (`W40.i3`).

### iOS

The guides promise the iPhone the same workflow as Android ("pick whichever phone you have"); each row below makes
the promise of its Android twin, thirty lower, unless it says otherwise. No iOS row has a real-path test of a user's
action or any runtime evidence: there is no test target and no simulator runtime (above). The next evidence is
`W40.i3`, which waits on the iOS fix items named below.

### C-31 · iOS · Pairing by QR scan

- **Promise:** as `C-01`.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow.
- **Reached by:** no endpoint (`I/ContentView.swift:7-8`) → `ConnectScreen` scanner (`I/UI/ConnectScreen.swift:64`,
  `I/UI/QRScannerView.swift`) → `vm.connectFromQR` (`I/Capture/CaptureViewModel.swift:108`; a payload that does not parse
  sets `.badQR`) → `attemptConnect` (`:115`).
- **Real-path test:** `scripts/e2e-phone-mac.sh --ios` pairs through `connectFromQR` from a launch payload (the scanner's own path after the scan; the camera scan itself is not run).
- **Runtime evidence:** 2026-10-22 · `W40.i3` · [`evidence/capture/W40.i3-ios-e2e.md`](evidence/capture/W40.i3-ios-e2e.md).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-22 W40.i3 — runtime evidence: the QR payload path from `connectFromQR` on (probe, pair, saved endpoint) ran; the camera scan did not. Stays `unproven`.
- **Notes:** opens on the scanner as promised, and names a bad QR (unlike `C-01`). A cloud-mode QR was refused; since
  `W40.i-fix-ios-cloud-pairing` (2026-10-21) Wi-Fi names it as a Cloud code and the Cloud choice accepts it. With camera access denied the scanner was black
  with no message; since `W40.i-fix-ios-polish` (2026-10-21) it says so and offers Open Settings.

### C-32 · iOS · Manual entry of host, port and token

- **Promise:** as `C-02`.
- **Promised in:** `README.md` §Live Capture (Pairing).
- **Reached by:** Connect (`I/UI/ConnectScreen.swift:45`) → `manualConnect` (`:112-124`, port checked 1-65535) →
  `vm.connect` (`I/Capture/CaptureViewModel.swift:104`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.

### C-33 · iOS · Honest connect diagnostics

- **Promise:** as `C-03`.
- **Promised in:** `CLAUDE.md` §Pairing + connect flow.
- **Reached by:** `attemptConnect` → `MacClient.reachability()` (`I/Capture/CaptureViewModel.swift:117`) → `connectPhase`
  `.unreachable` / `.refused` / `.unauthorized` (`:142-145`) → message (`I/UI/ConnectScreen.swift:77`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** when the QR carried a relay code and the phone was signed in, an unreachable Mac switched to Drive silently
  apart from a status line. Since `W40.i-fix-ios-cloud-pairing` (2026-10-21) Wi-Fi reports the cause and points at
  the Cloud choice; it never switches by itself.

### C-34 · iOS · Saved endpoint and Re-pair

- **Promise:** as `C-04`, without the USB case.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow.
- **Reached by:** saved endpoint (`I/ContentView.swift:10`) → Re-pair (`I/UI/CaptureScreen.swift:54`) → confirm
  (`:146-150`) → `vm.disconnect()` (`I/Capture/CaptureViewModel.swift:148`); a new connect calls `resumeUploads` (`:126`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** **Drift.** "Captured photos are kept and upload once you reconnect" (the dialog, `:150`) does not hold for a
  page whose upload is in flight at Re-pair: its reply from the old Mac marks it sent and the phone deletes it
  (code read) → `W40.i-fix-ios-pairing-generation` (S2).

### C-35 · iOS · Full-resolution shutter

- **Promise:** as `C-05`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone.
- **Reached by:** shutter (`I/UI/CaptureScreen.swift:98`) → `capture(.document)` (`:172`) → `camera.capturePhoto`
  (`I/Camera/CameraController.swift:80`, default `AVCapturePhotoSettings` `:88`) → `vm.addDocumentPhoto`
  (`I/Capture/CaptureViewModel.swift:187`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** the camera needs a real iPhone (`W40.i4`). Suspect S-022 (format and orientation not set).

### C-36 · iOS · Box and Folder markers

- **Promise:** as `C-06`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone.
- **Reached by:** Box (`I/UI/CaptureScreen.swift:94`) / Folder (`:102`) → `capture(_:)` (`:172`; reclassifies a selected
  page, `:173`) → `vm.captureMarker` (`I/Capture/CaptureViewModel.swift:204`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.

### C-37 · iOS · End segment

- **Promise:** as `C-07`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo;
  `SPEC/relay-object-format.md` A5.
- **Reached by:** End segment (`I/UI/CaptureScreen.swift:63`) → `finishDocumentSegment` (`I/Capture/CaptureViewModel.swift:309`)
  → tag sheet (`I/UI/CaptureScreen.swift:128-132`) → `finalizeSegment` (`:334`) → `trySendSegmentComplete` (`:366`).
- **Real-path test:** `scripts/test-relay-transport.sh` (the iOS `FileRelayTransport.segmentComplete` writes its object;
  passed 2026-10-21); the view model is untested; `scripts/e2e-phone-mac.sh --ios`: the app's DEBUG driver calls `finishDocumentSegment` then the sheet's Skip (`applyTagsAndContinue(nil, nil, nil)`) per document; the Mac received three separate segments.
- **Runtime evidence:** 2026-10-22 · `W40.i3` · [`evidence/capture/W40.i3-ios-e2e.md`](evidence/capture/W40.i3-ios-e2e.md).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-22 W40.i3 — runtime evidence: three segments ended and acknowledged by the Mac; the End segment and Skip buttons were not tapped (the driver calls their actions). Stays `unproven`.
- **Notes:** ended segments were held in a `Dictionary`, so their tag cards could reach the Mac out of order; since
  `W40.i-fix-ios-polish` (2026-10-21) they are kept in the order ended, through restore.

### C-38 · iOS · On-phone tagging: Quality and date

- **Promise:** as `C-08`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §On the phone.
- **Reached by:** tag sheet (`I/UI/SegmentTagSheet.swift`; Quality values `:61`) → `applyTagsAndContinue`
  (`I/Capture/CaptureViewModel.swift:319`); long-press (`I/UI/CaptureScreen.swift:83`) → `toggleQ3` (`:217`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** a Q3 toggled during an upload is a pending resend; the auto-retry and resume filters skipped it until
  `W40.i-fix-ios-heartbeat-count` (2026-10-21), which added it to both.

### C-39 · iOS · Uploads as shot, through a durable auto-retrying queue

- **Promise:** as `C-09`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo.
- **Reached by:** `addDocumentPhoto` (`I/Capture/CaptureViewModel.swift:187`) → `persist` (`:597`) → `enqueueUpload`
  (`:418`); `startAutoRetry` (`:512`, every 8 s, started at init `:76`); Retry (`I/UI/CaptureScreen.swift:61` →
  `retryFailed` `:466`).
- **Real-path test:** `scripts/test-relay-transport.sh` (the transport's retry-safe `postPhoto`; passed 2026-10-21);
  the queue is untested; `scripts/e2e-phone-mac.sh --ios`: the shutter's `capture(.document)` with the inject seam's bytes → `persistCapturedJPEG` → `addDocumentPhoto` → upload to the real Mac.
- **Runtime evidence:** 2026-10-22 · `W40.i3` · [`evidence/capture/W40.i3-ios-e2e.md`](evidence/capture/W40.i3-ios-e2e.md).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-22 W40.i3 — runtime evidence: uploads as shot reached the real Mac and were OCR'd (3/3 tokens and years); auto-retry and Retry were not exercised. Stays `unproven`.
- **Notes:** photos are kept in Caches, which iOS may empty → `W40.i-fix-ios-photo-storage` (S1); session writes ignored
  failure (fixed by `W40.i-fix-ios-session-durability`, 2026-10-21). Uploads with the app in the background: suspect S-023.

### C-40 · iOS · The phone's copy is deleted only after the Mac's durable ack

- **Promise:** as `C-10`.
- **Promised in:** `README.md` §Live Capture (On the phone); `CLAUDE.md` §Streaming + never-lose-a-photo;
  `SPEC/relay-object-format.md` §The one rule, §Never-lose invariant.
- **Reached by:** `postPhoto` → `setState(.uploaded)` → `removeConfirmed` (`I/Capture/CaptureViewModel.swift:534`);
  receipt acceptance `I/Net/FileRelayTransport.swift:35-42`, `I/Net/DriveRelayTransport.swift:40-44`.
- **Real-path test:** `scripts/test-relay-transport.sh` (no receipt or a mismatched one returns `false`); the deletion
  in the view model is untested; `scripts/e2e-phone-mac.sh --ios`: its driver reports DONE only once no page is left on the phone and every ended segment is acknowledged.
- **Runtime evidence:** 2026-10-22 · `W40.i3` · [`evidence/capture/W40.i3-ios-e2e.md`](evidence/capture/W40.i3-ios-e2e.md).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-22 W40.i3 — runtime evidence: every page left the phone after the Mac confirmed it; that none leaves before is not what this run shows. Stays `unproven`.
- **Notes:** two code-read ways an unsent photo is deleted: a late reply after Clear marks a new photo with the reused id
  as sent → `W40.i-fix-ios-clear-generation` (S1); a reply from the Mac just unpaired from →
  `W40.i-fix-ios-pairing-generation` (S2). Until those land this row cannot honestly move to `works`.

### C-41 · iOS · The queue survives the app being killed

- **Promise:** as `C-11`.
- **Promised in:** `README.md` §Live Capture (On the phone, "even across an app crash").
- **Reached by:** init → `restore()` (`I/Capture/CaptureViewModel.swift:75`, `:567`) → `SessionStore.load`
  (`I/Capture/SessionStore.swift`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** restore trusts each photo's absolute path, which changes on reinstall (`:567-595`) →
  `W40.i-fix-ios-photo-storage` (S1, fixed); a photo written but not yet listed is now adopted at launch, held for
  review when the session was stale (`W40.i-fix-ios-session-durability`, fixed 2026-10-21, host-tested only).

### C-42 · iOS · Queue-depth heartbeat

- **Promise:** as `C-12`.
- **Promised in:** `CLAUDE.md` §On the phone, §On the Mac.
- **Reached by:** `enqueueUpload` and the 8 s loop → `sendStatusReport` (`I/Capture/CaptureViewModel.swift:392`) →
  `MacClient.reportStatus`.
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
- **Notes:** counted pending and uploading only, not FAILED pages still retrying, and sent each report on its own
  unordered `Task`, so the Mac could be told 0 early. Fixed by `W40.i-fix-ios-heartbeat-count` (2026-10-21): every
  unconfirmed page counts, through one ordered writer (host tests in `CaptureQueueTests.swift`). Still `unproven`
  at runtime: no iPhone E2E yet (`W40.i3`).

### C-44 · iOS · Google Drive cloud relay, phone side

- **Promise:** as `C-14`, with the iPhone's own iOS OAuth client (bundle `com.archiveprocessor.capture.ios`).
- **Promised in:** `README.md` §Live Capture (Transports); `CLAUDE.md` §Google Drive cloud relay ("the iOS transport
  is built + mock-tested"); `ArchiveCapture/README-oauth.md` §iPhone companion; `SPEC/relay-object-format.md` §Epoch.
- **Reached by:** Cloud on the pairing screen (`I/UI/ConnectScreen.swift`, `cloudSection`) → scan (`vm.connectCloudFromQR`)
  or typed relay token (`vm.connectCloud(relayToken:)`) → `DriveAuth.signIn(loginHint:)` when signed out → `pair` →
  `DriveRelayTransport` (`I/Capture/CaptureViewModel.swift`, `makeTransport`).
- **Real-path test:** `scripts/test-drive-transport.sh` (the iOS Drive transport over a mock; passed 2026-10-21).
  Sign-in has no test.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b4 — row written, `unproven`.
  - 2026-10-21 W40.i-fix-ios-drive-oauth-client — placeholder id replaced by a build setting; still `unproven`.
  - 2026-10-21 W40.i-fix-ios-cloud-pairing — explicit Cloud choice, cloud QR and typed token, `login_hint`; QR parsing
    and the hint covered by `scripts/test-ios-capture-queue.sh`; still `unproven`.
- **Notes:** The id was the placeholder `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` with the sign-in button always
  shown; fixed by `W40.i-fix-ios-drive-oauth-client` (2026-10-21): the id comes from the gitignored
  `Config/DriveLocal.xcconfig`, and a build without one hides sign-in and says why (`I/Net/DriveOAuthConfig.swift`,
  parser covered by `scripts/test-ios-capture-queue.sh`). The reversed-client-id scheme is no longer registered in
  Info.plist; `ASWebAuthenticationSession` catches it itself — unverified on a device until `W40.i4`. Tokens are kept in the Keychain, this device only
  (`W40.i-fix-ios-drive-token-keychain`, 2026-10-21). A real sign-in needs an iOS OAuth client the owner mints (the `W40.i5` pack).
