# Lincoln and CREST through the gateway (W46.seg-lincoln-cloud-paid)

Completed arms are scored below. A GLM full-box arm that failed validation twice is explicitly reported without a score; no missing vote is invented. Earlier failed attempts remain charged.

Gemini 3.7 Flash (not 3.8), GLM 5.3 Flash, low reasoning, temperature 0; 1600px images plus cached Vision text. Frozen g1 windows (7 pages, stride 3), wh1 whole streams. Windows use the model photo labels; whole streams take the known absence of label photos. Whole images are JPEG quality 45 to fit the gateway 32 MB body limit; windows retain the original benchmark thumbnails. No page is resized or dropped. No prompt fitted to these answers.

GLM uses the documented native minimum, `reasoning_effort=low`, with a final 32768-token cap (completed low/8192 and low/16384 replies are reused; all caps include reasoning). Reasoning-only failures at 8192 and 16384 remain charged and unscored. Earlier `minimal` probes (including a reasoning-only capped reply) are included in item cost, but none enters the low-setting predictions. Source: [Z.ai thinking parameters](https://docs.z.ai/guides/capabilities/thinking), checked 2026-10-24. Gemini whole JSON-mode caps are 64 tokens/gap, minimum 8192, based on the pilot's ~41/gap; the saved Lincoln pilot had a 32768 cap.

Claude c2 combines earlier plan windows with gateway holes, same Sonnet 5.5 and stated cues, but inline-image delivery replaces tool reads. It is a mixed-transport result.

Item cost estimate $2.8940, at list token prices; gateway billing is unavailable. Includes every attempted call and unsettled reservation. Rates: Gemini $0.75/$3.75, GLM $0.15/$0.50, Claude $2/$10 per million input/output tokens (reasoning included), OpenRouter model catalog checked 2026-10-24. No batch discount claimed.

The initial uncompressed Lincoln request was rejected before inference (HTTP 413, 32 MB body limit, zero token cost); its reservation was released with an append-only ledger correction. Both whole-stream calls use JPEG quality 45, so their comparison with windows also changes JPEG encoding and photo assumptions, and cannot isolate context length alone. Lincoln's saved whole reply required exactly two opening array brackets restored at gaps 82/83 and 122/123. This repair is restricted to its SHA-256, keeps all 260 stated decisions/confidences unchanged, and passes the complete strict gap validator; it was not a raw-valid JSON reply.

| box | route | whole | attempts | parsed replies | used replies | input tokens | output tokens | cost estimate | mean seconds |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| CREST | claude-cue | False | 9 | 9 | 9 | 217405 | 3615 | $0.4710 | 6.2 |
| CREST | gemini | False | 44 | 44 | 44 | 535872 | 17982 | $0.4693 | 6.7 |
| CREST | gemini | True | 1 | 1 | 1 | 202907 | 5519 | $0.1729 | 43.7 |
| CREST | glm | False | 45 | 44 | 44 | 978677 | 56674 | $0.2027 | 7.7 |
| Deaver | claude-cue | False | 2 | 2 | 2 | 44689 | 772 | $0.0971 | 9.1 |
| Lincoln | gemini | False | 90 | 88 | 88 | 923376 | 35781 | $0.8939 | 10.5 |
| Lincoln | gemini | True | 2 | 1 | 1 | 335266 | 10619 | $0.2913 | 45.9 |
| Lincoln | glm | False | 77 | 72 | 0 | 1508352 | 139268 | $0.2959 | 9.1 |

## Findings

On Lincoln, Gemini windows put 87.0% of pages in the exact document and the repaired whole reply 88.1%; GLM windows: failed validation (no score). The existing open models were at 34.9–46.7%, while Claude c1 and c2 were 90.0%. The large open-model drop is not a ceiling imposed by the material. Small differences among cloud results on one agent-audited box do not establish a general ranking.

On CREST, Gemini windows score 84.4% and the whole reply 95.3%; GLM windows: 95.3%. The existing trained 4B is 98.4%, teacher 95.3%, and Claude c1/c2 84.4%. The whole-stream arm scores higher here, but changed JPEG encoding and photo assumptions mean this run does not isolate context length.

The table below reports least-confidence-first checking against the truth. High boundary agreement or PQ does not mean those confidence values rank the few errors well; check the review load separately. The finding-aid count is a measured variant, not a setting selected on these public answers.

The final 11 Claude c2 gateway holes leave CREST at 84.4% and Deaver at 97.9%. The cue cuts CREST checking from 3.9 to 2.3 per 100 pages, but raises Deaver from 10.7 to 14.8, with unchanged error counts. See seg-lincoln-cloud.md for all owner boxes and the original plan comparisons.

Lincoln GLM FAILED: two stopped, billed replies for pages [163, 169] failed the unchanged strict gap validator: boundaries for [163, 164, 165, 166, 168], wanted [163, 164, 165, 166, 167, 168]. No full-box metric is reported. Further windows in that box were not requested because they cannot repair this failed window; no prompt or score rule was changed.

### Lincoln: 261 pages, 81 documents

| source | pages exact | false splits | false merges | boundaries found | PQ | kappa | MNDD | pages exact, finding-aid count | checks per 100 pages to 98% |
|---|---|---|---|---|---|---|---|---|---|
| Gemini 3.7 Flash, g1 windows, gateway | 87.0% | 5 | 0 | 80/80 | 0.952 | 0.956 | 5 | 80.8% | 57.1 |
| Gemini 3.7 Flash, wh1 whole stream, gateway | 88.1% | 3 | 1 | 79/80 | 0.956 | 0.964 | 4 | 82.4% | 92.0 |
| Claude Sonnet 5.5, c2 (stated letter cues), plan + gateway holes | 90.0% | 2 | 0 | 80/80 | 0.984 | 0.982 | 2 | 79.7% | 7.3 |
| GLM 5.3 Flash, g1 windows, gateway | failed validation; no score | | | | | | | | |

### CREST: 128 pages, 31 documents

| source | pages exact | false splits | false merges | boundaries found | PQ | kappa | MNDD | pages exact, finding-aid count | checks per 100 pages to 98% |
|---|---|---|---|---|---|---|---|---|---|
| Gemini 3.7 Flash, g1 windows, gateway | 84.4% | 3 | 0 | 30/30 | 0.913 | 0.937 | 3 | 55.5% | 15.6 |
| GLM 5.3 Flash, g1 windows, gateway | 95.3% | 2 | 0 | 30/30 | 0.930 | 0.957 | 2 | 55.5% | 0.8 |
| Gemini 3.7 Flash, wh1 whole stream, gateway | 95.3% | 2 | 0 | 30/30 | 0.930 | 0.957 | 2 | 62.5% | 3.9 |
| Claude Sonnet 5.5, c2 (stated letter cues), plan + gateway holes | 84.4% | 3 | 0 | 30/30 | 0.913 | 0.937 | 3 | 45.3% | 2.3 |

