# Lincoln and CREST through the gateway (W46.seg-lincoln-cloud-paid)

PARTIAL CHECKPOINT: Claude cue arm only; Gemini/GLM collection continues.

Gemini 3.7 Flash (not 3.8), GLM 5.3 Flash, low/minimal reasoning, temperature 0; 1600px images plus cached Vision text. Frozen g1 windows (7 pages, stride 3), wh1 whole streams. Windows use the model photo labels; whole streams take the known absence of label photos. Whole images are JPEG quality 45 to fit the gateway 32 MB body limit; windows retain the original benchmark thumbnails. No page is resized or dropped. No prompt fitted to these answers.

Claude c2 combines earlier plan windows with gateway holes, same Sonnet 5.5 and stated cues, but inline-image delivery replaces tool reads. It is a mixed-transport result.

Item cost estimate $1.2837, at list token prices; gateway billing is unavailable. Includes every attempted call and unsettled reservation. Rates: Gemini $0.75/$3.75, GLM $0.15/$0.50, Claude $2/$10 per million input/output tokens (reasoning included), OpenRouter model catalog checked 2026-10-24. No batch discount claimed.

The initial uncompressed Lincoln request was rejected before inference (HTTP 413, 32 MB body limit, zero token cost); its reservation was released with an append-only ledger correction. Both whole-stream calls use JPEG quality 45, so their comparison with windows also changes JPEG encoding and cannot isolate context length alone.

| box | route | whole | attempts | valid | input tokens | output tokens | cost estimate | mean seconds |
|---|---|---|---:|---:|---:|---:|---:|---:|
| CREST | claude-cue | False | 9 | 9 | 217405 | 3615 | $0.4710 | 6.2 |
| Deaver | claude-cue | False | 2 | 2 | 44689 | 772 | $0.0971 | 9.1 |

### Lincoln: 261 pages, 81 documents

| source | pages exact | false splits | false merges | boundaries found | PQ | kappa | MNDD | pages exact, finding-aid count | checks per 100 pages to 98% |
|---|---|---|---|---|---|---|---|---|---|
| Claude Sonnet 5.5, c2 (stated letter cues), plan + gateway holes | 90.0% | 2 | 0 | 80/80 | 0.984 | 0.982 | 2 | 79.7% | 7.3 |

### CREST: 128 pages, 31 documents

| source | pages exact | false splits | false merges | boundaries found | PQ | kappa | MNDD | pages exact, finding-aid count | checks per 100 pages to 98% |
|---|---|---|---|---|---|---|---|---|---|
| Claude Sonnet 5.5, c2 (stated letter cues), plan + gateway holes | 84.4% | 3 | 0 | 30/30 | 0.913 | 0.937 | 3 | 45.3% | 2.3 |

