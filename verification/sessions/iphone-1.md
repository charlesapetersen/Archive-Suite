# Borrowed-iPhone session 1

> **Not handed over yet (2026-10-22).** This pack is drafted, but it is not time for the session. Three Mac-side
> Live Capture fixes are queued and would get in the way of every task that ends in filing on the Mac
> (`W40.fix-live-vision-drops-card-tags`, `W40.fix-processor-live-emptied-mixed`,
> `W40.fix-live-finalize-failure-silent`). The simulator has also not yet shown the parts of the app it can show
> (`W40.i-sim-ui`): the buttons pressed by touch, Retry, backgrounding, relaunch, and the dialogs. `W40.i5` waits
> on all four items. The session that closes it refreshes this pack against what they found, removes this note,
> and only then hands it over (`execution-plans/verification-phase/01-daemon-plan.md` §G "Is it time?").

About 60 to 90 minutes with a borrowed iPhone. Most of it is testing, plus 20 to 30 minutes of setup on the day.
The phone is borrowed for one concentrated period, so this session covers only what a simulator cannot: the
camera, a real network, and the device itself. Everything else about the iPhone app was checked in the simulator
first (`../evidence/capture/W40.i3-ios-e2e.md`, and `W40.i-sim-ui` once it ships). Whenever something confuses
you, is slow, or gets something wrong, write one line on the form at the end. The next daemon session turns each
note into a reproduced bug, a design question for you, or a suspect (`../SUSPECTS.md`).

Prepared by `W40.i5` on 2026-10-22, at the commit that added this file. The capture apps' state is in
[`../capture.md`](../capture.md) (the feature ledger; the iPhone's rows are C-31 to C-44).

## A few days before (at home, no phone needed)

1. **Only if you want to try the Google Drive relay (task 9): make the iPhone's Google sign-in client.** This takes
   about 15 minutes in the Google Cloud console. Wi-Fi capture needs none of it, so skip this step if Wi-Fi is
   enough for now. The steps are in `ArchiveProcessor/ArchiveCapture/README-oauth.md` §"iPhone companion" (that
   file lives in the Android folder but covers both phones):
   - In the same Google Cloud project as the Mac's Desktop client, create an OAuth client of type **iOS**.
     Use the bundle id `com.archiveprocessor.capture.ios` and turn on "Custom URI scheme". If you have to change the
     bundle id on the day (see *Signing*, step 4), this client has to be made again with the new id.
   - Your Google account must be a Test user on the consent screen. It is the same account the Mac signs in with.
   - Put the client id in a new file, `ArchiveProcessor/ArchiveCaptureiOS/Config/DriveLocal.xcconfig`, as one line:
     `DRIVE_OAUTH_CLIENT_ID = <the id>.apps.googleusercontent.com`. The file is gitignored, so it stays on this Mac.
   - The Mac side must already be signed in to Drive (Archive Processor ▸ Settings ▸ Live Capture).
2. **Check Xcode can see an Apple ID.** Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID, and sign in with your own
   Apple ID. A free account is enough. Xcode then lists "<your name> (Personal Team)".

## On the day: install the app (20 to 30 minutes, not counted)

No step below has been tried on a real device. Each one is the standard route for a free Apple ID. If one of them
fails, note the exact message on the form. That failure is itself a finding.

**Signing**

1. Ask the lender to unlock the phone. Connect it to the Mac with a cable, and tap **Trust** on the phone when it
   asks whether to trust this computer.
2. Generate and open the project:
   ```bash
   cd ~/Claude/"Archive Suite"/ArchiveProcessor/ArchiveCaptureiOS && xcodegen generate && open ArchiveCaptureiOS.xcodeproj
   ```
   Do not run `xcodegen generate` again during the session. It rewrites the project and drops the signing changes
   you are about to make. The project is generated and gitignored, so changing it in Xcode is fine.
3. Select the **ArchiveCaptureiOS** target and open **Build Settings**. The project is set up for the unsigned
   simulator build, so change two settings for the device: **Code Signing Identity** to "Apple Development", and
   **Code Signing Required** to "Yes".
4. Open **Signing & Capabilities**. Tick "Automatically manage signing" and pick **<your name> (Personal Team)**.
   If Xcode says the bundle id is not available, change it to something of your own, such as
   `com.<yourname>.capture.ios`. Wi-Fi capture is unaffected, but the Drive client from step 1 above then no
   longer matches, so skip task 9. The app needs no special capabilities (no App Groups, iCloud or push), so a free
   team should have nothing else to refuse.
5. At the top of the window, pick the borrowed iPhone as the run destination and press **Run** (⌘R).

**On the phone, the first time**

6. **Developer Mode.** iOS refuses the first install until it is on. Go to Settings ▸ Privacy & Security ▸
   **Developer Mode**, turn it on, and let the phone restart. After the restart, confirm **Turn On**. The setting
   appears only after Xcode has tried to install once, so the order is: Run, refused, turn it on, Run again.
7. **Trust the developer.** The app installs but will not open until the phone trusts your Apple ID: Settings ▸
   General ▸ **VPN & Device Management** ▸ your Apple ID under "Developer App" ▸ **Trust**.
8. Press **Run** in Xcode again. The app, called **Archive Capture**, opens on the phone.

A free account's install lasts seven days, and then the app stops opening. You can reinstall it from Xcode at any
time while the phone is with you.

**The Mac side**

9. Start the Processor: `cd ~/Claude/"Archive Suite" && ./launch.sh processor`. This builds current `main` first if
   the app is out of date.
10. Make scratch folders for this session, so nothing goes near your real collection:
    ```bash
    mkdir -p ~/Library/Caches/ArchiveSuiteRehearsal/iphone-1/output
    ```
    In the **Live Capture** pane, set the **Output folder** (Choose…) to that folder. `~/Library` is hidden in the
    panel, so press ⇧⌘G and paste the path. **Check the path before you shoot anything.** The photos as received
    are kept in the fixed Backup Folder, `~/Pictures/Archive Processor Live Capture/` (the pane's **Backup Folder**
    button opens it). That is the app's own folder, not your collection.
11. Leave the OCR provider and tagging as they are in Settings. A session of about 40 pages costs a few cents of
    OCR (the simulator runs cost a few cents in total).
12. In the Live Capture pane, press **Start** under Connection. A "Pair the phone" box appears with a QR code and
    the Mac's address.

**The network**

The phone and the Mac must be on the same network, and that network must let devices on it reach each other. Many
university and office networks do not allow that. If pairing fails with "Can't reach the Mac", turn on the
phone's **Personal Hotspot** and join the Mac to it, then press Stop and Start in the Live Capture pane so it shows
the new address. There is no cable route for an iPhone: the app is Wi-Fi or Google Drive only, by design. The
Mac's QR caption says "USB, Wi-Fi, or Cloud". The USB part applies to Android only.

Have three or four real documents ready, about 15 pages in all. Use copies or unimportant pages: the test is of
the capture, not of the material. Include one in landscape.

## Problems we already know about

Each of these has a fix item filed. If you hit one, you don't need to describe it, but **do write how much it got in
your way**.

- *(The session that hands this pack over fills this in from the items that are still open by then. Only problems
  that will stay open for a while belong here, each with the tasks it touches.)*
- **The Mac's QR does not appear** if the Mac's network address is not on its main Wi-Fi or Ethernet port
  (suspect S-037, unconfirmed). If that happens, type the address by hand on the phone (task 2) and note it.

## The tasks (60 to 90 minutes)

The minutes are a guide only. If one task is going badly, note it and move on. The ledger rows each task covers
are in brackets, for the session that files your notes. You don't need them.

1. **First launch and permissions (5 min).** The phone asks for the camera. Allow it. Later it asks about finding
   devices on your local network. Allow that too. Did each prompt say clearly why it was needed? Does the camera
   picture appear straight away? [C-35]
2. **Pair by scanning the QR (5 min).** On the phone, choose Wi-Fi, then **Scan QR code**, and point it at the
   Mac's screen. The phone should say "Connected · <the Mac's name>", and the Mac's pane should change to
   "Connected". Then pair a second time by hand: **Re-pair**, then "Enter manually" with the host, port and token
   the Mac shows. Is the token easy to read off the Mac? [C-31, C-32, C-33]
3. **Shoot one document (10 min).** Photograph a three-page document, one page per shot, in ordinary room light.
   Press **End segment**. In "Tag this document", pick a quality (Q2) and a year, then **Apply & continue**. On the
   Mac, watch the pages arrive and the tag card fill in. Press **Finish session** and look at the filed PDF in the
   output folder: are the pages sharp, the right way up, and in order, and does it carry the quality and year
   you gave it? [C-35, C-37, C-38]
4. **A landscape page, and the file format (5 min).** Shoot a page that is wider than it is tall, holding the
   phone sideways, then a normal page held upright. End the segment, then run this on the Mac and paste the output
   into your notes:
   ```bash
   cd ~/Pictures/"Archive Processor Live Capture" && \
     find . -name '*.jpg' -mmin -10 | while read -r f; do echo "$f $(xxd -l 3 -p "$f")"; sips -g pixelWidth -g pixelHeight "$f" | tail -2; done
   ```
   Every file should start `ffd8ff` (a real JPEG). The landscape page's PDF page should read the right way up.
   [C-35; settles suspect S-022]
5. **Box and Folder markers (5 min).** Shoot a box label with **Box**, then a folder label with **Folder**, then
   two pages of a document. On the Mac, do the box and folder land as markers and not as pages? [C-36]
6. **Lose the network mid-send (10 min).** Shoot five pages quickly, then at once turn off the phone's Wi-Fi, or
   walk out of range. Shoot two more. Turn Wi-Fi back on. Do the pages go across by themselves, or does it take
   **Retry**? Does the Mac's pane show that the phone still has pages to send while they wait? Nothing should be
   missing or doubled at the end. [C-39, C-42]
7. **Leave the app while it sends (5 min).** Shoot five pages, then at once lock the phone, or switch to another
   app, for about 30 seconds. Come back. Did the sending carry on, stop, or fail? [C-39; settles suspect S-023 on
   real hardware]
8. **Close the app with pages unsent (5 min).** With Wi-Fi off, shoot three pages. Swipe the app away from the app
   switcher, turn Wi-Fi back on, and open the app again. Are the three pages still there, and do they send?
   [C-41, C-40]
9. **Optional: the Google Drive relay (10 min).** Only if the client from the preparation is in place. On the Mac,
   make sure Live Capture shows a "Cloud relay code". On the phone, choose **Cloud**, scan the same QR, and
   sign in to Google when asked. Shoot a two-page document and file it. Did the sign-in work on the first try?
   How long did each page take to reach the Mac? [C-44]
10. **The phone itself (any time).** During the other tasks, note anything about the device: the shutter's
    delay, focus on close pages, the phone getting warm, the battery, text cut off on this screen size, anything
    hard to reach with one hand.

## When you are done

- **On the phone, before you give it back:** delete Archive Capture (press and hold its icon ▸ Remove App).
  Turn Developer Mode off again (Settings ▸ Privacy & Security). If you used **Save to phone**, the photos are in
  the lender's Photos library, so delete them there too.
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

**Setup:** which install step failed or confused you, and what did Xcode or the phone say?

**The phone:** model and iOS version (Settings ▸ General ▸ About).

**The known problems above:** which ones got in your way, and how much?

**Overall:** would you capture a real archive day with an iPhone as it stands? If not, what is the one thing that
stops you?

**Anything else:**

## For the session that files the notes

For each line on the form:

- **Something went wrong or was slow:** if it can be reproduced in the simulator or on the Mac side, file a
  `W40.fix-ios-<slug>` or `W40.fix-processor-<slug>` item with the reproduction and a severity, and mark the
  ledger row `broken`. Severity follows phase rule 8 (`S1` data loss or a write to the wrong file · `S2` a
  promised feature broken or unreachable · `S3` wrong but recoverable · `S4` cosmetic). The owner's letter informs
  it but does not set it.
- **Only reproducible on a real phone** (camera, focus, real network, the install itself): file it all the same,
  with the owner's note and any output pasted as the reproduction, and say in the item that its re-check needs
  the next borrowed phone.
- **A judgement call** ("I expected X"): put a question in the Daemon Report, one per note.
- **Not reproducible yet:** add a `SUSPECTS.md` entry with "Raised: owner session iphone-1".
- Move the ledger rows the session showed working to `works`, citing the returned form as evidence (phase
  rule 1). The owner is not the builder, so rule 6 allows it. Settle S-022 and S-023 from tasks 4 and 7.
- Keep the returned form as `verification/sessions/iphone-1-returned.md`.
