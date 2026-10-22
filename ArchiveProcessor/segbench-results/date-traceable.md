# Dating: the staged pipeline against one shot, with the evidence checked (W46.date-traceable)

Written by `scripts/segbench/date_traceable.py score`. The owner's 300 (W41's sample: 119 print their year, 131 do not, 50 decade tags) and the public 300 (Library of Congress By the People transcriptions, catalogue dates). Classes are date_truth's: A the previous document prints the same year, A' chained through it, B a printed same-year document within three, C four or more away, D none in the folder. $0: the 27B ran on FarmShare, the 2B's replies are W41's cached ones; the Gemini arm is W46.date-traceable-paid, the claude -p arm waits for W46.gateway-models-ok.

## Stage 1: rule candidates

Every date printed in the first 3,000 characters (full dates, numeric dates, month-year, bare years 1800-2030), each with its line. The pick is the first dated form in the first 15 lines, else the most weighted year. Sure = every dated form agrees; ambiguous = the chooser's cases.

| set | class | n | any candidate | truth among them | pick right | sure (right) | single (right) | ambiguous (right) | latest-year rule right |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| owner | in text | 119 | 119 | 119 | 106 (89.1%) | 63 (60) | 27 (27) | 29 (19) | 110 (92.4%) |
| owner | A | 33 | 6 | 1 | 1 (3.0%) | 3 (1) | 2 (0) | 1 (0) | 1 (3.0%) |
| owner | A' | 7 | 2 | 2 | 1 (14.3%) | 1 (1) | 0 (0) | 1 (0) | 1 (14.3%) |
| owner | B | 35 | 10 | 0 | 0 (0.0%) | 4 (0) | 2 (0) | 4 (0) | 0 (0.0%) |
| owner | C | 35 | 14 | 0 | 0 (0.0%) | 1 (0) | 6 (0) | 7 (0) | 0 (0.0%) |
| owner | D | 21 | 5 | 1 | 0 (0.0%) | 2 (0) | 0 (0) | 3 (0) | 0 (0.0%) |
| owner | rule time | | | | 0.38 ms a document on this Mac | | | | |
| public | in text | 257 | 255 | 255 | 236 (91.8%) | 170 (166) | 46 (46) | 39 (24) | 237 (92.2%) |
| public | not in text | 43 | 16 | 8 | 8 (18.6%) | 11 (8) | 3 (0) | 2 (0) | 8 (18.6%) |
| public | rule time | | | | 0.23 ms a document on this Mac | | | | |

## One shot, owner set (exact year)

The app's prompt (cached W41 replies) and the trace prompt sent to every document.

| configuration | in text | A | A' | B | C | D | not in text | decade | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gemini-3.8-flash | 97.5% | 81.8% | 71.4% | 62.9% | 45.7% | 61.9% | 63.4% | 68.0% | 92.7% | 0/300 | none asked | – | 92.4%, 3.0 y |
| qwen3.6-27b-nothink (app prompt) | 97.5% | 66.7% | 71.4% | 40.0% | 20.0% | 33.3% | 42.0% | 58.0% | 81.3% | 0/300 | none asked | – | 91.6%, 11.0 y |
| mlx-date-2b-8bit-nothink (app prompt) | 95.0% | 69.7% | 71.4% | 37.1% | 11.4% | 28.6% | 38.9% | 56.0% | 81.3% | 0/300 | none asked | – | 92.4%, 16.0 y |

## The staged pipeline, owner set (exact year)

t = the escalation threshold: a document printing no date takes the year of the nearest earlier document printing one when that is at most t documents back, else goes to the residue stage. t=0 sends every undated document there; t=3 only those propagation cannot reach (it looks three back). A row with no residue stage gives no year to what propagation does not reach.

| configuration | in text | A | A' | B | C | D | not in text | decade | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rules only|no residue stage|t=3 | 89.1% | 75.8% | 71.4% | 20.0% | 5.7% | 9.5% | 31.3% | 30.0% | 66.0% | 19/300 | 270 / 11 | 6 | 90.8%, unbounded (12 with no year) |
| 2B chooser|no residue stage|t=3 | 95.0% | 75.8% | 71.4% | 20.0% | 5.7% | 14.3% | 32.1% | 30.0% | 68.7% | 19/300 | 269 / 12 | 7 | 90.8%, unbounded (12 with no year) |

## One shot, public set (exact year)

The app's prompt (cached W41 replies) and the trace prompt sent to every document.

| configuration | in text | not in text | all | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mlx-date-2b-8bit-nothink (app prompt) | 95.3% | 90.7% | 94.7% | 97.3% | 0/300 | none asked | – | 93.0%, 2.0 y |

## The staged pipeline, public set (exact year)

t = the escalation threshold: a document printing no date takes the year of the nearest earlier document printing one when that is at most t documents back, else goes to the residue stage. t=0 sends every undated document there; t=3 only those propagation cannot reach (it looks three back). A row with no residue stage gives no year to what propagation does not reach.

| configuration | in text | not in text | all | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rules only|no residue stage|t=3 | 91.8% | 18.6% | 81.3% | 83.7% | 29/300 | 258 / 13 | 10 | 37.2%, unbounded (27 with no year) |
| 2B chooser|no residue stage|t=3 | 96.1% | 18.6% | 85.0% | 86.7% | 29/300 | 259 / 12 | 10 | 37.2%, unbounded (27 with no year) |

## Cost

GPU-seconds a reply: the job's measured wall time on one L40S (16 requests at once), shared over the arms by tokens. A configuration's cost per 1,000 documents is its calls times these; the 2B chooser runs on the Mac at 1.39 s a document. No money on any arm.

| arm | replies | GPU-seconds a reply |
|---|---:|---:|
| choose | 0 | – |
| trace-plain | 0 | – |
| trace-neigh | 0 | – |
| trace-shots | 0 | – |

| configuration | 27B calls per 1,000 | GPU-seconds per 1,000 | Mac seconds per 1,000 |
|---|---:|---:|---:|
| owner|rules only|no residue stage|t=3 | 0 | 0 | 0 |
| owner|2B chooser|no residue stage|t=3 | 0 | 0 | 260 |
| public|rules only|no residue stage|t=3 | 0 | 0 | 0 |
| public|2B chooser|no residue stage|t=3 | 0 | 0 | 190 |
