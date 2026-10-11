# Automatic segmentation: what the bake-off found, for your decision

Written 2026-10-11 (`W36.seg-report`). Your decision is `W36.seg-decision`. The figures come from the bench's
saved results: `ArchiveProcessor/segbench-results/SUMMARY.md`, `ensemble-dev.md` and `ensemble-test.md`. The
running notes are in `03-early-read.md`. This page makes no new model call.

## The answer in short

**Your bar was not met.** The best method was Claude judging seven-page windows, with every boundary it rated 85%
sure or less sent to you for review. It was scored once on the two locked boxes, Stanton and RG 165:

- **97.3% of pages ended up in an exactly right document after review** (Stanton 97.1%, RG 165 97.7%). The
  proposed bar was 98% in every test box.
- **About 10 boundaries to check per 100 pages** (Stanton 12.8, RG 165 4.4). For a box of 250 pages that is
  about 25 checks.
- **3 errors you would never be shown, in 363 pages.** That is about 4 per 500 pages. The proposed bar was 1.
- **With no review it is 87–89%**, about one page in eight in a wrongly split or merged document.

On the three development boxes the same rule scored 99.0% after review, with about 6 checks per 100 pages. The
drop on the locked boxes is the honest cost of having chosen the method on the development boxes.

## Every approach, side by side

The development boxes are Dean, Deaver and Herrnstein (551 pages). "Exact" means the share of pages whose
document holds exactly the right pages; it is the number that counts misdated and misfiled pages. The spring
prompts were tuned on all five boxes, so their rows flatter them. The other prompts were written after reading
your notes on the development boxes.

| approach | runs where | pages exact (dev) | false splits | false merges | cost per 1,000 pages |
|---|---|---:|---:|---:|---|
| the prompt the app ships (spring-v1, one page at a time) | cloud, inside the OCR call | 86.5% | 20 | 6 | already paid as part of OCR |
| A. Claude Sonnet 5.5, seven-page windows | cloud | 90.3% | 5 | 6 | about $48 at the API list price (about $24 by batch); $0 on your subscription |
| B. Gemini 3.1 Flash-Lite, seven-page windows | cloud | 84.6% | 27 | 3 | about $1.20 |
| B′. Gemini 3.8 Flash, seven-page windows (Deaver only) | cloud | 97.9% on Deaver, the same as Claude | 0 | 1 | about $3.80 |
| C. Gemini 3.8 Flash, one call per folder | cloud | **93.1%** | 7 | 7 | about $2.60 |
| D. feature model (page clues + Apple's built-in embeddings) | on the Mac | 66.2% (Deaver about 20%) | 21 | 57 | $0 |
| E. local vision models, zero-shot (Deaver only) | on the Mac | 47–57% on Deaver | 16–37 | 1–10 | $0 |
| F. the best combination with review (A alone, ≤85% sure flagged) | cloud | 99.0% after review, held out per box | — | — | the same as A |

Costs are list prices found on 2026-10-05; Gemini 3.8 Flash is at its introductory price until 31 Dec 2026. The
whole bake-off cost about $4 in paid calls. The Claude calls ran on your subscription.

**Combining models did not help.** Of the 15 combinations tried, the best rule was Claude's own confidence alone.
Adding the Gemini folder call (C) gave the same result with a few more checks. Gemini Flash-Lite disagreed mainly
where it was wrong itself, and the on-device model only added checks. The errors that matter are the ones every
model makes in the same way, so agreement cannot reveal them.

**Review load per box** (Claude alone, ≤85% sure flagged): Dean 13 checks in 202 pages, Deaver 7 in 149,
Herrnstein 12 in 200, Stanton 32 in 250, RG 165 5 in 113.

**The phone's "End segment" marks** (approach G) could not be measured. RG 165's folder keeps the photos and the
CSV, not the groups recorded during capture.

## The overnight option: on-device methods

You asked for models that may only be practical overnight, on a Mac left alone. This Mac is an M3 Pro with 18 GB.

| on-device method | time per 1,000 pages | peak memory | overnight only? | accuracy |
|---|---:|---:|---|---|
| D. feature model (Apple Vision image print, NaturalLanguage text embedding, logistic regression) | about 2 minutes on top of OCR | 0.15 GB | no: runs any time, unnoticed | 66% on dev; fails on clippings |
| E. Qwen3.5-4B, 4-bit | about 3 hours | 5.5 GB | in practice yes: it keeps the GPU busy for hours | 57% on Deaver |
| E. Qwen3-VL-8B, 4-bit | about 5½ hours | 7.9 GB | yes | 53% on Deaver |
| E. Gemma 4 12B, 4-bit | about 5½ hours | 12.3 GB | yes: leaves under 6 GB for everything else | 47% on Deaver, 8 of 51 windows failed |

How the times were measured: for E, the seconds per window recorded on Deaver (33, 57 and 60 s), times the 339
windows that 1,000 pages need. For D, a timing of the embedding step on 100 development pages today (11 s, 0.14 GB
peak). It ran in a background daemon session, which can slow a process several times over, so treat 2 minutes as
an upper figure. The local models ran under the Vision OCR lab's memory guard.

**None of the on-device methods is close.** The best local vision model gets 57% on the box where every cloud model
got 97.9%. Running it overnight would save money that is already small: about $1–3 per 1,000 pages for the Gemini
calls.

**Could your tagged corpus make a local model good?** The read-only survey (`W36.seg-corpus-survey`) found about
8,700 implied document starts and 38,354 implied continuations in 120 folders tagged per document. You marked a
sample: about one implied start in five is wrong (21%), and about one continuation in thirteen (8%). That makes
them noisy training labels, not truth. A LoRA fine-tune of Qwen3.5-4B on them would cost no money. Estimated, not
measured: a few nights of the Mac left alone, peak memory around 10–14 GB, and 3–5 daemon sessions of work. Whether
it would climb from 57% to the 90%+ that matters is unknown, and nothing measured here suggests it would.

## Recommendation

**Not as an automatic step.** At 87–89% with no review, about one page in eight would be misdated or misfiled
without a word. That is the harm you said would make it unusable.

**As a first draft that you review, yes, if a 97% result with about 10 checks per 100 pages is worth having
compared with segmenting by hand.** The build would propose every boundary and put the roughly 10 doubtful ones per
100 pages in front of you, page n beside page n+1. The rest would stay visible in the existing review sheet for a
skim. That skim is the only thing that would catch the unflagged errors, about one per 120 pages.

**If you approve a build, first run one cheap measurement:** Gemini 3.8 Flash over seven-page windows on Dean and
Herrnstein (about $1.50). Claude on your subscription is not a route the app can use. In the app it would be an
API key at about $24–48 per 1,000 pages. Gemini 3.8 Flash matched Claude on Deaver at about $4. If it holds on the
other two boxes, it is the provider to build on, and it would be scored once on the locked boxes like the others.

The on-device and overnight routes are not worth building now, and neither is the corpus fine-tune.

## Your options at W36.seg-decision

1. **Stop here.** Automatic segmentation is not good enough. The manual modes stay, and the Processor's
   verification items (`W40.b3`, `W40.d1`–`d4`) go ahead.
2. **Build the review-first assistant** on Claude-window confidence, at about $24–48 per 1,000 pages by API key.
   Roughly an L-sized, Tier-2 build of about a dozen sessions, and the W40 Processor items wait for it.
3. **Option 2, but measure Gemini 3.8 Flash windows first** (about $1.50, one session), then build on whichever
   provider holds up. *Recommended, if you want a build at all.*
4. **Try the corpus fine-tune for an on-device model**: no money, several nights, outcome doubtful. Not recommended.

Caveats on every figure: five boxes and 914 pages in all, so one boundary moves a box's figure by up to about a
point. The test boxes were scored once and nothing was tuned on them. The spring prompts saw all five boxes.
