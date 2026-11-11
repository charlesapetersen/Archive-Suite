# 05. Text placement on the page image

## 1. Stage and question

The stage writes the searchable PDF's invisible text layer: the reading of stage 04 fitted onto line geometry on the
page image, or, where it cannot be placed, a separate text page. The user chooses nothing per route on print; on
handwriting the owner's switch decides between the placed layer (with a per-page fallback) and a text page throughout.

## 2. Is there a choice?

No route choice for the user. The routes below are rules the solver applies by kind; the one switch is
`place.hand_on_image`, label "Place handwritten text on the page image (pages the aligner is unsure of get a text
page)", default on. The owner's 2026-10-20 decision prefers text placed on the image unless a text page is necessary
(`00-plan.md`), and the measured hand route passes 42.9% of owner hand lines where a text page passes none on the image
[M] (`place-hands-lines.md`, non-drafter Qwen3.6-27B reading). Off gives every handwritten page a text page only.

## 3. The rule for the settings layer

Sheet text, replacing `settings-design/figures.json` "fixed.placement" (which says Vision's own layer for print, and
calls 6 s a page the hand route's time, which is blla's detection alone [M] `place-hands.md`):

> Print: Apple Vision's line geometry, with the chosen reader's words aligned onto it, written one run per line; free.
> Handwriting: kraken blla lines with the reading force-aligned to them by a CTC recogniser; a page whose alignment
> confidence is under 0.67, or whose reader merges a page's lines into paragraphs, gets a text page instead. The layer
> sits on the reading copy the user chose (deskewed or as photographed).

- Metric: strict line pass rate, the share of truth lines whose PDFKit drag from first ink to last returns exactly the
  line's words, in order, with no break (F-placement §6.2, owner 2026-10-29). Higher is better. Find and Find-placed
  are reported beside it and never rank. Tie: a paired page-bootstrap 95% interval (2,000 draws) that holds 0
  (`place-print.md` card); on 20 owner hand pages differences under about 2 points are ties, on 14 Bentham pages about
  10 (`place-hands-lines.md` card).
- Print kinds (typewritten, printed, clippings, forms): `vision-lines-aligned`. The aligner keeps Vision's words on a
  page where under half of them anchor (F-placement §6.4) [M]. Fallback: `vision-own`.
- Handwritten and mixed pages, switch on: `hand-blla-ctc`, the `conf` matcher pick (the higher mean CTC confidence of
  `s1` and `s8` per page), the 0.67 gate. Fallback per page: `text-page`, named in the run report. A reader flagged
  `reflows` in stage 04's table (measured: LightOnOCR-3 4B) goes to `text-page` on every hand page, since the gate does
  not rescue it (21.5% line pass, 8 of 20 pages gated) [M] `place-hands-lines.md`, `place-hands.md`.
- Writer: the lab's SearchableWriter (one level run per line, font fitted, 0.25 em reserve) on every kind. One sloped
  run per line loses (−7.4, −10.7 to −4.2) [M] `place-geom.md`; per-word runs lose on owner hands (lab +8.4, +1.2 to
  +15.1) [M] `place-hands-lines.md`.
- Reading copy: the layer is placed on the image stage 01 produces. Deskew after OCR is stage 01's rule (median line
  angle 1° or more; `place-geom.md`, `place-geom-real5.md`); the layer is carried through the rotation.
- Must not run (text page only): scripts the writer has no path for (Hebrew, Arabic: no RTL path) or Vision gives no
  word boxes for (CJK, Thai) [M] F-placement §6.6-6.7; model-normalised readings (modernised spelling, expanded
  abbreviations) [I] F-placement §6.7.2; mark transcripts, until stage 06 rules (P11-1).
- Output: PDF/A-2b once the writer declares it (XMP `pdfaid`, sRGB output intent): 50 of 50 PDFs pass veraPDF 1.30;
  PDF/A-2u needs complete ToUnicode maps (19 of 20 lab PDFs pass, all after the maps) [M] `place-print.md`.

## 4. Table rows

The stage object (its `routes` are the six rows in the second block). `hand-ppocrv6-ctc` carries a `delta` field the
schema in `00-index.md` does not have: the file gives only the difference against the shipped placer on owner pages,
not a level, so the field is kept and the schema needs it or the level.

```
{"id":"placement","name":"Text placement on the page image","unit":"pages","choice":false,
 "metric":{"id":"line_pass_strict","label":"strict line pass rate, PDFKit drag","higher_is_better":true},
 "kinds":["typewritten","printed","handwritten"],
 "rules":[{"id":"place-print-aligned","text":"Print: Vision's line geometry with the reader's words aligned onto it, one run per line.","source":"place-print.md §Verdict","switch":null},
  {"id":"place-hands","text":"Handwriting: kraken blla lines, CTC forced alignment, conf pick; a page under 0.67 confidence, or read by a reflowing reader, gets a text page.","source":"place-hands-lines.md §Verdict","switch":{"id":"place.hand_on_image","label":"Place handwritten text on the page image (pages the aligner is unsure of get a text page)","default":true}},
  {"id":"place-text-only-scripts","text":"Text page only for RTL scripts, CJK and Thai, model-normalised readings and mark transcripts.","source":"F-placement.md §6","switch":null}],
 "fallback":"text-page"}
```

```
{"id":"vision-lines-aligned","name":"Apple Vision lines, reader's words aligned (lab writer)","family":"mac","app_route":null,"status":"measured",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"all-typed":{"value":54.4,"n":40,"truth":"place-truth folded, 1770 lines","source":{"file":"place-print.md","route":"LightOnOCR-3 4B aligned","attribute":"strict pass %, all pages","value":"54.4"}},
  "typewritten":{"value":63.7,"n":26,"truth":"place-truth folded","source":{"file":"place-print.md","route":"LightOnOCR-3 4B aligned","attribute":"strict pass %","value":"63.7"}},
  "printed":{"value":46.7,"n":14,"truth":"place-truth folded","source":{"file":"place-print.md","route":"LightOnOCR-3 4B aligned","attribute":"strict pass %","value":"46.7"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":null,"price_read":null,"source":{"file":"place-print.md","attribute":"no model call"}},
 "time":{"per_unit_s":null,"measured":false,"measured_on":"aligner and writer not timed"},"memory":{"peak_gb":null,"measured_on":"not measured"},
 "caveats":["selection ties Vision's own layer (+0.1, -0.4 to +0.7); Find placed +0.8 (-0.3 to +2.2), resolved only on typewritten (+1.6, +0.5 to +3.3)",
  "drafter reading Gemini 3.8 Flash is -0.6 (-1.0 to -0.2), a small resolved loss, labelled drafter","51% of typed truth lines Vision-derived (OCR-10)"],
 "kind_rules":["handwritten: hand-blla-ctc"],"fallback":"vision-own","conditions":[]}
{"id":"vision-own","name":"Apple Vision's own words and lines (today's layer)","family":"mac","app_route":null,"status":"shipped",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"all-typed":{"value":54.2,"n":40,"truth":"place-truth folded, 1770 lines","source":{"file":"place-print.md","route":"Vision's own lines","attribute":"strict pass %","value":"54.2"}},
  "typewritten":{"value":63.9,"n":26,"truth":"place-truth folded","source":{"file":"place-print.md","route":"Vision's own lines","attribute":"strict pass %","value":"63.9"}},
  "printed":{"value":46.4,"n":14,"truth":"place-truth folded","source":{"file":"place-print.md","route":"Vision's own lines","attribute":"strict pass %","value":"46.4"}},
  "handwritten":{"value":61.1,"n":18,"truth":"226 lines Vision read whole","source":{"file":"place-geom.md","route":"raw, lab writer","attribute":"hand line pass %","value":"61.1"}}},
 "cost":{"usd_1000_list":0},"time":{"per_unit_s":null,"measured":false},"memory":{"peak_gb":null},
 "caveats":["handwritten figure counts only lines whose every word Vision read; Find locates 585 of 1,405 distinct truth words in Vision's own hand layer and 922 in the aligned layer (F-placement §3, HW-PLACE row)",
  "RecognizeDocumentsRequest lines lose -10.8 (-15.3 to -6.5) and are not offered (place-print.md)"],
 "kind_rules":["handwritten: not chosen"],"fallback":"text-page","conditions":[]}
{"id":"hand-blla-ctc","name":"kraken blla lines, McCATMuS forced alignment, conf pick, 0.67 gate","family":"mac","app_route":null,"status":"shipped",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":null,"gpus":0},
 "figures":{"handwritten":{"value":42.9,"n":20,"truth":"owner-hand, 475 lines","source":{"file":"place-hands-lines.md","route":"blla.ctc-mccatmus-conf, Qwen3.6-27B","attribute":"line pass %, lab writer","value":"42.9 (204/475)"}},
  "handwritten-kept":{"value":46.3,"n":18,"truth":"owner-hand, 432 lines on kept pages","source":{"file":"place-hands-lines.md","route":"blla.ctc-mccatmus-conf, Qwen3.6-27B","attribute":"pass % on kept pages at 0.670","value":"46.3 (200/432)"}},
  "bentham":{"value":35.7,"n":14,"truth":"L2 PAGE-XML, 314 lines","source":{"file":"place-hands-lines.md","route":"Qwen3.6-27B","attribute":"line pass %","value":"35.7 (112/314)"}}},
 "cost":{"usd_1000_list":0},"time":{"per_unit_s":6.1,"measured":true,"measured_on":"blla detection only, CPU one core, M3 Pro 18 GB; alignment not timed","source":{"file":"place-hands.md","attribute":"s a page","value":"6.1"}},
 "memory":{"peak_gb":null,"measured_on":"not measured; the route ran on an M3 Pro 18 GB (place-hands.md)"},
 "caveats":["gate chosen on per-word Find (OCR-11); rescored on line pass, it only lowers it: -0.8 (-2.8 to 0.0) with Qwen, 39 failing drags spared",
  "a reflowing reader stays on the text page (LightOnOCR-3 21.5%)","on Bentham PP-OCRv6 lines pass +17.5 (+6.6 to +27.8) more: the detector is collection-dependent",
  "gate fitted on 20 pages; refit when more hand truth is drawn"],
 "kind_rules":["print: not used"],"fallback":"text-page","conditions":["reading keeps the page's line breaks"]}
{"id":"hand-ppocrv6-ctc","name":"PP-OCRv6 det lines, CTC forced alignment","family":"cluster","app_route":null,"status":"measured",
 "needs":{"key":[],"plan":[],"cluster":true,"mac_gb":null,"gpus":0},
 "figures":{"bentham":{"value":53.2,"n":14,"truth":"L2 PAGE-XML, 314 lines","source":{"file":"place-hands-lines.md","route":"ppocrv6.ctc-mccatmus-conf, Qwen3.6-27B","attribute":"line pass %","value":"53.2 (167/314)"}},
  "handwritten":{"value":null,"delta":-17.9,"n":20,"truth":"owner-hand, 475 lines","source":{"file":"place-hands-lines.md","route":"PP-OCRv6 lines","attribute":"Verdict, PP-OCRv6 lines vs shipped, owner pages","value":"-17.9"}}},
 "memory":{"peak_gb":32,"measured_on":"CPU, one Bentham page, max side 4000; paddlex has no MPS","source":{"file":"place-hands.md","attribute":"peaked at 32 GB","value":"32"}},
 "time":{"per_unit_s":null,"measured":false,"measured_on":"saved FarmShare polygons"},
 "caveats":["not a Mac route at its pinned settings"],"kind_rules":[],"fallback":"hand-blla-ctc","conditions":["offered as the hand detector setting on a cluster, not the default"]}
{"id":"hand-orli-ctc","name":"Orli base lines, CTC forced alignment","family":"mac","app_route":null,"status":"measured",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":null,"gpus":0},
 "figures":{"handwritten":{"value":38.3,"n":20,"truth":"owner-hand, 475 lines","source":{"file":"place-hands-lines.md","route":"orli.ctc-mccatmus-cer, Qwen3.6-27B","attribute":"line pass %","value":"38.3 (182/475), -4.6 (-14.9 to +4.2)"}}},
 "time":{"per_unit_s":6.2,"measured":true,"measured_on":"MPS bf16, owner-hand","source":{"file":"place-hands.md","attribute":"s a page","value":"6.2"}},
 "memory":{"peak_gb":null,"measured_on":"a run that reloaded its 594 MB weights per call grew to 12 GB and swapped an 18 GB Mac (place-hands.md)"},
 "caveats":["a tie with the shipped placer, not better"],"kind_rules":[],"fallback":"hand-blla-ctc","conditions":["not offered; kept as a measured alternative"]}
{"id":"text-page","name":"Separate text page after the image page","family":"mac","app_route":null,"status":"shipped",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"handwritten":{"value":0,"n":20,"truth":"owner-hand, 475 lines","source":{"file":"place-hands-lines.md","route":"text page","attribute":"gated pages' lines not selectable on the image","value":"counted as not passing"}}},
 "caveats":["places nothing; recovers Find on hand pages, 1,238 of 1,405 against 922 for the aligned layer and 585 for Vision's own (F-placement §3, HW-BUILD and HW-PLACE rows)"],
 "kind_rules":["every kind: per-page fallback"],"fallback":null,"conditions":[]}
```

Block-emitting readers (Unlimited-OCR, Nemotron-Parse 2.0) hold 9.4-13.5% of truth lines whole and alone, so they are no
line layer [M] `place-print.md`; no row. R6 services (Azure, Textract, Document AI, Transkribus): none measured
(F-placement §9). R3, R4, R5 readers return text only and use the two aligned rows.

## 5. Caveats carried

- OCR-10 (truth lines Vision's): test 2 and 3 are split by line source; the open-model cross-check and owner sheet were
  done (R-9 holds: 97 places on 17 of 40 pages; a line both detectors group the same wrong way is not found; blla left
  1,484 scored words outside every line) [M] `place-truth-lines.md`, pass 1. The aligned rows share Vision's lines, so
  the favour cancels between them (pass 6 summary).
- OCR-11 (gate chosen on Find): rescored on line pass with a non-drafter reading (`place-hands-lines.md`); the shipped
  placer stays first or tied first; the 0.67 gate is a product call (pass 4 summary). Carried in the row's caveats.
- P6-1, P7-7, P9-6 (test 7 partly made by the fold): test 7 is now reported unfolded and untouched. PP-OCRv6 det leads
  Vision +20.9 (+12.6 to +30.0) unfolded and +21.8 (+13.2 to +31.2) untouched among all; blla's lead is a tie on every
  truth (+10.4, −2.6 to +22.1 unfolded); the fold made about 1 point (1.31, pass 7) [M] `place-print.md`. No row
  ranks on test 7; it supports the item in §8. The "net effect toward Vision" sentence is gone (P9-6).
- P10-5 (Real5 wording): level pages are −0.1 (−1.5 to +1.2), UVDoc's 443 lost words lie on 84 images, page-clustered
  intervals are not wider, and the truth leans toward the raw arm, so transforms' gains are conservative [M]
  `place-geom-real5.md`.
- Pass 8 (P8-5 note): the owner pair blla against Vision in `ocr-ppocrv6-hands.md` is +7.9 (−0.5 to +17.2, p 0.11) on
  the 27.2 Vision text, a tie, not the +9.9 lead. That pair scores reading, not placement; the hand route rests on the
  line pass and Find, not on it [I]. P8-1(h): placement's Vision readings are on 27.2, the typed truth boxes come from
  `vision-words.json` of 2026-10-14 on 26.6; a caveat on the Vision rows, no figure moves [I].
- P4-3: `place-geom.md`'s Find reads as a range, 86.1-87.0%, no Find effect asserted.
- P11-1: whole-page mark readings carry no coordinates, so a mark cannot be placed without a box; marks stay off the
  layer until stage 06 settles (W46.marks-two-pass).

## 6. What would change the rule

- A hand detector or placer beating `hand-blla-ctc` by more than the tie on owner hands with a non-drafter reading.
- PP-OCRv6 det (or another detector) running on a Mac at 16 GB with Bentham's +17.5 kept: offered as a Mac setting.
- PP-OCRv6 det lines passing more print lines than Vision's under the lab writer (test 7's grouping lead says they may).
- A stage 04 reader shown to keep line breaks on hands: it joins the hand route instead of the text page.
- More hand truth: the gate refit (`place-hands.md` calls 0.67 a starting value).
- A dewarp whose lattice keeps every word and beats deskew on the owner's curled pages (it lost, −8.6, `place-geom.md`).
  On the owner's 32 most curved pages the layer itself loses −19.8 (−26.2 to −12.8) against flat pages, and blla's
  own lines as level runs lose as much, so it is the level run on a bent line [M] `place-curved-owner.md`.
- An RTL path in the writer, or word boxes for CJK and Thai.

## 7. Owner calls

Decided on 2026-11-06 (section "Owner's calls (2026-11-06)" below); kept as the evidence shown.

1. **Handwriting: aligned lines or a text page (the switch default and the gate).** Shown settled in direction: the
   placed layer passes 42.9% of owner hand lines, the text page none on the image, and the owner prefers placement;
   default on. Open: where the gate sits. Options: (a) keep 0.67: Qwen 2 of 20 pages to the text page, −0.8 points
   overall, kept pages 46.3%; (b) about 0.75: kept pages 52% at a cost of 19 passing lines; (c) no gate: 42.9%, 39 more
   failing drags. With the truth text 0.67 sends 4 pages (20 passing lines given up, 78 failing spared) [M]
   `place-hands-lines.md`. Recommendation: (a), as filed; moving it trades passing lines for a cleaner layer.
2. **The layer on warped photographs (a dewarped reading copy).** On Real5, UVDoc selects +7.9 (+3.1 to +12.9) over
   deskew and +17.0 (+11.8 to +22.0) on the 185 images it cuts nothing from, but cuts 900 of 15,067 lines and 443 words
   on 84 images [M] `place-geom-real5.md`; on the owner's 58 pages it loses −8.6 (−12.4 to −5.0) and cuts 289 own-sheet
   words on 38 pages [M] `place-geom.md`. Options: never offer; offer only where the lattice keeps every word, for
   warped material. Recommendation: not offered now (the reading-copy rule forbids removal and the owner's material
   loses); stage 01 carries the switch if the owner says otherwise.
3. **The hand line detector as a visible setting.** `place-hands-lines.md` asks that the detector stay a setting of the
   hand route. Options: hidden (blla always); shown on the cluster profile only (PP-OCRv6 det for Bentham-like hands).
   Recommendation: cluster only, since PP-OCRv6 det peaked at 32 GB on CPU for one Bentham page at the pinned max
   side 4000 (`place-hands.md`); a smaller side is unmeasured (W46.place-print-pp-lines).

## 8. Items to file

- **W46.place-hands-cost** (small, $0, waits on nothing): peak memory and seconds a page of the whole hand route (blla,
  McCATMuS alignment of both matchers, the pick, the writer) on the 20 owner hand pages, on 16 GB and 18 GB Macs. Done:
  `memory.peak_gb`, `needs.mac_gb` and `time` filled for `hand-blla-ctc`. Today only blla's 6.1 s a page is measured,
  and the route is known to run on an 18 GB M3 Pro; whether it fits 16 GB is unmeasured [?].
- **W46.place-print-pp-lines** (medium, $0): the lab writer over PP-OCRv6 det lines on the 40 typed pages, line pass
  folded and unfolded, and the largest image side at which PP-OCRv6 det fits a 16 GB Mac. Done: a row beside
  `vision-lines-aligned`.
- **W46.reader-keeps-lines** (small, $0, saved readings): for every stage 04 reader of hands, the reading's line count
  against blla's detected lines on the 20 owner hand pages. Done: a `reflows` flag per reader row.
- **W46.place-pdfa** (small, $0): the writer declares PDF/A-2b and writes complete ToUnicode maps; veraPDF passes.
- **W46.place-header-carrier** (small, spec): the Processor's page-2 metadata header needs a carrier (XMP or Info) before
  a layer-only output; until then the text page stays as the header's home (F-placement §6.7.4).
- Gaps (`12-settings-design.md` §3.9): `cost` on `hand-ppocrv6-ctc`, `hand-orli-ctc` and `text-page`, and `time` and
  `memory` on `text-page` (no file states them; all three run no model call [I]); `source` on most `time` and `memory`
  objects; a level for `hand-ppocrv6-ctc` on owner hands (only the −17.9 difference exists); aligner and writer seconds a page on print; R6 services' geometry on our pages;
  RTL and CJK placement; plan readings (R5) on hands, whether they keep lines.

## 9. Profile test expectations

| profile | typewritten / printed | handwritten (switch on) |
|---|---|---|
| laptop 16 GB | `vision-lines-aligned` with the 04 reader (54.4 all typed); `vision-own` if none | `hand-blla-ctc` if W46.place-hands-cost fits 16 GB, else `text-page`; a reflowing reader: `text-page` |
| laptop 32 / 64 GB | `vision-lines-aligned` | `hand-blla-ctc` (42.9), fallback `text-page` per page under 0.67 |
| cheap API | `vision-lines-aligned` (Qwen3.6-27B ties Vision, +0.1) | `hand-blla-ctc` with a line-keeping reading (Qwen3.6-27B 42.9) |
| premium API or plan | `vision-lines-aligned` (Gemini row labelled drafter) | `hand-blla-ctc` (Gemini 3.8 Flash 41.3, drafter); plan readers unmeasured, gate decides |
| cluster | `vision-lines-aligned` | `hand-blla-ctc` default; `hand-ppocrv6-ctc` when the user sets the detector (Bentham 53.2) |
| plus coding agent | as the base profile | as the base profile; no placement training measured |

Switch off, every profile: `text-page` on handwritten pages. A page in an RTL or CJK script: `text-page`.

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §1 call 6 and §2 "Placement". Section 3's rule and the stage object carry them.
- Aligned lines on handwriting, switch `place.hand_on_image` default on (call 1).
- The gate stays at 0.67, as filed (call 1, option a).
- The hand line detector is a visible setting on the cluster profile only (call 3); its peak memory and alignment
  time are measured by W46.place-hands-cost before any 16 GB claim is made.
- No dewarped reading copy (call 2): dewarping is not offered, so the layer always sits on the deskewed or
  as-photographed copy; a guarded dewarp is filed to revisit in 01-reading-copy.md.

Files read: execution-plans/processing-review/00-plan.md (lines 1-105); .worktrees/.../13-stage-rules/00-index.md; 14-owner-calls.md;
F-placement.md §5, §6, §7, §9; segbench-results/place-print.md, place-hands.md, place-hands-lines.md, place-geom.md,
place-geom-real5.md, place-truth.md, place-truth-lines.md; place-hands.json (seconds_per_page only);
11-measurement-audit.md OCR-10, OCR-11; measure-reviews 2026-10-31 (R-9), 2026-11-01 (pass 4 summary, P4-3),
2026-11-03 (pass 6 summary, P6-1), 2026-11-04 (P7-7, pass 7 corrections), 2026-11-04-2 (P8-1, P8-5), 2026-11-05 (P9-6,
P9-12), 2026-11-05-2 (P10-5), 2026-11-05-3 (P11-1); settings-design/figures.json "fixed".
