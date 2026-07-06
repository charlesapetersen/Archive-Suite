# Live Capture — Android phone-UI stress test (manual walkthrough)

A bit-by-bit script to fully exercise the **Android** companion (`ArchiveCapture/`) against the Mac's
**Live Capture** tab. Runs only when you're here to hold the phone — every step is: **tap on phone →
what the phone should do → what to check on the Mac**. It stresses pairing (LAN + USB + the new
Re-pair path), capture, markers, on-phone tagging, both processing modes, finish/collection naming,
the backup folder, and failure/recovery. (iPhone is deferred; this is Android-only.)

> **Golden rule under test:** *a captured photo is never lost.* Archival photos can't be re-shot, so
> anywhere below where a photo could vanish (crash, network drop, quit), we verify it survived — on the
> phone's durable queue, in the Mac backup folder, or both.

## Setup (once, before the runs)
1. On the Mac: `./launch.sh`, open the **Live Capture** tab. Confirm the QR code is showing.
2. Build/install the current Android app to the attached phone (`ArchiveCapture/`: `./gradlew installDebug`), matching the current app icon.
3. Have ready: a few printed/pretend **document pages**, one **box** (label visible), one **folder**.
4. Decide the run's **Settings → Live-capture mode** on the Mac (§Run A uses *Process live*, §Run B uses *Stage for later*).
5. Keep the **Backup Folder** in mind: `~/Pictures/Archive Processor Live Capture/` (Mac button reveals it).

---

## Run A — Wi-Fi pairing + Process live (the full happy path)

### A1 · Wi-Fi pairing
1. Phone + Mac on the **same Wi-Fi**, no USB cable.
2. Launch Archive Capture on the phone → it should show the **QR scanner** (no saved endpoint yet).
   - ✅ Expect: camera scanner screen. If it jumps straight to the capture screen, a stale endpoint is saved — do **A5 Re-pair first**, then come back.
3. Point the phone at the Mac's QR code.
   - ✅ Expect: phone recognizes it, shows **connecting…**, then the **capture screen**.
   - ✅ On Mac: the QR **hides** (paired), the tab shows the phone as connected (name).
4. **Stress:** cover the QR / scan a random QR → phone should reject gracefully (no crash, stays on scanner).

### A2 · First captures
5. Tap the **shutter** on a document page.
   - ✅ Phone: capture confirmed (thumbnail/counter increments); full-res shot.
   - ✅ Mac: the photo arrives in the Live Capture staging list; **and** a copy lands in the backup folder `…/<session>/`.
6. Take 2 more pages of the **same** document.
7. Tap **End segment**.
   - ✅ Phone: segment closed; counter/segment indicator advances.
   - ✅ Mac: a **tag card** appears for that document segment (auto-advancing, keyboard-driven).

### A3 · Markers (box / folder)
8. Tap **Box**, photograph the box label.
   - ✅ Phone: box marker recorded (red).
   - ✅ Mac: registered as a **box** → **Red** color; box-label OCR will seed the collection name later.
9. Tap **Folder**, photograph the folder.
   - ✅ Mac: registered as a **folder** → **Purple**.

### A4 · On-phone tagging (minimal)
10. On a new capture, set **priority** (P7–P10) and the **per-page P10** control; set **year/month** if the phone exposes it.
    - ✅ Phone: values stick on the item.
    - ✅ Mac: the tag card / output reflects the phone-supplied priority + date.

### A5 · Re-pair control (the bug we fixed — must work)
11. On the capture screen, open **Re-pair** → confirm the dialog → confirm.
    - ✅ Phone: returns to the **QR scanner** (this is the *only* way back once an endpoint is saved).
    - ✅ Captured-but-unsent items are **retained** (not dropped) across the disconnect.
12. Re-scan the Mac QR → back to capture; any retained items **re-upload** to the endpoint.
    - ✅ Mac: no duplicates (same group+seq replaces, idempotent).

### A6 · Finish (Process live)
13. Tap **Finish session** on the phone (or finish on the Mac).
    - ✅ Mac: for **Process live**, each segment was OCR'd on arrival; at finish you get a **collection-name confirm** per collection, auto-suggested from the box-label OCR and **fuzzy-matched to existing folders**.
14. Confirm/adjust the collection name → finalize.
    - ✅ Output: **PDF + renamed original image** per document (dual output), multi-page docs merged, `NNNNN` numbering continues an existing folder if matched.
    - ✅ Tags on output: year/month/subjects, Red/Purple markers, **`Unread` last**.
    - ✅ Only after a **successful finalize** does the session's backup folder get cleared/pruned — verify the backup folder emptied only post-success.

---

## Run B — USB pairing + Stage for later

### B1 · USB pairing
1. Set Mac **Settings → Live-capture mode = Stage for later**.
2. Connect the phone by **USB**. The Mac auto-runs `adb reverse` and the phone pairs to `127.0.0.1`.
   - ✅ Phone: reaches the capture screen; Mac shows connected over USB.
3. Capture 3–4 pages across 2 documents (End segment between them), one **box**, one **folder**.
   - ✅ Mac: items **collect** (staged); they are **not** OCR'd on arrival (that's live mode).
   - ✅ Backup folder receives every photo.

### B2 · Switch USB → Wi-Fi via Re-pair (the exact scenario the fix targets)
4. Unplug USB. On the phone, **Re-pair** → scanner.
   - ✅ The saved `127.0.0.1` endpoint is cleared; retained items kept.
5. Scan the Mac's Wi-Fi QR → reconnect over Wi-Fi; staged items re-upload.
   - ✅ No loss, no duplicates.

### B3 · Hand off to Process Files
6. Finish the staged session → hand off to **Process Files** for a batch run.
   - ✅ The staged captures appear as an input batch; run them through the normal pipeline (see `TESTING.md` §2.4) and verify output.

---

## Run C — Failure & recovery stress (the "never lose a photo" tests)

Do these deliberately; each must **not** lose a captured image.

### C1 · Network drop mid-capture
1. Mid-session (Wi-Fi), disable Wi-Fi on the phone (airplane mode) for ~20s, keep shooting 2–3 frames.
   - ✅ Phone: shots go to the **durable disk queue**; a retry/uploading indicator shows.
2. Re-enable Wi-Fi.
   - ✅ Queue **auto-retries**; all queued photos arrive on the Mac; backup folder gains them.

### C2 · Mac app quit mid-session
3. While the phone has unsent items, **quit the Mac app**. Keep the phone shooting a couple frames.
   - ✅ Phone: keeps queuing (ping fails, retries).
4. Relaunch the Mac app (`./launch.sh`), Live Capture tab.
   - ✅ On launch, legacy/prior session photos in the backup folder are **migrated/retained**, empty finalized folders pruned (never one still holding a photo).
   - ✅ Phone re-pairs (or auto-reconnects) and drains its queue.

### C3 · Phone app killed mid-session
5. Force-stop the Android app (swipe away / kill) with unsent items in the queue.
6. Reopen it.
   - ✅ The durable queue **survives the restart**; unsent items are still there and upload once connected.

### C4 · Backup-folder recovery (catastrophic case)
7. At any point mid-session, on the Mac click **Backup Folder**.
   - ✅ Finder opens `~/Pictures/Archive Processor Live Capture/<session>/` containing every photo the phone has sent so far — the operator can copy originals out even if the app won't relaunch.
8. Verify these originals are readable full-res images and are **not** deleted until a run finalizes successfully.

### C5 · Duplicate / idempotency
9. Force a re-upload (e.g. Re-pair then reconnect) of an already-received segment.
   - ✅ Same group+seq **replaces**, does not duplicate, on the Mac.

### C6 · Bad token / wrong Mac
10. (Optional) Point the phone at a **stale** QR (old token) or a different Mac.
    - ✅ Phone surfaces a connection/auth failure gracefully (the `bad token` case) and lets you Re-pair to the right one — no crash, no silent hang.

---

## What "pass" looks like
- Pairing works over **Wi-Fi and USB**, and **Re-pair** always returns to the scanner and re-uploads retained items with no duplicates.
- Every capture appears on the Mac **and** in the backup folder; markers map to Red/Folder-Purple; on-phone priority/date propagate.
- **Process live** yields dual output (PDF + renamed image) with correct tags + `Unread` last; **Stage for later** hands a clean batch to Process Files.
- Across **every** failure in Run C, **no captured photo is lost**, and the backup folder is only cleared after a successful finalize.

Log anything that fails (with the step number) in `KNOWN_ISSUES.md`. iPhone companion (`ArchiveCaptureiOS/`)
gets the same walkthrough later — the protocol and UX are shared, so most steps transfer.
