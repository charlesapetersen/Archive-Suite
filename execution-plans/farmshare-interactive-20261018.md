# Interactive FarmShare work — 2026-10-18

Owner asked this chat to set up as much queued FarmShare work as possible through the renewed SSH login.
The bounded read-only preflight reached `rice-04` as `cp1`. The first `squeue` was empty: none of these
jobs duplicates an existing queued run. Existing segmentation training, benchmark runs, venvs and source
packs were preserved. No paid API calls or writes to the real corpus.

## Run root and coordination

Owner walkthrough recorded in `4e3ab6e2` confirms this chat owns FarmShare work. Keep the two managed
login gates held until this interactive session hands the tasks back; do not request another login.

- Host: `cp1@login.farmshare.stanford.edu`, existing control socket `/Users/cp1/.ssh/cm-farmshare`.
- All new scripts/data/results: `/scratch/users/cp1/fs-ocr/interactive-20261018` (`R` below).
- `R/jobs.tsv` is the submission record. **Inspect these IDs and existing outputs before any resubmission.**
- Snapshot training code came from `d6be9d44`, including W41.date-model's text-row support; the server's
  pre-existing checkout stays at `710462b0`. No remote git pull, shared-venv install or environment replacement.
- This session owns the remote runs. The daemon's concurrent W41.app-institutional-compute explicitly
  excludes remote work; its kit rename does not affect these staged snapshots or the remote old kit.
- Per command use the bounded multiplexed options in `execution-plans/farmshare-access.md`. A successful
  local `ssh -O check` does not establish that remote commands work. Do not create another login/master.

## Submitted jobs

| item / purpose | Slurm ID | resources / work |
|---|---:|---|
| W41.date-model 2B | 1855406 | one L40S; 64-row pilot, full LoRA, merge, tests, public base-model test |
| W41.date-model 4B | 1855407 | same pipeline, Qwen3.5 4B |
| W43 specialist preparation | 1855419 | CPU, normal partition; download pinned weights, merge Qari/German adapters |
| W43.script-specialists CHURRO | 1855420 | one L40S; afterok:1855419 |
| W43.script-specialists Qari | 1855421 | one L40S; afterok:1855419 |
| W43.script-specialists German lines | 1855422 | one L40S; afterok:1855419 |
| W43.script-specialists Fanar | 1855423 | one L40S; afterok:1855419 |
| W43.sweep-farmshare Qwen3.6 27B | 1855424 | one L40S, existing FP8 checkpoint |
| W43.sweep-farmshare Qwen3.5 27B | 1855425 | one L40S, existing FP8 checkpoint; owner99 check follows |
| W43.sweep-farmshare Qwen3.6 35B-A3B | 1855426 | one L40S, existing FP8 checkpoint |

GPU wall ceilings are eight hours; CPU preparation two hours. Slurm enforces the four-GPU/running-job limits.
Only one copy of each job was submitted. Scheduler priority can leave these pending for a while.

### Dating

`R/date-data`: 7,428 training examples (3,714 corpus + 3,714 public) and 1,374 validation examples
(687 + 687). Existing neighbour-leakage exclusions retained. Exact prompts checked disjoint among train,
validation, and the two tests. The validation file is valid JSONL but contains a Unicode line separator:
iterate the file's actual newline records, **not** `str.splitlines()` when loading it. The existing trainer
reads only train.jsonl; it does not use validation for checkpoint selection.

`R/date-corpus` and `R/date-public` each contain the existing 300 test prompts. Corpus targets omit the day
because the owner's tags do not supply one; public targets teach it. Subjects are omitted; Date Uncertain
follows the owner's tags. One epoch, existing rank-16 / LR 1e-4 / accumulation-8 defaults. The existing
trainer drops an incomplete final accumulation (four training rows here); no test-based tuning.

- Training: `R/train/date-{2b,4b}`, pilots alongside with `-pilot` suffix. Adapters/checkpoints/merged models retained.
- Answers: `R/results/date-{corpus,public}/{date-2b,date-4b}/answers.jsonl`.
- Untrained comparisons: `R/results/date-public/{base-2b,base-4b}/answers.jsonl`.
- Thinking off, 512 generated-token cap, eight concurrent text requests. No model choice, locked-test score,
  MLX conversion, Mac measurement, new score or completed queue item claimed yet.
- `date-job.sh`, `serve.sh` and `text-eval.sh` run the whole submitted pipeline; a pilot failure stops its job.
  An existing full output directory makes the training script refuse a blind restart.

### Script specialists and sweep

The original **440-page reference manifest** is used unchanged, not the later 895-page extension. All frozen
source checksums and prepared JPEG digests were checked locally; all 3,107 staged input/script files were
checked again on FarmShare. `R/ocr/checksums.json` records the upload; `ocr_run.py` was subsequently corrected
to use the served model alias for the owner99 check. `serve.sh` now records its actual serving options.
`owner99.jsonl` and the combined-model preparation are later additions. Retain final script digests on the server.

- `R/ocr/public440.jsonl`: all 440 reference pages; seven strata, same 2,400 px prepared JPEG bytes.
- `R/ocr/arabic40.jsonl`: N1's 40 pages.
- `R/ocr/german-lines.jsonl`: 2,656 crops from the existing kraken segmentation of 80 L6 pages, same line order
  and invalid-line exclusions as the Mac TrOCR run; line area capped to 262,144 pixels, JPEG quality 95.
- `R/ocr/owner99.jsonl`: checks the **existing** `/home/users/cp1/fs-truthpack` images; no original-corpus read.
- `R/ocr/models.json`: public model revisions/licences. `ready-*.json` records downloaded paths and exact base revisions.
- CHURRO: `stanford-oval/churro-3B`, `ca2150ea465d5a3d67818c50e234b9422619c75d`, Qwen research licence,
  official XML system prompt; all 440 public pages, then owner99. **Contaminated L5/L7/L8:** its sources list
  iForal/Castilian/VOC, Koenigsfelden and OCR-D. Score as a labelled reference, not a clean winner there.
- Qari: `NAMAA-Space/Qari-OCR-0.4.0-VL-4B-Instruct`, `aa65b4a46336c6cc608e7da5a015f8e71472a68b`, Apache-2.0,
  adapter merged into its actual `unsloth/Qwen3-VL-4B-Instruct` base; card's `Free OCR.` prompt, N1 only.
- German: `dh-unibe/qwen3.5-4b-german-xix-v2`, `5ee0c4e702ea1cdea82ed04d663da4c1b22c2e33`, licence unstated,
  scoring only; merge into Qwen3.5 4B; exact card instruction, line crops, 512 output tokens.
- Fanar: `QCRI/Fanar-2-Oryx-IVU`, `5b4d0b722f4d01cab49fe8d8b938c33cfa078f36`, Apache-2.0,
  Qwen2.5-VL 7B full weights; N1 only; Arabic transcription-only instruction, recorded in collector.
- Sweep: the same panel JSON prompt / 8,192-token cap / temperature 0 / thinking off. Reuse prior Qwen3.6 27B
  and 35B owner99 results; Qwen3.5 27B gets its missing owner99 run through existing fs_ocr.py.
- Whole-node Qwen3.8 Flash Next caches hold **zero** of 17 W4A16 shards / zero of 131 FP8 shards; those are
  metadata-only caches. No huge new download or whole-node job was started.

Serving uses one GPU, max context 16,384, KV `auto`, GPU utilization .90, max sequences 16. Do not describe
these as identical throughput settings to the earlier fp8-KV/max-sequences-32 runs. Weights retain their
native BF16/FP8 precision. Raw OCR replies are streamed and kept per page. There is no repetition early-stop
or retry in these benchmark requests (plain reference conditions); a cap is a failure, not a short success.
A transport error has `.error.json`, so an explicit resumed collector can recover it; capped/answered files
are skipped. The Slurm wall limit bounds the whole run; the collector bounds an individual request at 900 s.

Outputs: `R/results/ocr/<label>/*.json`, with raw text, finish reason, usage, model, source, stratum, timing and
Slurm ID; `summary.json` is collection bookkeeping, **not an accuracy score**. German lines must be joined by
`page` and numeric `line` before scoring. CHURRO's XML must be parsed into text using its reference reader.
Never count a capped/malformed/missing page as answered. Compare with the original 440-page reference scores.

Primary sources checked for input/prompt/licence:
[Qari card](https://huggingface.co/NAMAA-Space/Qari-OCR-0.4.0-VL-4B-Instruct),
[CHURRO model](https://huggingface.co/stanford-oval/churro-3B),
[official CHURRO templates](https://github.com/stanford-oval/Churro/blob/main/src/churro_ocr/templates/presets.py),
[German model card](https://huggingface.co/dh-unibe/qwen3.5-4b-german-xix-v2),
[Fanar card](https://huggingface.co/QCRI/Fanar-2-Oryx-IVU).

### Combined segmentation + dating model: prepared, NOT submitted

`R/combined-data` has 5,885 original segmentation windows + 7,428 dating examples = 13,313 shuffled rows,
seed 41, referencing the existing `/home/users/cp1/fs-cleanpack/images` read-only. Date validation copied
separately. `R/combined-job.sh` and `prepare-combined.sh` are staged. **W41.date-model remains a prerequisite.**
Review its results first and complete the prerequisite; the job has a `date-prerequisite-reviewed` guard.
Do not bypass that guard merely because the files are present. After training, compare on development and
held-out segmentation first, freeze before one locked-test pass, and require <=1-point loss on each task.
The script prepares date evaluation only; the segmentation/MLX/Mac comparisons still need to be run.

## Verified execution snapshot

CPU preparation 1855419 completed successfully in 3m05s (exit 0), with all four models ready and both
adapters merged. At the last checked snapshot, date-2B was running at update 300 (loss .0583 is training
loss, not test accuracy); date-4B and all seven OCR tests were waiting on scheduler priority. The model
setup dependencies had cleared. The two 64-row/full training stages have been observed for 2B only;
4B training and every vLLM start remain unverified until the cluster schedules them.

Final script SHA-256 after the two setup corrections:
- `serve.sh`: `8c0dedf5c244bb17ece5298d46a6e9ebca102d5e0e093d2c2ae1e0382ac6babe`
- `ocr/ocr_run.py`: `fe5679d9913fdc92008ad6d409c05c7b400239dd1913eeb4639dde2f3e29576b`

Local collector checks passed for the served-model alias, correct prompt, streamed output/finish reason,
capped replies, durable writes and resumed skipping of terminal outputs. Shell/Python syntax checks passed;
training/validation/test exact prompts are disjoint. These checks do not replace the pending real GPU tests.

## Continue from this chat

1. Re-run the bounded remote preflight, then `squeue -u cp1` and `sacct -j <IDs> -X`.
2. Read `R/logs/`, `R/ocr/setup-status.json`, training logs and result summaries. Confirm pilots and the real
   server start-up, not just sbatch acceptance. For failed jobs inspect cause and any surviving outputs before
   selectively resubmitting. Preserve the old job ID/log; append replacement ID to jobs.tsv.
3. Bring back text answers/results to a separate cache folder. Import/score the date tests with the existing
   `date_tagging.py` and `public_dates.py` commands; these may write tracked score files, so use an isolated
   worktree. Do not train/tune against test scores. Compare the two sizes, then convert/measure the chosen MLX.
4. Parse/join specialist OCR replies, score them with `ocr_panel_score.score`'s per-stratum options, and include
   capped/missing/error rows as failures. Add to specialists and sweep tables and ArchiveOCRBench only once verified.
5. Resume W41.seg-date-model after dating's prerequisite. W43.seg-corpus-build has no frozen input boxes yet. The parallel October 18 walkthrough approved
   the named CIA/Archive.org host expansion and a browser attempt at Lincoln catalogue/IIIF inventory;
   that source-preparation work remains separate from these submitted GPU jobs.
6. These four queue items remain **open** until their measurement/reporting work is done. No completion gate,
   paid-run approval, corpus access expansion, weights publication or release was inferred from this session.


## Autonomous continuation — 2026-10-18 evening

Owner explicitly asked this chat to continue **all FarmShare work autonomously until done**. All ten
initial jobs completed with exit zero. Results were retrieved to
`/Users/cp1/Claude/Long term storage/FarmShare-20261018` (raw text stays there, outside git).
The parser/line-order/cap tests plus existing specialist tests pass (9 total). Numbers are now generated
in the worktree's public benchmark CSVs, date JSONs and the new interpretation reports. No item is
marked complete yet: commit/report/queue reconciliation and the remaining model checks are still due.

Dating: 2B 167/250 owner years, 76/120 months; 4B 166/250 years, 84/120 months. Public test: 2B 285/300
years, 224/240 months, 139/150 days (136/150 full date); 4B 291/300, 224/240, 138/150 (135/150 full date).
Neither emits Date Uncertain for the 50 owner-uncertain documents, and both are below Gemini on inferred
years. Fixed 2B single-task reference selected for the combined-model comparison (smaller; year essentially
tied, 2B public full date slightly ahead). No further test-guided tuning.

W41.seg-date-model job **1856294** is now training on one L40S in oat-03, after that single-task benchmark
review. Its already-staged 13,313 rows are unchanged. The dated recipe/reference is frozen; Mac measurement
continues independently while the several-hour mixed vision/text training runs. On success, existing
combined-job.sh merges it and evaluates the two date packs. It still needs development and held-out
segmentation runs, one frozen locked-test pass, 8-bit Mac conversion/measurement and the <=1-point decision.
Do not resubmit this job blindly. `/scratch/users/cp1/fs-ocr/interactive-20261018/combined-job.id` records it.

The 2B merged weights transferred to durable storage. Verified SHA-256:
`d39e6350ecee1a14e7629621f7da188dbfb5ba450de61a0efd20be45a45e001d`.
8-bit MLX conversion passed under the original memory guard (7s, 9.625 effective bits/weight, peak footprint
4.7GB). Build: `Long term storage/FarmShare-20261018/date-2b-8bit`. The full 600-prompt Mac run is active
through `institutional-compute/mlx_text.py`, under the same guard/lock; raw outputs go to `mlx-results`, label
`mlx-date-2b-8bit-nothink`. At the last snapshot 80/300 corpus prompts were complete, peak MLX 3.784GB.
The earlier conversion precheck refused for low reclaimable memory; no thresholds were weakened.

OCR: CHURRO public NES 69.9; owner96 NES 89.09 (94/96). Qwen3.6 27B public 51.3, Qwen3.5 27B 49.8,
35B-A3B 52.4. Qwen3.5 owner96 95.33 is only .08 above existing Qwen3.6's 95.25, not a ranking.
All specialist candidates are scored, with caps as failures, contamination labels and uncertainty intervals.
The newer Intel W4A16 Qwen3.8 Flash Next index actually totals 278.35GB; official FP8 185.50GB. Both are
infeasible at the kit's serving headroom on this node; no giant download was made. The registry does support
its Qwen4Exp architecture, so do not claim the registry was the blocker.

ArchiveOCRBench was updated with public date scores, the three public Qwen rows, all new specialists and
owner96 timings. Browser verification shows 4 public date rows, 39 general OCR rows, 21 specialist rows,
no console errors and a readable screenshot. Added UTF-8 metadata to fix the visible mojibake. Build/check
pass. The generated site is local, not published. The benchmark's dynamic prose now attributes the existing
bulk pilot to Qwen3.6 instead of to whichever tiny-score leader appears first.

Remaining independent work: finish/report the Mac dating run; ship specialist/sweep measurements and
reconcile their queue items; continue mixed-model training/evaluation; inspect W43.seg-corpus-build's now
approved host expansion and complete public-box inputs before any FarmShare runs there. Paid hosted calls,
real-corpus writes and model publication remain outside this continuation. Keep login gates held until the
interactive work is actually handed back, per the owner walkthrough.

## Completed Mac dating measurement

The guarded 600-prompt MLX run completed with exit zero. Corpus: years 164/250, months 78/120,
inferred years 51/131, decades 28/50, Date Uncertain 0/50. Public: years 284/300, months 224/240,
days 140/150, full dates 137/150. All 600 parse, no caps. Load 1.29s; corpus 416.69s, public 414.71s;
peak MLX 3.784GB. Guard wall 836s, peak footprint 4549MB, peak RSS 2248MB, max pressure 2, swap growth
-104MB. Model bytes 2,682,994,616. Raw outputs and run settings remain under Long term storage's
`FarmShare-20261018/mlx-results`. Numeric results imported through the existing date scorers.
W41.date-model is complete once this report/benchmark checkpoint ships; no model publication or default
change. The combined model's 1856294 remains active and owns the remaining FarmShare comparison.

## Public sources and combined-model evaluation preparation

CIA checkpoint 918df0bf: 22 supplied PDFs /128 pages, every PDF MD5 and Scandata count verified. All pages
visually checked, nine enclosure/article starts added (31 documents); original archive labels retained.
Page 94 explicitly marks two withheld physical pages. Metadata/truth/image hashes frozen in
`segbench-results/public-segmentation/crest.json`; images remain in Long term storage. Public loader refuses
missing/reordered/duplicated/unaudited pages, escaping paths and changed images; six tests pass. Apple Vision
read all 128 pages under unchanged memory guard in 69s, peak footprint 508MB, no failures. Free floors and
rule sketch scored with existing scorer. No paid call. Three free cluster packs are being prepared.

Lincoln: browser export of full Shelf Order catalogue page 1 (150/20,207 records), then **positions 2–73**,
72 consecutive manuscript items /261 complete supplied canvases. Stop rule is near 250 pages at an item
boundary: final item has 22 canvases. All manifests saved and counts checked. No completed-transcription
filter, skipped item, synthetic image, or inferred end-of-item. Raw catalogue/manifests in public source
cache; `download-lincoln.py` retrieves every canvas at 2000px ceiling through the approved fetch helper,
1s pacing and bounded retries, verifies decoding/aspect ratio and records SHA-256. Labels not frozen yet.
IIIF sizing follows https://iiif.io/api/image/2.1/#size (`full/!2000,2000/0/default.jpg`).

Combined model registered only as experimental benchmark keys `fs-seg-date-2b` / `seg-date-2b-8bit`.
A separate `seg-date-model-frozen.json`, committed after development/held-out review, is required before
any locked-test pack. Existing teacher/student freezes untouched. Preparing unchanged 187-window dev pack;
existing `/home/users/cp1/fs-holdout-fs-seg-2b` has 2459 held-out windows and can be copied/relabelled to a
separate run (its corpus-pairs keys are model-independent; do not import it into five-box caches).
Full repository health gate due at 34 commits since last green; started in primary with unattended/lock
protections. It remains running. Public + collector regressions: 45 tests pass, 4 platform skips.

### Automatic continuations prepared (same interactive task)

Joint development + held-out GPU evaluation **1856499** depends on afterok:1856294. Isolated current kit
snapshot at `R/seg-eval`, unchanged 187-window dev pack and byte-identical 2459-window held-out requests;
only model/output namespace differs. `R/serve-seg.sh` is a separate copy (original serve.sh hash preserved),
with current IC aliases and slash-safe log naming. `R/run-seg-eval.sh`, `joint-seg-eval-job.sh` and `.id`
record recovery. No locked test submitted. CIA's three 44-window packs staged at `R/public-packs`.

Unrounded single-task references and the <=1-point decision fields are frozen before joint results in
`segbench-results/seg-date-comparison-plan.json`. GPU dev pages-in-exact-doc 90.5405%; Mac 90.3475%.
Public dates are checked separately by year/month/day/full date; owner year/month retained. No new
recipe selection against the joint test outputs. Both original freezes remain unchanged.

A one-time local continuation is running from Long term storage `FarmShare-20261018/joint-mac-watch.py`,
not a scheduled automation. Tool session 8892. It waits for 1856294 success (no auth retry on SSH failure),
checks 8 GiB free, transfers the merged model, verifies remote/local SHA-256, then performs 8-bit conversion
and all 600 date +187 development-window Mac tests under the unchanged machine-wide guard. No Mac locked
or held-out call. Code snapshot `joint-mac-code`, exact text packs `date-packs`; status `joint-mac-status.json`,
logs `joint-mac-{watch,transfer,convert,measure}.log`, outputs `mlx-results` and the new benchmark cache key
`window-local-seg-date-2b-8bit`. At most 12 natural resource retries; no lowered threshold. Inspect rather
than overwrite a partial quantized build. A `joint-mac-stop` marker stops its waiting phase if needed.

LoC image downloads repeatedly closed HTTP/2 streams (curl 92). The host-limited helper now selects HTTP/1.1
only for tile.loc.gov, retaining TLS, host and redirect checks. Ten wire/refusal tests pass. Downloads are
continuing; occasional closed transfers still receive only the existing bounded retry. Lincoln audit
progress is saved independently in `public-segmentation/lincoln-audit.json` outside git (last reviewed 192).
No public model scores yet. Existing free rule baseline is fitting on **owner dev boxes only**, queued behind
the repository's VM health check; its parameters will be committed before public scoring.
