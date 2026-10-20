# Stock PP-OCRv6 FarmShare checkpoint — 2026-10-19

W43.ppocrv6-farmshare. Owner explicitly asked to queue the stock Paddle pipeline. The prior
Kraken-adapted recognizer and current PaddleOCR-VL1.5 are different routes and are not this measurement.

## Submitted work — collect, never duplicate

- CPU preparation **1858052**: normal partition,8CPU/48GB/2h, isolated package overlay and pinned downloads,
  model load plus a synthetic white-image API smoke. No benchmark page read on the login/CPU node.
- Native OCR **1858053**: one L40S GPU,8CPU/48GB/12h, afterany1858052 AND1857671 (Inkling).
  A failed preparation exits before benchmark inference. Three L1/L4/L8 pilots must produce schema-valid,
  nonempty text before full895 starts. The full pass reuses these three readings,895 total.
- First submission attempt was explicitly rejected by sbatch because `bash` was supplied as the script.
  No job existed; checked unique names and absence of jobs.json before correcting the script argument.
  Remote submission marker retained as submission-script-argument-rejected; no inference was repeated.

L=`/Users/cp1/Claude/Long term storage/FarmShare-ppocrv6-20261019`
S=`/scratch/users/cp1/fs-ocr/ppocrv6-20261019`
Read L/jobs.json, collection-status.json and S/logs before any recovery. Durable scripts live at L/S recovery,
not in a temporary worktree. The caffeinate collector polls180s for at most48h, retrieves terminal model
outputs (including failed partials) to L/outputs and logs to L/remote-logs, then exits. It never submits,
retries inference, starts the daemon or authenticates. If SSH breaks it saves needs_inspection and stops;
check PID/marker before restarting only the collector. Keep the owner's existing SSH master and held channel.

## Pinned configuration and provenance

[Detector](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det_safetensors), revision
4236c2b61741a259c091fd879dcc4edc339e916c.
[Recognizer](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_safetensors), revision
024cad6a831de75c2c3c26e711ba8c4a82ccd24b. Both Apache2.0; public, no remote code, <=2GB each enforced.
PaddleOCR3.7.0, PaddleX3.7.2 and Transformers5.20.2 pinned in S/venv, with explicitly pinned Torch2.13.0,
torchvision0.28.0/numpy2.3.5 installed there. --system-site-packages exposes the OS packages only;
the existing vLLM environment is not inherited or mutated. Transformers5.17 in the shared environment
lacks this architecture; it is not changed. Resolved package list retained outside Git.

The native PaddleOCR general pipeline uses transformers engine with document orientation/unwarping and
line orientation disabled, as in the official detector card's Python pipeline. Explicit native defaults:
detector limit64/min, max_side_limit4000 from pinned package, threshold0.3/box0.6/unclip1.5;
recognition batch6/score threshold0.0. Same frozen JPEG2400px/JPEG90 bytes as other runs, with per-image
SHA checks. Internal native preprocessing differs from VLMs and must be labelled. No autoregressive cap
or prompt; join native rec_texts with newlines, preserve the native JSON including geometry/confidence,
and do not invent layout ordering. This is not a controlled prompt-equivalent VLM panel row.

CPU smoke checks model loading and schema on a synthetic blank only; GPU three-page gate checks compatibility,
not transcription quality. Blanks/errors are retained as failures, never silently retried. Per-page records
bind image SHA plus model/config/code contract. Contract excludes manifest length to permit reuse when pages
are later added; this submitted batch itself refuses anything other than the frozen895 and matching pilot3.
A later expansion needs an explicitly reviewed manifest-size allowance, not rereading cached unchanged pages.
Pilot failure prevents full inference. Timeout/partial output is checkpointed, never presented as complete.
HF offline flags on GPU prevent floating downloads. Source/weight/config hashes and package versions retained.

## Resume and finish

Inspect prepared.json and scheduler/logs; then retrieve only recorded outputs. Review sample transcription,
page ordering/rotation/language and native resize settings before accepting scores. Score all895 raw answers
with blanks/errors as failures, preserve stratum/source identity, publish the route separately from both
PaddleOCR-VL1.5 and Kraken-on-Vision-crops, and keep historical440 unchanged. No automatic catalogue or
adoption/default changes. Reconcile SUITE_TODO/DONE and primary plan; delete this plan only when reviewed
results ship. Record interactive provenance honestly; no fabricated daemon PID, grant, usage or cost ledger.
No hosted money spent. No corpus construction, app changes, training or private locked-test repeat.

## Check-in — 2026-10-19 22:37 UTC

Preparation1858052 completed0 in4m46s; prepared.json is ready, pinned models loaded and the synthetic
white-page API smoke passed. GPU1858053 remains pending after Inkling1857671. No benchmark page has
yet been read by this route. Preparation receipt, pipeline.yaml and smoke JSON copied to
L/preparation-check. Original collectors and SSH held channel remain healthy; no new submissions.

## Rerun — 2026-10-20 (owner-directed; supersedes 1858053)

**Collect job 1860044, not 1858053.** 1858053 failed after 8 s at 06:02 on 20 Oct: `read_rows` in
`recovery/ppocrv6_run.py` rejected 42 of the 895 page IDs as unsafe (41 contain parentheses, e.g.
`eparchos__6791_(11)`; one has accented letters, `tapus__AN-96AP_1-dossier_1-pièces_…`). No page was read.
The ID is only ever used as the file name `<id>.json`, so the allowed set was widened from `[A-Za-z0-9_.-]` to
`[\w.()-]` (line 106; slashes and spaces still rejected). All 895 IDs pass. Original kept beside it as
`ppocrv6_run.py.orig-1858053`. The run contract file had not been written, so the runner hash did not conflict.

Resubmitted by hand as **1860044**: same resources (1 GPU, 8 CPU, 48 GB, 12 h), no dependency (setup 1858052 and
Inkling no longer gate it). Result: COMPLETED in 5 min 26 s, 895 raw readings in `ppocrv6-medium-native/raw`;
893 log lines `ok`, one page `blank` (`btp__afc1945001_ms04062-29`). Not yet reviewed or scored. Log:
`ppocrv6-20261019/logs/pp6-19-ppocrv6-medium-native-1860044.log`.
