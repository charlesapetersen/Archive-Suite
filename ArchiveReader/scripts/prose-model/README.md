# Can an on-device model improve Copy Cleaned for Prose? (W40.reader-prose-model, 2026-11-12)

**Verdict: no, not now.** On 40 typed pages the Foundation Models model, labelling lines for the app to assemble,
ties the Reader's rules on per-line labels and is clearly worse at finding where paragraphs, headings and items
start. No arm won on any measure by more than the noise. It also refused 2 of 40 pages on safety grounds, takes
3-9 s a page against the rules' instant result, and changes with each OS update. The rules stay the only pass;
no build is filed. What would reopen it is under *Scope*.

## Foundation Models: what it needs (Apple's documentation, checked here)

- **OS.** macOS 26 or later (`SystemLanguageModel`); image attachments, the 8,192-token context and the
  `contextSize`/`tokenCount` API need 26.4-27. The suite's floor is macOS 14. The Reader could weak-link the
  framework and gate it with `#available(macOS 26, *)`, but the pass would exist only on Macs that meet all three
  conditions below.
- **Hardware and setting.** A Mac that supports Apple Intelligence (Apple silicon), with Apple Intelligence
  switched on and in a supported region. `availability` reports `.unavailable(.deviceNotEligible |
  .appleIntelligenceNotEnabled | .modelNotReady)`. This Mac (M3 Pro, macOS 27.2 26B123) reports `available`.
- **Languages.** Those Apple Intelligence supports. This Mac lists da, de, en, es, fr, it, ja, ko, nb, nl, pt, sv,
  tr, vi and zh; an unsupported language throws `unsupportedLanguageOrLocale`.
- **Context.** 8,192 tokens on macOS 27 (measured here; it was 4,096 before 27). A 70-line page with its geometry
  is about 4,000 characters of prompt.
- **Stability.** Apple updates the model with the OS (26.0-26.3, 26.4 and 27.0 are different models) and asks
  developers to re-test their prompts on each one. Greedy sampling was deterministic here: 40 of 40 pages gave
  identical labels on a rerun.
- **Guardrails.** Guided generation is filtered. "May contain sensitive/unsafe content" refused 2 of 40 corpus
  pages, the same 2 on every text-only run. `.permissiveContentTransformations` changed nothing, because Apple
  documents it for plain-string responses only. With the one-example prompt, no page was refused.
- **Privacy.** On-device only. The Private Cloud Compute model (32K context, macOS 27) runs off the Mac and was
  not used.

Sources: developer.apple.com/documentation/foundationmodels (SystemLanguageModel; supporting languages and
locales; updating prompts for new model versions; managing the context window), WWDC26 session 241, and the
acceptable-use requirements, which do not restrict historical documents.

## The design measured

The model never writes text. Each page's rows are the rows the Reader's rules use (`CopyTextCleaner.layoutRows`
over PDFKit's line selections). Each row goes to the model with its indent from the margin in line heights, its
gap above in usual line spacings, its width as a share of the text width, and its text. Guided generation returns
a fixed-length array with one label a row: C continues, P new paragraph, H heading, I1-I4 list item and level. The
app turns the labels into `CopyTextCleaner.Unit`s and assembles them with `assemble`, whose word guard refuses any
result whose letters differ from the selection's. Every result that came back passed the guard. Where the model
refuses, the rules' text stands, so the arm scored as deployable is `+rules`.

Arms: **fm**, the text and geometry above; **fm-image**, the same plus the rendered page (a macOS 27 image
attachment); **fm-shot**, fm with one worked example of invented text in the instructions. Two controls: a
**rerun** of fm, and fm with **permissive** guardrails.

## Results (39 pages, 1,142 rows where the two drafters agree)

| arm | exact | break P | break R | break F1 | headings found | items found |
|---|---|---|---|---|---|---|
| rules | 0.854 | 0.468 | 0.924 | 0.621 | 6 of 20 | 8 of 16 |
| fm+rules | 0.868 | 0.445 | 0.412 | 0.428 | 3 of 20 | 6 of 16 |
| fm-shot+rules | 0.857 | 0.346 | 0.311 | 0.327 | 10 of 20 | 6 of 16 |
| fm-image+rules | 0.468 | 0.128 | 0.639 | 0.213 | 3 of 20 | 8 of 16 |

"Exact" is the row's label, list level included. A "break" is any label but C.

Paired differences from the rules, 95% from 2,000 page resamples:
- fm: exact +0.014 (−0.025 to +0.055), a tie; break F1 −0.194 (−0.328 to −0.062).
- fm-shot: exact +0.004 (−0.043 to +0.050), a tie; break F1 −0.294 (−0.421 to −0.169).
- fm-image: exact −0.386 (−0.511 to −0.255); break F1 −0.409 (−0.489 to −0.330).

Against each drafter alone (all rows), exact:
- Qwen: rules 0.740, fm 0.723, fm-shot 0.722.
- Gemma: rules 0.778, fm 0.814, fm-shot 0.794.

The direction flips with the drafter, so on exact labels the two methods are inside the truth's own error. The
text arm breaks too rarely: it labels most rows C. The image arm breaks at random. Only the example prompt found
more headings than the rules (10 against 6, of 20), and it lost more breaks than it gained.

**Time and memory, per page.**
- fm: median 3.9 s, max 7.8 s (rerun median 3.3 s).
- fm-image: median 4.9 s, max 8.9 s.
- fm-shot: median 3.9 s, max 6.3 s.
- The rules take milliseconds.
- The client process stays at 12 MB. The system's inference service (`TGOnDeviceInferenceProviderService`) peaked
  at 0.92 GB resident during the image arm.
- At these times the pass could not run on ⌘C as the copy does today. It would need a background pass or a
  separate command.

## Measurement card

- **Truth.**
  - Drafted blind on the Mac by two open vision models of different families, Qwen3-VL 8B and Gemma 3 12B (MLX,
    4-bit). Each saw the rendered page and its numbered rows as text only: no geometry and no label from either
    scored method. Neither drafter is a scored route or a relative of one.
  - Truth is their agreement. They disagree on 21% of rows (309 of 1,451); disputed rows are left out. The
    biggest splits: Qwen marks 130 rows as items where Gemma marks 14, and the two split paragraph starts from
    continuations in both directions.
  - What remains is mostly continuations (1,023 C, 83 P, 20 H, 16 I).
  - The owner checked none of it. The drafters are not clearly stronger than the rules.
  - This truth is enough to reject a clear win, which is what the item asks about. It cannot rank close arms.
- **Selection.** By geometry alone (`select.py`, seed 4011), never by either method's labels:
  - typed: 8-70 rows, 80+ words, 5+ words a row, even row heights;
  - structured: two or more indents each shared by two rows, or a narrow row set off by gaps.
  - 1,489 of the 5,000-file sample's pages qualify, 40 drawn. Precondition: the page's line boxes hold its text
    word for word (4,382 of 4,884 page-1 texts), which both methods need.
  - Page 1 only. Qwen's reply on one page did not parse, so 39 pages are scored.
- **Comparison.** The same rows of the same pages for every arm. The model arms receive the same geometry the
  rules measure; the image arm adds the page. Pages the model refused are scored with the rules' labels (`+rules`,
  as the app would copy them). Its own answered-page scores agree within 0.03.
- **Noise.** n = 39 pages, paired page bootstrap. The rerun floor is zero (greedy; 40 of 40 pages identical).
  Exact-label gaps are ties. The break-F1 losses lie outside their intervals.
- **Scope.** Not settled here:
  - other OS model versions (the result is for macOS 27.2's model);
  - other prompts (one, plus one variant);
  - handwriting, multi-column pages, later pages;
  - the Private Cloud Compute model, which the item excludes because text would leave the Mac;
  - an adapter trained for the task.
  - Against this truth the rules' break precision is 0.47: they split where both drafters see a continuation.
    Whether the rules over-split, or the drafters under-split, needs a stronger truth. It is not evidence for the
    model, which does worse there too.
  - **Reopen** when a new OS model version or a task adapter is available. Rerun `prosebench fm` on the same 40
    pages, then build an owner-checked truth before any build.

## Rerun

Scratch copies only (the 5,000-file sample in `~/Library/Caches/ArchiveSuiteRehearsal/reader-sample`). Run every
step through `ops/autonomous/heavy-run.py run --`:

```bash
swift build -c release --scratch-path /tmp/prosebench-build          # in this folder
B=/tmp/prosebench-build/release/prosebench; C=~/Library/Caches/ArchiveSuiteRehearsal/prose-model
$B extract all.txt pages.jsonl && $B rules pages.jsonl rules-all.jsonl   # all.txt: the sample's PDF paths
python3 select.py $C                                                     # selection.txt; rules40.jsonl and list40.txt
                                                                         # are its pages' records and paths, in order
$B render list40.txt img && $B fm rules40.jsonl fm40.jsonl               # PROSE_SHOT=1 / PROSE_PERMISSIVE=1;
$B fm rules40.jsonl fm40-img.jsonl 40 img                                # the image arm
<lab venv>/bin/python truth_draft.py $C qwen3-vl-8b                      # then gemma3-12b
python3 score.py $C
```
