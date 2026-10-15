# W41.ocr-prompt-app — the app's transcription instruction

2026-10-14. Baseline `7f3e66a7`. Only `OCRPrompt.build` TASK 3 changes: the owner's four panel
rulings, plus explicit retention of foreground box/folder-label transcription. Its original opening
sentence stays. TASK 1, TASK 2, FORMAT, context handling and every response-parser byte stay unchanged.
KIND is not added. Apple Vision and Mistral's dedicated OCR endpoint take no such prompt.

## Live comparison

Four copied W41 truth-set pages, using production `ImageEncoding.loadImageAsJPEG` (2048 px maximum,
EXIF orientation applied), the rendered app prompt, and the default `gemini-3.1-flash-lite` through the
direct Gemini `generateContent` endpoint. No previous-page context or custom instruction. The test
sets temperature 0 and a 4096-token output ceiling; all replies finish STOP with no thinking tokens.
Raw replies are read by the production `OCRPrompt.parseResponse`, compiled into a command-line host.
There is no app window or corpus write. These are transcription fixtures, not segmentation truth.

| Page | Before | Final instruction | Parsed header before → after |
|---|---|---|---|
| p010, ProQuest clipping | Citation/header and copyright footer included | Both included; transcription identical | document_start / rotate_0 → same |
| p081, ProQuest clipping | Citation/header and copyright footer included | Both included | document_start / rotate_0 → same |
| p062, bulleted page | Five `•` bullets | Five `*` bullets; heading and footer page number retained | document_continuation / rotate_0 → document_start / rotate_0 |
| p048, handwritten letter on printed letterhead | Letterhead and handwriting included; neighboring sheet excluded | Same scope | document_start / rotate_0 → same |

**Limits:** the run demonstrates bullet normalization and retained headers/footers, not an improvement
in header/footer recall: this default model already kept them with the old prompt. Three classifications
and all four rotations match; p062's classification changes despite unchanged classification instructions.
Thus the wire format and parser are preserved, but this run does **not** establish invariant model
classification values. No classification rule was tuned to force the older answer. The model also
continues to guess at words the owner marked `[illegible]`; an explicit instruction cannot guarantee
compliance. The regression checks the instruction and lossless parsing of that marker, not OCR certainty.

Before calling: estimated $0.03, cap $0.10. Eight initial calls used a narrower TASK 3 opening; review
restored the original sentence to retain its broad applicability, then four final-instruction calls
were made against the cached baseline. Both versions normalized all five bullets, kept headers/footers
and the foreground scope, and gave p062 document_start. Twelve calls in total: 24,889 input tokens,
7,344 output tokens, no thinking tokens, **$0.01723825** at the app's listed $0.25/$1.50 per million
input/output tokens. This is a token-derived cost, not a provider billing export. A TLS-handshake
failure sent no request; the installed CA bundle fixed verification without disabling it.

The private images and full texts are outside git at `/tmp/w41-ocr-prompt-app/`, including the first
pass in `pilot/`, `*-response.json`, production-parser `*-response.parsed.json`, `*-usage.json`,
the scratch drivers and the exact rendered prompts. Prompt SHA-256:

- Before: `91ca60115066f073ce41c1db1ec0f316ce83534bef5e567499622b9dc0523999`
- Final: `4777ab4265b00122ebc09a4905e78ea6714e7db973e1bee495326fe7335b73a8`

## Regression gate and acceptance

`bash ArchiveProcessor/scripts/test-ocr-prompt.sh` compiles the real builder/parser with only a minimal
classification-enum host stub. It checks all owner rulings across 24 previous-text/image/custom-context
variants, foreground labels, absence of KIND, response format, all 16 classification/rotation pairs,
the enclosure marker and verbatim text retention. **290/290 pass**. Compiling the same check against
the baseline source yields **170/290, exit 1**: each missing ruling and the explicit label instruction
fails in all 24 contexts. It runs before paid calls in `ArchiveProcessor/test-smoke.sh`.

**The item remains open on `W41.ocr-prompt-app-owner-ok`:** accepting the p062 classification drift
is an owner decision because the literal DONE criterion asks for unchanged tags. This checkpoint
does not claim that criterion passed.

Independent adversarial review caught the initial sheet-only ambiguity; the final wording preserves
foreground labels and the original opening. Validation passes: Processor Debug build (no compiler
warnings), 290/290 prompt checks, and the existing dual-date/enclosure regression. The first two
builds emitted the existing AppIntents metadata warning; the final build emitted no warnings.
The final scratch Process-Files smoke exits unaided with 2 succeeded / 0 failed and two PDFs after
unblocking inherited TERM before launching the harness. Its prior attempt hit one provider 502; the
script still reported PASS on the placeholder. Both that oracle defect and the inherited-TERM
cleanup hang are separately tracked as W41.ocr-smoke-term. The first two smoke children were
stopped only after verifying their success markers, PDFs, executable and direct parent.
