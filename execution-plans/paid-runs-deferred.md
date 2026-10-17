# Paid runs deferred to the end of the queue

Owner, 2026-10-17: no more paid hosted benchmarking for now; open-weight models on FarmShare first. Paid hosted runs
wait for W43.sweep at the end of the queue, which starts with a full price estimate over every line below and asks
the owner before spending (gate W43.sweep-owner-ok).

**The rule:** any session that wants a paid hosted run and does not do it because of this hold adds a line here, in the
same commit as the decision, naming the run, the item it came from, the pages or windows, and the cost estimate if it
has one. W43.sweep prices and runs this list; the line is deleted only when its run lands (git keeps the history).

| run | from | what it covers | estimate so far |
|---|---|---|---|
| Reference routes on the new public strata (L1, L4, N2, N5, N6, short L2/L3/L9) | W43.corpus-build-more | the two reference routes over each new stratum's frozen pages | about $0.0066 a page for the two routes (that item's figure) |
| Reference routes and voters on the CIA CREST and Lincoln Papers segmentation boxes | W43.seg-corpus-build | the public segmentation boxes, scored as `options.md` scores | none yet |
| The hosted model sweep on the broadened bench | W43.sweep | every hosted OCR, segmentation and handwriting candidate on the public strata and the owner-corpus benches | none yet |
| Hosted models made for hard scripts and hands | W43.script-specialists | the strata the bench reads worst, with any hosted specialist that item lists | none yet |
| Gemini 3.8 Flash on the dated public set, and with thinking off or minimal | W41.date-model | the dating baseline on outside documents; whether turning thinking down keeps accuracy (it is about 40% of the cost) | about $1.22 per 300 documents at the current setting (`date-tagging.md`) |
