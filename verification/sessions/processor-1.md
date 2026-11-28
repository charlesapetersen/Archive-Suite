# Processor and Live Capture guided session

About 45 minutes in Archive Processor (Process Files and Live Capture), revisiting the tasks from the November 23
walkthrough ([`W40.g3-owner-walkthrough-20261123.md`](../evidence/processor/W40.g3-owner-walkthrough-20261123.md)) on
scratch copies with a separate output destination. Work as you would on a real archive day. Whenever something confuses
you, feels slow, or gets something wrong, write one line on the form at the end. Short notes are enough, and so is
"I expected X". The next session turns each note into a reproduced bug, a design question for you, or a suspect
(`verification/SUSPECTS.md`).

Prepared by `W40.g3` on 2026-11-28.

**Is it time? Yes (judged 2026-11-28).** Every one of the eight findings from the November 23 walkthrough has shipped,
the Gate B architecture review and its four guided-path findings shipped, all fourteen open Processor items from the
November 27 readiness check shipped, both remaining 1.0 Mac local-model follow-ups (`W49.proc-kind-split-mac-fu`,
`W49.proc-managed-item-fields-text`) shipped, and Finder-tag mirroring was retired suite-wide
(`W49.storage-finder-drop-mirror`, `7ecc97d4`). Zero unblocked 1.0 items remain in the queue; the remaining work is
owner-gated, behind Nice to Have (`W46.nice-to-have`), or deferred to 2.0 (`W50.v2-release`). Before handing this pack
over, the whole `ArchiveProcessorUITests` suite ran in the off-screen macOS 27.2 VM at `7ecc97d4` alongside fresh
scratch rehearsals for setup, Process Files, and Live Capture; the results are under *Checked before handover* at the
end.

**What changed since the November 23 walkthrough:**

- **Live Capture Finish no longer stalls on Drive.** An idle or starting Drive receiver no longer blocks wired Finish
  from reaching rotation review and collection naming (`W40.fix-live-finish-settle`). A session with genuine relay
  activity still waits safely until the phone reports zero pending pages (`W49.proc-fix-s038`). A stalled scan tells
  you how to cancel, check Drive sign-in, and restart.
- **No Keychain prompt storm at launch or wired Start.** Process Files checks for saved provider keys without opening
  them until needed, and Live Capture checks Drive once at Start; if stored Drive credentials need approval, USB and
  Wi-Fi still start cleanly (`W40.fix-processor-keychain-prompts`).
- **Clearer first-launch notice.** Now reads *"Keep files for this app stored locally"* and explains the risks of cloud
  drives (`W40.fix-processor-local-notice`).
- **Redesigned 5-tab Settings.** Replaced the dense 8-tab layout with **Processing · Output · Capture · Accounts ·
  Advanced**, plus an optional **Compare routes & trade-offs…** Advisor sheet (`W49.proc-settings-redesign-core`,
  `W49.proc-settings-advisor-advanced`, `W40.fix-processor-general-padding`, `W40.fix-processor-reading-scan`).
  Turning on *"Keep pages on this Mac"* grays out cloud readers (`W49.proc-stays-on-mac-gray-cloud`).
- **Collection interview waits for file intake.** Picking a fresh output folder no longer interrupts you before you add
  files; *About the collection* opens once files are added (or when changing destinations with files queued)
  (`W40.fix-processor-collection-prompt-intake`).
- **Matching Preservation Copy filenames.** Preserved originals now use the filed PDF's base name and original extension
  (with ` - page N` when several originals merge into one PDF) instead of `source-1.jpeg`, verified byte-for-byte in
  `Preservation/<document UUID>/<file UUID>/` (`W40.fix-processor-preservation-names`).
- **Catalogue-native output with no Finder tags.** Filed PDFs keep all fields (dates, subjects, quality, read state,
  item fields, preservation digest) in their adjacent `<name>.pdf.archivesuite.json` companion and carry **zero Finder
  tags** (`W49.storage-finder-drop-mirror`). Segment JSON sidecars are off by default (`W49.proc-catalogue-cutover`).
- **App-managed local models & free Mac handwriting split.** Settings ▸ Accounts offers in-app downloads for
  Qwen3.5 9B, Qwen3-VL 8B, LightOnOCR-3 4B, Qwen3.5 4B (for Mac item-field publication dates), and Gemma 3 12B (for
  box/folder labels), coordinated one-at-a-time under a 10 GB memory ceiling (`W49.proc-managed-local-ocr`,
  `W49.proc-managed-ocr-9b-check`, `W49.proc-kind-split-mac-fu`, `W49.proc-managed-item-fields-text`). Apple Vision runs
  route handwritten pages to the best local reader on a dedicated single-worker lane while typed pages keep running
  concurrently on Vision.
- **Matching Android launcher icon.** Archive Capture on Android now uses the Mac Processor icon artwork as an adaptive
  icon (`W40.fix-android-launcher-icon`).
- **Per-collection date order, enclosures & totals.** Live Capture honours per-collection numeric date order (US vs
  International) (`W49.proc-live-date-order-per-collection`); document review lets you assign an enclosure's cover
  after a split (`W49.proc-s047-cover-select`); adding a photo twice lists and reads it once (`W49.proc-fix-s048`);
  refused Live Capture tagging calls are named explicitly in both the row and Finish summary (`W49.proc-fix-s045`).

## Before you start (5 minutes, not counted)

1. **Make a fresh scratch input and a separate scratch output folder.** Never point the session at
   `~/Desktop/Google Drive/Archival Photos/` or directly at `ArchiveProcessor/Test Files/`. These commands APFS-clone a
   small slice of the existing rehearsal set (`RG 165 — War Department`) into a fresh nested scratch tree plus a clean
   output folder:
   ```bash
   BASE=~/Library/Caches/ArchiveSuiteRehearsal/processor-session-2
   SRC=~/Library/Caches/ArchiveSuiteRehearsal/processor-set/"RG 165 — War Department"
   rm -rf "$BASE" && mkdir -p "$BASE/in/Box 1/Folder A" "$BASE/in/Box 1/Folder B" "$BASE/out-tree" "$BASE/out-flat" "$BASE/out-live"
   ls "$SRC"/*.jpg | head -n 4 | xargs -I{} cp -c -p "{}" "$BASE/in/Box 1/Folder A/"
   ls "$SRC"/*.jpg | sed -n '5,8p' | xargs -I{} cp -c -p "{}" "$BASE/in/Box 1/Folder B/"
   ```
   *(If `processor-set/` is missing, rebuild it read-only with
   `cd ~/Claude/"Archive Suite" && python3 ArchiveProcessor/scripts/make-processor-rehearsal.py --collection 'RG 165 — War Department'`.)*
2. **Start Archive Processor from current `main`:**
   ```bash
   cd ~/Claude/"Archive Suite" && ./launch.sh processor
   ```
   This builds current `main` if needed and opens the app.
3. **Quick check before Task 2:** open **Settings (⌘,) ▸ Output** and confirm **Keep full-resolution originals in a
   Preservation folder** is ON (it defaults to on for fresh installs; if an earlier test or session turned it off on this
   Mac, turn it back on so Task 2 exercises Preservation Copies).
4. **For Live Capture (Tasks 5–6):** have your Android phone (with Archive Capture installed from current `main`) and a
   USB cable ready. Point Live Capture's destination at `~/Library/Caches/ArchiveSuiteRehearsal/processor-session-2/out-live`.
5. Keep this file open beside the app and jot observations on the form at the bottom.

## Problems we already know about

Only limits that are staying open on purpose (or are queued after 1.0):

- **Segment JSON sidecars are off by default.** The catalogue companion (`<name>.pdf.archivesuite.json`) holds dates,
  subjects, quality, item fields, and correspondence names; OCR-only runs keep no separate name list (names stay
  searchable via full-text search in Reader). Turn on *Settings ▸ Advanced ▸ Export segment JSON metadata* only if you
  specifically want `.json` sidecars. *Tasks 2, 3.*
- **Accurate-mode helper downloads still fall back to the legacy Vision OCR GitHub release** until the five archives are
  published to Archive Suite's `visionocrkit-models-1` release (`W49.visionocrkit-drop-legacy-source-owner-ok`). Downloads
  work normally today via the fallback. *Task 1.*
- **Folder-tree intake reads up to 12 levels deep and skips collection re-organisation by design** (the input folder tree
  already decides where each file goes; the level map is offered once per output folder and edited later in Archive
  Reader). *Task 2.*
- **Up-front cost estimates show box/folder label reads per photo rather than a total**, because which photos are label
  shots is only known after OCR. *Task 3.*
- **Collection day-first numeric date order does not yet reach the separate trace/tagging model calls** (it governs the
  dating rule, OCR-damaged forms, image-pass prompt, folder labels, and Reader's folder-date offer; unifying the
  post-OCR metadata call is queued as `W49.proc-metadata-unified-apply`). *Tasks 3, 5.*
- **Advisor ▸ Range tab light-mode contrast:** an automated audit saw one intermittent unnamed contrast hit in light
  mode (`W49.proc-audit-range-contrast-intermittent`). Worth glancing at if you open the Advisor in light appearance.
  *Task 1.*

## The tasks (45 minutes)

The minutes are a guide. If one task goes badly, note it and move on.

1. **First launch, Keychain quietness, and Settings scan (8 min).**
   Launch the app cleanly. Count any Keychain password prompts at launch (expect **zero**). Read the local-storage
   notice if shown: is *"Keep files for this app stored locally"* clear? Open **Settings (⌘,)** and click through all
   five tabs (**Processing · Output · Capture · Accounts · Advanced**) in your usual appearance (and try toggling dark
   or light once).
   - On **Processing**: pick **Fast & Free (Apple Vision)** (or your preferred reader) and toggle **Keep pages on this
     Mac** — do cloud readers gray out cleanly with a clear explanation? Open **Compare routes & trade-offs…** (Advisor)
     briefly and close it.
   - On **Output**: confirm **Keep full-resolution originals in a Preservation folder** is ON, and note that the old
     Finder-tag mirroring switch is gone.
   - On **Accounts**: check **Local models on this Mac** (Qwen3.5 9B, Qwen3-VL 8B, LightOnOCR-3 4B, Qwen3.5 4B, Gemma 3
     12B) — are sizes, memory ceilings, and Download/Remove controls clear? (Do not wait for a multi-GB download unless
     you want to test one.)

2. **Fresh Process Files — nested folder tree, companions, Preservation Copies & run totals (12 min).**
   In Process Files, set the output folder to `…/processor-session-2/out-tree`. Notice whether *About the collection*
   stays quiet until you actually add files. Now drag or add `…/processor-session-2/in` (which holds `Box 1/Folder A`
   and `Box 1/Folder B`, 8 photos total).
   - When asked whether to read the folders inside, choose to preserve the folder tree. If *About the collection* opens
     now (after intake), review or dismiss it.
   - Try adding one of the same photos a second time: does Processor refuse the duplicate cleanly and keep the count at
     8?
   - Check the pre-run count, time/cost estimate, and Start with **Apple Vision** (free, on this Mac; if you have a
     downloaded local handwriting reader, note whether handwritten pages route to it while typed pages keep moving).
   - When the run finishes, inspect the run summary totals and check `out-tree/` in Finder:
     - Are the PDFs filed under `Box 1/Folder A/` and `Box 1/Folder B/`?
     - Does each PDF have an adjacent `<name>.pdf.archivesuite.json` companion and **zero Finder tags**?
     - Under `Preservation/<doc>/<file>/`, do the preserved JPEGs carry the **same base filenames** as their reading
       PDFs (instead of `source-1.jpeg`)?
     - Open one PDF in Preview or Archive Reader (in catalogue mode) to check image + page-2 text.

3. **Fresh Process Files — review, correction & collection grouping (8 min).**
   Switch output to `…/processor-session-2/out-flat` and add 6–8 flat photos directly from `Folder A` + `Folder B`
   (including at least one box/folder label photo if present, or use a quick paid/local model route with **Tagging** and
   **Review document breaks before filing** enabled).
   - Step through the **Document Segmentation Review** window: try changing one page's classification or boundary with
     the keyboard, and confirm. If an enclosure appears, check the **"Sent with:"** cover selector.
   - Confirm box/folder labels and collection naming if prompted.
   - Check the finished run summary totals, `out-flat/` PDFs, their `.archivesuite.json` companions, and verify zero
     Finder tags were written onto the filed PDFs.

4. **Live Capture — wired connection, Android icon, tag card & Finish while Drive starts (10 min).**
   Check the Archive Capture launcher icon on your Android phone — does it match the Mac Processor icon?
   Switch Processor to **Live Capture**, set destination to `…/processor-session-2/out-live`, choose **Wired (USB)**
   (or USB + Wi-Fi), and click **Start**.
   - Count any Keychain prompts (expect **zero** for wired start, even if Drive credentials exist).
   - Take 2–3 test photos of a scratch page on the phone as one document segment; add a subject, year, or quality rating
     (e.g. `Q2`) on the Mac tag card and save.
   - Watch the connection indicator: even if Drive shows *"Drive starting…"* or is unavailable, click **Finish** once the
     staged group shows processed.
   - Does Finish move straight into rotation review / collection naming without stalling on Drive?
   - Confirm the collection name and inspect `out-live/<collection>/`: do you see the filed PDF(s), matching
     `.archivesuite.json` companion(s) carrying your tag-card values, matching-name Preservation Copies, zero Finder
     tags, and clean retirement of the staged originals?

5. **Live Capture — staging for later & relay pending safety (4 min).**
   Switch Live Capture to **Stage for later**, send 2 more scratch photos from the phone, and finish staging. Confirm
   the originals stay safely in the session backup and can be handed off cleanly to Process Files (and that already-filed
   photos from Task 4 are not re-offered). If you also use Drive relay, note whether Finish waits safely if a photo is
   still uploading and clears once it arrives.

6. **Help, Diagnostics & quitting cleanly (3 min).**
   Glance at the **Help** menu (Handbook / Diagnostics / Run History) and open **Processing History** to confirm the
   totals from Tasks 2–4 match what ran. Quit (`⌘Q`) — does it exit promptly with no stray prompts?

## When you are done

- Reset Process Files' output folder (and Live Capture's destination) back to your normal destination if you don't want
  them pointing at `processor-session-2/`.
- Leave `~/Library/Caches/ArchiveSuiteRehearsal/processor-session-2/` in place until your notes are filed, in case the
  filing session needs to inspect a companion, run record, or preservation map. After that, delete it with
  `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/processor-session-2`.
- Hand the form back however suits you: tell a session *"file my Processor session notes"* and paste them, or save this
  file with the form filled in.

## Notes form

Severity: **B** it stopped me or got something wrong · **A** annoying, slowed me down · **C** cosmetic · **?** just a
thought or a question.

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

**The known problems above:** which ones got in your way, and how much?

**Overall:** would you trust Archive Processor (Process Files + Live Capture) for a real archive session as it stands?
If not, what is the one thing that stops you?

**Anything else:**

## For the session that files the notes

Follow `execution-plans/verification-phase/01-daemon-plan.md` §G: turn each reproducible defect into a
`W40.fix-processor-<slug>` item with a severity (moving its ledger row to `broken`), each judgement call into a Daemon
Report question (or record the decision if settled live), and any unconfirmed behaviour into `verification/SUSPECTS.md`
with *"Raised: owner session processor-1"*. Tasks that worked as promised count as runtime evidence for their ledger
rows. Archive the returned form as `verification/sessions/processor-1-returned.md`, then delete
`~/Library/Caches/ArchiveSuiteRehearsal/processor-session-2/`.

## Checked before handover

Verified at `main` `7ecc97d4` on 2026-11-28 (zero real money spent, zero real corpus touched):

- **Whole Processor VM UI suite** (`./ops/gui/vm-gui-runner.sh processor xcuitest`, macOS 27.2 off-screen Tart VM):
  **108 tests executed — 88 passed, 20 opt-in journey/visual-review tests skipped, 0 failures, 0 crashes or hangs**
  (2,516.8 s), including:
  - `AccessibilityAuditUITests` (5/5: light, dark, light-by-setting, dark-by-setting, contrast parser)
  - `AppearanceSettingUITests` (2/2), `CloudDriveWarningUITests` (1/1), `LayoutGuardUITests` (3/3)
  - `MessageJourneyUITests` (9/9), `MoneyJourneyUITests` (12/12, including local handwriting split)
  - `ProcessorUITests` (43/43, including `testLiveFinishWithDriveReceiverUnavailable`,
    `testWiredStartWithDriveCredentialsUnavailable`, `testFirstRunOffersReaderDownloadsAndKeepsVision`,
    `testCollectionInterviewWaitsForPickerIntake`, `testGemmaOfferDisclosesSizeAndCanBeDismissed`,
    `testManagedPageReadersShowNeedsAndAskBeforeDownload`)
  - `SettingsTabsUITests` (9/9: 5-tab layout light & dark, `Keep pages on this Mac` cloud gray-out, collection scope,
    rotation & searchable placement; visually verified `settings-tab-output-light.png` & `settings-tab-output-dark-end.png`)
  - `TagsWindowUITests` (1/1) and `TransientStateUITests` (3/3)
- **Headless scratch rehearsals at `7ecc97d4`:**
  - Setup & Settings: `test-settings-tabs.sh` (`ALL PASS`), `test-settings-interviews.sh` (`ALL PASS`),
    `test-local-models.sh` (`ALL PASS`, plus supervisor seam check).
  - Process Files, companions, Preservation Copies & run totals: `test-collection-organize.sh` (`ALL PASS` — nested
    tree filing, per-folder merges, incremental skip, label recording, zero source mutation), `test-header-parity.sh`
    (`ALL PASS`), `test-dual-date.sh` (`ALL PASS`), `test-processing-history.sh` (`ALL PASS`), `test-deferred-output.sh`
    (`ALL PASS`, including `S-056` and `S-057` preservation copy honouring), plus an end-to-end Apple Vision nested tree
    scratch run (`Box 1/Folder A/scan_01.pdf`, `scan_02.pdf`) verifying nested filing, schema-1 `.archivesuite.json`
    companions, zero Finder tags, and `Done. 2 succeeded, 0 failed.` totals.
  - Live Capture & relay safety: `check-relay-finish.py` (`ALL PASS` — `all-pages-before-finish` finalized in 2.92 s,
    `last-page-while-finish-waits` held safely for the arriving relay photo and finalized in 30.21 s),
    `test-filerelay.sh` (`PASS 13/13`, including `S-038` cross-transport relay hold/drain), `test-drive-transport.sh`
    (`PASS`), and `test-recovery.sh` (`ALL PASS`).
