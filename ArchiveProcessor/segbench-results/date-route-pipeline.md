# The restated dating route end to end (W46.date-route-pipeline)

Written by `scripts/segbench/date_route_pipeline.py score`. The route of `13-stage-rules/08-dating.md` section 3 as one pipeline: (1) the trace prompt with the neighbours' dates on the app's own OCR text, the year explicit when the document's own text carries it; (2) the image pass (first two pages, images alone) only where the own text has no year candidate; (3) inheritance, not measured; (4) the same trace reply's neighbour estimate, written only when `date_scorers.evidence_check` passes, always with Date Uncertain. Date Uncertain is set by the step, never by the model's flag. Text: Apple Vision (macOS 27.2) on the JPEG originals, upright, 2,400 px; no ABBYY text is an input. Sets: the owner's 300 (272 with a confirmed JPEG original of the first page; the rest are left out) and the undated 100 of W46.date-undated (90 readable).

## Findings

- **The route on Gemini 3.7: 58.2% (53/91) where the year is not in the app's own text, 96.3% (131/136) where it is.** Not in text splits into the year on the page (73.3% (22/30)) and nowhere on the page (50.8% (31/61)). By the step that wrote the year: 158 explicit from the text (88.0% (139/158) exact), 12 from the image (83.3% (10/12)), 51 estimated from a neighbour with checked evidence (68.6% (35/51)), 6 with no year written. These combined rows replace the hand-summed one-shot-plus-image row (F-1); they are on Vision-defined sets and not comparable figure for figure with the ABBYY-defined 131.
- **The image step adds a little and takes nothing:** 53 against 48 of 91 with and without it, 5 documents right only with it, 0 only without (sign test p 0.0625), a direction inside the rerun floor.
- **Undated documents get a false year 15.6% (14/90) of the time under section 3's rule**, against 6.7% for the app's own call restated on the owner's rulings (date-undated.md): step 1 writes any year a rule candidate in the own text carries as explicit, and an undated document's text often mentions a year (a citation, a table heading). Requiring the reply to quote it from the document itself changes little (see the variant). The model knew on most of them: letting its own flag add Date Uncertain to an explicit text year, never remove it, gives 5.6% (5/90) false years, and on the owner's documents flags 11 more text years, of which 5 are the owner's year and 7 he himself marked uncertain (uncertain years left unflagged 37.5% (15/40) to 20.0% (8/40)). Section 3 forbids taking the flag from the model; whether this one-way use is allowed is the owner's call.
- **The evidence checker off its writing set (P13-5):** 239 valid, 31 unsupported, 0 with no evidence on Gemini's replies; 12 right years refused (quote does not carry the year given 8; cited document is not in the context given 3; quote is not in the cited document's text 1), 30 wrong years accepted, since the check is for traceability, not truth.
- **The image pass on documents whose text has a year (item 8.2):** on 172 it finds an own date on 142; that date differs from the route's year on 11, of which 7 are the owner's year (7 wrong to right, 2 right to wrong); it quotes a stamp date on 24 (second-role dates for the sidecar). Sending it everywhere would cost the image call on every document.
- **Cost and time:** about $3.11 per 1,000 documents of the owner's mix at 3.8's list price as a ceiling, and 5.6 s of calls a document in sequence (one trace call each, the image pass on 32% of them).
- **The route on the 27B (Sherlock): 37.4% (34/91) where the year is not in the own text, 96.3% (131/136) where it is**, against Gemini's 53/91 on the same documents (22 right only on Gemini, 3 only on the 27B, sign test p 0.0002; all owner documents 184 against 165 of 227, p 0.0003). It loses on the page (53.3% (16/30)) and off it (29.5% (18/61)): 35 checked neighbour estimates (51.4% (18/35) exact) against Gemini's 51, and 17 documents with no year written against 6. Its trace replies are weaker and the checker refuses more of them (226 valid, 44 unsupported; 15 right years refused, 37 wrong accepted). Undated: 17.8% (16/90) false years under section 3, 12.2% (11/90) with the flag rule; Date Uncertain on certain years 10.1% (18/179), left off uncertain ones 45.2% (14/31).

## Exact year by where the year is (the owner's documents)

"In text": the owner's year is written in the document's own Vision text (3,000 characters). "On the page": not in the text, but the Gemini image pass (sent on every owner document for this split) quotes a date with that year. "Not on the page": neither. "Not in text" is the last two together, the stage's metric, now defined from the app's own text and the image pass, not from the ABBYY text (DAT-1). Decade-tagged documents are scored apart. 95% Wilson intervals.

| route | in text | on the page | not on the page | not in text | interval | wrong year written, not in text |
|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 96.3% (131/136) | 73.3% (22/30) | 50.8% (31/61) | 58.2% (53/91) | 48-68 | 32/91 |
| Qwen3.6 27B (Sherlock) | 96.3% (131/136) | 53.3% (16/30) | 29.5% (18/61) | 37.4% (34/91) | 28-48 | 40/91 |

## By evidence class (the owner's documents)

The class is the step that wrote the year: explicit from the text or the image (no Date Uncertain), estimated from a neighbour with checked evidence (Date Uncertain), or none written.

| route | text | image | estimate | none | certain years flagged | uncertain years unflagged | estimate interval covers, median width |
|---|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 158, 88.0% (139/158) exact | 12, 83.3% (10/12) exact | 51, 68.6% (35/51) exact | 6 | 14.4% (26/181) | 37.5% (15/40) | 86.3% (44/51), 1 y |
| Qwen3.6 27B (Sherlock) | 166, 84.3% (140/166) exact | 9, 77.8% (7/9) exact | 35, 51.4% (18/35) exact | 17 | 10.1% (18/179) | 45.2% (14/31) | 80.0% (28/35), 0 y |

## Step 1 needing a quote from the document itself (a variant, in-sample)

Section 3 makes a year explicit when any rule candidate in the own text carries it, whatever the reply cites. The variant also needs the reply to cite "self", as the trace prompt asks for a printed own date; a year the reply takes from a neighbour is then an estimate, with Date Uncertain, even when the text mentions it. Chosen after reading this run's undated false years, so it is an in-sample comparison, not a tested rule.

| route | step 1 | in text | not in text | all owner, paired: default only / variant only, p | explicit / estimated years on the undated | false-year rate |
|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | any own candidate (section 3) | 96.3% (131/136) | 58.2% (53/91) | 184/227 | 55 / 28 | 15.6% (14/90) |
| Gemini 3.7 Flash (gateway) | a quote from self | 96.3% (131/136) | 58.2% (53/91) | 184/227; 0 / 0, p 1.0 | 52 / 31 | 13.3% (12/90) |
| Qwen3.6 27B (Sherlock) | any own candidate (section 3) | 96.3% (131/136) | 37.4% (34/91) | 165/227 | 56 / 22 | 17.8% (16/90) |
| Qwen3.6 27B (Sherlock) | a quote from self | 96.3% (131/136) | 37.4% (34/91) | 165/227; 0 / 0, p 1.0 | 53 / 25 | 14.4% (13/90) |

## The model's own flag on an explicit text year (a variant, in-sample)

Section 3 never takes Date Uncertain from the model. Here the trace reply's own `date_uncertain` is allowed one thing only: to add Date Uncertain to a year step 1 made explicit (the year is kept, nothing is removed). A year with Date Uncertain is not a false year. Like the self-quote variant, it was chosen after reading this run's undated false years and is evaluated on the same replies, so it is an in-sample comparison, not a tested rule; and part of its undated false-year rate is judged by the Gemini image pass, the scored route's own step 2 (split below the table).

| route | owner text years the model flagged: n, exact, owner-uncertain | certain years flagged | uncertain years unflagged | false-year rate, undated |
|---|---|---|---|---|
| Gemini 3.7 Flash (gateway), section 3 | – | 14.4% (26/181) | 37.5% (15/40) | 15.6% (14/90) |
| Gemini 3.7 Flash (gateway), the flag demotes | 11, 5, 7 | 16.6% (30/181) | 20.0% (8/40) | 5.6% (5/90) |
| Qwen3.6 27B (Sherlock), section 3 | – | 10.1% (18/179) | 45.2% (14/31) | 17.8% (16/90) |
| Qwen3.6 27B (Sherlock), the flag demotes | 5, 0, 2 | 11.7% (21/179) | 38.7% (12/31) | 12.2% (11/90) |

Gemini 3.7 Flash (gateway), the flag demotes: of its 5 undated false years, 2 are on documents the owner ruled (2 of 15 explicit years there) and 3 are judged by the Gemini image pass (3 of 30).

Qwen3.6 27B (Sherlock), the flag demotes: of its 11 undated false years, 5 are on documents the owner ruled (5 of 18 explicit years there) and 6 are judged by the Gemini image pass (6 of 33).

## What the image step adds (paired, not in text)

The same documents and trace replies, the route with and without step 2.

| route | with step 2 | without | only with | only without | sign test p |
|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 53/91 | 48/91 | 5 | 0 | 0.0625 |
| Qwen3.6 27B (Sherlock) | 34/91 | 30/91 | 4 | 0 | 0.125 |

## The evidence checker on fresh replies (P13-5)

Every trace reply with a year on the owner's documents, checked by the widened checker of W46.date-evidence-check, which was written on the 27B's earlier replies: these are its first counts off them. "Right refused": the year is the owner's but the citation fails; "wrong accepted": the citation passes but the year is not the owner's.

| route | valid | unsupported | none | right years refused | wrong years accepted | valid by form |
|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 239 | 31 | 0 | 12 | 30 | four digits 214 (27 wrong), two digits 25 (3 wrong) |
| Qwen3.6 27B (Sherlock) | 226 | 44 | 0 | 15 | 37 | four digits 202 (35 wrong), two digits 24 (2 wrong) |

Gemini 3.7 Flash (gateway), right years refused by reason: quote does not carry the year given 8; cited document is not in the context given 3; quote is not in the cited document's text 1.

Qwen3.6 27B (Sherlock), right years refused by reason: quote does not carry the year given 13; quote is not in the cited document's text 2.

## The undated documents (false years)

A false year is a year written without Date Uncertain where the document has no own date of that year. Truth: the owner's ruling on the documents he ruled (W46.date-undated-fold), else the Gemini image pass's reading of the page (model-scored).

| route | documents | years written, explicit / estimated | false, owner-ruled | false, model-scored | false-year rate | interval |
|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 90 | 55 / 28 | 4 of 17 ruled explicit (20 ruled) | 10 of 38 | 15.6% (14/90) | 10-24 |
| Qwen3.6 27B (Sherlock) | 90 | 56 / 22 | 5 of 18 ruled explicit (20 ruled) | 11 of 38 | 17.8% (16/90) | 11-27 |

## The image pass where the text has a year (item 8.2)

Sent on the owner's documents whose own text has a year candidate, which the route does not send it to. "Changes the year": the pass names a document date, written in a date it quoted, other than the route's year.

| route | documents | own date found | changes the year | of them right | wrong → right | right → wrong | a stamp date found |
|---|---|---|---|---|---|---|---|
| Gemini 3.7 Flash (gateway) | 172 | 142 | 11 | 7 | 7 | 2 | 24 |
| Qwen3.6 27B (Sherlock) | 172 | 141 | 10 | 7 | 7 | 2 | 23 |

## Cost and time (Gemini)

Per call, from every ledger row behind the replies used: trace 362 calls, $0.00220 mean, 3.85 s median; image 366 calls, $0.00284 mean, 5.64 s median (3.8's list price as a ceiling; the gateway's own figure $1.2844 on 516 of 516 calls, 1.00 times the estimate on them). Per 1,000 documents of the owner's mix, one trace call each and the image pass on 32% of them: about $3.11 and 5,642 s of calls in sequence. This item spent $1.28.

## Time (the 27B)

Sherlock job 52063413, one GPU, vLLM batched (model load not counted): trace 354 calls in 306.5 s, image 181 calls in 844.9 s (the rest reused). At the route's 362 trace and 115 image calls on 362 documents, about 2.35 GPU-s a document. No money.

Vision: 1972 pages read now in 378.8 s on macOS 27.2 (the rest reused from date_undated's 27.2 readings), 2495 oriented in 828.1 s.

## Measurement card

- **Truth.** the owner's date tags on his 300 (year, and Date Uncertain for the two flag rates); for the undated set, his page-date rulings on the documents he ruled and the Gemini image pass's own reading on the rest, the latter Gemini's own reader on its rows and another model's reading on the 27B's, reported apart. The tag differs from the page for 4 of 26 own-page cases (date-truth-sets.md), so a route quoting the page can score wrong against the tag.
- **Selection.** the owner's 300 as date_tagging drew them and the undated 100 as W46.date-undated drew them, never by a tested route or the ABBYY text; documents whose first page has no confirmed JPEG original are left out (the app would have its own photo). The strata come from the app's own Vision text and the Gemini image pass, so "on the page" is defined by the Gemini reader that one route uses as its step 2.
- **Comparison.** every route on the same documents, the same Vision text, the same prompts and images; the step-2 effect is paired on the same trace replies, and Gemini against the 27B on the same documents. The older step rows were on ABBYY-defined sets and corpus text and are not compared figure for figure.
- **Noise.** one run each (temperature 0; Gemini at reasoning low, the 27B with thinking off); the dating rerun floor is a same-year rate of 94% (85/90) between two identical runs (date-undated.md), so a gap of a few points between routes is inside it. Wilson intervals on single rates; the step-2 gap and the model gap by an exact sign test on their discordant pairs.
- **Scope.** Gemini 3.7 on the gateway (3.8 on a direct key is unmeasured here); the 27B is Qwen3.6-27B-FP8 on vLLM (Sherlock batch 20261112), its 118 image replies on W46.date-image's documents reused from that run, which used other server flags on the same model and prompt; inheritance (step 3) is not measured; the checker counts are off its writing set but on one prompt; the false-year rate is a share of the collection-balanced undated sample, not a corpus rate (P3-1).

