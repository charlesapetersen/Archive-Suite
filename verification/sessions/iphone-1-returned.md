# iPhone session 1 — returned

Part A (the cable) on 2026-10-31, with the owner's iPhone 14 (iPhone14,7) and the Mac (M3 Pro, 12 cores, macOS 27.2),
in an interactive session that installed the app, watched the Mac side and wrote this form from the owner's reports
and the Mac's files. Part B (Wi-Fi and the Drive relay) was not run; `W40.i4` now waits on
`W40.fix-processor-after-finish-not-processed`, because Part B files a document and then shoots another. Times are
UTC, from the session folder `~/Pictures/Archive Processor Live Capture/2026-10-31T21-37-30Z/`. The scratch output
folder is `~/Library/Caches/ArchiveSuiteRehearsal/iphone-1/output/`.

The Mac-side diagnoses below were made from the app's files, `sample` stacks, the log, the code and two `curl` checks.
Where a cause is read from code rather than measured, the line says so.

## The form

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | First launch and permissions | Clear prompts, camera at once | Not reported in detail; the camera worked and the session went ahead. | — |
| 2 | Pair over the cable | Cable pre-selected, QR pairs | Paired over the cable by QR, several times after Mac relaunches (Re-pair). The manual pairing code was not tried. | — |
| 3 | Shoot one document | Pages sharp, upright, in order, tags as given | First attempt (six pages): processing hung in the Mac's rotation check (B). After rotation Off and a relaunch, every page failed with Gemini's HTTP 402, shown as "Rate limit exceeded" (B, the direct Gemini key's prepaid credits were used up). On the Stanford gateway, after correcting its base URL (B), two three-page documents processed with text on every page and the tags given (2025, Q2, and March where the owner gave it). Pages reached the Mac about 1 s apart; the last page of a document was processed about 20 s after it arrived. Filed as one PDF per page, because "merge documents" is off on this Mac (?). | B |
| 4 | Unplug mid-send | Pages go across by themselves, none missing or doubled | Nine pages, seq 19-27, none missing or doubled. Six arrived before the cable was pulled; the other three arrived together about 32 s later, after it was plugged back in. The document was then never processed (B): it was the first document after a Finish in the same app run. Finish then reported it "could NOT be filed" and blamed the output folder's permissions or free space, which were fine (A). | B |
| 5 | Lock the phone while it sends | Sending stops while locked, carries on after | Eleven pages, seq 28-38, all processed with text. Pages 31-34 arrived 21:42:44-47, then nothing for 34 s while the phone was locked, then 35-37 at 21:43:21-23 and 38 at 21:43:31: sending stopped while locked and resumed by itself on return. | — |
| 6 | Landscape page and file format | Every file `ffd8ff`; landscape page upright | Both photos real JPEGs (`ffd8ff`), both 4032×3024 with no EXIF orientation. The upright shot filed upright; the shot taken with the phone held sideways filed upside down (rotation correction was Off). | A |
| 7 | Box and Folder with the camera | Labels readable on the Mac | Skipped: no box or folder label at hand. | — |
| 8-11 | Part B | | Not run. | — |
| 12 | The phone itself | | The owner noted that some test pages were magazine pages that are mostly photographs, with little text. | — |

**Install:** the pack's step 3 failed twice. First Xcode had no Apple ID at all (after the Xcode 27.2 update); the
owner added it under Xcode ▸ Settings ▸ Accounts. Then the team id the step reads from "the" Apple Development
certificate was wrong: this Mac has two such certificates (two Apple IDs), and the command took team 278GUHN39A from
the first, while Xcode's account is the Personal Team G8K4XNHXYQ. The build signed only with the account's team.
`devicectl` install and launch worked; the phone was already paired and trusted.

**The phone:** iPhone 14 (iPhone14,7), listed by `devicectl` as paired and available.

**The known problems above:** S-023 (sending stops while locked) showed as expected in task 5 and cost nothing.
S-022 showed in task 6 (orientation). S-040 did not show: the "03 March" tag was the owner's own. S-038 belongs to
Part B.

**Overall:** the cable route worked on the device: pairing by QR, transfer, an unplug and a lock lost nothing. The
session's time went to Mac-side defects, listed below.

**Anything else:** Clear was used three times to discard test documents; it sent their photos to the Trash and kept
their PDFs, as designed. Two empty collection folders (`Temp2`, `Temp3`) were made by Finishes that filed nothing.

## What was filed from it

- `W40.fix-processor-rotation-deadlock` (S2): the local Vision rotation check hung a six-page segment, every worker
  thread parked in `RotationDetector.score`. Fixed by the engine the same evening, with `W40.fix-processor-rotation-flip`.
- `W40.fix-processor-gemini-402-message` (S3): a 402 "prepayment credits are depleted" read as "Rate limit exceeded".
  Fixed by the engine the same evening.
- `W40.fix-processor-after-finish-not-processed` (S2): tasks 4 above, and Finish's wrong advice.
- `W40.fix-processor-failed-ocr-filed-image-only` (S3): a document whose every page failed was labelled image-only,
  lost its bulk Retry, and was filed with no text (`output/Temp`).
- `W40.fix-processor-live-settings-per-run` (S3): turning the gateway on changed nothing until a relaunch; Retry,
  Clear, Finish and Start all kept the first route.
- `W40.fix-processor-gateway-url-doubled` (S3): a base URL ending `/chat/completions` was doubled, every call 404.
- `W40.fix-processor-pending-invisible-after-relaunch` (S3): after a relaunch a failed document had no row and no
  Retry until the phone sent new pages (read from the code).
- `W40.fix-ios-landscape-orientation` (S3): task 6.
- Ledger: C-43 (the cable) to `works` on tasks 2-5. S-022 confirmed (orientation; the format half cleared), S-023
  confirmed as the expected pause. The cable limitation entry in `ArchiveProcessor/KNOWN_ISSUES.md` updated.
