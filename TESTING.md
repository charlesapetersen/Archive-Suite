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
  reading the run dir *after* the app exits (reading tags in-process contends with Spotlight and wedges).
  Needs `pypdf` (present) for PDF page/header checks.
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
