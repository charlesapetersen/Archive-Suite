# Capture companions — Android and iOS

Format and statuses: [`README.md`](README.md). The parity comparison below was written by `W40.i2`, 2026-10-21.
The feature-ledger rows (`C-01` …) come later, from `W40.b4`, which extends this file.

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
| Group id | `g` + 8 lowercase hex | `g` + 8 **uppercase** hex | cosmetic: the Mac's `isSafeGroupId` takes both |
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
| `W23.m8` (2026-07-30) | `SessionStore.save` reports failure; a durable stale marker; pages recovered against a stale session are held for review | absent: `SessionStore.save` ignores errors (`I/Capture/SessionStore.swift:38-41`) | `W40.i-fix-ios-session-durability` |
| manifest fallback (2026-07-12) | a fallback no longer deletes the last good session before the new one is written | iOS writes `.atomic` and has no fallback path, so this case does not arise | none |
| pending count (2026-07-12) | auto-retrying FAILED pages count as pending, so they hold the Mac's Finish | absent: the heartbeat counts only pending and uploading (`CaptureViewModel.swift:392-396`), although auto-retry does resend FAILED pages | `W40.i-fix-ios-heartbeat-count` |
| Clear race (2026-07-12) | Clear cancels and joins uploads, and item ids are never reused | absent: `clearSession()` resets `nextId = 1` and leaves uploads running (`CaptureViewModel.swift:548-563`) | `W40.i-fix-ios-clear-generation` |
| thumbnails off the UI thread (2026-07-12) | | already off the main thread (`I/UI/CaptureScreen.swift:225`) | none |
| Quality `Q1`–`Q3` cutover (2026-09-03) | | iOS sends the same values | none |
| `W23.h4` (2026-07-30) | delete confirmation for an unsent page, and a recoverable save-and-delete | **iOS had the guard first** (2026-07-09); Android caught up. The parts Android added beyond it are not on iOS | `W40.i-fix-ios-delete-confirm` |

## Feature by feature

| Area | Android | iOS | Verdict |
|---|---|---|---|
| Where photos are kept | `filesDir/capture/` (`A/capture/CaptureViewModel.kt:33`) | **`cachesDirectory/capture/`** (`CaptureViewModel.swift:69`), a folder iOS may empty when storage runs low | **gap, S1** → `W40.i-fix-ios-photo-storage` |
| Restoring the session after the app is killed | skips items whose file is gone (`A/data/SessionStore.kt:124`); a pending resend is kept over an uploaded state | stores each photo's **absolute** file URL, never checks it still exists, and drops uploaded items even when a resend is pending (`CaptureViewModel.swift:567-595`). The app's container path changes when it is reinstalled, and a free-account install is reinstalled every seven days | **gap, S1** → `W40.i-fix-ios-photo-storage` |
| Clear session | bumps a session generation, cancels and waits for uploads, never reuses ids (`CaptureViewModel.kt:876-899`) | resets ids to 1 with uploads still running, so a late reply marks a *new* photo with the same id as uploaded; it is never sent, and the next restore deletes it | **gap, S1** → `W40.i-fix-ios-clear-generation` |
| Re-pairing while uploads run (`W23.m1`) | see above | see above | **gap, S2** → `W40.i-fix-ios-pairing-generation` |
| "Phone still has N to send" heartbeat | counts every unconfirmed page; one ordered, conflated writer (`CaptureViewModel.kt:736-740`) | excludes FAILED pages; one unordered `Task` per report. The Mac can be told 0 while pages are still to come, and finish a partial session | **gap, S2** → `W40.i-fix-ios-heartbeat-count` |
| Photos on disk the session does not list | adopted into a recovery segment, held for review if the session was stale (`CaptureModels.kt:184-215`) | never seen again: a crash between writing the photo and saving the session strands it | **gap, S2** → `W40.i-fix-ios-session-durability` |
| Session file writes | off the main thread, temp + fsync + atomic move, reports failure (`A/data/ManifestFileWriter.kt`) | `.atomic` write on the main thread on every change; failure ignored | **gap, S3**, part of `W40.i-fix-ios-session-durability` |
| Pending resend (a Q3 toggle or reclassify during an upload) | included in auto-retry and resume | not in the auto-retry or resume filters | **gap, S3**, part of `W40.i-fix-ios-heartbeat-count` |
| Google Drive sign-in | client id from `local.properties`; empty disables sign-in with a message (`A/net/DriveAuth.kt:105-113`) | hard-coded placeholder `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` (`I/Net/DriveAuth.swift:73`, `project.yml:42`); the sign-in button always shows and Google rejects it | **gap, S2** → `W40.i-fix-ios-drive-oauth-client`. The cloud relay cannot be reached on iOS |
| Drive tokens | private SharedPreferences, `allowBackup=false` | access and refresh tokens in plain `UserDefaults`, which goes into device backups (`DriveAuth.swift:29-48`) | **gap, S3** → `W40.i-fix-ios-drive-token-keychain` |
| Cloud pairing | an explicit Cloud mode with no LAN probe; relay token from the QR or typed in; Google sign-in launched with the QR's `account` as the login hint (`A/ui/ConnectScreen.kt:183-249`) | no Cloud choice: Drive is used only after a LAN ping, a refused connection never falls back, and a working LAN is passed over for Drive when signed in (`CaptureViewModel.swift:115-146`). A `mode:"cloud"` QR is refused as "not an Archive Processor pairing code" (`I/Net/MacEndpoint.swift:19-32`). No typed relay token | **gap, S3** → `W40.i-fix-ios-cloud-pairing` |
| Deleting a page | confirms whenever the page is unsent *or* has a pending resend; cancels and waits for its upload; "Save to gallery & delete" or "Delete permanently" (`CaptureViewModel.kt:477-563`) | confirms only when the page is unsent, so a pending resend is deleted unasked; no cancel; "Delete permanently" only (`CaptureViewModel.swift:256-281`) | **gap, S3** → `W40.i-fix-ios-delete-confirm` |
| Tests | ten JVM test files over the queue, delete, recovery, orphans, pairing generation, QR parsing, the Drive transport, relay bytes and the session writer | no test target; four `swiftc` scripts cover only the network layer. None of the view model's safety logic is tested, and there is no runtime to host an XCTest bundle | **gap, S3** → `W40.i-fix-ios-testable-core`, which the S1 and S2 fixes wait on so each lands with a failing test first (rule 8) |
| Small differences | `savedToPhone` badge; "Segment ended · N" and "No pages in this segment yet"; ended segments kept in order; accessibility labels | none of these; ended segments in a `Dictionary`, so tag cards can reach the Mac out of order; the QR sheet is black with no message when camera access is denied; the recent-year chips can overflow | **gap, S4** → `W40.i-fix-ios-polish` |
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
| `W40.i-fix-ios-cloud-pairing` | S3 | no Cloud mode, cloud QR refused, no typed relay token |
| `W40.i-fix-ios-drive-token-keychain` | S3 | Drive tokens in `UserDefaults` |
| `W40.i-fix-ios-delete-confirm` | S3 · Tier-2 | a pending resend deleted unasked; no cancel; no save-and-delete |
| `W40.i-fix-ios-polish` | S4 | the small differences above |

**Doc drift** for `W40.b5`: `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md` still says the iPhone is deferred, and
`ArchiveProcessor/README.md` §Transports still says the phone side of the Drive relay is owner-gated on OAuth.
`ArchiveProcessor/CLAUDE.md` calls the iOS Drive transport "built + mock-tested", which is true of the transport but
not of sign-in, which cannot work with the placeholder client id.
