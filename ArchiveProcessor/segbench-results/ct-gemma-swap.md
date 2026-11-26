# Switching between Gemma labels and local page OCR

W49.proc-gemma-swap-time · Gemma 3 12B IT 4-bit (labels) and Qwen3.5 4B 4-bit (pages) · mlx-vlm 0.7.4 on the
18 GB M3 Pro, macOS 27.2.1 · loopback only, local cached weights, $0 · run 2026-11-26.

Live Capture can need Gemma for a box or folder label between pages that a local OCR model reads. This measures
what that switch costs when only one model is in memory at a time. Rows: [`ct-gemma-swap-rows.jsonl`](ct-gemma-swap-rows.jsonl)
(timings and sizes only). Script: `scripts/segbench/ct_gemma_swap.py`.

## The server's automatic switch does not fit an 18 GB Mac

mlx-vlm 0.7.4's server switches models itself when a request names another one, but `get_cached_model` keeps the
outgoing model while it loads the next, so Gemma and the OCR model are resident together. Both attempts on
2026-11-23 were stopped by Agent Manager's memory guard (65% of the Mac, 11.7 GB) under memory pressure before a
measurement was saved: at **13.0 GB** with Qwen3-VL 8B and at **12.0 GB** with Qwen3.5 4B. Owner session,
2026-11-24: those two stops are the result for that route on this Mac, and it is not run again.

## One model at a time: stop the server, start it with the next model

The harness stops the server and starts a fresh one with the next model preloaded, so two models are never in
memory together. This is the rule `LocalModelSupervisor` already follows for app-managed models (a read for
another model stops the loaded worker and waits for it to exit). Gemma is loaded first; then four blocks each
switch to Qwen, read two pages, switch back to Gemma and read two labels. Image order alternates (0, 1, 1, 0), so
each image is the first read after a load twice. Every request must finish with `stop` and a usable reply, and the
server must list only the expected model before and after its reads. All 9 loads and 18 reads completed.

Times are seconds; memory is the server's physical footprint in GiB (the guard's unit), sampled every 0.1 s.

| Step | Gemma 3 12B | Qwen3.5 4B |
| --- | --- | --- |
| Stop the other model's server | 0.26–0.37 (4 stops of Qwen) | 0.22–0.36 (4 stops of Gemma) |
| Cold load: process start to answering, model in memory | 4.66–5.73, median 5.56 (n 5) | 3.21–3.41, median 3.37 (n 4) |
| Peak while loading | 7.75 | 3.39 |
| First read after a load, label 1 / label 2 or page 1 / page 2 | 13.25–14.45 / 13.23–13.26 | 22.43–23.67 / 11.70–12.35 |
| Warm read, same images | 13.42–13.48 / 11.94–12.29 | 23.62–23.82 / 11.36–11.92 |
| Peak while reading | 9.83 | 6.02 |
| Full switch into the model: stop + load + first read | 18.47–20.32, median 19.17 (n 4) | 15.20–27.30 (n 4; page 2 / page 1) |

- **Overhead of a switch, beyond the read itself:** about 5.9 s into Gemma (stop plus load) and about 3.6 s back
  to the OCR model. A label between two pages therefore costs about 9.5 s of switching plus Gemma's read, about
  23 s in all, against about 13 s if Gemma were loaded already.
- **First read after a load:** Gemma's is up to 1.3 s slower than a warm read of the same label (label 2: 13.2 s
  against 11.9–12.3 s; label 1 within 1 s); Qwen's is within 1 s of a warm read either way. Page time follows the page:
  page 1 (3,441 characters) takes about 23 s, page 2 (1,486) about 12 s. Qwen's first streamed text came at
  2.9–3.1 s in every read.
- **Memory:** the highest footprint of the run, 9.83 GiB, is Gemma reading alone, under the item's 10 GiB stop
  line and the guard's 11.7 GB. A first attempt that set the stop line at 10 × 10⁹ bytes stopped at 10.17 × 10⁹
  bytes (9.47 GiB) during Gemma's first read; the guard and the item count in GiB, and the route-fields benchmark
  measured the same Gemma server at 9.85 GiB.

## The configurations, each on its own

1. **The server's automatic switch (mlx-vlm 0.7.4):** does not fit; 13.0 and 12.0 GB stops above.
2. **One model at a time, switching for each label:** about 9.5 s of switching per label on top of a 12–14 s
   Gemma read, so about 23 s per label between pages. Peak 9.83 GiB. Live Capture's segment work waits that long.
3. **One model at a time, labels batched** (read together at a segment's end or at Finish, one switch each way per
   batch): about 9.5 s per batch plus 12–13.5 s per label, the reads after the first being warm. For 10 labels in a
   session, about 9.5 + 10 × 12.8 ≈ 137 s against about 10 × 23 ≈ 230 s switching per label. The label
   suggestions arrive at the batch, not as each label is photographed.
4. **Apple Vision + parser, no Gemma:** 0.17 s a photo (`ct-read.md`), no model and no extra memory, no switch.
   It gives up Gemma's measured leads on repository (+7 points, +1 to +13), collection title (+16, +9 to +22) and
   collection number (+11, +4 to +18). Vision + parser is ahead on what the photo is (+20), collection subtitle
   (+8), accession (+6) and box title (+16); container, series, series title and folder number are ties
   (`ct-read.md`, 194 photos).

Configurations 2 and 3 need the app to control the process, as it does for its own managed models. On a server the
user runs (mlx-vlm, LM Studio, Ollama), the app cannot stop and restart it; what happens there is the open question
in W49.proc-gemma-external-switch.

## Measurement card

- **Truth.** None: a timing and memory measurement. A reply counted only if it finished with `stop` and was usable
  (Gemma's parsed to at least one field by the bench parser; Qwen's non-empty). Reading quality was not scored.
- **Selection.** Two upright label photos (`00736de9d746`, `01237d4176bd`) from the frozen container-label set and
  two OCR truth-panel pages (`p008`, `p023`), the same scratch copies the 2026-11-23 attempts chose; not chosen by
  any route's result. Hashes are in the rows file.
- **Comparison.** One mlx-vlm 0.7.4 server process at a time, pinned snapshots (Gemma `86cc6a8d`, Qwen `c43ee1d6`),
  the app's Swift JPEG encoder (labels 1,600 px long edge; pages capped at 900 px), the app's label prompt (640
  tokens, unstreamed) and first-page OCR prompt (4,096 tokens, streamed), temperature 0, reasoning off. Run under
  the heavy lock with no other model job.
- **Noise.** n is 4–5 loads and 2–3 reads per image and model, one run. Ranges are reported, not intervals. The
  weights were in the file cache (both models had been read before), so the loads are warm-disk; a disk-cold load
  after the cache is evicted would be slower and was not measured.
- **Scope.** mlx-vlm 0.7.4 server started per model; the app's `LocalModelWorker.py` follows the same stop-then-start
  rule but was not timed here. LM Studio, Ollama, other OCR models and a disk-cold load were not measured. One
  18 GB M3 Pro.
