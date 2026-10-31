# iPhone session 1

About 75 to 100 minutes with your own iPhone, plus 15 to 20 minutes to install the current app. The phone is
yours, so the session does not have to happen in one sitting: Part A (the cable) and Part B (Wi-Fi and the
Drive relay) can be done on different days. The session covers only what a simulator cannot show: the camera, the
real USB cable, a real network, and the device itself. Everything else about the iPhone app was checked in the
simulator first (`../evidence/capture/W40.i3-ios-e2e.md`, `../evidence/capture/W40.i-sim-ui.md`, and the cable
route in `../evidence/capture/W40.i-usb-build-cable-e2e.md`). Whenever something confuses you, is slow, or gets
something wrong, write one line on the form at the end. The next daemon session turns each note into a reproduced
bug, a design question for you, or a suspect (`../SUSPECTS.md`).

Prepared by `W40.i5` on 2026-10-22. Rewritten by `W40.i5-usb` on 2026-10-31 for the iPhone cable route
(`W40.i-usb-mac`, `W40.i-usb-app`, `W40.i-usb-build`), which is now the first way to connect, and for what your
install on 2026-10-29 found. The capture apps' state is in [`../capture.md`](../capture.md) (the feature ledger;
the iPhone's rows are C-31 to C-44, the cable is C-43).

## What the install on 2026-10-29 found

These are folded into the steps below. Listed here so the session that files your notes knows they are known.

- The bundle id `com.archiveprocessor.capture.ios` is registered to another Apple team, so a personal team
  cannot sign it. `com.charlespetersen.capture.ios` worked, and the steps below use it.
- Xcode did not list the phone until it was paired from the command line with `xcrun devicectl manage pair`.
- The Developer Mode setting never appeared. On iOS 18.6.2, on a Stanford-managed phone, trusting the developer
  under VPN & Device Management was enough.
- A command-line build and a `devicectl` install avoid the Xcode signing edits (the old pack's steps 3 and 4),
  and `xcodegen generate` can no longer undo them.

The app installed that day predates the cable route, so it has to be installed again (steps 3 and 4 below). It
replaces the old one in place; nothing was captured with it.

## A few days before (at home, no phone needed)

1. **Only if you want to try the Google Drive relay (task 11): make the iPhone's Google sign-in client.** About 15
   minutes in the Google Cloud console. The cable and Wi-Fi need none of it, so skip this if they are enough for
   now. The steps are in `ArchiveProcessor/ArchiveCapture/README-oauth.md` §"iPhone companion" (that file lives in
   the Android folder but covers both phones):
   - In the same Google Cloud project as the Mac's Desktop client, create an OAuth client of type **iOS**, with
     the bundle id **`com.charlespetersen.capture.ios`** (not the one the guide shows) and "Custom URI scheme"
     turned on.
   - Your Google account must be a Test user on the consent screen. It is the same account the Mac signs in with.
   - Put the client id in a new file, `ArchiveProcessor/ArchiveCaptureiOS/Config/DriveLocal.xcconfig`, as one line:
     `DRIVE_OAUTH_CLIENT_ID = <the id>.apps.googleusercontent.com`. The file is gitignored, so it stays on this Mac.
     Do this before step 3 of the install, because the id is read when the app is built.
   - The Mac side must already be signed in to Drive (Archive Processor ▸ Settings ▸ Live Capture).

## Install the current app (15 to 20 minutes, not counted)

You did this once on 2026-10-29, so the phone already trusts this Mac and your Apple ID. The commands are the
standard command-line route, but the session that wrote this pack could not run them, as no phone is attached to
it. If one fails, note the exact message on the form; that is a finding too.

1. Unlock the phone and plug it into the Mac with the cable. If it asks whether to trust this computer, tap
   **Trust**. Check the Mac sees it:
   ```bash
   xcrun devicectl list devices
   ```
   The phone should be listed as `connected`. If it is missing or says it is not paired, pair it:
   `xcrun devicectl manage pair --device "<the phone's name>"`, and tap Trust on the phone.
2. Generate the project. Signing is set on the command line in the next step, so nothing in Xcode needs changing:
   ```bash
   cd ~/Claude/"Archive Suite"/ArchiveProcessor/ArchiveCaptureiOS && xcodegen generate
   ```
3. Build for the phone, signed with your personal team, under your bundle id. The team id is read from your
   Apple Development certificate:
   ```bash
   TEAM=$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject \
     | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
   echo "team: $TEAM"
   xcodebuild -project ArchiveCaptureiOS.xcodeproj -scheme ArchiveCaptureiOS -configuration Debug \
     -destination 'generic/platform=iOS' -derivedDataPath build/device -allowProvisioningUpdates \
     PRODUCT_BUNDLE_IDENTIFIER=com.charlespetersen.capture.ios DEVELOPMENT_TEAM="$TEAM" \
     CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES build
   ```
   It should end `** BUILD SUCCEEDED **`. If it says no account or no profile, open Xcode ▸ Settings ▸ Accounts,
   check your Apple ID is there, and run it again.
4. Install it and open it:
   ```bash
   xcrun devicectl device install app --device "<the phone's name>" build/device/Build/Products/Debug-iphoneos/ArchiveCaptureiOS.app
   xcrun devicectl device process launch --device "<the phone's name>" com.charlespetersen.capture.ios
   ```
   If the phone says the developer is not trusted: Settings ▸ General ▸ **VPN & Device Management** ▸ your Apple
   ID under "Developer App" ▸ **Trust**, then launch again. If iOS asks for **Developer Mode** (it did not on
   2026-10-29), turn it on under Settings ▸ Privacy & Security, let the phone restart, and confirm **Turn On**.

A free account's install lasts seven days, and then the app stops opening. Steps 3 and 4 reinstall it at any time.
If you rebuild after pulling new code, run `xcodegen generate` first; it no longer undoes anything.

**The Mac side**

5. Start the Processor: `cd ~/Claude/"Archive Suite" && ./launch.sh processor`. This builds current `main` first
   if the app is out of date. If macOS asks for the login Keychain password for the OCR key, choose
   **Always Allow**.
6. Make a scratch folder for this session, so nothing goes near your real collection:
   ```bash
   mkdir -p ~/Library/Caches/ArchiveSuiteRehearsal/iphone-1/output
   ```
   In the **Live Capture** pane, set the **Output folder** (Choose…) to that folder. `~/Library` is hidden in the
   panel, so press ⇧⌘G and paste the path. **Check the path before you shoot anything.** The photos as received
   are kept in the fixed Backup Folder, `~/Pictures/Archive Processor Live Capture/` (the pane's **Backup Folder**
   button opens it). That is the app's own folder, not your collection.
7. Leave the OCR provider and tagging as they are in Settings. A session of about 50 pages costs a few cents of
   OCR.
8. In the Live Capture pane, press **Start** under Connection. A "Pair the phone" box appears with a QR code. The
   one code works for the cable, Wi-Fi and the Drive relay.

Have four or five real documents ready, about 25 pages in all. Use copies or unimportant pages: the test is of
the capture, not of the material. Include one in landscape.

## Problems we already know about

No fix for the iPhone app or for Live Capture is queued, so nothing below is about to change. What remains are
four unconfirmed suspects (`../SUSPECTS.md`), each raised by reading the code or by a simulator run, and what the
cable route has not been seen doing on a device. If you hit one, you don't need to describe it, but **do write
how much it got in your way**.

- **The cable has only been tested in the simulator.** Not yet seen on a real phone: the Mac reaching the app
  through the cable, the trust prompt, recovery after a lock (expected about 10 seconds after you unlock, an
  estimate), and whether pages reach the Mac at a normal speed. Tasks 2 to 5 are those checks.
- **Sending stops while the app is in the background or the phone is locked** (S-023), on the cable and on Wi-Fi
  alike: the app has no background mode. It should carry on by itself once you come back. Tasks 5 and 9.
- **A photo might be written in the wrong format or the wrong way up** (S-022). Task 6 checks it.
- **A year you give on the phone may keep the day the OCR read** from a different date on the page (S-040). For
  example, a page dated "December 3, 1974" that you tag 1962 may be filed "1962, Day 3". In task 3, look at the
  filed PDF's tags and note whether the day or month is one you did not give.
- **Over the Google Drive relay, Finish session may not wait for pages still on the phone** (S-038). In task 11,
  wait until the last page has reached the Mac before you press Finish, then note whether the PDF has every page.

The QR no longer disappears when the Mac has no Wi-Fi address (S-037, fixed 2026-10-31): it then says to pair
over the cable or Cloud.

## Part A: the cable (40 to 50 minutes)

The minutes are a guide only. If one task is going badly, note it and move on. The ledger rows each task covers
are in brackets, for the session that files your notes. You don't need them.

1. **First launch and permissions (5 min).** The phone asks for the camera. Allow it. It may also ask about
   finding devices on your local network. Allow that too. Did each prompt say clearly why it was needed? Does the
   camera picture appear straight away? [C-35]
2. **Pair over the cable (5 min).** With the phone plugged in and unlocked, the app opens on "Connect to your
   Mac", with Cable, Wi-Fi and Cloud across the top. **Cable** should already be chosen, with a green "A Mac is on
   the cable". Tap **Scan QR code** and point it at the Mac's screen. The phone should say "Connected · <the Mac's
   name> · cable", and the Mac's pane "Connected". If the green line never appears, note what it says instead,
   unplug and replug, and try once more. Then pair a second time by hand: **Re-pair**, Cable, "Enter pairing
   code", and type the token the Mac shows. Is the token easy to read off the Mac? [C-43, C-32, C-33]
3. **Shoot one document (10 min).** Photograph a three-page document, one page per shot, in ordinary room light.
   Press **End segment**. In "Tag this document", pick a quality (Q2) and a year, then **Apply & continue**. On the
   Mac, watch the pages arrive and the tag card fill in. Press **Finish session** and look at the filed PDF in the
   output folder: are the pages sharp, the right way up, and in order, and does it carry the quality and year
   you gave it? Roughly how long did each page take to reach the Mac? [C-43, C-35, C-37, C-38]
4. **Unplug mid-send (5 min).** Shoot five pages quickly, then at once pull the cable out. Wait 30 seconds and plug
   it back in. Did the pages go across by themselves, and how long after you plugged in? Nothing should be missing
   or doubled at the end. [C-43, C-39]
5. **Lock the phone while it sends (5 min).** Shoot five pages, then at once lock the phone (not only switch apps)
   for about 30 seconds. Unlock it and come back to the app. Did sending stop while it was locked, and how long
   after you came back did it carry on? [C-43, C-39; S-023 on real hardware]
6. **A landscape page, and the file format (5 min).** Shoot a page that is wider than it is tall, holding the
   phone sideways, then a normal page held upright. End the segment, then run this on the Mac and paste the output
   into your notes:
   ```bash
   cd ~/Pictures/"Archive Processor Live Capture" && \
     find . -name '*.jpg' -mmin -10 | while read -r f; do echo "$f $(xxd -l 3 -p "$f")"; sips -g pixelWidth -g pixelHeight "$f" | tail -2; done
   ```
   Every file should start `ffd8ff` (a real JPEG). The landscape page's PDF page should read the right way up.
   [C-35; settles suspect S-022]
7. **Box and Folder with the camera (3 min).** Shoot a real box label with **Box** and a folder label with
   **Folder**. Are the labels readable in what reaches the Mac? [C-36, C-35]

## Part B: Wi-Fi and the Drive relay (30 to 45 minutes, another day is fine)

The phone and the Mac must be on the same network, and that network must let devices on it reach each other.
Many university and office networks do not allow that. If pairing fails with "Can't reach the Mac", turn on the
phone's **Personal Hotspot** and join the Mac to it, then press Stop and Start in the Live Capture pane so it shows
the new address. Unplug the cable for this part, so you know the pages are coming over Wi-Fi.

*Tasks 9 and 10 are short on purpose.* The simulator has already pressed their buttons against the real Mac
(`W40.i-sim-ui`): Retry and auto-retry with the Mac stopped, the app sent to the background and closed with pages
unsent, the Clear and delete dialogs, and Re-pair. What it cannot show is a real network dropping.

8. **Pair over Wi-Fi (5 min).** **Re-pair**, choose **Wi-Fi**, scan the same QR. The phone should say "Connected ·
   <the Mac's name>", without "cable". Shoot a two-page document and file it. [C-31, C-33, C-35]
9. **Lose the network mid-send (5 min).** Shoot five pages quickly, then at once turn off the phone's Wi-Fi, or
   walk out of range. Turn Wi-Fi back on. Did the pages go across by themselves, and how long after the network came
   back? Nothing should be missing or doubled at the end. [C-39]
10. **Close the app with pages unsent (3 min).** With Wi-Fi off, shoot three pages. Swipe the app away from the app
    switcher, turn Wi-Fi back on, and open the app again. Do the three pages send? [C-41, C-40]
11. **Optional: the Google Drive relay (10 min).** Only if the client from the preparation is in place. On the Mac,
    make sure Live Capture shows a "Cloud relay code". On the phone, **Re-pair**, choose **Cloud**, scan the same
    QR, and sign in to Google when asked. Shoot a two-page document and file it. Did the sign-in work on the first
    try? How long did each page take to reach the Mac? [C-44]
12. **The phone itself (any time).** During the other tasks, note anything about the device: the shutter's
    delay, focus on close pages, the phone getting warm, the battery, text cut off on this screen size, anything
    hard to reach with one hand. Which route would you use on a real archive day, and why?

## When you are done

- **On the phone:** keep the app if you like; it is yours. If you used **Save to phone**, the photos are in your
  Photos library.
- **On the Mac:** leave `~/Library/Caches/ArchiveSuiteRehearsal/iphone-1/` and the session's folder under
  `~/Pictures/Archive Processor Live Capture/` in place for the session that files your notes.
- Save the form below as `verification/sessions/iphone-1-returned.md`, or hand it over in any form.

## The form

Severity: **B** it stopped me or got something wrong · **A** annoying, slowed me down · **C** cosmetic · **?**
just a thought or a question.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
| 9 | | | | |
| 10 | | | | |
| 11 | | | | |
| 12 | | | | |

**Install:** which step failed or confused you, and what did the command or the phone say?

**The phone:** model and iOS version (Settings ▸ General ▸ About), and whether it is still managed by Stanford.

**The known problems above:** which ones got in your way, and how much?

**Overall:** would you capture a real archive day with an iPhone as it stands, and over which route? If not, what
is the one thing that stops you?

**Anything else:**

## For the session that files the notes

For each line on the form:

- **Something went wrong or was slow:** if it can be reproduced in the simulator or on the Mac side, file a
  `W40.fix-ios-<slug>` or `W40.fix-processor-<slug>` item with the reproduction and a severity, and mark the
  ledger row `broken`. Severity follows phase rule 8 (`S1` data loss or a write to the wrong file · `S2` a
  promised feature broken or unreachable · `S3` wrong but recoverable · `S4` cosmetic). The owner's letter informs
  it but does not set it. For a cable failure the simulator cannot show (the real usbmuxd's forwarding, the trust
  prompt, ATS on a device), start from `ArchiveProcessor/scripts/usbmux-probe.sh` and the Mac's log.
- **Only reproducible on a real phone** (camera, focus, the cable, a real network, the install itself): file it
  all the same, with the owner's note and any output pasted as the reproduction, and say in the item that its
  re-check needs the owner's phone.
- **The install steps:** correct this pack's install section from what the form says, so the next install follows
  what worked.
- **A judgement call** ("I expected X"): put a question in the Daemon Report, one per note.
- **Not reproducible yet:** add a `SUSPECTS.md` entry with "Raised: owner session iphone-1".
- Move the ledger rows the session showed working to `works`, citing the returned form as evidence (phase
  rule 1). The owner is not the builder, so rule 6 allows it. C-43 is the cable (tasks 2 to 5). Settle S-022 and
  S-023 from tasks 5, 6 and 9. Where the notes bear on them, add history to S-040 (task 3) and S-038 (task 11).
  Update `ArchiveProcessor/KNOWN_ISSUES.md`'s cable limitation entry (W40.i-usb-build) with what the device
  showed: the lock recovery time (task 5), the speed per page (task 3), and ATS.
- Keep the returned form as `verification/sessions/iphone-1-returned.md`.
