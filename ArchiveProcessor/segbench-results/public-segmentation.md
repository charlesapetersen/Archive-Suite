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

## Lincoln Papers: full catalogue and complete manifests

The browser successfully reached the full catalogue after its automatic verification, sorted it by
Shelf Order, and saved the first **150 of 20,207** records. Starting at catalogue position 2 (the first
manuscript after a printed envelope), complete consecutive item manifests are being exported. The catalogue
order is preserved exactly even where numeric item identifiers are not increasing. The run will stop at
an item boundary near 250 supplied canvases, before any model call or page-label audit based on output.

The earlier By the People CSV contains only completed transcriptions (28,816 Lincoln assets in 10,061
items), so it cannot establish complete item or page order. It is not used to select or truncate this box.
Manifest export is still underway; this box is not frozen and has no scores. Browser connection failures
are retried in bounded attempts; no catalogue item is skipped after a failed manifest request.

## Reproduce and score

`public_segmentation.py --root <local source cache> --box crest verify` checks every supplied source page,
image hash, audit and order against the committed freeze. `ocr` uses the existing Apple Vision helper;
`pack --key fs-seg-2b --out <new directory>` makes the unchanged segmentation requests for the cluster.
`institutional-compute/cluster_seg.py run/import` remains the collector; `score --key <key>` uses the
existing window combiner and document scorer. Public caches are separate from the owner's bench.
The free floors are always retained; no paid collector is provided. Integrity tests reject missing
middle/tail pages, duplicates, reordering, unaudited labels, changed images and paths outside the cache.
