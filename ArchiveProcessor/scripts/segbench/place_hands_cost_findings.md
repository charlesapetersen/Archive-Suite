## Findings

**Time: the whole hand route takes 7.52 s a page (median of 40 page runs, two passes over the 20 pages on the
CPU), 9.0 s on average, 17.5 s at most.** blla is the larger part (4.7 s a page median), then McCATMuS recognition of
the detected lines (1.3 s), the two matchers and the `conf` pick (1.3 s; it grows with the page's line count, to 9-10 s
on p022's 42 lines, the 17.5 s page), and the writer (0.08 s). Loading the two models takes about 1 s, once. The two
passes differ by 0.05 s a page in the median and 0.36 s at most, so a gap under about 0.4 s a page is a tie. On the
average figure the route places about 400 pages an hour on this Mac. W46.place-hands' 6.1 s was blla alone, through
kraken's command line over all pages at once; here blla is 4.7 s through kraken's API, the same model on the CPU.

**Memory: a page needs at most 4.64 GB on the CPU, but one process running page after page keeps more; it reached
8.51 GB over 60 pages and had not levelled off.** In a fresh process per page the peak footprint is 3.82 to 4.64 GB
(p009 the most), almost all of it blla working on the full-size photograph. In one CPU process over the 20 pages it
peaked at 6.26 and 5.78 GB in the two passes, and over the 20 pages three times (60 pages) the pass peaks were 4.96,
6.87 and 8.51 GB, falling back to 1.4-2.4 GB on some pages between, so this is memory the allocator keeps rather than a
steady leak; 60 pages cannot say where it stops. On MPS, with `torch.mps.empty_cache()` after every page, the peak is
4.39 GB and the footprint falls back to about 1.1 GB after every page, at a similar speed (7.98 s a page median:
blla 3.8 s, recognition slower at 3.1 s). Without emptying the cache, MPS grew from 0.6 to past 7 GB within the first
two pages (a first run, stopped by the guard; not in the tables).

**So the route fits a 16 GB Mac, not an 8 GB one, and the Processor should bound its memory.** By the solver's rule,
the measured peak plus 5 GB of headroom: the highest measured, 8.51 GB, needs about 14 GB; a page's own 4.64 GB, or
MPS with the cache emptied, about 10 GB. Each fits 16 GB and none fits 8 GB. The row carries 8.51 GB, the highest
measured, and the condition that the app runs the route on MPS emptying the cache after each page, or in a worker it
restarts every few pages, since the single CPU process was still growing at 60 pages. A 16 GB Mac was not available:
the fit is the solver's rule applied to figures measured on the 18 GB M3 Pro, not a run on 16 GB. Seconds a page on a
smaller Mac (fewer performance cores) will be longer; this Mac's 6 performance cores ran 6 torch threads.

**What W46.place-hands ran, for the record.** Its blla ran on the CPU (kraken's command line), but its McCATMuS
recognition ran on MPS: kraken's API defaults to `accelerator='auto'`, which is MPS on a Mac. Placement does not
depend on it here: every page's line count and `conf` confidence match the saved runs on the CPU and on MPS.

## Measurement card

- **Truth.** None is scored: this is a cost measurement. Parity instead: each page's blla line count and the `conf`
  pick's CTC confidence equal W46.place-hands' saved run with the same reading (Qwen3.6-27B), 20 of 20 in every run,
  so the route timed is the route scored in `place-hands-lines.md`.
- **Selection.** The owner's 20 hand pages the placement truth audit passed (`place_hands.keep`), the same pages as
  W46.place-hands; not chosen by any route.
- **Comparison.** Same pages, reading, models and machine for every run, each under the Mac-wide heavy lock (no other
  heavy job beside it), at normal priority (the session was not QoS-clamped: a pure Python loop ran at its usual
  speed). CPU against MPS differ only in the accelerator both models use.
- **Noise.** Time: two CPU passes, per-page difference median 0.05 s, at most 0.36 s; the 60-page run's pass medians
  7.47, 7.34 and 7.16 s. Memory: footprint is sampled every 0.1 s inside the worker and read whole-process by
  `/usr/bin/time -l`; the one-process peak varies by run (6.26 and 5.78 GB for the same 20 pages), so the per-page
  fresh figure (3.82-4.64 GB) is the stable one.
- **Scope.** One machine (M3 Pro, 18 GB); no 16 GB Mac was run. The writer is the lab writer (`place_functional`), not
  the Processor's, which does not yet place hands (W42.int-s5). The reading is a saved one: its own cost is stage 04's.
  60 pages do not show whether the single CPU process levels off; thousands were not run.
