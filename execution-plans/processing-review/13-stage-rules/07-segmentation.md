# 07 Page-stream segmentation and enclosure relations (Phase 4 rule note, draft)

Tags: [M] measured, [I] inferred, [?] unverified. Every figure names its file; files without a path are in
`ArchiveProcessor/segbench-results/`. Corrections cite the pass id. Nothing here is recomputed.

## 1. Stage and question

The stage cuts a box's photographed page stream into documents (a gap between two document pages is a start or a
continuation), keeps an enclosure with its covering letter, and shows the user the gaps worth checking.
The user chooses which voter judges the seven-page windows (or none), which review rule picks the gaps to check, and,
with a coding agent and a cluster, whether to adapt the local model after a reviewed box.

## 2. Is there a choice?

Yes. Routes in view: R1 none (doc-split-v1 on the Mac CPU and the feature model are not a segmenter: 29.1% unchecked
on the test boxes with 86.8 checks per 100 pages, seg-adapt-curve.md; features 64.7% on dev, SUMMARY.md) [M]. R2 the
corpus-trained Qwen3.5 2B, 8-bit MLX. R3 GLM-5.3 Flash (OpenRouter). R4 Gemini 3.8 Flash (direct key), Claude
Sonnet 5.5, GPT-6.1 Sol. R5 the Claude and ChatGPT plans through `claude -p` and `codex exec`. R6 none measured
(no document service was run on segmentation in these inputs) [?]. R7 the 2B, 4B and 27B teacher on Sherlock or
FarmShare, and the LoRA continuation. R8 the review rule (a second model's disagreement) and the plan mix.

## 3. The rule for the settings layer

Sheet text: "Pages are grouped into documents by a model reading seven-page windows. The figure is pages in exactly
the right document, measured on the owner's locked boxes; it is not a forecast for your collection. Gaps the model is
unsure of, or where two models disagree, are shown to you to check; checking every gap is always possible."

- **Metric.** `pages_exact`: pages in an exact document, no checking, on the two locked test boxes (Stanton and RG165,
  363 pages; options.md), higher is better. Beside it the solver reads `checks_per_100` (boundaries to check per 100
  pages), `after_checking` and `unflagged_per_500`, and moves the shown figure from no-checking toward after-checking
  by the share of checks the user's minutes cover (12-settings-design.md §3.3). Figure keys are `<kind>` for pages
  exact and `<kind>.<attribute>` for the others.
- **Tie rule.** A difference in pooled test-box pages exact under twice the larger window-offset range of the two
  routes compared is a tie and the cheaper route wins (12-settings-design.md §3.3; figures.json
  `noise.seg_rerun_pages_exact_points`). A route with no measured range takes the largest measured. Measured: Gemini
  3.7 on g2 0.3 points (88.8-89.1%, seg-g2-offsets.md) and on g1 2.1 (83.0-85.2%, seg-boxes-score.md); no other route
  has one, so every pair is held to twice 2.1, **4.2 points** (`SettingsSolver.segmentationTie`, which the solver's
  test checks against the table's `test-boxes.offset_range` figures). This is the reading rule's construction (twice
  the larger rerun range of the two, a route without one held to its family's largest: ocr-rerun-noise.md §The tie
  rule), made the same on purpose (W46.seg-g2-offsets, P14-1): the gap between two single runs moves by up to each
  route's spread, so one range under-counts it, and the 3.2 it replaces was one range (the top of the 1.4-3.2 per-box
  floor) applied to pooled figures before any pooled range was measured. The window offset is segmentation's rerun:
  at temperature 0 the answers are fixed for fixed windows, and the offset is what a real batch varies. Per box the
  ranges are wider (g2: Stanton 2.9, RG165 6.9 points), so a per-box comparison would need its own floor.
  The floor is in pages exact; a gap-accuracy difference has no measured floor, so there the paired interval
  decides (seg-boxes-score.md Noise). Error counts differ by one or two within noise (options.md Reading).
- **Kind rules.** Kinds the bench scores apart are boxes, not document kinds (12-settings-design.md §3.9):
  `test-boxes` (typed letters, Stanton and RG165), `letters` (Sasha, typed and handwritten, the one box no student
  trained on), `magazine` (Illustrated Review, articles within issues), `clippings-mixed` (SC0122, the review's
  clippings box: individual clippings taken in a reading room, mixed with other papers, 61% clipping-tagged; STATE.md
  "Locked boxes named"), and two public boxes, `manuscripts-public` (Lincoln, 19th-century handwritten
  correspondence) and `typed-gov-public` (CREST) [M]. Rules: (a) a `magazine` figure ranks only for a route whose
  prompt states the article-within-issue rule: since W46.seg-magazine-rule-app that is Gemini 3.8 Flash on g2, whose
  figure is Gemini 3.7's g2 answer (93.8% of the Illustrated Review's gaps), labelled as 3.7's and as measured on the
  set rule 10 was written and adopted on, not a held-out one (pass 14, P14-7). Every other route's
  `magazine` figure (g1, w1, c1, and the students, which trained on the box) is shown with "ranks nothing yet" and the
  solver never picks on it. Until then the reason was not the prompts (only Gemini's g1 carries the full-issue rule; Claude's w1 and GLM's c1 have none, and
  every cloud route merges the newsletter pair with or without it, P8-4, seg-boxes-score.md Reading): it is that the
  students trained on the box and the shipped routes' prompts do not state the article-within-issue rule. Measured
  since (W46.seg-magazine-rule-redo, seg-magazine-rule.md): Gemini 3.7 with g2, g1 with rule 10 on that rule, scores
  93.8% of the Illustrated Review's gaps against g1's 71.2% (false merges 40 to 0), so g1's rule caused its merges
  there. The app's Gemini voter sends g2 since W46.seg-magazine-rule-app (its level refit on 3.7's g2 answers is
  0.965, unchanged); the ChatGPT voter's c1 keeps g1's rule 10 until W46.gateway-models-ok. (b) The
  `clippings-mixed` comparison uses the owner-ruled weighted figure, never the all-known diagnostic (P4-2). (c) On
  handwritten manuscript material a local or cluster Qwen route carries the warning "on Lincoln's manuscripts this
  model put 35.6% of pages in the right document" and the sheet recommends a cloud voter where one is feasible
  (seg-lincoln-cloud.md: cloud 86.2-90.4%, open 35.6-49.8%) [M]. (d) Enclosures: an enclosure is the same document as
  its covering letter (owner rulings at Lincoln 229|230 and CREST 74|75, seg-truth-rescore.md). Every cloud route
  splits both; the 2B and 4B join Lincoln's (seg-truth-rescore.md) [M]. No route is scored on enclosure relations as
  such, so the stage offers no enclosure setting; the user's check is the safeguard [I].
- **Window.** Seven pages at stride 3 with images and Vision text, every route (seg-window-modality.md
  recommendation 1 for the 2B; seg-window-gateway.md "What this means" 1 for Gemini 3.7) [M]. No self-voting
  (seg-window-modality.md recommendation 3). No collection-facts block (seg-context.md recommendation).
- **Review rule.** Cloud routes and the plan mix flag by their own frozen rule and level (min confidence at or below
  the level in options.md: Claude 0.850, Gemini 0.965, ChatGPT 0.990, GLM 0.925, the 2B 0.995). For the local 2B,
  when a second model is available, the gaps shown are those where the 2B and the partner disagree, least confident
  first (seg-adapt-curve.md finding 3) [M]; with no partner the 2B's own level applies, which flags nearly every gap
  (78.8 per 100 pages, options.md). Decided as call 3 (a).
- **Fallback.** A window that fails to parse votes 0.5 new on its gaps (cheap-models.md), so its gaps are flagged
  [M]. If every route fails, the built-in behaviour is manual: every gap is a check (86.8 per 100 pages, options.md),
  as `SegmentationApproach.defaultApproach = .manual` in the app.
- **When the stage must not run.** It always runs; "manual" proposes nothing. Label photos (box and folder) are
  boundaries by construction and are never voted on (options.md Denominators; seg-adapt-curve.md header).
- **Adaptation (after training).** The rule set before scoring was not met (no loss of start recall on either box;
  at k = 200 each box loses one start, seg-adapt-lora.md), so the figures alone say no. The owner decided (14-owner-calls.md
  call 7): after a reviewed box of about 200 corrected gaps of one material, a LoRA continuation of the 2B
  (row `seg-2b-lora-k200`, whose kit part is note 12's) is offered for the next boxes of that material to cluster
  profiles only, flagging kept on, labelled "measured on one material", and loaded only past the kit's gate. Not at 50.
  The trigger is this note's; the training job, gate and held-out box are note 12's.

## 4. Table rows

Truth tags: `owner-test` Stanton and RG165 owner-ruled, Stanton with the 2026-10-31 rulings; `owner-locked` the three
boxes of 2026-10-29/30; `lincoln-audit` and `crest-audit` agent-audited with the owner's disputed gaps folded in,
segment figures conditional on each route's call at unsure gaps.

```json
[
{"id":"manual","name":"No model: check every gap","family":"manual","app_route":"manual","status":"shipped","needs":{"key":[],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes.checks_per_100":{"value":86.8,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Full manual","attribute":"boundaries to check per 100 pages","value":"86.8"}},
  "test-boxes.after_checking":{"value":100.0,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Full manual","attribute":"pages right after checking","value":"100.0%"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"options.md","route":"Full manual","attribute":"API cost","value":"none"}},
 "time":{"per_unit_s":null,"measured":false,"measured_on":"20 s a boundary assumed, 12-settings-design.md §3.9","source":null},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},"caveats":["checking time unmeasured"],"kind_rules":[],"fallback":null,"conditions":[]},

{"id":"gemini3.8-flash","name":"Gemini 3.8 Flash","family":"cloud","app_route":"gemini|gemini-3.8-flash","status":"shipped","needs":{"key":["gemini"],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":88.8,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Gemini only","attribute":"pages in an exact document, no checking","value":"88.8%"}},
  "test-boxes.offset_range":{"value":0.3,"low":88.8,"high":89.1,"n":363,"truth":"owner-test","source":{"file":"seg-g2-offsets.md","route":"Gemini 3.7","attribute":"spread of pages exact, no checking, over window offsets 0, 1 and 2","value":"0.3 points"}},
  "test-boxes.checks_per_100":{"value":25.3,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Gemini only","attribute":"boundaries to check per 100 pages","value":"25.3"}},
  "test-boxes.after_checking":{"value":100.0,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Gemini only","attribute":"pages right after checking","value":"100.0%"}},
  "test-boxes.unflagged_per_500":{"value":0.0,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Gemini only","attribute":"unflagged errors per 500 pages (count)","value":"0.0 (0)"}},
  "dev-boxes":{"value":91.9,"n":551,"truth":"owner-dev","source":{"file":"seg-magazine-rule-app.md","route":"g2 on 3.7, held out (pooled)","attribute":"pages exact, no checking","value":"91.9%"}},
  "magazine.gap_acc":{"value":93.8,"n":146,"truth":"owner-locked, the adoption set","source":{"file":"seg-magazine-rule.md","route":"g2","attribute":"Gap accuracy","value":"93.8%"}}},
 "cost":{"usd_1000_list":3.61,"usd_1000_batch":1.81,"price_read":"2026-10-05","source":{"file":"options.md","route":"gemini-3.8-flash/low","attribute":"list $ / batch $","value":"$3.61 / $1.81"}},
 "time":{"per_unit_s":5.33,"per_window_s":16.0,"measured":false,"measured_on":"Gemini 3.7's gateway window call, lent to 3.8 (not timed on 3.8)","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-boxes-score.md","route":"Gateway line","attribute":"s a call","value":"16.0 s"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["the app sends prompt g2 to 3.8; every figure and the level (0.965) are Gemini 3.7 Flash's g2 answers through the gateway, labelled as 3.7's, the level fitted on them (seg-magazine-rule-app.md; owner, 2026-11-10: no 3.8 run on the personal key)","the figures are g2's window offset 0; over offsets 0, 1 and 2 it scores 88.8-89.1% no checking, 25.3-29.2 checks per 100 pages, 100.0% after checking and no unflagged error (seg-g2-offsets.md); 3.7's range on g1 at this level is 83.0-85.2%","introductory price to 31 Dec 2026; then $7.22 list, $3.61 batch (options.md); tokens measured on 3.8 with g1","no locked-box figure at 3.8; the locked boxes were scored on 3.7 (SEG-9)","the magazine figure is the Illustrated Review set g2 was adopted on (seg-magazine-rule.md), not a held-out one"],
 "kind_rules":[],"fallback":"manual","conditions":[]},

{"id":"gemini3.7-flash-gateway","name":"Gemini 3.7 Flash (Stanford gateway)","family":"cloud","app_route":null,"status":"measured","needs":{"key":["gateway"],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":85.2,"n":363,"truth":"owner-test","source":{"file":"seg-boxes-score.md","route":"3.7, offset 0","attribute":"pages in an exact document, no checking (range 83.0-85.2%)","value":"85.2%"}},
  "test-boxes.offset_range":{"value":2.1,"low":83.0,"high":85.2,"n":363,"truth":"owner-test","source":{"file":"seg-boxes-score.md","route":"Gemini 3.7","attribute":"window offsets move no-check exact pages","value":"2.1 points"}},
  "test-boxes.checks_per_100":{"value":25.9,"n":363,"truth":"owner-test","source":{"file":"seg-boxes-score.md","route":"3.7, offset 0","attribute":"boundaries to check per 100 pages (range 25.9-27.3)","value":"25.9"}},
  "test-boxes.after_checking":{"value":98.5,"n":363,"truth":"owner-test","source":{"file":"seg-boxes-score.md","route":"3.7, every offset","attribute":"pages right after checking","value":"98.5%"}},
  "letters.gap_acc":{"value":96.0,"n":175,"truth":"owner-locked","source":{"file":"seg-boxes-score.md","route":"Gemini 3.7 Flash, g1 (gateway), Sasha","attribute":"gap accuracy","value":"96.0%"}},
  "letters":{"value":82.2,"n":174,"truth":"owner-locked","source":{"file":"seg-boxes-score.md","route":"Gemini 3.7 Flash, g1 (gateway), Sasha","attribute":"pages exact","value":"82.2%"}},
  "magazine.gap_acc":{"value":71.2,"n":146,"truth":"owner-locked","source":{"file":"seg-boxes-score.md","route":"Gemini 3.7 Flash, g1, IllustratedReview","attribute":"gap accuracy","value":"71.2%"}},
  "clippings-mixed.owner_weighted":{"value":99.5,"n":90,"truth":"owner-ruled 30 disputes and 60 controls","source":{"file":"seg-boxes-score.md","route":"Gemini 3.7 Flash, g1, SC0122","attribute":"owner-ruled, weighted","value":"99.5%"}},
  "manuscripts-public":{"value":86.2,"n":261,"truth":"lincoln-audit","source":{"file":"seg-lincoln-gateway.md","route":"Gemini 3.7 Flash, g1 windows","attribute":"pages exact","value":"86.2%"}},
  "typed-gov-public":{"value":89.1,"n":128,"truth":"crest-audit","source":{"file":"seg-lincoln-gateway.md","route":"Gemini 3.7 Flash, g1 windows","attribute":"pages exact","value":"89.1%"}},
  "tabme.boundary_f1":{"value":0.882,"n":503,"truth":"TABME++ document ids, first 504 pages","source":{"file":"seg-tabme-gateway.md","route":"Gemini 3.7 Flash, images and text","attribute":"boundary F1","value":"0.882"}}},
 "cost":{"usd_1000_list":3.59,"usd_1000_batch":null,"price_read":"settled gateway charges","source":{"file":"seg-boxes-score.md","route":"3.7, offset 0","attribute":"settled $ per 1,000 pages","value":"$3.59"}},
 "time":{"per_unit_s":5.33,"per_window_s":16.0,"measured":true,"measured_on":"gateway, a seven-page window call","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-boxes-score.md","route":"Gateway line","attribute":"s a call","value":"16.0 s"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["g1 figures at 0.965, the level fitted for 3.8 on g1 (P7-4); fitted on 3.7's own g2 answers the level is also 0.965 (seg-magazine-rule-app.md)","the app has no gateway route; its range is shown on the 3.8 card labelled as 3.7's, and Sasha's lead over the 2B stands on this card only (14-owner-calls.md call 8)","gateway serves no batch"],
 "kind_rules":["magazine: g1's figure, on the old full-magazine rule, ranks nothing"],"fallback":"manual","conditions":[]},

{"id":"gemini3.7-flash-text","name":"Gemini 3.7 Flash, text-only windows (cheaper tier lead)","family":"cloud","app_route":null,"status":"measured","needs":{"key":["gateway"],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"dev-boxes":{"value":89.6,"n":551,"truth":"owner-dev","source":{"file":"seg-window-gateway.md","route":"Gemini 3.7, text only","attribute":"pages exact, K = 7","value":"89.6% (control 92.3%, -2.7, -9.5 to +1.6)"}},
  "tabme.boundary_f1":{"value":0.898,"n":503,"truth":"TABME++ document ids","source":{"file":"seg-tabme-gateway.md","route":"Gemini 3.7 Flash, text only","attribute":"boundary F1","value":"0.898"}}},
 "cost":{"usd_1000_list":null,"usd_1000_batch":null,"price_read":null,"source":{"file":"seg-window-gateway.md","route":"k7-t against k7-it","attribute":"cost for 187 windows","value":"$0.890 against $1.920"}},
 "time":{"per_unit_s":1.53,"per_window_s":4.6,"measured":true,"measured_on":"gateway, mean s a K = 7 call (6.7 with images)","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-window-gateway.md","route":"k7-t","attribute":"mean seconds","value":"4.6"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["not run on the test boxes; a test-box run is needed before it ships (seg-window-gateway.md)","per-1,000-page cost not tabulated","one run, no Gemini rerun floor (P10-8)"],
 "kind_rules":[],"fallback":"gemini3.8-flash","conditions":["the test-box run (item 2) before any tier is offered"]},

{"id":"claude-sonnet5.5","name":"Claude Sonnet 5.5 (key or Claude plan)","family":"plan","app_route":"anthropic|claude-sonnet-5-5","status":"shipped","needs":{"key":["anthropic"],"plan":["claude"],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":85.5,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude only","attribute":"pages in an exact document, no checking","value":"85.5%"}},
  "test-boxes.checks_per_100":{"value":10.2,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude only","attribute":"boundaries to check per 100 pages","value":"10.2"}},
  "test-boxes.after_checking":{"value":97.3,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude only","attribute":"pages right after checking","value":"97.3%"}},
  "test-boxes.unflagged_per_500":{"value":4.1,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude only","attribute":"unflagged errors per 500 pages (count)","value":"4.1 (3)"}},
  "manuscripts-public":{"value":90.4,"n":261,"truth":"lincoln-audit","source":{"file":"seg-lincoln-cloud.md","route":"Claude Sonnet 5.5, c1, plan","attribute":"pages exact","value":"90.4%"}},
  "typed-gov-public":{"value":89.1,"n":128,"truth":"crest-audit","source":{"file":"seg-lincoln-cloud.md","route":"Claude Sonnet 5.5, c1, plan","attribute":"pages exact","value":"89.1%"}}},
 "cost":{"usd_1000_list":16.93,"usd_1000_batch":8.47,"price_read":"2026-10-11","source":{"file":"options.md","route":"claude-sonnet-5-5","attribute":"list $ / batch $","value":"$16.93 / $8.47"}},
 "time":{"per_unit_s":1.5,"measured":true,"measured_on":"25 min per 1,000 pages at three calls at once, the owner's plan","derived":"25 minutes times 60 over 1,000 pages","source":{"file":"usage.md","route":"Claude only","attribute":"time","value":"about 25 minutes per 1,000 pages"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["on the plan, no money; about 5% of a five-hour window per 100 pages (figures.json note, usage.md)","not scored on the three locked boxes","whether the app's anthropic route is key or plan is not in these inputs [?]"],
 "kind_rules":[],"fallback":"manual","conditions":[]},

{"id":"chatgpt-gpt6.1-sol","name":"ChatGPT, GPT-6.1 Sol (key or plan)","family":"plan","app_route":"openai|gpt-6.1-sol","status":"shipped","needs":{"key":["openai"],"plan":["chatgpt"],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":90.9,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"ChatGPT only","attribute":"pages in an exact document, no checking","value":"90.9%"}},
  "test-boxes.checks_per_100":{"value":79.1,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"ChatGPT only","attribute":"boundaries to check per 100 pages","value":"79.1"}},
  "test-boxes.after_checking":{"value":100.0,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"ChatGPT only","attribute":"pages right after checking","value":"100.0%"}}},
 "cost":{"usd_1000_list":14.51,"usd_1000_batch":7.25,"price_read":"2026-10-11","source":{"file":"options.md","route":"gpt-6.1-sol/low","attribute":"list $ / batch $","value":"$14.51 / $7.25"}},
 "time":{"per_unit_s":5.0,"measured":false,"measured_on":"figures.json placeholder","source":{"file":"execution-plans/processing-review/settings-design/figures.json","route":"ChatGPT only","attribute":"s_page","value":"5.0 (s_est true)"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["its confidence flags nearly every gap (0.990 level)","Dean, Herrnstein, RG165, Stanton only; Lincoln and CREST not collected (owner dropped the arm)","no plan meter the app can read"],
 "kind_rules":[],"fallback":"manual","conditions":[]},

{"id":"mix-claude-chatgpt","name":"Claude and ChatGPT together","family":"plan","app_route":"mix","status":"shipped","needs":{"key":[],"plan":["claude","chatgpt"],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":90.9,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude and ChatGPT together","attribute":"pages in an exact document, no checking","value":"90.9%"}},
  "test-boxes.checks_per_100":{"value":10.2,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude and ChatGPT together","attribute":"boundaries to check per 100 pages","value":"10.2"}},
  "test-boxes.after_checking":{"value":97.3,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude and ChatGPT together","attribute":"pages right after checking","value":"97.3%"}},
  "test-boxes.unflagged_per_500":{"value":4.1,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Claude and ChatGPT together","attribute":"unflagged errors per 500 pages (count)","value":"4.1 (3)"}}},
 "cost":{"usd_1000_list":31.44,"usd_1000_batch":15.72,"price_read":"2026-10-11","source":{"file":"options.md","route":"Claude and ChatGPT together","attribute":"list $ / batch $","value":"$31.44 / $15.72"}},
 "time":{"per_unit_s":5.0,"measured":false,"measured_on":"figures.json placeholder","source":{"file":"execution-plans/processing-review/settings-design/figures.json","route":"Claude and ChatGPT together","attribute":"s_page","value":"5.0 (s_est true)"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["no locked-box or public-box figure","the mix adds little over Claude alone: the models err alike (options.md Reading)"],
 "kind_rules":[],"fallback":"claude-sonnet5.5","conditions":[]},

{"id":"glm5.3-flash","name":"GLM-5.3 Flash (OpenRouter)","family":"cloud","app_route":"openrouter|z-ai/glm-5.3-flash","status":"shipped","needs":{"key":["openrouter"],"plan":[],"cluster":false,"mac_gb":0,"gpus":0},
 "figures":{"test-boxes":{"value":80.6,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"GLM-5.3 Flash only (budget)","attribute":"pages in an exact document, no checking","value":"80.6%"}},
  "test-boxes.checks_per_100":{"value":33.1,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"GLM-5.3 Flash only (budget)","attribute":"boundaries to check per 100 pages","value":"33.1"}},
  "test-boxes.after_checking":{"value":97.0,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"GLM-5.3 Flash only (budget)","attribute":"pages right after checking","value":"97.0%"}},
  "test-boxes.unflagged_per_500":{"value":4.1,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"GLM-5.3 Flash only (budget)","attribute":"unflagged errors per 500 pages (count)","value":"4.1 (3)"}},
  "typed-gov-public":{"value":88.3,"n":128,"truth":"crest-audit","source":{"file":"seg-lincoln-gateway.md","route":"GLM 5.3 Flash, g1 windows, gateway","attribute":"pages exact","value":"88.3%"}}},
 "cost":{"usd_1000_list":1.16,"usd_1000_batch":null,"price_read":"2026-10-13","source":{"file":"options.md","route":"z-ai/glm-5.3-flash/minimal","attribute":"list $ / batch $","value":"$1.16 / none"}},
 "time":{"per_unit_s":5.0,"measured":false,"measured_on":"figures.json placeholder","source":{"file":"execution-plans/processing-review/settings-design/figures.json","route":"GLM-5.3 Flash only (budget)","attribute":"s_page","value":"5.0 (s_est true)"}},
 "memory":{"peak_gb":0,"measured_on":null,"source":null},
 "caveats":["Lincoln failed validation twice, no score (seg-lincoln-gateway.md)","figures.json gives a $0.46 batch price that options.md does not (item 4)"],
 "kind_rules":["manuscripts: no figure"],"fallback":"manual","conditions":[]},

{"id":"seg-qwen3.5-2b-8bit","name":"Trained Qwen3.5 2B on this Mac (no key)","family":"mac","app_route":"local|seg-qwen3.5-2b-8bit","status":"shipped","needs":{"key":[],"plan":[],"cluster":false,"mac_gb":16,"gpus":0},
 "figures":{"test-boxes":{"value":80.3,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Corpus-trained Qwen3.5 2B on this Mac (no key)","attribute":"pages in an exact document, no checking (bf16 on FarmShare)","value":"80.3%"}},
  "test-boxes.checks_per_100":{"value":78.8,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Corpus-trained Qwen3.5 2B","attribute":"boundaries to check per 100 pages","value":"78.8"}},
  "test-boxes.after_checking":{"value":98.8,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Corpus-trained Qwen3.5 2B","attribute":"pages right after checking","value":"98.8%"}},
  "test-boxes.unflagged_per_500":{"value":1.4,"n":363,"truth":"owner-test","source":{"file":"options.md","route":"Corpus-trained Qwen3.5 2B","attribute":"unflagged errors per 500 pages (count)","value":"1.4 (1)"}},
  "letters.gap_acc":{"value":89.7,"n":175,"truth":"owner-locked, held out","source":{"file":"seg-boxes-score.md","route":"shipped 2B, 8-bit MLX on this Mac, Sasha","attribute":"gap accuracy","value":"89.7%"}},
  "letters":{"value":37.4,"n":174,"truth":"owner-locked, held out","source":{"file":"seg-boxes-score.md","route":"shipped 2B, 8-bit MLX, Sasha","attribute":"pages exact","value":"37.4%"}},
  "magazine.gap_acc":{"value":72.6,"n":146,"truth":"owner-locked, trained-on","source":{"file":"seg-boxes-score.md","route":"shipped 2B, IllustratedReview","attribute":"gap accuracy","value":"72.6%"}},
  "clippings-mixed.owner_weighted":{"value":98.1,"n":90,"truth":"owner-ruled, trained-on","source":{"file":"seg-boxes-score.md","route":"shipped 2B, SC0122","attribute":"owner-ruled, weighted","value":"98.1%"}},
  "manuscripts-public":{"value":35.6,"n":261,"truth":"lincoln-audit","source":{"file":"seg-lincoln-cloud.md","route":"trained Qwen3.5 2B, FarmShare","attribute":"pages exact","value":"35.6%"}},
  "typed-gov-public":{"value":81.2,"n":128,"truth":"crest-audit","source":{"file":"seg-lincoln-cloud.md","route":"trained Qwen3.5 2B, FarmShare","attribute":"pages exact","value":"81.2%"}},
  "tabme.boundary_f1":{"value":0.814,"n":6236,"truth":"TABME++ test split","source":{"file":"seg-tabme.md","route":"Trained 2B, images and text","attribute":"boundary F1","value":"0.814 (0.795-0.834)"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"options.md","route":"seg-qwen3.5-2b-8bit/off","attribute":"list $","value":"$0.000"}},
 "time":{"per_unit_s":6.0,"measured":true,"measured_on":"M3 Pro 18 GB, 18 s a seven-page window","source":{"file":"seg-students.md","route":"2B, 8-bit","attribute":"reads about 6 seconds a page","value":"6"}},
 "memory":{"peak_gb":4.4,"measured_on":"M3 Pro 18 GB, MLX peak","source":{"file":"seg-students.md","route":"2B, 8-bit","attribute":"peak GB","value":"4.4"}},
 "caveats":["test-box, Lincoln, CREST and TABME figures are the bf16 2B on FarmShare; the 8-bit build ran on dev boxes and the locked boxes only","its own confidence is close to random on hard boxes (seg-adapt-curve.md)","an 8 GB Mac is unmeasured","figures.json uses a 6.8 GB footprint (local-seg-proof-runtime.json) where seg-students.md gives 4.4 GB peak [?]","on other collections it behaves like a zero-shot reader of about the teacher's quality on one public set (P10-10)"],
 "kind_rules":["manuscripts: warning, recommend a cloud voter","magazine: trained-on, ranks nothing","clippings-mixed: trained-on"],"fallback":"manual","conditions":[]},

{"id":"seg-qwen3.5-2b-bf16-cluster","name":"Trained Qwen3.5 2B (your cluster)","family":"cluster","app_route":null,"status":"measured","needs":{"key":[],"plan":[],"cluster":true,"mac_gb":0,"gpus":1},
 "figures":{"test-boxes":{"value":80.3,"n":363,"truth":"owner-test","source":{"file":"seg-scorers.md","route":"window-or-fs-seg-2b","attribute":"pages exact, locked test boxes","value":"80.3%"}},
  "letters.gap_acc":{"value":89.1,"n":175,"truth":"owner-locked, held out","source":{"file":"seg-boxes-score.md","route":"fine-tuned 2B, bf16, Sasha","attribute":"gap accuracy","value":"89.1%"}},
  "letters":{"value":46.6,"n":174,"truth":"owner-locked, held out","source":{"file":"seg-boxes-score.md","route":"fine-tuned 2B, bf16, Sasha","attribute":"pages exact","value":"46.6%"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"seg-students.md","route":"Qwen3.5 2B, fine-tuned","attribute":"cost paid","value":"$0.000"}},
 "time":{"per_unit_s":0.17,"per_window_s":0.5,"measured":true,"measured_on":"one L40S, concurrency 16, per window","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-window-modality.md","route":"2B","attribute":"s a window","value":"0.5"}},
 "memory":{"peak_gb":null,"measured_on":null,"source":null},
 "caveats":["cluster throughput, queue wait not in it"],"kind_rules":["manuscripts: warning"],"fallback":"manual","conditions":[]},

{"id":"seg-qwen3.5-4b-cluster","name":"Trained Qwen3.5 4B (your cluster)","family":"cluster","app_route":null,"status":"measured","needs":{"key":[],"plan":[],"cluster":true,"mac_gb":0,"gpus":1},
 "figures":{"test-boxes":{"value":80.0,"n":363,"truth":"owner-test","source":{"file":"seg-students.md","route":"Qwen3.5 4B, fine-tuned, test pooled","attribute":"no checking","value":"80.0%"}},
  "letters.gap_acc":{"value":80.0,"n":175,"truth":"owner-locked, held out","source":{"file":"seg-boxes-score.md","route":"fine-tuned 4B, bf16, Sasha","attribute":"gap accuracy","value":"80.0%"}},
  "manuscripts-public":{"value":49.8,"n":261,"truth":"lincoln-audit","source":{"file":"seg-lincoln-cloud.md","route":"trained Qwen3.5 4B, FarmShare","attribute":"pages exact","value":"49.8%"}},
  "tabme.boundary_f1":{"value":0.820,"n":6236,"truth":"TABME++ test split","source":{"file":"seg-tabme.md","route":"Trained 4B","attribute":"boundary F1","value":"0.820 (0.799-0.840)"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"seg-students.md","route":"Qwen3.5 4B, fine-tuned","attribute":"cost paid","value":"$0.000"}},
 "time":{"per_unit_s":0.3,"per_window_s":0.9,"measured":true,"measured_on":"one L40S, per window","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-window-modality.md","route":"4B","attribute":"s a window","value":"0.9"}},
 "memory":{"peak_gb":null,"measured_on":null,"source":null},
 "caveats":["ties the 2B on test (80.0 against 80.3%, seg-students.md); under it on Sasha gaps (80.0 against 89.1%, seg-boxes-score.md)"],"kind_rules":["manuscripts: warning"],"fallback":"manual","conditions":[]},

{"id":"qwen3.5-27b-teacher","name":"Qwen3.5 27B (your cluster)","family":"cluster","app_route":null,"status":"measured","needs":{"key":[],"plan":[],"cluster":true,"mac_gb":0,"gpus":1},
 "figures":{"test-boxes":{"value":81.5,"n":363,"truth":"owner-test","source":{"file":"seg-teacher.md","route":"Qwen3.5 27B, test pooled","attribute":"no checking","value":"81.5%"}},
  "test-boxes.checks_per_100":{"value":86.8,"n":363,"truth":"owner-test","source":{"file":"seg-teacher.md","route":"Qwen3.5 27B, level flag all","attribute":"flagged per 100 pages","value":"86.8"}},
  "letters.gap_acc":{"value":67.4,"n":175,"truth":"owner-locked","source":{"file":"seg-boxes-score.md","route":"Qwen3.5 27B teacher, Sasha","attribute":"gap accuracy","value":"67.4%"}},
  "manuscripts-public":{"value":40.6,"n":261,"truth":"lincoln-audit","source":{"file":"seg-lincoln-cloud.md","route":"Qwen3.5 27B teacher, FarmShare","attribute":"pages exact","value":"40.6%"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":null},
 "time":{"per_unit_s":1.67,"per_window_s":5.0,"measured":true,"measured_on":"one L40S, FP8, per window","derived":"seconds a seven-page window call over 3, a window every 3 pages at stride 3","source":{"file":"seg-window-modality.md","route":"Teacher","attribute":"s a window","value":"5.0"}},
 "memory":{"peak_gb":null,"measured_on":null,"source":null},
 "caveats":["its confidence flags every gap (seg-teacher.md)","the students' teacher, a relative of them, not an independent route (seg-students.md card)"],
 "kind_rules":[],"fallback":"manual","conditions":["useful as a disagreement partner for the 2B, not as a voter alone (seg-adapt-curve.md)"]},

{"id":"seg-2b-lora-k200","name":"The 2B adapted to your material (LoRA continuation on a cluster after about 200 corrected gaps)","family":"kit","app_route":null,"status":"after-training","licence":"Apache-2.0, its base model's (Qwen3.5 2B); the Mac build is converted with mlx-vlm (MIT)","needs":{"key":[],"plan":[],"cluster":true,"mac_gb":16,"gpus":1},
 "figures":{"manuscripts-public.next_box":{"value":86.8,"n":244,"truth":"Lincoln box 2: catalogue starts plus Gemini 3.7 continuation calls (lincoln2.json)","metric":"pages exact; corpus 2B 52.1%","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 200, box 2","attribute":"pages exact","value":"86.8%"}},
  "manuscripts-public.next_box_errors_per_100":{"value":4.9,"n":244,"truth":"as above","metric":"errors per 100 gaps; corpus 2B 17.2; change -12.3 (-18.8 to -7.4)","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 200, box 2","attribute":"errors per 100 gaps","value":"4.9"}},
  "manuscripts-public.next_box_errors_per_100_k50":{"value":15.6,"n":244,"truth":"as above","metric":"errors per 100 gaps; change -1.6 (-4.5 to +1.2), a tie","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 50, box 2","attribute":"errors per 100 gaps","value":"15.6"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":null,"price_read":null,"source":{"file":"seg-adapt-lora.md","route":"What this means","attribute":"cost","value":"about 1.4 GPU-hours on Sherlock; $0.45 gateway for box 2's truth only"}},
 "time":{"per_unit_s":null,"measured":false,"measured_on":"training 15 and 54 minutes on one Sherlock GPU; serving as the 2B","source":{"file":"seg-adapt-lora.md","route":"What this means","attribute":"training","value":"15 and 54 minutes"}},
 "memory":{"peak_gb":null,"measured_on":"unmeasured: an adapter or merged continuation on the Mac was not measured; the shipped 2B 8-bit it continues peaks at 4.4 GB on the M3 Pro (seg-students.md); Mac training not measured to fit (P9-12)","source":null},
 "caveats":["the pre-set rule (no loss of start recall) is not met: at k = 200 each box loses one start (box 2 finds 67 of 69 catalogue starts against the 2B's 68)","one material (Lincoln correspondence), two adjacent boxes, one training seed","box 2's truth holds no scored start inside an item (P9-8)","k = 50 buys a tie on box 2 and loses two catalogue starts there"],
 "kind_rules":["per material: the next boxes of the material the corrections came from"],"fallback":"seg-qwen3.5-2b-8bit",
 "conditions":["the fine-tuning answer is 'on a cluster' (14-owner-calls.md call 7)","at least 200 corrected gaps of one material in the review records (trigger: note 07)","labelled 'measured on one material'","review flagging by disagreement with a second model stays on after adaptation","the kit's gate passes on a held-out box of the same material holding at least 267 known gaps (owner-ruled or tagged) beyond the 200 corrected, its interval resampling that box's documents (note 12, seg-kit-gate.md)"]}
]
```

Not given rows: GPT-5.6 Luna (83.0%, 86.2 checks, $1.90) and Qwen3.5 Flash (76.1%) are in figures.json from cheap-models.md
but not in the app's voter catalogue (`SegmentationApproach.swift` `WindowVoter.catalog`) [M]; whole-folder Gemini
(82.7% on test, seg-scorers.md) is not a route the app runs. Few-shot examples in the cloud prompt are not a row:
no measurable gain at 1.43x to 2.01x the input tokens (seg-adapt-fewshot.md finding 3) [M]. The adaptation row
`seg-2b-lora-k200` is one row shared with note 12, the same JSON in both notes.

Fields used beyond 00-index.md's schema: figure keys of the form `kind.attribute`; `metric` inside a figure (the
adaptation row).

## 5. Caveats carried

- SEG-1 and P4-2: SC0122's agreed stratum was drafted from tags and the scored teacher. Respected: the
  `clippings-mixed` figure is the owner-ruled weighted one (30 disputes, 60 controls; 0 of 60 wrong, 0.0-7.0%
  weighted interval, seg-truth-rescore.md); the all-known 98.4-99.5% is a diagnostic. All routes tie there.
- SEG-2, SEG-3: the owner ruled the ambiguous CREST and Lincoln gaps. CREST no longer ranks routes (88.3-89.1%, a
  tie, seg-truth-rescore.md); Lincoln's drop holds (cloud 86.2-90.4%, open 35.6-49.8%). Respected: CREST is shown, not
  used to rank; Lincoln drives kind rule (c) only.
- SEG-4: the stated letter cue c2 has no measured effect; no row or rule uses it.
- SEG-5: the students' 97.6% is agreement with the teacher on agreed gaps. Not quoted anywhere here.
- SEG-6: checkpack label noise 5.3% (agree rule), carried for stage 12.
- SEG-7 with R-11 (measure-reviews/2026-10-31.md): the article-within-issue rule touches 4 Stanton gaps, 5 pages,
  and the owner re-ruled them; the test-box figures are the rescored ones. The magazine prompt redo remains.
- SEG-8: the three locked boxes are scored (seg-boxes-score.md); they carry the per-box rows above.
- SEG-9: 3.7 and 3.8 sit 5-8 points apart on a box and are level overall (seg-window-gateway.md). Respected: two
  separate Gemini rows; a 3.7 figure appears on the 3.8 card only labelled as 3.7's (14-owner-calls.md call 8).
- SEG-10 and the pass-7 note (P7-4): the app's five cloud figures are single Gemini 3.8 runs with no measured range;
  3.7's offset range at the 3.8 level is 83.0-85.2% no checking and 25.9-27.3 checks. Respected: a caveat string on
  the 3.8 row; 14-owner-calls.md call 8 declined the 3.8 offsets run. P7-4's cost point: settled 3.7 range $3.56-$3.59, used in the 3.7 row.
- SEG-11 to SEG-15: minor, hold. SEG-12 (text-only 2B off its training shape) is why no text-only 2B row exists;
  SEG-13 (8-bit "most accurate" within noise) does not change the build.
- P2-1: the kit checker's missing-comparison hole; the LoRA row's condition names the gate, which stage 12 owns.
- P2-2: unsure gaps are out of boundary counts (W46.seg-unsure-mask); Lincoln and CREST segment figures stay
  conditional, stated in the truth tags.
- P2-3: regenerated reports carry current truth. Found here: `ensemble-test.md` still shows pre-fold Stanton
  figures (Claude 86.8%, against 84.8% in options.md and seg-truth-rescore.md) [M]; item 5. No row cites it.
- P2-4: shared errors are overlap, not a ceiling; nothing here forecasts a second teacher.
- P7-1: seg-window-gateway's side claims softened; the text-only row uses the -2.7 (-9.5 to +1.6) tie and the paired
  difference of losses (+5.6, -2.9 to +13.2), not resolved.
- P8-4: the newsletter pair is merged by every cloud route with or without the magazine rule, and only the 2B splits
  it (new 1.000). Respected: the 3.8 caveat says so; the redo is "the first thing to try", not a fix.
- P9-8: box 2 of the LoRA test has no scored internal start; carried as a caveat on `seg-2b-lora-k200`.
- P9-9 and P10-10: TABME++ reads "does not transfer as it stands"; the 2B's card says zero-shot, about the teacher's
  quality on one public set, never the owner's figures as expected accuracy.
- P10-8: on TABME++ Gemini leads the teacher and ties the students; no Gemini segmentation rerun floor exists.
- P6-4 and P9-12: no Mac-against-cluster training claim; Mac LoRA fit is "not measured to fit".

## 6. What would change the rule

- A 3.8 offsets run on the test boxes (declined for now, 14-owner-calls.md call 8): if its range moves the 3.8 pages exact more
  than 4.2 points from 88.8% (3.7's g2 figure, the card's), the cheap-API and premium picks are rechecked. The card
  already shows 3.7's g2 range, 88.8-89.1% over three offsets (W46.seg-g2-offsets, seg-g2-offsets.md).
- A measured offset range for any other route, Claude's w1 first (it waits on W46.gateway-models-ok): it replaces
  the borrowed 2.1 for that route's pairs, and the floor becomes per pair.
- The text-only Gemini window on the test boxes within 3.2 points of the image window, at about half the tokens
  (seg-window-gateway.md, 46% of the cost on dev): a text tier row becomes `shipped` for a budget setting.
- W46.seg-magazine-rule-redo (done 2026-11-10, seg-magazine-rule.md): on Gemini 3.7, g2 splits Stanton 101|102 and
  102|103 and the route's unflagged count falls from 2 to 0 (pages exact 85.2% to 88.8% no checking, 98.5% to 100%
  after). The app sends it since W46.seg-magazine-rule-app (seg-magazine-rule-app.md), so Gemini 3.8's `magazine`
  figure ranks, labelled as 3.7's; a ChatGPT figure ranks once c1 states the rule.
- A handwritten manuscript owner box locked and scored: the manuscript warning would then rest on owner material, not
  Lincoln, and may change kind rule (c).
- A second material for the LoRA test with start recall held: the "measured on one material" label goes; a loss of
  starts larger than one a box withdraws the offer.
- A measured checking time other than 20 s a boundary changes every after-checking figure the solver shows.
- A Gemini price above $3.61 list per 1,000 pages after 31 Dec 2026 ($7.22, options.md) keeps the ranking (the
  accuracy lead is over the floor) but changes "cheapest within a point" picks [I].

## 7. Owner calls

Every call below was decided on 2026-11-06 (14-owner-calls.md); each ends with its decision.

1. **Adaptation rule (queued from the 2026-11-06 Daemon Report).** Question: offer the LoRA continuation after about
   200 corrected gaps, flagging kept on? Evidence: box 2 errors 17.2 to 4.9 per 100 gaps (-12.3, -18.8 to -7.4),
   pages exact 52.1% to 86.8%, against a rerun move of +1.4; k = 50 a tie (-1.6); at k = 200 each box loses one
   start, at k = 50 box 2 loses two catalogue starts (86|87 and 219|220) and box 1 none; one material, one seed, box 2
   truth from Gemini 3.7 with no internal start (seg-adapt-lora.md, P9-8). Options: (a) offer at about 200 to cluster
   profiles with flagging on and the kit gate; (b) hold until a second material is tested; (c) never. Decided (owner,
   14-owner-calls.md call 7): (a), to cluster profiles, labelled "measured on one material"; item 7 tests (b)'s case.
2. **Text-only cloud window as a cheaper tier.** Evidence: -2.7 points (-9.5 to +1.6) on 551 dev pages, $0.89 against
   $1.92 for 187 windows, 4.6 s against 6.7 s a call (seg-window-gateway.md); on TABME++ text-only is +0.4 to +3.0
   boundary F1 (seg-tabme-gateway.md). Not run on the test boxes. Options: (a) file the test-box run (Gemini 3.7 on
   the gateway; an image offset cost $1.3016 for 363 pages, measure-reviews/2026-11-04.md, and text alone cost 46% of
   the image arm on dev [M]) and decide then; (b) ship now as a budget tier; (c) drop. Decided (session, section 2):
   (a), filed as a test-box run before any tier is offered.
3. **The review rule.** Evidence: for the 2B, disagreement with a second model beats its own confidence (Stanton at
   10 checks: cloud partner 90.5%, teacher 86.0%, 2B confidence 82.7%, random 77.0%; Lincoln to 98%: 54.8 against
   96.2), and the teacher fails on Lincoln (seg-adapt-curve.md finding 3). For the cloud routes their own confidence
   already flags at 10.2 (Claude) and 24.2 (Gemini) per 100 pages (options.md). Options: (a) disagreement rule for the
   2B when a partner is feasible, own level otherwise, cloud routes unchanged; (b) disagreement for every route
   (needs two voters, so cost doubles, and the mix shows the models err alike); (c) confidence everywhere.
   Decided (session, section 2): (a).
4. **The app's cloud default, and whether 3.7 or 3.8 figures stand for it.** The app starts a user on Gemini 3.8 when
   a key is set (`SegmentationApproach.preferredDefault`), and its doc comment still quotes the pre-rescore 88.8% and
   "none wrong after checking" [M]. The 3.8 figures are single runs (P7-4); every locked-box and public figure is 3.7.
   Options: (a) keep 3.8 as the default and run the 3.8 offsets on the direct key (about 726 pages, about $2.60 at
   list, P7-4); (b) show the 3.7 range labelled as 3.7; (c) show the 3.8 single run as is. Also: whether Sasha's 3.7
   lead over the 2B (96.0 against 89.7 gaps, p 0.019) may stand on the 3.8 card. Decided (owner, 14-owner-calls.md
   call 8): no offsets run; 3.8 stays the default; its card shows 3.7's range labelled as 3.7's and the 3.8 run as a
   single run; the Sasha lead stands on the 3.7 card only.
5. **The magazine rule redo (shown settled in its order).** W46.seg-magazine-rule-redo waits on
   W46.seg-boxes-sir-article and W46.review-done (.maintenance/AUTONOMOUS_PLAN.md). Open was whether the sheet shows
   the magazine kind before then. Decided (session, section 2): shown with "ranks nothing yet", per kind rule (a).
6. **The checking-time assumption.** 20 s a boundary, unmeasured (12-settings-design.md §3.9). Options: (a) keep the
   assumption, labelled, and file a timing measure from the app's review screen in an owner session after the magazine
   redo; (b) show checks per 100 pages only. Decided (session, section 2): (a).
7. **The laptop route and when it is offered.** Evidence: 80.3% unchecked, 78.8 checks, 98.8% after (options.md);
   Sasha gaps 89.7% against Gemini 3.7's 96.0% and pages exact 37.4% against 82.2% (seg-boxes-score.md); Lincoln
   35.6%; TABME++ 0.814 boundary F1, the teacher's quality (seg-tabme.md); 4.4 GB peak, 16 GB Mac has room, 8 GB
   unmeasured (seg-students.md). Options: (a) offered to every 16 GB Mac with no key, card "zero-shot on your
   material; the owner's figures are not a forecast", the manuscript warning, and a cloud voter recommended when a
   key appears; (b) also offered beside a cloud voter as the disagreement partner; (c) only after the kit gate.
   Decided (session, section 2): (a), and (b) as an option, not a default.
8. **The tie threshold.** The floor is a range (1.4-3.2 points a box). Applying 3.2 to pooled figures makes Claude
   plan (85.5%) tie Gemini 3.8 (87.3%) and the plan route win on cost. Options: 3.2, 1.4, or the per-box rule.
   Decided (session, section 2): 3.2, the top of the rerun floor, until a measured range exists [I]. Replaced by
   W46.seg-g2-offsets (2026-11-13): twice the larger measured offset range, 4.2 points (section 3, Tie rule).

## 8. Items to file

1. `W46.seg-38-offsets`: not filed. The owner declined the personal-key spend (14-owner-calls.md call 8); the 3.8
   card carries 3.7's labelled range instead.
2. `W46.seg-text-tier-test`: Gemini 3.7 text-only K = 7 on Stanton and RG165 at the frozen level; done is the five
   figures and a per-1,000-page cost. Small, gateway, under $3 [I]. No blocker (call 2 decided).
3. `W46.seg-check-time`: time a person checking flagged gaps on the review screen; done is seconds a boundary with n.
   Small, owner session. Waits on W46.seg-magazine-rule-redo.
4. `W46.seg-figures-fix`: figures.json `unflagged_per_500` holds counts (Claude 3, Gemini 2) where options.md gives
   4.1 and 2.8 per 500 [M]; GLM batch $0.46 against options.md "none"; the 2B's 6.8 GB against 4.4 GB peak; needs
   list Gemini under `openrouter` though the app's Gemini voter is provider `.gemini` only [M]. Offline, $0.
5. `W46.seg-stale-copies`: `ensemble-test.md` rescored or marked superseded; `SegmentationApproach.swift`'s
   preferredDefault comment updated to 87.3% and 98.5%. Offline, $0.
6. `W46.seg-locked-plans`: Claude (plan) and the Claude and ChatGPT mix on Sasha, the Illustrated Review and SC0122;
   done is rows for the plan routes on the locked boxes. Medium, plan usage, no money. No blocker.
7. `W46.seg-adapt-second-material`: the LoRA test on a material unlike Lincoln (an owner box pair) with a second
   seed and internal-start truth; done is the start-recall rule tested. Medium, Sherlock. No blocker (call 1 decided).
8. The draft's `W46.seg-clippings-box` is dropped: SC0122 is the review's clippings box (individual clippings taken
   in a reading room, mixed with other papers, 61% clipping-tagged; STATE.md "Locked boxes named"), locked and scored
   as `clippings-mixed`, so no further box is needed for the kind.
9. `W46.seg-enclosure-truth`: the A to D cover-to-enclosure truth (10-gap-audit.md, segmentation paragraph) so
   enclosure handling is scored, not inferred from two gaps. Medium.
10. `W46.seg-mac-8gb`: the 2B on an 8 GB Mac beside the app. Small. No blocker.
11. Gaps for the table: cloud seconds a page (every cloud row `measured: false`), cluster memory peaks, a per-1,000-
    page figure for the text tier, the 4B and teacher review loads under the disagreement rule on the test boxes,
    Mac memory for the adaptation row served as an adapter.

## 9. Profile test expectations

Pooled test boxes unless named; zero checking budget unless named; tie under 4.2 points (twice the larger offset
range, section 3), cheaper wins.

- **Laptop, 16 GB.** `seg-qwen3.5-2b-8bit` (80.3% against manual's none; $0; 4.4 GB). Manuscripts: same pick with the
  warning (35.6%). Letters: same (89.7% gaps). Magazine: same, shown with "ranks nothing yet". Clippings mixed: same
  (98.1%, a tie with every route).
- **Laptop, 32 and 64 GB.** `seg-qwen3.5-2b-8bit`; the teacher as a local partner is not a row (seg-adapt-curve.md
  calls it "local on a 32 GB Mac", unmeasured there) [?]. 8 GB: `manual`.
- **Cheap API (OpenRouter only).** `glm5.3-flash` (80.6%, $1.16) against the 2B (80.3%): a tie, and the 2B wins on
  cost if the Mac has 16 GB [I]; without the Mac's memory, GLM. Manuscripts: no GLM figure, so the sheet shows the gap.
- **Premium API (Gemini key).** `gemini3.8-flash` (88.8%, 88.8-89.1% over three offsets, $3.61; Gemini 3.7's g2
  figures, labelled as 3.7's) over GLM (80.6%) and the 2B (80.3%), beyond the 4.2 floor. With full checking: 100.0%. Letters: no 3.8 figure; the 3.7 figure 96.0% gaps is shown on the card labelled as 3.7's
  and decides no pick.
- **Plans.** Claude only: `claude-sonnet5.5` (85.5%, 10.2 checks). Both plans: `mix-claude-chatgpt` (90.9%, 10.2
  checks) over Claude alone (85.5%), 5.4 points, beyond the 4.2 floor. Claude plan and a Gemini key: Gemini's
  88.8-89.1% over three offsets against Claude's 85.5 is 3.3 to 3.6 points, under the 4.2 floor (Claude has no
  measured range and is held to the largest, 2.1), so a tie and the plan route wins on money (W46.seg-g2-offsets; on
  the 3.2 floor, W46.seg-magazine-rule-app had picked Gemini by 0.1). Claude's w1 carries no article rule, which g2
  states, so a like-for-like Claude arm (W46.gateway-models-ok) could move the gap either way.
- **Cluster.** `seg-qwen3.5-2b-bf16-cluster`: 80.3% against the 4B's 80.0% and the teacher's 81.5%, ties, and the 2B is
  fastest (0.5 s a window); on Sasha it leads the teacher by 21.7 points on gap accuracy (44 gaps against 6, p 3.24e-08,
  seg-kit-gate-sherlock.md).
- **A cluster profile, with or without a coding agent.** After about 200 corrected gaps on a box: `seg-2b-lora-k200`
  for the next box of that material, flagging on (box 2 86.8% against 52.1%), labelled "measured on one material", once
  the kit gate passes. A profile with a coding agent and no cluster does not see it (note 12 §3).

## Owner's calls (2026-11-06)

From 14-owner-calls.md. The owner's own calls bearing on this stage:
- **Call 7, the kit's scope.** Adaptation after about 200 corrections of one material is offered to cluster profiles,
  flagging kept on, labelled measured on one material, every model past the gate; no Mac segmentation LoRA. Section
  3's adaptation rule now states this as the rule; the row `seg-2b-lora-k200` is shared with note 12, which owns the
  kit part.
- **Call 8, the Gemini 3.8 offsets.** Declined: no 3.8 offsets run and no personal-key spend. Gemini 3.8 Flash stays
  the app's segmentation default; its card shows Gemini 3.7's range labelled as 3.7's and the single 3.8 run as a
  single run. Sasha's lead over the 2B stands on the 3.7 card only. Item 1 is withdrawn.

Picks the session took on this note's recommendations (section 2, owner may veto): the text-only cloud window is a
filed test-box run on the gateway (about $1.30) before any tier is offered; the review rule is disagreement with a
second model for the 2B when a partner is feasible, own confidence otherwise and for the cloud routes; the magazine kind
is shown with "ranks nothing yet" until W46.seg-magazine-rule-redo; the 20 s checking-time assumption is kept, labelled,
with a timing measure filed for an owner session after the redo; the 2B is offered to every 16 GB Mac with no key with a
zero-shot card and the manuscript warning, and as an optional disagreement partner beside a cloud voter; the tie
threshold is 3.2 points, the top of the rerun floor, until a measured range exists (replaced 2026-11-13 by twice the
larger measured offset range, 4.2 points: W46.seg-g2-offsets, section 3).

Files read: execution-plans/processing-review/00-plan.md (1-105), STATE.md ("Locked boxes named"); the worktree's
13-stage-rules/00-index.md and 14-owner-calls.md; segbench-results/seg-kit-gate-sherlock.md (paired table);
settings-design/figures.json, build_figures.py; segbench-results/options.md, seg-boxes-score.md,
seg-boxes-score-local.md, seg-truth-rescore.md, seg-window-gateway.md, seg-window-modality.md, seg-lincoln-cloud.md,
seg-lincoln-gateway.md, seg-adapt-lora.md, seg-adapt-curve.md, seg-adapt-fewshot.md, seg-context.md, seg-scorers.md
(dev, test, Lincoln, CREST tables), seg-students.md, seg-tabme.md, seg-tabme-gateway.md, public-segmentation.md (head),
ensemble-test.md, window-claude-report.md (agreement and review load), SUMMARY.md (headline), seg-teacher.md and
cheap-models.md (grepped rows); A-segmentation.md (sections named); 11-measurement-audit.md lines 312-377;
measure-reviews R-11, P2-1 to P2-5, P4-2, P6-4, P7-1, P7-4, P7-5, P8-4, P8-6, P9-8, P9-9, P9-12, P10-8, P10-10 and the
section-1 segmentation rows of passes 4, 7 and 9; 12-settings-design.md §3.3 and §3.9; 10-gap-audit.md (segmentation
paragraph, fix 5); .maintenance/AUTONOMOUS_PLAN.md (seg-adapt-lora entry, W46.seg-magazine-rule-redo);
ArchiveProcessor/macOS/Sources/ArchiveProcessor/Segmentation/SegmentationApproach.swift (default and voter catalogue).
