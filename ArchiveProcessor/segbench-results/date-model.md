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
unchanged memory guard in 7 seconds (9.625 effective bits/weight); its Mac measurement is in progress.

Source numbers: `date-tagging.json` / `date-tagging-public.json`. Full setup, model revisions, source decisions
and raw-output locations: `execution-plans/farmshare-interactive-20261018.md`. Training outputs and raw test
answers are kept in the task's Long term storage folder and the isolated FarmShare run. No money spent.
