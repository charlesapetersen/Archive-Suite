# Future features

Ideas the owner wants kept for later. Nothing here is queued, and an autonomous session must not start any of it.
An entry moves into `SUITE_TODO.md` and the plan only when the owner asks for it. Each entry says what it is, why
it is waiting, and what is already known, so that nobody has to measure it again before deciding.

## On-device segmentation model

Filed 2026-10-11 by the owner, at `W36.seg-decision`, as an experiment worth trying later.

**What it is.** Segmentation that runs on the Mac, with no API key and no subscription: a small local vision model
fine-tuned (LoRA) on the boundaries implied by the owner's own tagged corpus, possibly run only overnight.

**Why it is waiting.** In the bake-off no on-device method came close to the cloud models. The local vision models
scored 47–57% of pages in an exactly right document on Deaver, where every cloud model scored 97.9%. The feature
model, built on page clues and Apple's built-in embeddings, scored 66% on the development boxes and about 20% on
Deaver. The cloud route it would replace costs about $1–4 per 1,000 pages. The segmentation options build
(`execution-plans/segmentation/04-options-build.md`) comes first.

**What is already known** (from `execution-plans/segmentation/01-results.md`):

- The corpus implies about 8,700 document starts and 38,354 continuations, in 120 folders tagged per document. The
  owner's marked sample found about one implied start in five wrong (21%) and about one continuation in thirteen
  (8%), so these are noisy training labels, not truth.
- The best zero-shot model was Qwen3.5-4B at 4 bits: about 3 hours per 1,000 pages and 5.5 GB peak memory on this
  Mac, an M3 Pro with 18 GB.
- Estimated, not measured: a fine-tune would take a few nights with the Mac left alone, peak memory around
  10–14 GB, and 3–5 daemon sessions of work. Whether it would climb from 57% towards the 90% or more that matters is
  unknown, and nothing measured so far suggests it would.
