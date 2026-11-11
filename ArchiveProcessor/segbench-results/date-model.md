# Dating fine-tunes (W41.date-model)

Two Qwen3.5 models (2B and 4B), one epoch of LoRA on 7,428 text-only examples: 3,714 owner-corpus documents
and 3,714 dated public documents. Whole collections/projects held out; 1,374 validation examples retained;
test documents and neighbours containing their snippets excluded from training. Corpus targets omit subjects
and day (the owner did not tag days); public targets supply year/month/day at the catalogue's precision.
Date Uncertain follows the owner's tags, not the specification's different rule. Seed 41, rank 16, LR 1e-4,
accumulation 8. The existing trainer performs 928 updates and drops its incomplete last accumulation (4 rows).

Exact app prompts, three neighbour snippets, 512 output tokens, temperature zero, thinking off. The two
single-task recipes were fixed before testing. Scores use the existing app-response parser. All 300 replies
per model/bench are present, parseable and below the output cap. No paid Gemini public baseline was run.

| model | corpus year (250) | corpus month (120) | public year (300) | public month (240) | public day (150) | full public date (150) |
|---|---:|---:|---:|---:|---:|---:|
| trained 2B | 66.8% | 63.3% | 95.0% | 93.3% | 92.7% | 90.7% |
| trained 2B, Mac 8-bit | 65.6% | 65.0% | 94.7% | 93.3% | 93.3% | 91.3% |
| trained 4B | 66.4% | 70.0% | 97.0% | 93.3% | 92.0% | 90.0% |
| untrained 2B | not rerun | not rerun | 93.7% | 83.3% | 53.3% | 49.3% |
| untrained 4B | existing baseline | existing baseline | 95.0% | 12.9% | 71.3% | 8.7% |

For comparison, Gemini on the same owner-corpus test gets 79.6% of years right and 63.4% where the year is
not printed. The trained 2B reaches only 41.2% (54/131) on those inferred years; the 4B 40.5% (53/131).
Neither trained model marks Date Uncertain on any of the 50 owner-uncertain documents. A low training loss
is not evidence that this task was learned. These models are not recommended as the app's default tagger.

The public-set full-date improvement is real on this fixed test, but includes learning the app's exact
response format: the untrained 4B often emits a month the app parser cannot retain. Year-only catalogue
records are not full truth about every date printed in a document. The 2B gives a day on 96/150 records
whose catalogue lacks one; the 4B 90/150. Those are disclosed separately, not automatically called invented.

The 2B is the fixed local/combined-model reference: corpus-year accuracy is essentially tied (one document),
it is smaller and faster, and its public full-date score is at least as good. The 4B's better corpus-month
figure and public-year figure are retained above; no claim of a statistically significant overall winner.
The automatic app call already requests and writes the day, so that requested app change is unnecessary.

GPU jobs 1855406 (2B, 35m01 including pilot/merge/tests/base public comparison) and 1855407 (4B, 1h05m28)
completed with exit zero. Full 2B training took 1,624 seconds. The 8-bit MLX conversion passed under the
unchanged memory guard in 7 seconds (9.625 effective bits/weight). The 2.683 GB MLX build completed all
600 test prompts: 416.69 seconds for the corpus and 414.71 seconds for the public set, about 1.39 seconds
per document, with 1.29 seconds to load. Peak MLX memory was 3.784 GB; the guard recorded a 4.549 GB peak
footprint without terminating the run. All responses parsed and none hit the token cap. Compared with
the GPU 2B, quantization loses three owner years (1.2 percentage points) and one public year (0.3 points);
it gains one public day. These small differences do not establish an improvement. Its inferred-year
accuracy is 51/131 (38.9%), and it still identifies none of the 50 owner-uncertain documents.
The Mac test used the same frozen prompts, thinking off, temperature zero and 512 output tokens.

Source numbers: `date-tagging.json` / `date-tagging-public.json`. Full setup, model revisions, source decisions
and raw-output locations: `execution-plans/farmshare-interactive-20261018.md`. Training outputs and raw test
answers are kept in the task's Long term storage folder and the isolated FarmShare run. No money spent.

## Measurement card

- **Truth.** Corpus: the owner's Finder tags on each document's first page (year, month, `Date Uncertain`; the owner tagged no days, so day is not scored there). Public: the catalogue title's date in the Library of Congress By the People package (Letters to Lincoln); bracketed or circa dates count as uncertain, and folder-level items, ranges and undated titles are left out. Year-only catalogue records are not full truth about every date in a document, so the 96 of 150 (2B) and 90 of 150 (4B) days given where the catalogue has none are disclosed, not judged. No scored model drafted either truth. The owner checked nothing for this item.
- **Selection.** Corpus test: the W41 date-tagging sample of 300 (round-robin across collections within each truth class, seed 41; corpus year 250, month 120). Its text is ABBYY's layer, so the corpus prompts were built from ABBYY text, an input banned since 2026-10-30. Public test: 300 documents (150 day, 90 month, 60 year) from 9 projects held out by hash. Training is 3,714 corpus plus 3,714 public rows, whole collections and projects held out, excluding test documents and any training row whose neighbour snippets held test text. No tested route chose the set.
- **Comparison.** Same frozen app prompts, three neighbour snippets, 512 output tokens, temperature 0, thinking off and the same app-response parser for the GPU and Mac 8-bit runs alike; all 300 replies per model and bench were present, parseable and under the cap. The untrained 2B was not rerun on the corpus, and the untrained 4B's corpus row is an existing baseline. The Gemini comparison (79.6% corpus year, 63.4% on unprinted years) is W41's Gemini 3.8 Flash run on the same corpus test; no Gemini public baseline was run. A dating test: its two sets are the owner's corpus and the LoC public set, not the two OCR sets.
- **Noise.** Single runs, one seed (41), one epoch, one recipe; no intervals and no rerun floor. The 2B and 4B corpus years (66.8 against 66.4%) differ by one document, a tie, and no overall winner is claimed. The 8-bit Mac run's differences from the GPU 2B (three owner years, one public year, one public day) do not establish a change.
- **Scope.** It does not show the task was learned: inferred corpus years reach only 41.2% (2B) and 40.5% (4B) against Gemini's 63.4%, and neither model flags any of the 50 owner-uncertain documents. The public full-date gain includes learning the app's response format. One corpus and one public archive. It settles no app default; the report recommends neither model as the default tagger.
