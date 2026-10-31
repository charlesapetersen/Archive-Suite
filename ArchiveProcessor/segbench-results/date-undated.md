# Dating undated documents: the app's false years and Date Uncertain (W46.date-undated)

Written by `scripts/segbench/date_undated.py score`. Measurement audit DAT-6 and DAT-7 (`execution-plans/processing-review/11-measurement-audit.md`). The app's tagging call (`TagGenerator.generateTags`, the prompt verbatim) always gives a year; W41.date-tag-measure scored it only where the owner had dated the document. Here it reads documents the owner left with no date tag, and W46.date-image's unprinted-year documents, on Apple Vision's reading of the JPEG originals (no ABBYY text), with the app's context of three neighbouring segments, through the Stanford gateway (Gemini 3.7 Flash; the app's default is 3.8, which the gateway does not serve), with no temperature or reasoning setting, as the app sends it.

**A date on the document's own pages** is the image pass's reading (`date_image.py`'s prompt, the JPEG originals' first two pages, images alone, Gemini 3.7 Flash at temperature 0, reasoning low): the reply names the document's own date, and its year is written in one of the dates it quoted. For the dated set these are W46.date-image-paid's cached replies; for the undated set the same request was sent here.

## Undated documents

425 agreed documents carry no date tag at all, every one with a JPEG original paired to its first page. 100 were drawn round-robin across 55 collections (seed 46). 10 of those have no JPEG original confirmed as their first page's photo (ocr_truth.orient_like_pdf below 0.65), so Vision has nothing to read and they are left out; 90 answered.

| measure | documents |
|---|---:|
| the reply gives a year | 100% (90/90; 96-100) |
| the app writes Date Uncertain | 49% (44/90; 39-59) |
| the app writes a year without Date Uncertain | 51% (46/90; 41-61) |
| the image pass finds the document's own date on its pages | 43% (39/90; 34-54) |
| **false year**: a year without Date Uncertain, and no own date on the pages or a different one | 13% (12/90; 8-22) |

Where the image pass found the document's own date on the page (39), the owner left it untagged; there the app's year equals the page's for 100% (39/39; 91-100), and the app writes Date Uncertain for 13% (5/39; 6-27). The page's year is in Vision's text for 29 of them.

Where it found none (51), the app writes Date Uncertain for 76% (39/51; 63-86); the rest is a confident year the pages do not carry.

## Date Uncertain against a date on the document's own pages

The prompt's test for `date_uncertain` is whether the year can be determined from the document itself. Scored here against the image pass, not the owner's tag (the owner knows the box; DAT-7).

| set | own date on the pages | documents | app writes Date Uncertain | app's year equals the page's |
|---|---|---:|---:|---:|
| undated | yes | 39 | 13% (5/39; 6-27) | 100% (39/39; 91-100) |
| undated | no | 51 | 76% (39/51; 63-86) | – |
| dated (unprinted-year) | yes | 61 | 23% (14/61; 14-35) | 92% (56/61; 82-96) |
| dated (unprinted-year) | no | 61 | 89% (54/61; 78-94) | – |

Agreement of Date Uncertain with "no own date on the pages", both sets: 82% (174/212; 76-87). The dated set is W46.date-image's: documents whose owner year is not in the ABBYY text (that is how they were chosen; ABBYY text is not sent).

## The dated set's years, on Vision text

The same 122 documents, the app's year against the owner's tag, by W46.date-image's classes (D has no printed carrier near it).

| class | documents | year exact | within one | Date Uncertain |
|---|---:|---:|---:|---:|
| D | 17 | 65% (11/17; 41-83) | 94% (16/17; 73-99) | 41% (7/17; 22-64) |
| C | 31 | 55% (17/31; 38-71) | 94% (29/31; 79-98) | 58% (18/31; 41-74) |
| B | 35 | 74% (26/35; 58-86) | 83% (29/35; 67-92) | 54% (19/35; 38-70) |
| A | 32 | 84% (27/32; 68-93) | 91% (29/32; 76-97) | 62% (20/32; 45-77) |
| A' | 7 | 86% (6/7; 49-97) | 86% (6/7; 49-97) | 57% (4/7; 25-84) |
| all | 122 | 71% (87/122; 63-79) | 89% (109/122; 83-94) | 56% (68/122; 47-64) |

## Rerun

The undated set sent a second time (90 answered both times), at the app's default sampling, with the gateway's no-cache field (without it the gateway returned the first run's replies byte for byte): the same year 94% (85/90; 88-98), the same Date Uncertain 98% (88/90; 92-99); false year in the rerun 13% (12/90; 8-22).

## W41.date-tag-measure, weighted to the pool

Its year figures were pooled over a 120/80/50 sample; weighted to the pool's agreed counts (3,868 year+month, 1,000 year, 133 year+DU) they are 89.2% exact (pooled 79.6%) and 98.0% within one (pooled 95.2%). Per stratum: `date-tagging.md`. Those were ABBYY text and Gemini 3.8 direct.

## Measurement card

- **Truth.** Undated: the owner's tags carry no date (truth that the owner could not or did not date it, not that no date exists). "Own date on the pages": Gemini 3.7 Flash's image pass, the same model family as the route scored, so the Date Uncertain agreement is relative to a Gemini reader, not to a human; the owner checked none of these. Dated set: the owner's year tag.
- **Selection.** Undated: round-robin across collections, seed 46, among those whose first page has a paired JPEG; never by a route's reply or the ABBYY text. Dated: W46.date-image's 122, chosen as owner years not in the ABBYY text.
- **Comparison.** One route, one prompt, one text source (Vision on the JPEG originals at 2,400 px). 19 documents had a page without a confirmed JPEG, read as empty. Not compared with ABBYY-text runs (different model version and text).
- **Noise.** n as given, Wilson 95% intervals in brackets; the rerun section is the floor between two identical runs. A gap inside it is a tie.
- **Scope.** It does not say how often a date is truly on an undated document's pages (a Gemini reading), nor how the app would do with 3.8 or its own OCR's settings beyond Vision's defaults.

## Cost

482 gateway calls, 615,652 input and 225,805 output tokens: about $1.31 at 3.8 Flash's list price taken as a ceiling (the gateway returns no price), plus the 122 cached image replies of W46.date-image-paid.
