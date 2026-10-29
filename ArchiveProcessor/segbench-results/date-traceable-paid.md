# Dating: Gemini on the trace prompts and the residue (W46.date-traceable-paid)

Written by `scripts/segbench/date_traceable_gateway.py score`. Gemini 3.7 Flash through the Stanford AI API gateway (temperature 0, reasoning low, text only) on W46.date-traceable's three trace prompts, for the 161 of the owner's 300 that need them: every document the rule stage leaves undated and every one whose year is not in the corpus text. The 27B's rows are W46.date-traceable's replies to the same prompts; Gemini 3.8 Flash's are W41's one shot with the app's prompt (OpenRouter). The gateway serves no 3.8. Spend: about $1.39 for 483 replies (1,097,087 input, 151,161 output tokens incl. reasoning), an estimate at 3.8's list price $0.75 / $3.75 per million, so about $2.88 per 1,000 replies. The stated-confidence rerun is dropped (the trace prompt's 90% interval is what the conformal column reads).

## Findings

- **Gemini with the trace prompt comes within two points of Gemini with the app's prompt, and cites its evidence.** On the 131 whose year is not in the corpus text, Gemini 3.7 Flash with the neighbour dates (trace-neigh) gets 61.8%, plain 58.0%, with five same-collection examples 57.3%; Gemini 3.8 Flash one shot with the app's prompt got 63.4%. The 27B with the same three prompts gets 42.7% to 45.8%, so the gap to Gemini is about 16 points whichever prompt. Gemini's citations check better than the 27B's (86 valid / 45 unsupported on trace-neigh, the 27B 65 / 61), and its 90% intervals are narrower at the same coverage (conformal width about 4 years against 10 to 16).
- **Neighbour dates help where the year is near and hurt where it is not.** With them, Gemini gains on A' (71.4% to 85.7%) and B (54.3% to 71.4%) and loses on C and D, the classes this arm was for (C+D 44.6% to 39.3%; the app prompt's 3.8 51.8%): a printed neighbour year is a strong pull, and on C and D it is the wrong year. The five labelled examples add nothing (41.1% on C+D). No trace variant beats the app prompt on C+D.
- **Staging still costs accuracy, even with Gemini as the residue.** Rules, the 2B chooser and Gemini trace-neigh on every document the rules leave undated (t=0, 124 calls of 300) get 49.6% of the 131, against 61.8% for the same prompt one shot; at t=3 (19 calls) 38.9%. At t=0 the whole loss is the rule stage: 37 of the 131 print some other year, the rule's pick stands and is right on 2 of them, where Gemini one shot is right on 19; on the rest the pipeline gives Gemini's own answer. At higher t propagation adds to the loss, passing a neighbour's year on to B, C and D. The printed years are unchanged (95.0%). So for the profile that pays for Gemini, one shot on every document is the better route on the unprinted years; staging saves calls (124 or 19 of 300) at the cost of those points.
- **Cost.** About $2.88 per 1,000 replies at 3.8's list price taken as a ceiling (about 2,300 input and 310 output tokens a reply, reasoning low); the gateway returns no price. Gemini 3.7, not 3.8, because the gateway serves no 3.8.

## One shot on the 131 whose year is not in the corpus text

Exact year, by class. Evidence: the cited quote checked against the cited document (date_scorers.evidence_check). Coverage and width: split-conformal at 90%, swapped halves, on the 131.

| configuration | not in text | A | A' | B | C | D | C+D | evidence valid / unsupported | coverage | width |
|---|---|---|---|---|---|---|---|---|---|---|
| Gemini 3.8 Flash, app prompt (W41, OpenRouter) | 63.4% | 81.8% | 71.4% | 62.9% | 45.7% | 61.9% | 51.8% | 0 / 0 | 92.4% | 3.0 |
| Gemini 3.7 Flash (gateway), trace-plain | 58.0% | 81.8% | 71.4% | 54.3% | 37.1% | 57.1% | 44.6% | 78 / 50 | 93.9% | 4.4 |
| Gemini 3.7 Flash (gateway), trace-neigh | 61.8% | 84.8% | 85.7% | 71.4% | 34.3% | 47.6% | 39.3% | 86 / 45 | 96.9% | 4.5 |
| Gemini 3.7 Flash (gateway), trace-shots | 57.3% | 81.8% | 57.1% | 60.0% | 31.4% | 57.1% | 41.1% | 76 / 52 | 93.9% | 3.8 |
| Qwen3.6 27B, trace-plain | 42.7% | 75.8% | 42.9% | 45.7% | 17.1% | 28.6% | 21.4% | 69 / 61 | 91.6% | 9.6 |
| Qwen3.6 27B, trace-neigh | 45.8% | 72.7% | 71.4% | 51.4% | 17.1% | 33.3% | 23.2% | 65 / 61 | 89.3% | 13.8 |
| Qwen3.6 27B, trace-shots | 42.0% | 72.7% | 57.1% | 40.0% | 17.1% | 33.3% | 23.2% | 65 / 61 | 91.6% | 15.6 |

## The staged pipeline with Gemini as the residue

Rules, the 2B chooser, propagation within t documents, the residue to the trace model. On all 300; 'not in text' is the 131, 'in text' the 119.

| configuration | residue calls of 300 | in text | not in text | A | B | C | D | C+D |
|---|---|---|---|---|---|---|---|---|
| 2B chooser|Gemini 3.7 trace-plain|t=0 | 124 | 95.0% | 47.3% | 72.7% | 45.7% | 25.7% | 42.9% | 32.1% |
| 2B chooser|Gemini 3.7 trace-plain|t=1 | 55 | 95.0% | 42.0% | 75.8% | 40.0% | 20.0% | 28.6% | 23.2% |
| 2B chooser|Gemini 3.7 trace-plain|t=2 | 30 | 95.0% | 38.2% | 75.8% | 34.3% | 14.3% | 19.0% | 16.1% |
| 2B chooser|Gemini 3.7 trace-plain|t=3 | 19 | 95.0% | 36.6% | 75.8% | 28.6% | 11.4% | 19.0% | 14.3% |
| 2B chooser|Gemini 3.7 trace-neigh|t=0 | 124 | 95.0% | 49.6% | 72.7% | 57.1% | 22.9% | 38.1% | 28.6% |
| 2B chooser|Gemini 3.7 trace-neigh|t=1 | 55 | 95.0% | 45.8% | 75.8% | 51.4% | 22.9% | 23.8% | 23.2% |
| 2B chooser|Gemini 3.7 trace-neigh|t=2 | 30 | 95.0% | 42.7% | 75.8% | 45.7% | 17.1% | 19.0% | 17.9% |
| 2B chooser|Gemini 3.7 trace-neigh|t=3 | 19 | 95.0% | 38.9% | 75.8% | 34.3% | 14.3% | 19.0% | 16.1% |
| 2B chooser|Gemini 3.7 trace-shots|t=0 | 124 | 95.0% | 45.8% | 72.7% | 48.6% | 17.1% | 47.6% | 28.6% |
| 2B chooser|Gemini 3.7 trace-shots|t=1 | 55 | 95.0% | 42.0% | 75.8% | 42.9% | 17.1% | 33.3% | 23.2% |
| 2B chooser|Gemini 3.7 trace-shots|t=2 | 30 | 95.0% | 38.2% | 75.8% | 34.3% | 11.4% | 23.8% | 16.1% |
| 2B chooser|Gemini 3.7 trace-shots|t=3 | 19 | 95.0% | 37.4% | 75.8% | 28.6% | 11.4% | 23.8% | 16.1% |
| 2B chooser|27B trace-plain|t=0 | 124 | 95.0% | 35.1% | 66.7% | 34.3% | 8.6% | 28.6% | 16.1% |
| 2B chooser|27B trace-plain|t=1 | 55 | 95.0% | 35.1% | 75.8% | 31.4% | 14.3% | 14.3% | 14.3% |
| 2B chooser|27B trace-plain|t=2 | 30 | 95.0% | 35.1% | 75.8% | 28.6% | 11.4% | 14.3% | 12.5% |
| 2B chooser|27B trace-plain|t=3 | 19 | 95.0% | 35.1% | 75.8% | 25.7% | 11.4% | 14.3% | 12.5% |
| 2B chooser|27B trace-neigh|t=0 | 124 | 95.0% | 37.4% | 63.6% | 37.1% | 11.4% | 28.6% | 17.9% |
| 2B chooser|27B trace-neigh|t=1 | 55 | 95.0% | 38.9% | 75.8% | 37.1% | 14.3% | 19.0% | 16.1% |
| 2B chooser|27B trace-neigh|t=2 | 30 | 95.0% | 37.4% | 75.8% | 34.3% | 11.4% | 14.3% | 12.5% |
| 2B chooser|27B trace-neigh|t=3 | 19 | 95.0% | 35.9% | 75.8% | 28.6% | 11.4% | 14.3% | 12.5% |
| 2B chooser|27B trace-shots|t=0 | 124 | 95.0% | 34.4% | 63.6% | 31.4% | 11.4% | 28.6% | 17.9% |
| 2B chooser|27B trace-shots|t=1 | 55 | 95.0% | 35.1% | 75.8% | 28.6% | 17.1% | 14.3% | 16.1% |
| 2B chooser|27B trace-shots|t=2 | 30 | 95.0% | 35.1% | 75.8% | 28.6% | 11.4% | 14.3% | 12.5% |
| 2B chooser|27B trace-shots|t=3 | 19 | 95.0% | 35.1% | 75.8% | 25.7% | 11.4% | 14.3% | 12.5% |
