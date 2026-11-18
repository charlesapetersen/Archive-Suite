# The Mac 8B's image quotes on the actual no-key laptop route (W46.date-8b-local-baseline)

Measurement review pass 15, P15-3: 08-dating.md call 7.5 adds the Qwen3-VL 8B image pass at 16 GB, option (c), to option (a) once its quotes improve the year. W46.date-route-pipeline-8b paired the 8B only with the Gemini and 27B trace replies; this pairs the same cached 8B replies with option (a) itself: Vision text, rules, the 2B chooser and propagation at t=3. $0: cached replies only, no model run, no upload, no ABBYY input. Script: `ArchiveProcessor/scripts/segbench/date_8b_local.py`.

## Verdict

The owner's condition (the 8B's quotes improve the year on the route) is **not met**. On the 55 owner documents whose own Vision text gives no year candidate, the only documents where (a) and (c) can differ, the quote-source reading gains 1 and loses 2 (exact sign test p 1.0); the strict reading gains 0 and loses 1 (p 1.0). No image route is added: the 16 GB route stays (a) and `qwen3-vl-8b-image-mac` stays unoffered.

## Results

Documents readable from JPEG originals: 272 owner, 90 undated; 227 owner documents with a year tag, 55 of them with no rule candidate in their own Vision text and 172 with one. The 8B reply is cached for 115 of the 115 no-candidate documents across both sets; none missing.

| arm | no-candidate exact | wrong, explicit | wrong, Date Uncertain | no year | all owner exact |
|---|---|---|---|---|---|
| (a) Vision, rules, propagation t=3 | 60.0% (33/55; 47-72) | 0 | 19 | 3 | 70.9% (161/227; 65-76) |
| (c) + 8B own date (strict) | 58.2% (32/55; 45-70) | 1 | 19 | 3 | 70.5% (160/227; 64-76) |
| (c) + 8B quote source | 58.2% (32/55; 45-70) | 3 | 17 | 3 | 70.5% (160/227; 64-76) |

All-owner figures leave the rule pick standing where a candidate exists (the 2B chooser not run, see Measurement card); they are identical in the three arms there, so they serve only as context.

Paired against (a) on the no-candidate owner documents:

| arm | image years (right) | gains | losses | sign p | changed | wrong to another wrong | none to wrong | flagged right made explicit |
|---|---|---|---|---|---|---|---|---|
| (c) + 8B own date (strict) | 2 (1) | 0 | 1 | 1.0 | 1 | 0 | 0 | 1 |
| (c) + 8B quote source | 10 (7) | 1 | 2 | 1.0 | 4 | 1 | 0 | 6 |

Strata, named for this comparison (whether the 8B quotes a year; whether propagation reaches within t=3), exact years per arm:

| stratum | n | (a) | strict | quote source |
|---|---|---|---|---|
| 8B quotes a year, propagation reaches | 10 | 8 | 7 | 7 |
| 8B quotes a year, propagation does not reach | 0 | 0 | 0 | 0 |
| 8B quotes no year, propagation reaches | 42 | 25 | 25 | 25 |
| 8B quotes no year, propagation does not reach | 3 | 0 | 0 | 0 |

Documents where the quote-source year differs from (a)'s:

| document | owner year | (a) | (a) flagged | 8B strict | 8B quote source |
|---|---|---|---|---|---|
| o:9a73f1b3b4b8d971 | 1967 | 1968 | yes | None | 1967 |
| o:723df4da10d243e3 | 1959 | 1959 | yes | None | 1962 |
| o:bb15eb97ea131bb3 | 1935 | 1937 | yes | None | 1926 |
| o:28102e895f9918d0 | 1937 | 1937 | yes | 1979 | 1979 |

False years on the undated 90 (a year written without Date Uncertain where the document has no own date of that year):

| arm | explicit years | false, owner-ruled | false, model-scored | false-year rate |
|---|---|---|---|---|
| (a) Vision, rules, propagation t=3 | 55 | 6 of 17 | 14 of 38 | 22.2% (20/90; 15-32) |
| (c) + 8B own date (strict) | 56 | 6 of 18 | 14 of 38 | 22.2% (20/90; 15-32) |
| (c) + 8B quote source | 58 | 6 of 18 | 15 of 40 | 23.3% (21/90; 16-33) |

Date Uncertain against the owner's flag, all owner documents with a year written:

| arm | certain years flagged | uncertain years unflagged |
|---|---|---|
| (a) Vision, rules, propagation t=3 | 14.8% (27/183; 10-21) | 39.0% (16/41; 26-54) |
| (c) + 8B own date (strict) | 14.2% (26/183; 10-20) | 41.5% (17/41; 28-57) |
| (c) + 8B quote source | 10.4% (19/183; 7-16) | 43.9% (18/41; 30-59) |

## Measurement card

- **Truth:** the owner's date tags on his 300 (year exact; his Date Uncertain flag for the flag table). Neither arm drafted it. Undated 90: the owner's rulings on 20 (W46.date-undated-fold), the rest scored against Gemini 3.7's reading of the page image, a model that is not one of the compared arms; that half is model-scored and reported apart.
- **Selection:** date_route_pipeline's sets (date_tagging's owner sample, W46.date-undated's 90), kept where the first page has Vision text of a confirmed JPEG original. The comparison set is chosen by the rule on the document's own Vision text, the step both arms share, not by either tested reader and not by ABBYY text. The strata above are defined here from the arms' own inputs; date_truth's ABBYY-defined classes are not used.
- **Comparison:** same documents, same Vision text and neighbours, same propagation, the 8B replies as cached (1,400 px, the first two pages, date_image.PROMPT). The 2B chooser acts only where a candidate exists, so it is identical in (a) and (c) and cancels from every paired figure. Its cached replies answer prompts built from ABBYY text, not these inputs, so none was reused, and none was needed: the smallest 2B run the comparison requires is zero documents. The quote-source reading was chosen after its replies were read in W46.date-route-pipeline-8b (in-sample); the strict one was fixed beforehand.
- **Noise:** n = 55 paired owner documents; exact two-sided sign test on the discordant pairs, Wilson 95% intervals on rates. The 8B's rerun floor is not measured (one reply per document, greedy decoding), so a gap of one or two documents cannot be told from rerun noise; the verdict needs no floor here, since (c) does not lead (a) even in the raw counts.
- **Scope:** the 16 GB no-key route on these sets. It does not measure a residue stage, the 8B on documents with a candidate (item 8.2's question), inheritance (step 3), the 2B chooser's accuracy on Vision-text prompts, or other memory tiers.
