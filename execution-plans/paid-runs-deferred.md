# Paid runs deferred to the end of the queue

Owner, 2026-10-17: no more paid hosted benchmarking for now; open-weight models on FarmShare first. Paid hosted runs
wait for W43.sweep at the end of the queue, which starts with a full price estimate over every line below and asks
the owner before spending (gate W43.sweep-owner-ok).

Owner, 2026-10-21: the W46 processing review's paid arms are released (root CLAUDE.md, the gateway-first rule);
they are not listed here. The rows below that the review's items cover (the CREST and Lincoln reference routes) run
inside W46.seg-lincoln-cloud.

**The rule:** any session that wants a paid hosted run and does not do it because of this hold adds a line here, in the
same commit as the decision, naming the run, the item it came from, the pages or windows, and the cost estimate if it
has one. W43.sweep prices and runs this list; the line is deleted only when its run lands (git keeps the history).

| run | from | what it covers | estimate so far |
|---|---|---|---|
| Reference routes on the new public strata (L1, L4, N2, N5, N6, short L2/L3/L9) | W43.corpus-build-more | Gemini 3.8 Flash and Qwen3-VL 235B on **455 added frozen pages**: L1/L2/L3/L4 80 each, L9 15, N2/N5/N6 40 each (895 public pages total, original 440 already measured) | **about $3.00** for both routes at the original run's measured $0.0066 per page; estimate only, no extension calls made; price afresh for W43.sweep |
| Reference routes and voters on the CIA CREST and Lincoln Papers segmentation boxes | W43.seg-corpus-build | Gemini 3.1 Flash-Lite and Gemini 3.8 Flash, plus the planned Claude subscription reference, on frozen CREST128 pages/44 windows and Lincoln261 pages/88 windows. CPU rules and FarmShare teacher/2B/4B are complete; no new input construction. Same scorer; hosted/subscription readings remain unrun | about $2.60 for ~500 pages was the plan estimate; actual frozen total389 pages/132 windows. Price the two Gemini routes afresh at W43.sweep; Claude uses subscription capacity, no per-call API spend estimate |
| The hosted model sweep on the broadened bench | W43.sweep | every hosted OCR, segmentation and handwriting candidate on the public strata and the owner-corpus benches | none yet |
| Hosted models made for hard scripts and hands | W43.script-specialists | Transkribus public models on the strata the bench reads worst: Text Titan II on L5 and L7 (160 pages), The German Giant I on L6 (80 pages); none for N1, N3 or N4, where no hosted specialist was found. List: `segbench-results/bench-corpus/specialists.md` | Transkribus bills credits, not tokens: 1 credit a handwritten page in the app, half that through the API; 250 credits cost €59.50 on demand, and the Scholar plan (€99 a year) includes 900 credits and the API (Transkribus credit page, 2026-10-17). The 240 pages are about 120 API credits, so the smallest purchase is €59.50, over the $3 limit: the owner decides |
| Gemini 3.8 Flash on the dated public set, and with thinking off or minimal | W41.date-model | the dating baseline on outside documents; whether turning thinking down keeps accuracy (it is about 40% of the cost) | about $1.22 per 300 documents at the current setting (`date-tagging.md`) |
| The OpenRouter panels on the 15 JPEG-original truth pages | W46.truth-jpeg-rest | the local panel's 11 open models and the cloud panel's 12 routes on the 15 pages W46.truth-jpeg-upgrade swapped; the free routes and the gateway Gemini showed no gain from the originals, so nice-to-have | cents for the open models; about $1 for the cloud panel at its measured per-page cost; price afresh |
| The app's tagging call (Gemini 3.8 Flash) on W46.fix-ent-truth's 72 additions | W47.item-fields-truth | fresh tagging replies so the item-field scores (kind, publication, recipient place) cover the role-addressed, unsigned and handwritten letters the 300 lack; the item scored the 145 documents with cached replies and labelled all 219 | about $0.30 at the date-tagging run's $1.22 per 300 documents |
