# FarmShare extensions — resumable handoff, 2026-10-19

Owner authorized two additions: OCR the remaining frozen pages if previous readings survive corpus growth,
and test the already-frozen combined model on both public segmentation boxes. Keep Codex usage low and the
existing SSH shell open. No source expansion, paid calls, new training, private-test repeat or publication.

## Submitted jobs — resume, never duplicate

| queue tag | job | work |
|---|---:|---|
| W43.seg-date-public |1857598| combined2B, CREST44 +Lincoln88 existing public windows |
| W43.farmshare-ocr-more |1857599| Qwen3.6 27B: reuse440 cached pages, read455 added pages |
| W43.farmshare-ocr-more |1857600| Qwen3.5 27B: reuse440 cached pages, read455 added pages |
| W43.farmshare-ocr-more |1857601| Qwen3.6 35B-A3B: reuse440 cached pages, read455 added pages |

Job1857598 completed0 while this checkpoint was prepared; raw answers have been retrieved. The first OCR
job is running and the other two wait for resources. Inspect scheduler/status files rather than inferring
current state from this snapshot. Eight-hour OCR limits; one L40S/8CPU/64GB each, original serving settings.

L=`/Users/cp1/Claude/Long term storage/FarmShare-20261019`
R=`/scratch/users/cp1/fs-ocr/interactive-20261018` (existing models, server scripts and per-page cache)
E=`/scratch/users/cp1/fs-ocr/interactive-20261019` (new packs, wrappers, logs and reuse receipts)

Read L/jobs.json and L/collection-status.json first. The bounded one-shot L/collect-jobs.py, under caffeinate,
polls every60s through the existing cm-farmshare master. It never submits jobs, reauthenticates or starts a
daemon. It retrieves completed raw results, validates reuse receipts, then runs the saved-output scorers under
the unchanged shared resource guard. Output stages: L/numeric-results (expanded OCR), L/public-numeric-results
(combined public segmentation). Raw files are under L/results. Status becomes completed_numeric_outputs or
needs_inspection. Log L/collection.log; scorer logs L/ocr-score.log and L/public-score.log. Its SSH polling also
keeps the existing connection active while jobs run. The owner's master/socket/shell are never closed/replaced.

## Why expansion does not require repeated OCR

Inputs have stable source/page identities, source image/truth checksums, and saved raw answers per page/model.
The prepared expanded manifest contains all895 pages but adds only455 JPEGs; original440 JPEGs are reused in
place. Preflight verified exactly440 compatible terminal readings for each of the three models. The unchanged
legacy collector skips those files, including terminal capped answers. The wrapper verifies every cached
image digest/model/mode, binds prompt, model revision, decoding, vLLM and serving settings independently of
manifest size, and verifies cached answer bytes were not rewritten. Each job emits an auditable reuse receipt.
Adding pages means new calls for new pages and rescoring the aggregate. Correcting truth can rescore saved raw
answers. Changing image bytes, model/prompt or inference settings requires a separate experiment/cache; it must
never silently reuse an incompatible reading. Transport errors remain resumable; caps remain scored failures.

Code: corpus/farmshare_incremental.py (pack + cache guard), corpus/farmshare_expanded_report.py (saved outputs
only). Protocol: existing2400px/JPEG90 panel prompt,8192 output tokens, temperature0, thinking off; native FP8
checkpoints/BF16 KV, context16384/util.90/16 sequences, concurrency8. Cached HF revisions are pinned in the job
wrapper and evidence JSON. Original collector SHA fe5679d9913fdc92008ad6d409c05c7b400239dd1913eeb4639dde2f3e29576b.
Original440 aggregate and raw local results remain unchanged. Original remote summaries are backed up under
R/results/ocr/<model>/runs/ before extension. Replies retain original IDs; new readings append to that cache.

## Finish each queue item

If jobs are still pending/running, checkpoint their actual IDs/state; do not allocate duplicate work. If the
collector is alive, let it retrieve/score. If it failed, inspect saved logs and scheduler states first; all
successful page readings remain reusable. An uncertain submission is recorded separately; query the unique job
name before any retry. No failed-page or capped-answer inference rerun is silently authorized by collection.

For W43.farmshare-ocr-more: inspect three E/receipts/<model>.json (collected at L/receipts) for895 terminal
answers, at least440 reused, old_readings_unchanged=true and collector_exit=0. Review L/numeric-results,
then copy only numeric outputs into bench-corpus/farmshare-expanded*. Keep farmshare.csv and its original440
comparison intact. Report original440, added455 and full895 separately: the895-page mix cannot be compared
directly with hosted references that read only440. Update ArchiveOCRBench in the same results commit.

For W43.seg-date-public: review L/public-numeric-results/{crest,lincoln}-scores.json; preserve frozen truth
hashes and the three existing model rows. Add a named combined-model row to the report and benchmark. This is
a public generalization comparison; it does not reopen the private-test freeze or reverse the original joint
adoption decision (Mac full-date loss1.333points). No retraining or rerunning the locked private test.

After each results commit: move the full item to SUITE_TODO_DONE, tick the same tag with plan-edit complete,
push/fast-forward primary, verify tracker sync and manager hooks. Delete this plan after BOTH items finish.
Raw data/models remain durable outside git. Use saved source snapshots or the checkpoint commit if future
prompt code differs; stale-request refusal is a reason to use the recorded version, never to repeat inference.

## Agent Manager accounting and restart readiness

The previous batch was already recorded through shared completed trackers, the locked primary plan Session
Log and pushed commit bodies. Agent Manager's completed/fingerprint/status hooks read those sources directly;
its walkthrough also reads origin/main. Its restart/precheck, pregate, queue, holds, completed and status hooks
passed. An interactive chat is not a daemon-launched session: no fake engine ledger, session PID, grant, token
usage or cost record was written. New work has its own two shared queue tags and concrete external job IDs.

A pre-existing ticked W36.seg-decision stub was moved intact to DONE, preserving the owner's old answer; the
open-tracker stub check now passes. Other sessions' dirty worktrees are preserved, not cleaned or merged by
this task. The full global handoff audit can still flag them; they are distinct from the manager's passing
restart hooks. No daemon was started or stopped. The last full health gate is GREEN; this checkpoint changes
benchmark tooling/docs only. Nine importer/cache regressions pass, and the new reporter reproduces all24
committed original440 Qwen aggregate rows exactly without inference.
