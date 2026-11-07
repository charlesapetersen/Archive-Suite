# Public segmentation boxes — W43.seg-corpus-build

CIA input frozen on 2026-10-18, Lincoln since; both are scored below. These public boxes are reported
separately from the owner's locked boxes. They were expected to be easier; Lincoln turned out harder (below).
Hosted routes on them are in `seg-lincoln-cloud.md` and `seg-lincoln-gateway.md` (W46's paid arms were released
on 2026-10-21).

The 2026-10-18 walkthrough approved `www.cia.gov` and checked Archive.org file-delivery subdomains.
The host-limited fetch helper now covers precisely that grant; nine refusal/redirect tests pass.
Original source files and page images stay outside git, under
`Long term storage/FarmShare-20261018/public-segmentation`. Only metadata, labels and scores are tracked.

## CIA CREST: 128 supplied pages, 30 documents after the owner's rulings

The [Archive.org box-0017 inventory](https://archive.org/advancedsearch.php?q=identifier%3Acia-readingroom-document-cia-rdp96-00788r0017*&fl%5B%5D=identifier&fl%5B%5D=title&rows=5000&output=json)
returned all 282 records (SHA-256 `3243cf94977348f783f6bc4022105f1a1c21cf7d0a3393e21964ea10a68accb2`).
Folder **00170027** contains exactly documents **1–22**. All 22 original PDFs match their Archive.org MD5;
all PDF page counts match the complete Scandata records, totaling **128 pages**, about 8.83 MB of PDFs.
The plan's example folder 00170021 was rejected because it has sixteen missing document numbers.

A contiguous available prefix does not prove that no tail documents or unfilmed sides were withheld.
**Stream page 94 explicitly says the next two pages are exempt.** They are absent from the delivered PDF;
no images or labels were invented for them. This is a complete copy of the supplied digital folder,
with a known hole in the underlying physical record. This limitation matters to interpretation.

[crest.json](public-segmentation/crest.json) freezes source checksums, supplied page order, image SHA-256,
archive labels and an audit note on every page. Poppler rendered all pages at a 2,000-pixel ceiling, JPEG
quality 90. Every page was visually reviewed in sixteen contact sheets; handwritten decision pages 42,
46, 110 and 111 were also enlarged. No model output informed this truth.

The agent's audit retained the archive's 22 PDF starts and added nine internal starts (31 documents). The owner's
2026-10-31 rulings (W46.seg-truth-sheet, folded by W46.seg-truth-rescore; the manifest carries `owner_rulings` and
`unsure`) join PDF 19 to PDF 18 (gap 74|75, the same document), confirm the start at 95, and leave 45|46, 87|88,
93|94 and 110|111 unsure: those four gaps are out of every boundary count, and segment figures take each
route's own call there (W46.seg-unsure-mask). The internal starts were added under the owner-approved
[document rules](../../execution-plans/segmentation/02-truth-check.md):

| stream page | reason |
|---|---|
| 2 | complete enclosed briefing script after its covering memorandum |
| 13 | separately authored Monroe Systems RE/TBI Discovery Program handout |
| 35 | separately titled and bylined *Altered States of Consciousness* magazine article; not a whole magazine |
| 42 | handwritten SA legal/operations notes with their own topic heading |
| 48 | typed briefing-script fragment after handwritten meeting notes |
| 52 | separately titled Secretary of the Army briefing after its signed covering memorandum |
| 65, 108 | separately titled briefing questions/answers, each retained with its own following page |
| 110 | handwritten SA Brief notes with their own date and heading |

Unheaded approval jottings (46), the briefing's seal illustration (88), the exemption marker (94), and
undated cue/timing jottings (111) remain continuations. Separately preserved briefing copies each start
anew, under rule 4. Ambiguous rule interpretations are explicitly listed in the manifest; this is an
agent audit, not a second owner adjudication. CREST also includes third-party material: no blanket
US-government public-domain claim is made and no image redistribution is included.

## Lincoln Papers: 261 supplied pages, 80 documents after the owner's rulings

The [full Library of Congress catalogue](https://www.loc.gov/collections/abraham-lincoln-papers/?sb=shelf-id&c=150)
was sorted by Shelf Order. The saved first page contains 150 of 20,207 records. Catalogue positions **2–73**
are 72 consecutive manuscript items, with every one of their **261 canvases** included. Selection starts
after the first printed Stern envelope and stops near 250 pages at a whole-item boundary: the final
Lincoln-to-Corning manuscript has 22 canvases. The returned catalogue order is preserved even when numeric
identifiers decrease. This proves consecutive catalogue positions, **not** gap-free physical archival order.
The completed-transcription By the People export was not used to select or truncate the box.

All 72 official IIIF manifests are saved and checksummed. Each supplied canvas was downloaded through the
host-limited helper as a 2,000-pixel-ceiling IIIF rendering, then checked for decoding, aspect ratio and
SHA-256. These are all supplied canvases, rather than full-resolution masters. Temporary network failures
received bounded retries; no selected item or canvas was skipped.

[lincoln.json](public-segmentation/lincoln.json) freezes every source page, original item boundary and
page-by-page audit before model collection. The 72 catalogue starts are retained. Nine internal starts
make **81 documents**: an Evening Edition clipping (76), Martial and Civil Law order/article (102),
Missionaries resolutions (123), a separate editorial (124), a fresh Milroy-to-Usher letter (139), certified
Grand State Council resolution (223), Rights of the Press proceedings (230), and isolated wrappers (77/231).
The owner's 2026-10-31 rulings (W46.seg-truth-sheet, folded by W46.seg-truth-rescore; the manifest carries
`owner_rulings` and `unsure`) make 230 the same document as its Comstock letter, leaving **80 documents**, confirm
the clipping at 76, and leave 76|77, 106|107 and 230|231 unsure: out of every boundary count, segment figures conditional on each
route's call there.
The two wrappers follow an intervening enclosed publication rather than their covering letter: in a
contiguous stream they are retained as separate fragments. This is an explicitly ambiguous rule-6
interpretation, not a second owner adjudication. The manifest records the other retained continuations,
including envelopes adjacent to their letters, quoted communications beginning within a physical page,
and complete pamphlets under rule 10. All 261 images were visually reviewed in 66 contact sheets.

## Reproduce and score

`public_segmentation.py --root <local source cache> --box crest verify` checks every supplied source page,
image hash, audit and order against the committed freeze. `ocr` uses the existing Apple Vision helper;
`pack --key fs-seg-2b --out <new directory>` makes the unchanged segmentation requests for the cluster.
`institutional-compute/cluster_seg.py run/import` remains the collector; `score --key <key>` uses the
existing window combiner and document scorer. Public caches are separate from the owner's bench.
The free floors are always retained; no paid collector is provided. Integrity tests reject missing
middle/tail pages, duplicates, reordering, unaudited labels, changed images and paths outside the cache.

## Free comparisons completed 2026-10-19

All six FarmShare runs (eight with the combined 2B's two, below) completed with no missing, rejected, or failed windows: 44 per CREST run and 88 per
Lincoln run. Requests use the unchanged seven-page image+Apple Vision prompt, window combiner and document
scorer, with models predicting photo kinds themselves. No public truth selected a model or rule setting.
The fitted rule baseline is fixed from 551 owner-development pages; no public labels or OCR entered fitting.

| approach | CREST exact document pages (128) | Lincoln exact document pages (261) |
|---|---:|---:|
|Every page starts a document|13/128 (10.16%)|18/261 (6.90%)|
|Whole box is one document|0/128 (0.00%)|0/261 (0.00%)|
|Rule sketch + Apple Vision|13/128 (10.16%)|18/261 (6.90%)|
|Rules fitted on owner dev + Apple Vision|19/128 (14.84%)|44/261 (16.86%)|
|Qwen3.5 27B teacher, FarmShare|113/128 (88.28%)|106/261 (40.61%)|
|Trained Qwen3.5 2B, FarmShare|104/128 (81.25%)|93/261 (35.63%)|
|Trained Qwen3.5 4B, FarmShare|113/128 (88.28%)|130/261 (49.81%)|
|Combined segmentation + dating 2B, FarmShare|110/128 (85.94%)|87/261 (33.33%)|

Scored on the owner's rulings (rescored 2026-10-31, W46.seg-truth-rescore). CREST is easier for the teacher and the 4B than the owner's locked
boxes (88.3% each, against 81.5% and 80.0% on the pooled test boxes); for the 2B it is about level (81.2% against
80.3%), where before the rulings it was 91.4% against 78.8%. **Lincoln is harder**, despite the requested
public/easier section label. Public provenance does not guarantee ease. Lincoln's long manuscripts and
separate enclosed items make whole-document accuracy demanding; one wrong split can spoil a long document.
The agent-audited truth was frozen before any model ran; on 2026-10-31 the owner's rulings on a blind sheet of
its ambiguous gaps were folded in (W46.seg-truth-rescore; the manifests carry `owner_rulings` and `unsure`), and
every cached answer was rescored, no model rerun. The isolated wrappers 77/231 are now unsure gaps, out of every
boundary count (segment figures conditional). The other gaps remain agent-audited. No claim of unseen/pretraining-clean data.
Per-model false splits/merges, boundary F1, and all additive counts are in the two `*-scores.json` files,
rescored with the unsure mask on 2026-10-31 (W46.seg-report-refresh; each file records `unsure_gaps`).

**The combined segmentation + dating 2B** (W43.seg-date-public; the frozen `seg-date-2b` weights of `seg-date-model.md`, no retraining) ran the same windows as job 1857598 on 2026-10-19, with no failed window, and was scored from its cached answers on the current truth on 2026-11-06. It sits with the separate 2B, not above it: CREST 110/128 against 104/128 (boundary F1 0.949 against 0.931; 2 false splits and 1 merge against 2 and 2), Lincoln 87/261 against 93/261 (F1 0.761 against 0.772; 45 false splits and 2 merges against 44 and 1). Each gap is about one long document on 128 and 261 pages, a few points either way, inside the rerun floor below on Lincoln and near it on CREST. It stays behind the 4B on both boxes. This is a public generalization comparison only: it does not reopen the locked private test or the decision to keep separate segmentation and dating models (Mac public full date 135/150 against 137/150).

FarmShare job IDs: teacher 1857094, 2B 1857095, 4B 1857096, combined 2B 1857598. Raw answers, summaries, timing and original images
remain outside git. Only metadata/truth/numeric scores are published. Hosted reference routes were run later and are reported
in `seg-lincoln-cloud.md` and `seg-lincoln-gateway.md`; this report's own runs made no paid or subscription-agent call. Source construction
and the available free CPU/FarmShare comparisons are finished; no more corpus work is needed for these boxes.

## Measurement card

- **Truth.** Agent-audited truths, frozen before any model ran (contact-sheet review of every page; no model output informed them), with the owner's 2026-10-31 rulings on their ambiguous gaps folded in (W46.seg-truth-sheet, W46.seg-truth-rescore). CREST: 74|75 joined; unsure 45|46, 87|88, 93|94, 110|111. Lincoln: 229|230 joined; unsure 76|77, 106|107, 230|231. Their other gaps remain agent-audited, which is weaker than the owner-ruled boxes they are set against. Unsure gaps are out of every boundary count; segment figures (pages exact) take each route's own call there, the conditional reading (W46.seg-unsure-mask, `score.py`). Photo kinds come from each model, not from truth photos.
- **Selection.** CREST is folder 00170027, the one complete PDF folder (documents 1-22, checksum- and page-count-checked; 00170021 was rejected for missing numbers). Lincoln is catalogue positions 2-73 in shelf order, stopped near 250 pages at a whole-item boundary. Neither box was chosen by a model, by ABBYY text or by the By the People transcriptions. CREST has a known hole: the two exempt pages after stream page 94 are absent.
- **Comparison.** Every route got the same seven-page image and Apple Vision prompt, window combiner and document scorer, on FarmShare; the rule baseline was fitted on the 551 owner-development pages only. The comparison with the owner's locked boxes sets an agent-audited truth with model photo labels against owner truth with truth photos.
- **Noise.** 128 pages and 261 pages, one run per route, no intervals. Against the rerun floor of 1.4-3.2 points a box (SEG-10) the teacher and the 4B on CREST (88.3% each) are a tie; a byte-identical rerun moved Lincoln's 2B by 1.6 points (`seg-window-modality.md`). The combined 2B against the separate 2B (+4.7 points on CREST, -2.3 on Lincoln) is a tie on Lincoln and not a clear win on CREST.
- **Scope.** Two public boxes, not the owner's material. Nothing here makes a claim about unseen or pretraining-clean data, and a public box is not shown to be easier: Lincoln is harder.
