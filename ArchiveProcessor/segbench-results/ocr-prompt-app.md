# W41.ocr-prompt-app — the app's transcription instruction

2026-10-14. Baseline `7f3e66a7`. Only `OCRPrompt.build` TASK 3 changes. TASK 1, TASK 2, FORMAT, context
handling and every response-parser byte stay unchanged. KIND is not added. Apple Vision and Mistral's
dedicated OCR endpoint take no such prompt.

Final TASK 3, after the original opening sentence:

- For a box-label or folder-label photograph, transcribe the foreground box or folder label.
- Transcribe everything on this sheet of paper, including headers, footers, citations, stamps and
  copyright lines that a database or archive added to the page.
- Leave out empty checkboxes and other symbols that are not text.
- Write [illegible] for a word that cannot be read.

The ruling to leave out other sheets and folders is carried by the prompt's existing paragraph ("For
classification and transcription, focus ONLY on the foreground page — ignore any background pages or
partially visible documents"), which the tracker already named as matching it. Two lines of checkpoint 1
are gone: the bullet rule (owner, walkthrough 2026-10-14: not worth a place in this prompt) and a separate
TASK 3 sentence restating the other-sheet rule, which is what moved p062's classification when it is read alone (below).

## Checkpoint 1 and the owner's answer

Checkpoint 1 (`50157846`) ran four truth pages once each at temperature 0: headers/footers kept, bullets
normalized, every rotation kept, but p062 went document_continuation → document_start. The owner did not
accept that drift: resolve it or show it is noise, without touching TASK 1; remove the bullet rule.

## Classifier stability (checkpoint 2)

The app's own request this time: `GeminiClient.ocr`'s body (optional previous image first, then the page,
then the prompt), **no temperature** (the app sets none; checkpoint 1's temperature 0 was not what the app
sends), no thinking config, `gemini-3.1-flash-lite`, production `ImageEncoding` and `parseResponse`. Only
`maxOutputTokens: 4096` is added, as a cost ceiling. It truncated two replies whose headers still parsed:
`p081-iso-before` and `seq-final-q00285` (a run into blank lines; see section 2). Neighbouring pages are copied out of the corpus read-only: p062 is
`00293 — Intel Publications.pdf`, page 4 of the *Inteleads* January 1983 newsletter whose cover is `00292`.

Three prompts are compared. **Before** is baseline `7f3e66a7`. **Intermediate** is checkpoint 1 with the
bullet rule already removed, other-sheet sentence still in (SHA `7a8f91…`, below); checkpoint 1 itself, with
its bullet rule, was not re-run without temperature. **Final** is the intermediate minus the other-sheet
sentence; it is what ships.

### 1. Page by page, as checkpoint 1 measured

p062, count of `document_continuation` (the rest `document_start`; every rotation `rotate_0`). "Text
context" is the app default: the last 200 characters of a transcription of the cover made alone.

| Prompt | Alone | Text context: cover read by each prompt | Text context: cover read by Before | Text + previous image |
|---|---|---|---|---|
| Before | 3/6 | 8/12 | 8/12 (same) | 4/4 |
| Intermediate | 0/6 | 0/4 | — | 4/4 |
| **Final** | **7/12** | **0/12** (1/4 with the Intermediate's cover text) | **0/8** | **4/4** |

Alone, the other-sheet sentence was the cause: dropping it from the intermediate gives 7/12 against the
baseline's 3/6. Dropping any other line instead (headers, checkboxes, illegible, labels) gave 0/4 each. Three
rewordings that kept an other-sheet sentence gave 2/12, 0/6 and 0/6. With the previous image every prompt
answers continuation 4/4, which is the right answer.

With text context only, the final prompt still answers start where the baseline mostly answers
continuation (0/12 and 0/8 against 8/12), and no single line is responsible. Dropping any one of the
four remaining TASK 3 lines from the final prompt gives 0/6 each. Adding any one of them alone to the
baseline gives 0/6 each. This p062 setup tips on any addition to TASK 3.

16 further truth pages, alone, one draw each (every 8th from p004 to p100, plus p010, p081, p048): final
vs baseline **16/16 identical classification and rotation**. The intermediate prompt differed on p068
(repeats: baseline 4/4 continuation, intermediate 2/4); the final prompt matches the baseline there.

### 2. As the app runs: a folder in sequence

The test that decides segmentation: 20 consecutive photos of the same folder (`00285`–`00304`, p062's
neighbours), run in order the way the app's sequential path does by default (`sendPreviousImage` is off),
each page given the last 200 characters of that prompt's own transcription of the page before. Each prompt
ran twice. These images are the photos embedded in the corpus PDFs, passed through the production
`ImageEncoding`. They are smaller than the truth-set copies (p062 there is 1609×2048; `00293` here is
1047×1333). In the first Final run, the truncated `00285` reply passed only "10/18/74" as context to `00286`.

| Pair | Pages whose classification differs (of 20) |
|---|---|
| Before vs Before (run to run) | 4 |
| Final vs Final (run to run) | 4 |
| Before vs Final (the four cross pairs) | 3, 3, 5, 5 |

Continuations per run: Before 10 and 14, Final 9 and 9. Every rotation is `rotate_0` in all four runs.
**p062 (`00293`) is `document_continuation` in all four runs.** The two prompts disagree with each other
no more than each disagrees with itself. In the app's actual sequential use, any difference is within the
noise at this sample size. Final did give slightly fewer continuations, 9 and 9 against 10 and 14, and two
runs per prompt cannot rule out a small lean toward start. The isolated "cover text only" setup in section 1
is reproducible but is not what the app does. In the sequence, p062 is not moved.

**Transcription, final prompt:** the ProQuest clippings p010 and p081 keep their citation header and the
"Reproduced with permission of the copyright owner…" footer. p048 (a handwritten letter on Harvard
letterhead) keeps the letterhead and leaves out the neighbouring sheet. Every version did the same,
including the baseline and the final prompt without the other-sheet sentence; the only differences are
draw-level word changes. The existing foreground paragraph names "background pages or partially visible
documents". It does not name a fully visible sheet *beside* the page, which the owner's ruling did. On
these pages that made no difference.

Bullets are left as printed. The model still guesses at words the owner marked `[illegible]`; an
instruction cannot guarantee compliance, and the regression checks the instruction and the parser only.

**Cost.** Estimates were stated before each runner, with a cap of $0.40 per runner. This checkpoint made
326 calls: 706,352 input and 176,795 output tokens, no thinking, **$0.4418** at the app's listed
$0.25/$1.50 per million. Checkpoint 1 spent $0.0172, so the item stands at about **$0.46**. That figure is
token-derived, not a billing export. One provider 503 was not retried in place; the rerun resumed from
cache. Private images, raw replies, runners and rendered prompts are in `/tmp/w41-ocr-prompt-app/`
(`stability/` for this checkpoint), outside git.

Rendered prompt SHA-256 with no context:

- Before: `91ca60115066f073ce41c1db1ec0f316ce83534bef5e567499622b9dc0523999`
- Checkpoint 1 (with bullet rule): `4777ab4265b00122ebc09a4905e78ea6714e7db973e1bee495326fe7335b73a8`
- Intermediate: `7a8f91d5b40783d3a66ca2127f7bbffc1ec2c6c735eaaa704464b6f563e63106`
- Final: `f2fd2fee354a77cec597c9c23d53542389ffa0dd7cda73cb691ddf600d06438d`

## Regression gate

`bash ArchiveProcessor/scripts/test-ocr-prompt.sh` compiles the real builder/parser with only a minimal
classification-enum host stub. It checks the rulings across 24 previous-text/image/custom-context variants,
the exact foreground paragraph, foreground labels, the absence of KIND, of a bullet rule and of a separate
other-sheet sentence, the response format, all 16 classification/rotation pairs, the enclosure marker and
verbatim text retention. **314/314 pass**. Against the baseline source **218/314, exit 1**; against
checkpoint 1's source **266/314, exit 1** (the bullet and other-sheet checks, in all 24 contexts). It runs
before paid calls in `ArchiveProcessor/test-smoke.sh`.
