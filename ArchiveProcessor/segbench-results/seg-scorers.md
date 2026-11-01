# The field's segmentation scorers on every cached answer — W46.fix-seg-scorers

Made by `scripts/segbench/rescore.py` (owner, public, report) from the response caches, with no call and no money: a cache miss is reported as incomplete and the process refuses the network. Definitions are in `score.py`'s docstring; the figures are pooled sums over the boxes named. Window and whole-folder sources take the truth's photo labels, so their figures measure boundaries; the spring runs keep their own. Higher is better except Pk, WindowDiff and MNDD. A source appears in a table only where its cache is complete on every box of that table. On the owner boxes Pk equals WindowDiff: k is half the mean truth segment length, and their documents average about 1.6 pages, so k rounds to 1 with or without the label photos counted, and at k = 1 the two measures are the same; on Lincoln and CREST k is 2.

## Development boxes (Dean, Deaver, Herrnstein; 551 pages)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| whole-gemini | whole folder, Gemini API | 93.1% | 0.941 | 0.026 | 0.026 | 0.963 | 0.969 | 0.994 | 0.950 | 66.7% | 2.7 |
| window-or-fs-seg-4b-pilot | window, FarmShare | 92.5% | 0.929 | 0.031 | 0.031 | 0.940 | 0.945 | 0.995 | 0.929 | 58.3% | 2.9 |
| window-cues-codex | window, subscription | 91.3% | 0.958 | 0.018 | 0.018 | 0.970 | 0.978 | 0.992 | 0.956 | 70.8% | 3.1 |
| window-claude | window, subscription | 90.7% | 0.954 | 0.020 | 0.020 | 0.966 | 0.973 | 0.992 | 0.951 | 70.8% | 3.3 |
| window-gemini-3.8-flash-low | window, Gemini API | 90.7% | 0.941 | 0.026 | 0.026 | 0.960 | 0.965 | 0.994 | 0.947 | 70.8% | 3.6 |
| window-or-fs-seg-2b | window, FarmShare | 90.5% | 0.929 | 0.031 | 0.031 | 0.938 | 0.945 | 0.993 | 0.923 | 58.3% | 3.4 |
| window-local-seg-2b-8bit | window, Mac local | 90.3% | 0.929 | 0.031 | 0.031 | 0.940 | 0.948 | 0.992 | 0.922 | 54.2% | 3.4 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 90.2% | 0.933 | 0.029 | 0.029 | 0.956 | 0.963 | 0.993 | 0.941 | 66.7% | 3.8 |
| window-or-glm5.3-flash | window, OpenRouter | 90.2% | 0.937 | 0.027 | 0.027 | 0.952 | 0.958 | 0.994 | 0.942 | 66.7% | 4.0 |
| window-or-gpt5.6-luna | window, OpenRouter | 90.0% | 0.945 | 0.024 | 0.024 | 0.958 | 0.967 | 0.991 | 0.942 | 66.7% | 3.6 |
| window-local-seg-date-2b-8bit | window, Mac local | 89.4% | 0.921 | 0.035 | 0.035 | 0.935 | 0.941 | 0.993 | 0.919 | 50.0% | 4.2 |
| whole-gemini-c10 | whole folder, Gemini API | 89.4% | 0.941 | 0.026 | 0.026 | 0.954 | 0.962 | 0.991 | 0.937 | 62.5% | 3.8 |
| window-or-fs-seg-4b | window, FarmShare | 89.2% | 0.941 | 0.026 | 0.026 | 0.956 | 0.965 | 0.990 | 0.937 | 58.3% | 3.8 |
| window-local-seg-4b-8bit | window, Mac local | 87.8% | 0.929 | 0.031 | 0.031 | 0.946 | 0.954 | 0.992 | 0.929 | 58.3% | 4.5 |
| spring-v1 | spring 2026 Gemini (own photo labels) | 86.9% | 0.890 | 0.053 | 0.053 | 0.921 | 0.926 | 0.994 | 0.901 | 45.8% | 5.1 |
| window-local-seg-4b | window, Mac local | 86.5% | 0.903 | 0.042 | 0.042 | 0.931 | 0.939 | 0.991 | 0.911 | 54.2% | 4.5 |
| window-local-seg-2b | window, Mac local | 85.5% | 0.889 | 0.049 | 0.049 | 0.910 | 0.923 | 0.985 | 0.881 | 50.0% | 5.4 |
| window-or-qwen3.5-flash | window, OpenRouter | 84.9% | 0.933 | 0.029 | 0.029 | 0.949 | 0.959 | 0.990 | 0.927 | 58.3% | 4.7 |
| window-gemini-3.1-flash-lite-minimal | window, Gemini API | 84.6% | 0.872 | 0.055 | 0.055 | 0.896 | 0.903 | 0.992 | 0.881 | 58.3% | 6.7 |
| spring-v2 | spring 2026 Gemini (own photo labels) | 81.1% | 0.866 | 0.069 | 0.069 | 0.894 | 0.900 | 0.993 | 0.872 | 54.2% | 7.4 |
| spring-baseline | spring 2026 Gemini (own photo labels) | 76.8% | 0.856 | 0.077 | 0.077 | 0.880 | 0.894 | 0.984 | 0.832 | 37.5% | 8.2 |
| window-or-fs-qwen3.5-4b | window, FarmShare | 67.6% | 0.611 | 0.159 | 0.159 | 0.735 | 0.745 | 0.986 | 0.712 | 33.3% | 15.6 |
| rule-cues | baseline | 58.5% | 0.516 | 0.197 | 0.197 | 0.696 | 0.709 | 0.983 | 0.672 | 33.3% | 20.5 |
| rule-cues-sketch | baseline | 57.9% | 0.381 | 0.241 | 0.241 | 0.641 | 0.642 | 0.997 | 0.637 | 29.2% | 24.5 |
| all-new | baseline | 39.2% | 0.000 | 0.365 | 0.365 | 0.486 | 0.486 | 1.000 | 0.486 | 16.7% | 36.3 |
| no-boundaries | baseline | 0.6% | 0.000 | 0.536 | 0.536 | 0.025 | 0.029 | 0.860 | 0.018 | 12.5% | 75.7 |

## Locked test boxes (Stanton, RG165; 363 pages), answers already cached by the finalists' --final runs

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| window-cues-codex | window, subscription | 90.9% | 0.941 | 0.025 | 0.025 | 0.943 | 0.955 | 0.987 | 0.921 | 60.0% | 3.0 |
| window-gemini-3.8-flash-low | window, Gemini API | 87.3% | 0.915 | 0.036 | 0.036 | 0.915 | 0.929 | 0.986 | 0.888 | 53.3% | 4.1 |
| window-claude | window, subscription | 85.5% | 0.896 | 0.044 | 0.044 | 0.909 | 0.925 | 0.982 | 0.871 | 53.3% | 4.1 |
| window-or-gpt5.6-luna | window, OpenRouter | 83.0% | 0.877 | 0.053 | 0.053 | 0.886 | 0.902 | 0.982 | 0.848 | 53.3% | 5.5 |
| whole-gemini | whole folder, Gemini API | 82.7% | 0.909 | 0.039 | 0.039 | 0.909 | 0.925 | 0.983 | 0.877 | 53.3% | 5.2 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 81.5% | 0.840 | 0.069 | 0.069 | 0.847 | 0.862 | 0.983 | 0.817 | 46.7% | 7.4 |
| window-or-glm5.3-flash | window, OpenRouter | 80.6% | 0.882 | 0.050 | 0.050 | 0.902 | 0.918 | 0.983 | 0.856 | 46.7% | 4.7 |
| window-or-fs-seg-2b | window, FarmShare | 80.3% | 0.827 | 0.075 | 0.075 | 0.825 | 0.842 | 0.980 | 0.791 | 60.0% | 7.7 |
| window-or-fs-seg-4b | window, FarmShare | 80.0% | 0.852 | 0.064 | 0.064 | 0.852 | 0.867 | 0.982 | 0.816 | 40.0% | 7.2 |
| spring-v1 | spring 2026 Gemini (own photo labels) | 78.5% | 0.890 | 0.053 | 0.053 | 0.890 | 0.904 | 0.984 | 0.851 | 33.3% | 6.1 |
| window-or-qwen3.5-flash | window, OpenRouter | 76.1% | 0.857 | 0.061 | 0.061 | 0.858 | 0.879 | 0.975 | 0.805 | 46.7% | 7.2 |
| spring-baseline | spring 2026 Gemini (own photo labels) | 57.0% | 0.820 | 0.116 | 0.116 | 0.806 | 0.842 | 0.957 | 0.703 | 0.0% | 12.4 |
| spring-v2 | spring 2026 Gemini (own photo labels) | 55.8% | 0.755 | 0.144 | 0.144 | 0.764 | 0.793 | 0.963 | 0.675 | 6.7% | 13.8 |
| rule-cues | baseline | 33.6% | 0.311 | 0.319 | 0.319 | 0.467 | 0.499 | 0.936 | 0.398 | 20.0% | 31.1 |
| rule-cues-sketch | baseline | 22.4% | 0.096 | 0.449 | 0.449 | 0.314 | 0.317 | 0.989 | 0.308 | 13.3% | 45.7 |
| all-new | baseline | 20.9% | 0.000 | 0.507 | 0.507 | 0.289 | 0.289 | 1.000 | 0.289 | 13.3% | 50.4 |
| no-boundaries | baseline | 8.5% | 0.000 | 0.366 | 0.366 | 0.073 | 0.086 | 0.844 | 0.049 | 26.7% | 68.0 |

## Lincoln (261 pages, 80 documents as stored, 78-81 with its 3 unsure gaps either way)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| window-cues-claude | window, subscription | 90.4% | 0.982 | 0.008 | 0.015 | 0.983 | 0.987 | 0.995 | 0.962 | 0.0% | 0.8 |
| window-cues-claude-cue | window, subscription | 89.3% | 0.972 | 0.008 | 0.023 | 0.966 | 0.969 | 0.996 | 0.945 | 0.0% | 1.1 |
| window-or-fs-seg-4b | window, FarmShare | 49.8% | 0.742 | 0.081 | 0.236 | 0.669 | 0.712 | 0.939 | 0.524 | 0.0% | 12.3 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 40.6% | 0.677 | 0.089 | 0.301 | 0.571 | 0.614 | 0.930 | 0.426 | 0.0% | 15.7 |
| window-or-fs-seg-2b | window, FarmShare | 35.6% | 0.640 | 0.100 | 0.324 | 0.529 | 0.571 | 0.927 | 0.384 | 0.0% | 17.2 |
| window-or-fs-seg-date-2b | window, FarmShare | 33.3% | 0.624 | 0.100 | 0.336 | 0.512 | 0.552 | 0.927 | 0.365 | 0.0% | 18.0 |
| rule-cues | baseline | 16.9% | 0.269 | 0.274 | 0.537 | 0.276 | 0.313 | 0.881 | 0.191 | 0.0% | 39.5 |
| all-new | baseline | 6.9% | 0.000 | 0.452 | 0.931 | 0.105 | 0.105 | 1.000 | 0.105 | 0.0% | 69.0 |
| rule-cues-sketch | baseline | 6.9% | 0.000 | 0.452 | 0.931 | 0.105 | 0.105 | 1.000 | 0.105 | 0.0% | 69.0 |
| no-boundaries | baseline | 0.0% | 0.000 | 0.541 | 0.541 | 0.000 | 0.000 | 0.000 | — | 0.0% | 91.6 |

## CREST (128 pages, 30 documents as stored, 30-34 with its 4 unsure gaps either way)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| window-cues-claude | window, subscription | 89.1% | 0.978 | 0.008 | 0.016 | 0.983 | 0.985 | 0.998 | 0.955 | 0.0% | 0.8 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 88.3% | 0.978 | 0.008 | 0.016 | 0.983 | 0.985 | 0.998 | 0.954 | 0.0% | 0.8 |
| window-or-fs-seg-4b | window, FarmShare | 88.3% | 0.978 | 0.008 | 0.016 | 0.982 | 0.984 | 0.998 | 0.952 | 0.0% | 0.8 |
| window-or-fs-seg-date-2b | window, FarmShare | 85.9% | 0.933 | 0.024 | 0.040 | 0.938 | 0.952 | 0.984 | 0.889 | 0.0% | 2.3 |
| window-or-fs-seg-2b | window, FarmShare | 81.2% | 0.910 | 0.040 | 0.056 | 0.890 | 0.903 | 0.986 | 0.839 | 0.0% | 3.9 |
| rule-cues | baseline | 14.8% | 0.076 | 0.508 | 0.786 | 0.213 | 0.216 | 0.984 | 0.203 | 0.0% | 63.3 |
| all-new | baseline | 10.2% | 0.000 | 0.579 | 0.905 | 0.160 | 0.160 | 1.000 | 0.160 | 0.0% | 73.4 |
| rule-cues-sketch | baseline | 10.2% | 0.042 | 0.540 | 0.857 | 0.169 | 0.169 | 1.000 | 0.169 | 0.0% | 69.5 |
| no-boundaries | baseline | 0.0% | 0.000 | 0.397 | 0.397 | 0.000 | 0.000 | 0.000 | — | 0.0% | 86.7 |

## What the metric choice changes

Pages in an exact document gives a page no credit unless its whole document is right; PQ credits a segment that overlaps its document by more than half. The gap between the two is how much of a box's score the strict metric withholds for near misses.

| box | source | pages exact | PQ | PQ − pages exact | kappa | MNDD per 100 pages |
|---|---|---|---|---|---|---|
| Dean | window-or-fs-seg-4b | 85.2% | 0.942 | +8.9 pts | 0.935 | 5.4 |
| Dean | window-or-fs-seg-2b | 93.9% | 0.952 | +1.3 pts | 0.946 | 2.5 |
| Dean | window-or-fs-qwen3.5-27b | 84.2% | 0.949 | +10.7 pts | 0.934 | 5.4 |
| Deaver | window-or-fs-seg-4b | 92.2% | 0.955 | +3.3 pts | 0.938 | 2.7 |
| Deaver | window-or-fs-seg-2b | 88.7% | 0.898 | +1.1 pts | 0.891 | 4.7 |
| Deaver | window-or-fs-qwen3.5-27b | 96.5% | 0.973 | +0.9 pts | 0.969 | 1.3 |
| Herrnstein | window-or-fs-seg-4b | 91.2% | 0.972 | +6.0 pts | 0.951 | 3.0 |
| Herrnstein | window-or-fs-seg-2b | 88.4% | 0.956 | +7.2 pts | 0.939 | 3.5 |
| Herrnstein | window-or-fs-qwen3.5-27b | 91.7% | 0.949 | +3.2 pts | 0.902 | 4.0 |
| Stanton | window-or-fs-seg-4b | 80.2% | 0.843 | +4.1 pts | 0.841 | 8.4 |
| Stanton | window-or-fs-seg-2b | 75.3% | 0.797 | +4.4 pts | 0.791 | 10.4 |
| Stanton | window-or-fs-qwen3.5-27b | 79.8% | 0.830 | +3.2 pts | 0.816 | 9.2 |
| RG165 | window-or-fs-seg-4b | 79.3% | 0.885 | +9.2 pts | 0.876 | 4.4 |
| RG165 | window-or-fs-seg-2b | 94.3% | 0.929 | -1.3 pts | 0.938 | 1.8 |
| RG165 | window-or-fs-qwen3.5-27b | 86.2% | 0.907 | +4.5 pts | 0.908 | 3.5 |
| Lincoln | window-or-fs-seg-4b | 49.8% | 0.669 | +17.1 pts | 0.742 | 12.3 |
| Lincoln | window-or-fs-seg-2b | 35.6% | 0.529 | +17.3 pts | 0.640 | 17.2 |
| Lincoln | window-or-fs-qwen3.5-27b | 40.6% | 0.571 | +16.5 pts | 0.677 | 15.7 |
| CREST | window-or-fs-seg-4b | 88.3% | 0.982 | +9.9 pts | 0.978 | 0.8 |
| CREST | window-or-fs-seg-2b | 81.2% | 0.890 | +7.8 pts | 0.910 | 3.9 |
| CREST | window-or-fs-qwen3.5-27b | 88.3% | 0.983 | +10.0 pts | 0.978 | 0.8 |

Rank agreement over the 22 non-baseline sources complete on the development boxes (Spearman, against pages in an exact document): PQ 0.772, kappa 0.714, doc F1 0.823, MNDD (negated) 0.967, WindowDiff (negated) 0.743.

## The document-count prior (A-segmentation test 9)

Each source's per-gap P(new) ranked, and exactly `count − streams` document gaps kept as boundaries. Lincoln's count is the catalogue's 72 items (truth: 80 documents as stored, 78-81 with its 3 unsure gaps either way) and CREST's the folder's 22 PDFs (truth: 30 documents as stored, 30-34 with its 4 unsure gaps either way); the oracle uses the stored labels' own count, which no user has, and bounds what a count can buy. Where the box has unsure gaps the oracle count is one point of the range above, not the one true count.

| box | source | count | as answered: pages exact | with the prior | PQ as answered | PQ with the prior |
|---|---|---|---|---|---|---|
| Lincoln | window-cues-claude | 72 (finding aid) | 90.4% | 80.8% | 0.983 | 0.884 |
| Lincoln | window-cues-claude-cue | 72 (finding aid) | 89.3% | 80.1% | 0.966 | 0.898 |
| Lincoln | window-or-fs-qwen3.5-27b | 72 (finding aid) | 40.6% | 46.4% | 0.571 | 0.720 |
| Lincoln | window-or-fs-seg-2b | 72 (finding aid) | 35.6% | 36.0% | 0.529 | 0.549 |
| Lincoln | window-or-fs-seg-4b | 72 (finding aid) | 49.8% | 59.0% | 0.669 | 0.717 |
| Lincoln | window-or-fs-seg-date-2b | 72 (finding aid) | 33.3% | 41.8% | 0.512 | 0.575 |
| CREST | window-cues-claude | 22 (finding aid) | 89.1% | 54.7% | 0.983 | 0.702 |
| CREST | window-or-fs-qwen3.5-27b | 22 (finding aid) | 88.3% | 37.5% | 0.983 | 0.767 |
| CREST | window-or-fs-seg-2b | 22 (finding aid) | 81.2% | 32.0% | 0.890 | 0.694 |
| CREST | window-or-fs-seg-4b | 22 (finding aid) | 88.3% | 53.9% | 0.982 | 0.659 |
| CREST | window-or-fs-seg-date-2b | 22 (finding aid) | 85.9% | 44.5% | 0.938 | 0.693 |
| Lincoln | window-cues-claude | 80 (oracle) | 90.4% | 90.4% | 0.983 | 0.983 |
| Lincoln | window-cues-claude-cue | 80 (oracle) | 89.3% | 90.4% | 0.966 | 0.983 |
| Lincoln | window-or-fs-qwen3.5-27b | 80 (oracle) | 40.6% | 56.7% | 0.571 | 0.779 |
| Lincoln | window-or-fs-seg-2b | 80 (oracle) | 35.6% | 50.2% | 0.529 | 0.626 |
| Lincoln | window-or-fs-seg-4b | 80 (oracle) | 49.8% | 64.0% | 0.669 | 0.780 |
| Lincoln | window-or-fs-seg-date-2b | 80 (oracle) | 33.3% | 52.5% | 0.512 | 0.638 |
| CREST | window-cues-claude | 30 (oracle) | 89.1% | 86.7% | 0.983 | 0.931 |
| CREST | window-or-fs-qwen3.5-27b | 30 (oracle) | 88.3% | 83.6% | 0.983 | 0.959 |
| CREST | window-or-fs-seg-2b | 30 (oracle) | 81.2% | 76.6% | 0.890 | 0.863 |
| CREST | window-or-fs-seg-4b | 30 (oracle) | 88.3% | 78.9% | 0.982 | 0.934 |
| CREST | window-or-fs-seg-date-2b | 30 (oracle) | 85.9% | 81.2% | 0.938 | 0.929 |

Development boxes, the oracle count (pooled):

| source | pages exact as answered | with the oracle count | change |
|---|---|---|---|
| whole-gemini | 93.1% | 90.5% | -2.5 pts |
| window-or-fs-seg-4b-pilot | 92.5% | 92.5% | +0.0 pts |
| window-cues-codex | 91.3% | 91.5% | +0.2 pts |
| window-claude | 90.7% | 90.5% | -0.2 pts |
| window-gemini-3.8-flash-low | 90.7% | 90.7% | +0.0 pts |
| window-or-fs-seg-2b | 90.5% | 88.4% | -2.1 pts |
| window-local-seg-2b-8bit | 90.3% | 89.8% | -0.6 pts |
| window-or-fs-qwen3.5-27b | 90.2% | 88.8% | -1.4 pts |
| window-or-glm5.3-flash | 90.2% | 85.5% | -4.6 pts |
| window-or-gpt5.6-luna | 90.0% | 89.2% | -0.8 pts |
| window-local-seg-date-2b-8bit | 89.4% | 85.7% | -3.7 pts |
| whole-gemini-c10 | 89.4% | 90.3% | +1.0 pts |
| window-or-fs-seg-4b | 89.2% | 87.1% | -2.1 pts |
| window-local-seg-4b-8bit | 87.8% | 87.6% | -0.2 pts |
| window-local-seg-4b | 86.5% | 85.1% | -1.4 pts |
| window-local-seg-2b | 85.5% | 84.0% | -1.5 pts |
| window-or-qwen3.5-flash | 84.9% | 84.0% | -1.0 pts |
| window-gemini-3.1-flash-lite-minimal | 84.6% | 86.1% | +1.5 pts |
| window-or-fs-qwen3.5-4b | 67.6% | 71.2% | +3.7 pts |

## Sources with an incomplete cache somewhere

Not collected on every box (each box lists only what it holds): whole-gemini (Lincoln, CREST), whole-gemini-c10 (Stanton, RG165, Lincoln, CREST), window-claude (Lincoln, CREST), window-cues-claude (Herrnstein, Stanton, RG165), window-cues-claude-cue (Deaver, Herrnstein, Stanton, RG165, CREST), window-cues-codex (Lincoln, CREST), window-cues-codex-cue (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-cues-opus (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.1-flash-lite-minimal (Stanton, RG165, Lincoln, CREST), window-gemini-3.5-flash-lite-minimal (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.8-flash-high (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.8-flash-low (Lincoln, CREST), window-local-gemma4-12b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-qwen3-vl-8b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-qwen3.5-4b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-seg-2b (Stanton, RG165, Lincoln, CREST), window-local-seg-2b-8bit (Stanton, RG165, Lincoln, CREST), window-local-seg-4b (Stanton, RG165, Lincoln, CREST), window-local-seg-4b-8bit (Stanton, RG165, Lincoln, CREST), window-local-seg-date-2b-8bit (Stanton, RG165, Lincoln, CREST), window-or-fs-qwen3.5-2b (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-fs-qwen3.5-4b (Stanton, RG165, Lincoln, CREST), window-or-fs-seg-4b-pilot (Stanton, RG165, Lincoln, CREST), window-or-fs-seg-date-2b (Dean, Deaver, Herrnstein, Stanton, RG165), window-or-gemini3.1-flash-lite (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemini3.5-flash-lite (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemma4-26b-a4b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemma4-31b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-glm5.3-flash (Lincoln, CREST), window-or-gpt5.4-mini (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gpt5.4-nano (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gpt5.6-luna (Lincoln, CREST), window-or-llama4-maverick (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-mistral-small (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-122b-a10b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-27b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-flash (Lincoln, CREST), window-or-qwen3.6-35b-a3b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.6-35b-a3b-fp4 (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.6-flash (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST).

## Measurement card

- **Truth.** The owner's ruled boxes: development Dean, Deaver and Herrnstein, test Stanton and RG165; Stanton carries the owner's 2026-10-31 segmentation-sheet rulings (W46.seg-truth-rescore). The public boxes are agent-audited truths with the owner's rulings on their disputed gaps folded in: Lincoln (`5ba5a0e67380…`: 5 gaps owner-ruled, unsure 76|77, 106|107, 230|231); CREST (`c7a0cfcac896…`: 6 gaps owner-ruled, unsure 45|46, 87|88, 93|94, 110|111). Their other gaps remain agent-audited. Unsure gaps are out of every boundary count; segment figures (pages exact, PQ) are the conditional reading, the route's own call at an unsure gap, so they are not one fixed truth across routes (W46.seg-unsure-mask, `score.py`).
- **Selection.** Whole boxes, chosen before these routes were run; every source whose cache is complete on a table's boxes, none chosen by its score. Nothing is fitted on the test boxes or the public ones here.
- **Comparison.** Every source on the same pages and the same truth, window and whole-folder sources with the truth's photo labels (so they measure boundaries); each source's own request and settings, as cached. The scorers differ, the answers do not.
- **Noise.** Single cached runs, no intervals here: the rerun floor (1.4-3.2 points of pages exact a box, SEG-10) and the truth's own label error are not in these figures, so a gap of a few points between sources is a tie.
- **Scope.** Which scorer agrees with pages exact, and what a document count buys, on these seven boxes. It does not rank routes for the app (options.md does, with its review rule), and the conditional segment figures on Lincoln and CREST are not one fixed truth across routes.

