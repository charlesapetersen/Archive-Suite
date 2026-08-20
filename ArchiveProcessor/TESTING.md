# Archive Processor — Test Plan

How we verify the whole app actually works, end to end. There is **no CI and no human reviewer**, the
app writes **irreplaceable data** and **spends real money**, so testing is deliberate and tiered by what
can run **unattended** vs. what needs **eyes on the GUI**.

Three tiers:

| Tier | What | Interaction | Cost | Where |
|---|---|---|---|---|
| **1 · Smoke** | build + launch + real OCR to each provider | **none — runs while you're away** | ~free (2 imgs, cheapest models) | `scripts/test-smoke.sh` |
| **2 · GUI functional** | every feature, driven through the UI, incl. full OCR runs | manual (you click) or Claude-driven | low, bounded (see budget) | this doc, §2 |
| **3 · Release** | adversarial review of the whole diff + live smoke | per `CLAUDE.md` Tier-3 | as needed | pre-DMG only |

**Cost rule (always):** cheapest capable model for tests — `gemini-2.5-flash-lite` for vision OCR,
`mistral-ocr-latest` for OCR, `claude-sonnet-4-6` only if Anthropic must be exercised. Smallest input
set that proves the behavior. A full run below is ≤ ~40 images unless you opt into more.

---

## Tier 1 — Unattended smoke (`scripts/test-smoke.sh`)

**Run it and walk away.** From the repo root:

```bash
./scripts/test-smoke.sh
```

The **first** time, macOS pops a Keychain prompt ("`security` wants to use the … keychain") because the
script reads your saved API keys — click **Always Allow**. That is the "log in with the Keychain
credentials at the beginning" step; after that it never prompts again and truly runs unattended.

**What it proves**
1. **Build** — `xcodegen generate` + `xcodebuild` Debug succeeds, and reports the warning count (should be 0).
2. **Launch** — the app opens, has a window, and stays alive (no launch crash); then it quits itself.
3. **OCR** — for 2 real `Test Files` images (downscaled to keep cost/size low), it calls **every provider
   whose key is in the Keychain** (`Gemini` → `gemini-2.5-flash-lite`, `Mistral` → `mistral-ocr-latest`)
   with the **same request shapes the app uses**, and asserts a non-empty transcription comes back.
   Missing keys are skipped with a note, not failed.
4. **Report** — a timestamped `PASS`/`FAIL` line per check to the console **and** to
   `.maintenance/test-results/smoke-<timestamp>.log` (gitignored). Exit 0 = all pass.

**What it deliberately does NOT do:** drive the Process Files pipeline (segmentation/tagging review
dialogs need interaction) or write any tags/PDFs. It tests the load-bearing dependencies — *does it
build, does it launch, do the OCR providers + your keys actually work* — so a green smoke means the
Tier-2 GUI run below is worth your time. The app's own OCR→tag→PDF code is exercised in Tier 2.

**Keys:** stored in Keychain under service `com.archiveprocessor.app`, account = provider name
(`Gemini`, `Mistral`, `Anthropic`, `Gateway`). The script reads them at runtime and **never prints
them**; no key is ever written into this repo.

---

## Tier 2A — Automated pipeline test (`scripts/test-tier2.sh`) — unattended

Drives the **real Process Files pipeline** (OCR → segmentation → tagging → PDF) end-to-end with **no
clicking**, via a headless hook built into the app (`Capture/ProcessFilesTestDriver.swift`, gated by
`PROCESSFILES_TESTMODE=1`, inert in normal use). Run it and walk away:

```bash
./scripts/test-tier2.sh
```

**How it works (and why it's built this way):**
- The hook drives a **private, unobserved `OCRProcessor`** (no SwiftUI view watches it) — otherwise the
  pipeline's rapid `@Published` churn re-evaluates the main view and trips a **Swift-6
  `swift_task_isCurrentExecutor` crash** in the view graph. Unobserved = identical pipeline, no UI, no crash.
- A concurrent **auto-pilot** answers every review gate the way a human clicking "Continue" would
  (accepting the LLM's segmentation/tagging proposals), so it runs fully unattended.
- The app writes only a `TEST_DONE.txt` marker + a small `manifest.tsv` (per-file classification +
  status). **All PDF / Finder-tag / sidecar verification is done externally** by `scripts/tier2_assert.py`
  reading the run dir *after* the app exits. Finder tags come from `scripts/finder_tags.py`, which reads the
  `com.apple.metadata:_kMDItemUserTags` **xattr** directly — shared with `scripts/assert_mac.py` since
  `W26.oracle`, and verified by `./scripts/test-finder-tags.sh` (~2 s, no key, no app build). That proof also
  runs `tier2_assert.py` in every tagging mode against a hand-written scratch manifest whose xattr read is
  deliberately unreadable: the Process Files oracle must fail closed and name the blind read, never pass as
  though tags were verified absent, while a verified-absent xattr remains valid for `none`
  (`W26.oracle-fu1`).
  ⚠️ **The parenthetical that used to sit here — *"reading tags in-process contends with Spotlight and
  wedges"* — is an UNVERIFIED rationale for this whole out-of-process architecture, and is flagged as
  `execution-plans/despotlight.md` §"Site 8" rather than acted on.** No tag read on this path has ever gone
  through Spotlight: `tier2_assert.py` has always used the xattr, and `TagReading.read` uses
  `url.resourceValues`. The likelier cause is the main-actor context named two bullets up. Do not delete this
  architecture on the strength of that, and do not restate the Spotlight claim as fact.
  ⚠️ **`pypdf` is NOT installed on this machine** (measured 2026-08-06; this line used to say "present").
  `tier2_assert.py` makes that a **hard failure** — *"pypdf not available — cannot verify PDF structure"* — so
  `test-tier2.sh` cannot pass here at all until someone installs it.
- Each case launches the app with env config, waits for the marker, kills the app, asserts, and cleans up
  the pipeline's `pending_run.json` resume-state so no stale "Resume Run" prompt is left behind.

**Env contract** (all read by the driver; the key is passed straight through, never written to Keychain):

| Var | Meaning |
|---|---|
| `PROCESSFILES_TESTMODE=1` | gate (inert otherwise) |
| `PROCESSFILES_TESTKEY` | API key |
| `PROCESSFILES_TESTIN` | input image folder |
| `PROCESSFILES_TESTOUT` | output root (refuses `Test Files/`; writes only a fresh `run-<epoch>/`) |
| `PROCESSFILES_TAGGING` | `automatic` \| `none` \| `copySource` (manual modes rejected — need human input) |
| `PROCESSFILES_MAXIMAGES` | image cap (default 8) · `PROCESSFILES_PROVIDER`/`_MODEL` · `PROCESSFILES_EXPORTORIGINALS=1` |

**What each mode verifies** (asserted from disk): every output is a **2-page PDF** with the `Extracted
text.` page-2 header; **`none`** → no tags; **`copySource`** → source tags copied, no `Unread`;
**`automatic`** → date (`YYYY` + `MM Month`) + 2–6 subjects, box → **Red**+`Box`, folder → **Purple**+`Folder`,
**`Unread` stamped last**, JSON sidecar per document; and **segmentation classification vs the
`Ground Truth Segmentation/*/…csv`** (reported as a match rate). Cost: cheapest models + small caps ≈ cents.

The default suite runs `none` + `copySource` + `automatic` across the Dean and RG-165 ground-truth sets
plus a dual-output (`exportOriginals`) case. Add lines / raise `MAXIMAGES` for a larger confidence run.

---

## Tier 2B — GUI functional checklist (manual; the interactive UI itself)

Tier 2A covers the pipeline headlessly. This checklist covers the things that **only exist in the live
UI** (and so aren't exercised headless): the review *dialogs* themselves, the cost estimator, Settings
controls + help popovers + gray-out, the Tools tab, rotation review, error dialogs, gateway, and custom
models. Drive the app by hand (`./launch.sh`). Each row: **do → expect**; note failures in `KNOWN_ISSUES.md`.

**Suggested inputs (never modified — outputs only):**
- **Small OCR set** — 3–4 images from `Test Files/Herrnstein/` (text-heavy letters).
- **Segmentation set** — `Test Files/Ground Truth Segmentation/Herrnstein/` (has known boundaries +
  a `test_results/` ground truth to compare the app's box/folder/start/continuation calls against).
- **Mixed collection** — one folder under `Test Files/` that includes a box photo and a folder photo
  (to exercise Red/Purple + `Unread`-last).
- **PDF set** — a handful from the 586 `*.pdf` (pre-OCR'd / re-OCR path).

### 2.0 Launch & shell
- [ ] `./launch.sh` builds-if-stale and brings up the window (confirm `pgrep -x ArchiveProcessor`).
- [ ] The three areas are reachable: **Process Files**, **Tools**, **Live Capture**; **Settings** opens with ⌘,.
- [ ] No console crash/exception on launch; window renders (not blank).

### 2.1 Settings (⌘,) — every control, help, and gray-out
Per the project convention, **every setting has a `?` help popover and grays out when irrelevant.**
- [ ] **Provider** dropdown lists Anthropic / Gemini / Mistral; **Model** dropdown updates to that provider's built-ins.
- [ ] **Thinking level** (Low/High) shows only for models that support it; grayed/hidden otherwise.
- [ ] **API mode + key**: entering a key persists to Keychain; masked; not echoed. Switching provider swaps the key field.
- [ ] **Use gateway** toggle: ON reveals base URL / model ID / Gateway key and **grays out** batch + LLM-rotation (unsupported on gateway path); OFF hides them.
- [ ] **Manage custom models…** adds an extra Anthropic/Gemini model ID; it then appears in the Model dropdown; persists across relaunch.
- [ ] **Input resolution** control present + `?` popover; **Batch** toggle present + `?`; **Rotation mode** present + `?`.
- [ ] **Tagging options** + **Live-capture mode** (Stage for later / Process live) present + `?`.
- [ ] Each control's `?` popover opens with a real explanation (spot-check 5+).
- [ ] **Pinned cost-estimate pane** shows a 1,000-file estimate and updates when provider/model/batch change.

### 2.2 Cost estimator (Process Files)
- [ ] Add files → estimate appears; **standard vs batch** shown side by side.
- [ ] Estimate updates as files are added/removed and when the model changes.
- [ ] Batch price is visibly lower than standard.

### 2.3 File input
- [ ] **Drag-and-drop** images onto the window adds them.
- [ ] **File selection button** opens the standard macOS open panel; adds selection.
- [ ] Accepts JPEG, PNG, TIFF, HEIC; rejects/ignores unsupported types gracefully.

### 2.4 Process Files — full run (the core; **full OCR**)
Use the **small OCR set** (3–4 Herrnstein images), provider **Gemini**, model **gemini-2.5-flash-lite**,
tagging mode **Automatic**, an output folder in the scratchpad (not inside `Test Files/`).
- [ ] Start processing → progress advances; multiple workers run concurrently (fast).
- [ ] **Segmentation review** appears; boundaries are sensible (box=new box, folder=new folder, letters split by To/From/signature).
- [ ] **Tagging review** appears; each doc has Year + `MM Month`, 2–6 subjects; undeterminable date → year estimated + `Date Uncertain`, month never guessed.
- [ ] Output = **one PDF per input image**, same basename, in the output folder.
- [ ] **Page 1** = the original image full-page.
- [ ] **Page 2** = header `Extracted text.`, subheader `[Provider] · [Model] · [D Month YYYY]`, then the body; **all text on a single tall page** (never overflows to page 3).
- [ ] macOS Finder **tags applied**: year, month, subjects; **box photo → Red**, **folder photo → Purple**; **`Unread` present and applied last**.
- [ ] A **batch log `.txt`** lists any files that produced no OCR text, with the reason.

### 2.5 Tagging modes
For each mode, run 2 images and verify behavior (esp. the **`Unread`-last** rule):
- [ ] **Automatic** — full segmentation + date + subjects; `Unread` stamped last.
- [ ] **Auto date** / **Auto date + manual seg** — dates auto, seg per mode; `Unread` stamped.
- [ ] **Human** — you supply tags via the review UI; `Unread` stamped.
- [ ] **No tagging** — PDFs produced, **no tags written, no `Unread`**.
- [ ] **Copy source tags** — original file's tags copied to output, **no `Unread`**.

### 2.6 Document segmentation accuracy
Run `Test Files/Ground Truth Segmentation/Herrnstein/` and compare the app's box/folder/Document-Start/
Continuation calls to that folder's `test_results/` ground truth.
- [ ] Box photos → new box (Red); folder photos → new folder (Purple).
- [ ] Letters/memos/articles split at headline / To-From / signature / title.
- [ ] Continuation pages stay attached to their Document Start (not split).
- [ ] Note the match rate vs. ground truth in the run log.

### 2.7 Rotation review
- [ ] With rotation enabled, sideways/upside-down scans are flagged for rotation review and corrected in output.

### 2.8 Batch mode
- [ ] Enable **Batch**; submit a small run → app reports it's submitted for batch (lower cost, longer turnaround); results land when ready; batch log correct.

### 2.9 Pre-OCR'd / PDF input
- [ ] Feed a PDF from `Test Files/*.pdf`; the app handles it (re-OCR or passthrough per design) without collision/overwrite of the input.

### 2.10 Gateway (OpenAI-compatible) — *only if you have an endpoint*
- [ ] Turn on **Use gateway**, set base URL + model + Gateway key, run 1 image → OCR returns via the gateway; batch/rotation correctly disabled.

### 2.11 Custom models
- [ ] Add a custom Gemini model ID, select it, run 1 image → it's used (visible in the page-2 subheader).

### 2.12 Tools tab
- [ ] **Compare Models** — run 1 image across 2 cheap models; side-by-side diff renders.
- [ ] **Test Resolution** — runs `performResolutionTestCall`; shows the resolution/cost tradeoff result.

### 2.13 Error handling & resilience
- [ ] **Bad key** → clear error, no crash, no silent empty PDFs.
- [ ] **Gemini "Recitation"** (feed a page of clearly copyrighted text) → page 2 shows `No text returned…` with the `Recitation` reason.
- [ ] **No text returned** → `No text returned by model.` + reason; file listed in batch log.
- [ ] **Network drop mid-run** → surfaced + retry/resume, not a lost file or a corrupt PDF.
- [ ] **Interrupt a batch** partway → no half-written/overwritten outputs; safe to re-run.

### 2.14 Full OCR sweep (the "fully test it" pass, cost-bounded)
- [ ] Run **~30–40 images** spanning several `Test Files` collections through Automatic + Gemini
  `gemini-2.5-flash-lite`. Confirm: all produce PDFs, page-2 formatting holds on long transcriptions,
  tags look right across document types, no crashes, batch log accounts for every non-text file.
  Record wall-clock + rough cost in `.maintenance/test-results/`.

**Tier-2 cost budget:** ~50–80 cheap vision/OCR calls total across §2.4–2.14 ≈ well under a dollar on
`gemini-2.5-flash-lite` / `mistral-ocr-latest`. Stay on the cheap models unless a bug needs a stronger one.

---

## Tier 2C — Live Capture relay/cloud transport (`scripts/test-{filerelay,relay-golden,relay-transport,drive-*}.sh`)

The cloud-transport work (USB local relay + **Google Drive cloud relay**, the `RelayObjectStore` /
`FileRelayReceiver` seam) has its own Tier-2 scripts. Each launches the built app (or a standalone
`swiftc` compile of the real relay sources) with a headless env-gated driver, waits for its `DONE.txt`,
and asserts the emitted `results.json` externally via `scripts/relay_assert.py` (mirrors `tier2_assert.py`).
Most are **key-free / \$0 / offline**; only the live one touches Google:

- **`test-filerelay.sh`** — key-free. Drives `FileRelayReceiver.scanOnce()` (the offline shared-directory
  cloud stand-in) through the never-lose-a-photo invariants + the object-format amendments (A1–A11) against
  a temp relay dir — no OCR, no key, no network.
- **`test-relay-golden.sh`** — key-free. Cross-platform format guard (A7/A8): each platform's
  `RelayObjectFormat` must emit **byte-identical** canonical JSON to the committed golden in
  `SPEC/relay-golden/` (checks iOS via `swiftc` + Android via plain-JVM JUnit) — catches any
  Swift↔Kotlin escaping / key-order / hex-case drift.
- **`test-relay-transport.sh`** — key-free. The phone-side never-lose contract of the iOS
  `FileRelayTransport`: a photo is only considered sent once a matching receipt comes back, never on a
  write alone.
- **`test-drive-store.sh`** — key-free. Compiles the real `RelayObjectFormat` + `DriveClient` +
  `DriveObjectStore` against a **mock** Drive HTTP seam (no network/OAuth); asserts name→fileId mapping,
  idempotent overwrite, list-filtering, quarantine, and per-object delete.
- **`test-drive-transport.sh`** — key-free. Compiles the real iOS `DriveRelayTransport` against a mock
  Drive; asserts `postPhoto` returns true **only** after a matching receipt appears (never on a write
  alone) and rejects stale-fingerprint / wrong-epoch acks.
- **`test-drive-live.sh`** — **owner-gated; needs a real Drive account + OAuth** (`drive.file` token in
  `$DRIVE_ACCESS_TOKEN`). The one thing the mocks can't cover: a create/list/read/overwrite/quarantine/
  delete round-trip against **live** Google Drive in a throwaway folder, then deletes everything it created.

---

## Tier 2D — headless `$0` regression drivers (key-free, no network, no GUI)

**Read this section before writing a new test.** These are the cheapest and most-used suites in the
Processor — and until 2026-07-31 they were the least discoverable, because this file indexed Tiers 1/2A/2B/2C
and none of them. Each is a standalone shell driver that compiles or drives the *real* sources headlessly,
asserts externally, and needs no API key, no network and no window. Nothing here touches a real corpus.

Run one directly: `ArchiveProcessor/scripts/<name>.sh`. They are the right home for any invariant that does
not need pixels — which, given the Processor still has **no test target at all** (`project.yml` declares
neither a unit nor a UITest bundle — SUITE_TODO `W21.vmgui-d`), is where nearly all of its coverage lives.

The four long-running report drivers (`test-recovery.sh`, `test-manifest-persistence.sh`,
`test-merge-safety.sh`, and `test-batch-resume.sh`) share one bounded report waiter: 180 seconds for the
three former 60-second waits, and the batch-resume driver's existing 300 seconds for its 80-Stop sweep. Each
logs every completed check, so a missing report now identifies the elapsed time, completed-check count, and
last check seen; an early app exit is reported separately from a true timeout. This is diagnostic-only: their
existing scratch, key-free, no-network execution remains unchanged.

**Live Capture data safety**
- **`test-recovery.sh`** — the DATA-SAFETY invariants: confirm-before-delete, keep-on-failed-backup, and the
  recovered-photo hold. 45 checks as of 2026-07-31.
- **`test-manifest-persistence.sh`** — manifest durability + completion acknowledgements: a session's record
  survives a crash, and an ack is only emitted once the write is durable. 86 checks as of 2026-07-31.
- **`test-network-session.sh`** — paid-POST retry safety and limiter cancellation accounting, injected so no
  request leaves the machine. 7 checks as of 2026-07-31. **This is the suite that proves a retry cannot
  double-charge you.**
- **`test-segment-json.sh`** — byte-identity of the shared `SegmentJSONBuilder` output.

**Process Files pipeline**
- **`test-batch-resume.sh`** — batch/non-batch crash-resume manifests, **and** (W16.bat1) the three paid
  batch clients' provider **response-shape contract** — every status/result body shape Anthropic, Gemini and
  Mistral are accepted in, from literal fixtures through the pure parse seams in `BatchOCR.swift`
  (`BatchParseContract`) — plus (W16.bat1-fu) the two pure rules the poll uses to decide where a finished
  chunk's pages come from and whether a chunk that produced none may be marked consumed.
  Also (W16.bat2) the **cancel path's journal-retention contract** (`BatchCancelContract`): pressing Stop
  deletes the paid-batch recovery journal if and only if every chunk's server-side cancellation was
  confirmed — driven through the real seam with a stub canceller and a real temp file, swept over all four
  providers × chunk counts 0–6 × which chunk refused. Scope: the `cancel()` RULE, not the whole
  Stop path — W16.bat3 is open and owner-gated.
  And (W16.bat2-fu) the **cancel path's WIRING** (`BatchCancelWiringContract`) — the arguments that rule is
  fed: the real `cancel()` with both cancel-path seams stubbed, proving it cancels the journal's
  acknowledged chunk IDs (not a decoy batch ID), through a canceller that closes over the batch's *own*
  provider's client (`clientTypeName`, so a right label in front of the wrong client reddens), names the
  paid-batch journal and no other durable file, assigns the kept-journal warning and refreshes the resume
  banner, touches nothing when there is no live batch, and cannot cancel or re-charge the same batch twice.
  Those are named shapes; W16.bat2-fu3 adds the complement — a sweep that presses Stop on the whole
  cross-product (every provider × 0–3 acknowledged chunks × journal-present × each chunk refused in turn,
  80 Stops) and demands an exact outcome from each, plus the two shapes the named cases missed: a
  single-job provider (Anthropic/Mistral) handed SEVERAL chunks must attempt nothing and keep the journal,
  and a legacy (`lifecycleVersion == nil`) journal must be cancelled by its batch ID, never by its
  non-authoritative stored chunk list.
  Its header lists what it still does not cover — in particular the warning *surviving* the cancelled run's
  own messages, which no scenario there can see because none has a live `processingTask`. That half is
  W16.bat6, in section 17's own section 5. Read both headers before citing a green section 14.
  Finally (W16.bat4) the **interrupted-batch TAIL** (`BatchInterruptTailContract`): sections 13/14 are about
  Stop, this one is about a run that ends itself with a paid job possibly still alive. The real
  `finishInterruptedBatchPoll()` — the one tail both paid-batch entry points now run — must recompute the
  resume banner (the Resume control every interruption message names, and the half that was simply missing on
  a FIRST run), delete exactly this run's own temp PDF→JPEG conversions and nothing else in the directory
  (including decoys named from the shipped `pending_batch.json` / `pending_run.json` constants), and leave the
  interruption message, the run's results and the interrupted-RUN manifest untouched — swept over all 24 start
  states the four interrupted exits can arrive in. Its header scopes out the two call sites themselves, which
  need a real paid submission to drive.
  And (W16.bat2-fu2) the **journal PATH + the shipped deleter** (`BatchJournalPathContract`, section 16).
  Sections 13–15 all replace the deleter seam, so the default body — the line that actually removes
  `pending_batch.json` — was verified by reading it, and neutering it to `{ }` left all 241 checks green.
  The journal directory is now redirectable: `OCRProcessor.pendingStateDirectory` honours
  `ARCHIVEPROC_TEST_STATE_ROOT` **only** alongside `BATCHRESUME_TEST=1` and only as a usable absolute
  directory, so this script points it at its own temp dir and section 16 runs the SHIPPED deleter against a
  real journal file. Two halves: the fail-closed table (9 near-miss flag values, then 11 unusable override
  roots — 20 resolutions in two independent loops, not a cross product — must all come back with the
  operator's real Application Support path, because a mis-read variable here strands a paid batch rather
  than merely failing a test), and, behind a guard that makes them refuse to run unless the path really is
  redirected, the destructive checks — save/read/delete all land in the redirected directory, the default
  deleter removes the journal, a confirmed Stop with the real deleter installed removes it, an unconfirmed
  one keeps it and warns, and no outcome touches `pending_run.json`. **That guard runs first, from the top
  of the driver**, not from section 16: the redirect fails closed *silently*, so a harness whose
  `ARCHIVEPROC_TEST_STATE_ROOT` did not validate has to be caught before section 13 presses Stop 80+ times,
  not after section 15.
  A side effect worth knowing: those 80 sweep Stops in section 14 now read an empty state directory instead
  of the operator's, so the suite no longer slows down in proportion to a large real interrupted run.
  And (W16.bat3/W16.bat6) **Stop during the POLL** (`BatchPollCancelContract`, section 17). Everything above
  stops at `cancel()`; this follows the cancellation into the run unwinding alongside it, which is where the
  journal was really being deleted. Its sections 1–2 press Stop on the real `pollBatchUntilComplete` (before
  the first status check, swept over every provider; and during the wait between checks, timed to show the
  sleep was aborted rather than waited out), section 3 drives the first run's tail against a real journal
  file, and section 4 drives a whole cancelled `resumeBatch`. Section 5 (W16.bat6) is the other half of the
  promise — the operator being *told*: it is the only place in the suite that presses Stop with a **live
  `processingTask`**, and it asserts the kept-journal warning is still the message on screen after the
  cancelled run has finished writing its own. Both poll guards precede the `switch provider`, so no request
  is ever made, and section 5 stubs both cancel-path seams; the sections that write a journal sit behind the
  same `redirectIsInForce` verdict as section 16.
  No network, no keys, no cost. 268 checks as of 2026-08-02 (16 of them section 15, 17 of them section 16 —
  one of which, the redirect guard, is emitted from the top of the driver rather than from the section — and
  10 of them section 17).
- **`test-incremental-skip.sh`** — incremental processing correctly skips already-processed files.
- **`test-multipage-reocr.sh`** — the multi-page-PDF re-OCR route over synthetic pages.
- **`test-processing-history.sh`** — cost tracking + the run log.
- **`test-processfiles-tagwarn.sh`** — the OUTPUT-WARNING contract (W23.m5 + W23.h5-fu): the run may only
  report tags it actually wrote.

**File & tag safety (no undo → Tier-2 territory)**
- **`test-output-file-safety.sh`** — `OutputFileSafety`, in a fresh temporary directory only.
- **`test-merge-safety.sh`** — merged-PDF tag transfer.
- **`test-collection-organize.sh`** — collision-safe collection organization.
- **`test-controlled-vocabulary.sh`** — post-parse controlled-vocabulary enforcement.

**Providers**
- **`test-localagent.sh`** — drives the real `LocalAgentClient` against a fake CLI
  (`scripts/localagent-fake-cli.sh`), so the Local Agent path is provable with no account and no spend.

Counts drift as checks are added — treat the numbers above as a floor, not a contract, and read a script's
header comment for what it actually covers. Related non-`test-*` drivers in the same directory:
`localagent-{mechanism,pacing,validator,wiring}-test.swift` (compiled directly) and `android-ui-drive.sh`
(the Android companion's emulator lane).

---

## Tier 3 — Release gate
Before any DMG/GitHub release, run the `CLAUDE.md` Tier-3 flow: a multi-agent **adversarial review of the
whole accumulated diff** since the last release (find → refute; only survivors are real) **plus** a live
smoke test if the OCR/tagging/PDF path changed. Cut the release only after it comes back clean.

---

## Appendix — provider/model & cost cheat-sheet

| Provider (Keychain acct) | Cheapest test model | Endpoint shape | Notes |
|---|---|---|---|
| `Gemini` | `gemini-2.5-flash-lite` | `…/models/<m>:generateContent?key=` inline_data | may refuse copyrighted text → `Recitation` |
| `Mistral` | `mistral-ocr-latest` | `POST /v1/ocr` image_url data URI | returns **markdown** |
| `Anthropic` | `claude-sonnet-4-6` | messages API, image block | use only when Anthropic path must be tested |
| `Gateway` | (your model) | OpenAI-compatible `chat/completions` | no batch / no rotation |

Read a key manually (will prompt once): `security find-generic-password -s com.archiveprocessor.app -a Gemini -w`

Live Capture is tested separately — see **`LIVE_CAPTURE_ANDROID_TEST.md`** (manual, needs the phone).
