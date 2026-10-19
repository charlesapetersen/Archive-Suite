# Public segmentation boxes — W43.seg-corpus-build

CIA input frozen on 2026-10-18; Lincoln inventory in progress. No model scores yet. These public boxes
are reported separately from the owner's locked boxes and are expected to be easier. Paid hosted runs
remain deferred to W43.sweep, under the owner's 2026-10-17 instruction.

The 2026-10-18 walkthrough approved `www.cia.gov` and checked Archive.org file-delivery subdomains.
The host-limited fetch helper now covers precisely that grant; nine refusal/redirect tests pass.
Original source files and page images stay outside git, under
`Long term storage/FarmShare-20261018/public-segmentation`. Only metadata, labels and scores are tracked.

## CIA CREST: 128 supplied pages, 31 audited documents

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

The archive's 22 PDF starts are retained. Nine internal starts were added under the owner-approved
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

## Lincoln Papers: 261 supplied pages, 81 audited documents

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

All six FarmShare runs completed with no missing, rejected, or failed windows: 44 per CREST run and 88 per
Lincoln run. Requests use the unchanged seven-page image+Apple Vision prompt, window combiner and document
scorer, with models predicting photo kinds themselves. No public truth selected a model or rule setting.
The fitted rule baseline is fixed from 551 owner-development pages; no public labels or OCR entered fitting.

| approach | CREST exact document pages (128) | Lincoln exact document pages (261) |
|---|---:|---:|
|Every page starts a document|9/128 (7.03%)|19/261 (7.28%)|
|Whole box is one document|0/128 (0.00%)|0/261 (0.00%)|
|Rule sketch + Apple Vision|9/128 (7.03%)|19/261 (7.28%)|
|Rules fitted on owner dev + Apple Vision|15/128 (11.72%)|44/261 (16.86%)|
|Qwen3.5 27B teacher, FarmShare|122/128 (95.31%)|103/261 (39.46%)|
|Trained Qwen3.5 2B, FarmShare|117/128 (91.41%)|91/261 (34.87%)|
|Trained Qwen3.5 4B, FarmShare|126/128 (98.44%)|122/261 (46.74%)|

CREST is easier for these models than the owner's locked boxes; **Lincoln is harder**, despite the requested
public/easier section label. Public provenance does not guarantee ease. Lincoln's long manuscripts and
separate enclosed items make whole-document accuracy demanding; one wrong split can spoil a long document.
The frozen primary truth is unchanged, including the explicitly ambiguous isolated wrappers 77/231. These
are agent-audited references, not a second owner adjudication. No claim of unseen/pretraining-clean data.
Per-model false splits/merges, boundary F1, and all additive counts are in the two `*-scores.json` files.

FarmShare job IDs: teacher 1857094, 2B 1857095, 4B 1857096. Raw answers, summaries, timing and original images
remain outside git. Only metadata/truth/numeric scores are published. Hosted reference routes remain in
W43.sweep's deferred-run register; no paid call or subscription-agent call was made. Source construction
and the available free CPU/FarmShare comparisons are finished; no more corpus work is needed for these boxes.
