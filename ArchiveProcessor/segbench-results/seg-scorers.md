# The field's segmentation scorers on every cached answer — W46.fix-seg-scorers

Made by `scripts/segbench/rescore.py` (owner, public, report) from the response caches, with no call and no money: a cache miss is reported as incomplete and the process refuses the network. Definitions are in `score.py`'s docstring; the figures are pooled sums over the boxes named. Window and whole-folder sources take the truth's photo labels, so their figures measure boundaries; the spring runs keep their own. Higher is better except Pk, WindowDiff and MNDD. A source appears in a table only where its cache is complete on every box of that table. On the owner boxes Pk equals WindowDiff: k is half the mean truth segment length, and their documents average about 1.6 pages, so k rounds to 1 with or without the label photos counted, and at k = 1 the two measures are the same; on Lincoln and CREST k is 2.

## Development boxes (Dean, Deaver, Herrnstein; 551 pages)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| whole-gemini | whole folder, Gemini API | 93.1% | 0.941 | 0.026 | 0.026 | 0.963 | 0.969 | 0.994 | 0.950 | 66.7% | 2.7 |
| window-or-fs-seg-4b-pilot | window, FarmShare | 92.5% | 0.929 | 0.031 | 0.031 | 0.940 | 0.945 | 0.995 | 0.929 | 58.3% | 2.9 |
| window-cues-codex | window, subscription | 91.3% | 0.958 | 0.018 | 0.018 | 0.970 | 0.978 | 0.992 | 0.956 | 70.8% | 3.1 |
| window-gemini-3.8-flash-low | window, Gemini API | 90.7% | 0.941 | 0.026 | 0.026 | 0.960 | 0.965 | 0.994 | 0.947 | 70.8% | 3.6 |
| window-claude | window, subscription | 90.7% | 0.954 | 0.020 | 0.020 | 0.966 | 0.973 | 0.992 | 0.951 | 70.8% | 3.3 |
| window-or-fs-seg-2b | window, FarmShare | 90.5% | 0.929 | 0.031 | 0.031 | 0.938 | 0.945 | 0.993 | 0.923 | 58.3% | 3.4 |
| window-local-seg-2b-8bit | window, Mac local | 90.3% | 0.929 | 0.031 | 0.031 | 0.940 | 0.948 | 0.992 | 0.922 | 54.2% | 3.4 |
| window-or-glm5.3-flash | window, OpenRouter | 90.2% | 0.937 | 0.027 | 0.027 | 0.952 | 0.958 | 0.994 | 0.942 | 66.7% | 4.0 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 90.2% | 0.933 | 0.029 | 0.029 | 0.956 | 0.963 | 0.993 | 0.941 | 66.7% | 3.8 |
| window-or-gpt5.6-luna | window, OpenRouter | 90.0% | 0.945 | 0.024 | 0.024 | 0.958 | 0.967 | 0.991 | 0.942 | 66.7% | 3.6 |
| whole-gemini-c10 | whole folder, Gemini API | 89.4% | 0.941 | 0.026 | 0.026 | 0.954 | 0.962 | 0.991 | 0.937 | 62.5% | 3.8 |
| window-local-seg-date-2b-8bit | window, Mac local | 89.4% | 0.921 | 0.035 | 0.035 | 0.935 | 0.941 | 0.993 | 0.919 | 50.0% | 4.2 |
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
| window-cues-codex | window, subscription | 92.4% | 0.954 | 0.019 | 0.019 | 0.952 | 0.962 | 0.990 | 0.934 | 66.7% | 2.5 |
| window-gemini-3.8-flash-low | window, Gemini API | 88.8% | 0.928 | 0.030 | 0.030 | 0.924 | 0.935 | 0.989 | 0.901 | 60.0% | 3.6 |
| window-claude | window, subscription | 87.0% | 0.909 | 0.039 | 0.039 | 0.918 | 0.932 | 0.985 | 0.884 | 60.0% | 3.6 |
| window-or-gpt5.6-luna | window, OpenRouter | 84.5% | 0.889 | 0.047 | 0.047 | 0.894 | 0.908 | 0.985 | 0.861 | 60.0% | 5.0 |
| whole-gemini | whole folder, Gemini API | 84.2% | 0.921 | 0.033 | 0.033 | 0.918 | 0.931 | 0.986 | 0.890 | 53.3% | 4.7 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 83.0% | 0.853 | 0.064 | 0.064 | 0.855 | 0.867 | 0.986 | 0.828 | 53.3% | 6.9 |
| window-or-glm5.3-flash | window, OpenRouter | 82.1% | 0.895 | 0.044 | 0.044 | 0.911 | 0.924 | 0.986 | 0.869 | 46.7% | 4.1 |
| window-or-fs-seg-4b | window, FarmShare | 79.1% | 0.852 | 0.064 | 0.064 | 0.855 | 0.873 | 0.979 | 0.814 | 40.0% | 7.4 |
| window-or-fs-seg-2b | window, FarmShare | 78.8% | 0.814 | 0.080 | 0.080 | 0.815 | 0.835 | 0.976 | 0.777 | 53.3% | 8.3 |
| window-or-qwen3.5-flash | window, OpenRouter | 77.6% | 0.870 | 0.055 | 0.055 | 0.866 | 0.885 | 0.979 | 0.818 | 46.7% | 6.6 |
| spring-v1 | spring 2026 Gemini (own photo labels) | 77.0% | 0.877 | 0.058 | 0.058 | 0.880 | 0.897 | 0.981 | 0.837 | 33.3% | 6.6 |
| spring-baseline | spring 2026 Gemini (own photo labels) | 57.0% | 0.833 | 0.111 | 0.111 | 0.815 | 0.849 | 0.961 | 0.708 | 0.0% | 11.8 |
| spring-v2 | spring 2026 Gemini (own photo labels) | 55.8% | 0.768 | 0.139 | 0.139 | 0.772 | 0.799 | 0.966 | 0.680 | 6.7% | 13.2 |
| rule-cues | baseline | 33.0% | 0.302 | 0.324 | 0.324 | 0.455 | 0.485 | 0.938 | 0.389 | 20.0% | 31.7 |
| rule-cues-sketch | baseline | 21.8% | 0.094 | 0.454 | 0.454 | 0.306 | 0.310 | 0.989 | 0.301 | 13.3% | 46.3 |
| all-new | baseline | 20.3% | 0.000 | 0.512 | 0.512 | 0.282 | 0.282 | 1.000 | 0.282 | 13.3% | 51.0 |
| no-boundaries | baseline | 8.5% | 0.000 | 0.360 | 0.360 | 0.074 | 0.087 | 0.844 | 0.050 | 26.7% | 68.0 |

## Lincoln (261 pages, 81 documents)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| window-cues-claude | window, subscription | 90.0% | 0.973 | 0.004 | 0.023 | 0.956 | 0.957 | 0.999 | 0.944 | 0.0% | 1.1 |
| window-cues-claude-cue | window, subscription | 90.0% | 0.982 | 0.008 | 0.015 | 0.984 | 0.988 | 0.996 | 0.963 | 0.0% | 0.8 |
| window-or-fs-seg-4b | window, FarmShare | 46.7% | 0.722 | 0.089 | 0.255 | 0.643 | 0.688 | 0.935 | 0.490 | 0.0% | 13.4 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 39.5% | 0.683 | 0.093 | 0.301 | 0.579 | 0.624 | 0.928 | 0.426 | 0.0% | 15.7 |
| window-or-fs-seg-2b | window, FarmShare | 34.9% | 0.638 | 0.100 | 0.332 | 0.517 | 0.559 | 0.925 | 0.373 | 0.0% | 17.6 |
| window-or-fs-seg-date-2b | window, FarmShare | 34.1% | 0.638 | 0.100 | 0.328 | 0.529 | 0.569 | 0.930 | 0.382 | 0.0% | 17.6 |
| rule-cues | baseline | 16.9% | 0.274 | 0.274 | 0.537 | 0.282 | 0.319 | 0.884 | 0.198 | 0.0% | 39.5 |
| all-new | baseline | 7.3% | 0.000 | 0.456 | 0.927 | 0.111 | 0.111 | 1.000 | 0.111 | 0.0% | 69.0 |
| rule-cues-sketch | baseline | 7.3% | 0.000 | 0.456 | 0.927 | 0.111 | 0.111 | 1.000 | 0.111 | 0.0% | 69.0 |
| no-boundaries | baseline | 0.0% | 0.000 | 0.544 | 0.544 | 0.000 | 0.000 | 0.000 | — | 0.0% | 91.6 |

## CREST (128 pages, 31 documents)

| source | family | pages exact | kappa | Pk | WD | PQ | RQ | SQ | doc F1 | STP | MNDD/100 p |
|---|---|---|---|---|---|---|---|---|---|---|---|
| window-or-fs-seg-4b | window, FarmShare | 98.4% | 0.978 | 0.000 | 0.016 | 0.952 | 0.952 | 1.000 | 0.952 | 0.0% | 0.8 |
| window-or-fs-qwen3.5-27b | window, FarmShare | 95.3% | 0.957 | 0.008 | 0.032 | 0.930 | 0.938 | 0.992 | 0.906 | 0.0% | 1.6 |
| window-or-fs-seg-2b | window, FarmShare | 91.4% | 0.913 | 0.032 | 0.056 | 0.860 | 0.871 | 0.988 | 0.839 | 0.0% | 3.9 |
| window-or-fs-seg-date-2b | window, FarmShare | 85.2% | 0.935 | 0.016 | 0.048 | 0.908 | 0.921 | 0.986 | 0.857 | 0.0% | 2.3 |
| window-cues-claude | window, subscription | 84.4% | 0.937 | 0.016 | 0.048 | 0.913 | 0.923 | 0.989 | 0.862 | 0.0% | 2.3 |
| rule-cues | baseline | 11.7% | 0.074 | 0.524 | 0.817 | 0.162 | 0.166 | 0.979 | 0.152 | 0.0% | 65.6 |
| all-new | baseline | 7.0% | 0.000 | 0.595 | 0.937 | 0.113 | 0.113 | 1.000 | 0.113 | 0.0% | 75.8 |
| rule-cues-sketch | baseline | 7.0% | 0.041 | 0.556 | 0.889 | 0.119 | 0.119 | 1.000 | 0.119 | 0.0% | 71.9 |
| no-boundaries | baseline | 0.0% | 0.000 | 0.405 | 0.405 | 0.000 | 0.000 | 0.000 | — | 0.0% | 86.7 |

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
| Stanton | window-or-fs-seg-4b | 79.0% | 0.847 | +5.7 pts | 0.841 | 8.8 |
| Stanton | window-or-fs-seg-2b | 73.3% | 0.784 | +5.2 pts | 0.774 | 11.2 |
| Stanton | window-or-fs-qwen3.5-27b | 81.9% | 0.840 | +2.1 pts | 0.833 | 8.4 |
| RG165 | window-or-fs-seg-4b | 79.3% | 0.885 | +9.2 pts | 0.876 | 4.4 |
| RG165 | window-or-fs-seg-2b | 94.3% | 0.929 | -1.3 pts | 0.938 | 1.8 |
| RG165 | window-or-fs-qwen3.5-27b | 86.2% | 0.907 | +4.5 pts | 0.908 | 3.5 |
| Lincoln | window-or-fs-seg-4b | 46.7% | 0.643 | +17.5 pts | 0.722 | 13.4 |
| Lincoln | window-or-fs-seg-2b | 34.9% | 0.517 | +16.8 pts | 0.638 | 17.6 |
| Lincoln | window-or-fs-qwen3.5-27b | 39.5% | 0.579 | +18.4 pts | 0.683 | 15.7 |
| CREST | window-or-fs-seg-4b | 98.4% | 0.952 | -3.2 pts | 0.978 | 0.8 |
| CREST | window-or-fs-seg-2b | 91.4% | 0.860 | -5.4 pts | 0.913 | 3.9 |
| CREST | window-or-fs-qwen3.5-27b | 95.3% | 0.930 | -2.3 pts | 0.957 | 1.6 |

Rank agreement over the 22 non-baseline sources complete on the development boxes (Spearman, against pages in an exact document): PQ 0.772, kappa 0.714, doc F1 0.823, MNDD (negated) 0.967, WindowDiff (negated) 0.743.

## The document-count prior (A-segmentation test 9)

Each source's per-gap P(new) ranked, and exactly `count − streams` document gaps kept as boundaries. Lincoln's count is the catalogue's 72 items (truth 81) and CREST's the folder's 22 PDFs (truth 31); the oracle uses the truth's own count, which no user has, and bounds what a count can buy.

| box | source | count | as answered: pages exact | with the prior | PQ as answered | PQ with the prior |
|---|---|---|---|---|---|---|
| Lincoln | window-cues-claude | 72 (finding aid) | 90.0% | 81.2% | 0.956 | 0.862 |
| Lincoln | window-cues-claude-cue | 72 (finding aid) | 90.0% | 79.7% | 0.984 | 0.871 |
| Lincoln | window-or-fs-qwen3.5-27b | 72 (finding aid) | 39.5% | 45.2% | 0.579 | 0.697 |
| Lincoln | window-or-fs-seg-2b | 72 (finding aid) | 34.9% | 36.0% | 0.517 | 0.542 |
| Lincoln | window-or-fs-seg-4b | 72 (finding aid) | 46.7% | 57.9% | 0.643 | 0.694 |
| Lincoln | window-or-fs-seg-date-2b | 72 (finding aid) | 34.1% | 41.8% | 0.529 | 0.568 |
| CREST | window-cues-claude | 22 (finding aid) | 84.4% | 55.5% | 0.913 | 0.728 |
| CREST | window-or-fs-qwen3.5-27b | 22 (finding aid) | 95.3% | 48.4% | 0.930 | 0.756 |
| CREST | window-or-fs-seg-2b | 22 (finding aid) | 91.4% | 32.8% | 0.860 | 0.719 |
| CREST | window-or-fs-seg-4b | 22 (finding aid) | 98.4% | 54.7% | 0.952 | 0.686 |
| CREST | window-or-fs-seg-date-2b | 22 (finding aid) | 85.2% | 45.3% | 0.908 | 0.719 |
| Lincoln | window-cues-claude | 81 (oracle) | 90.0% | 88.5% | 0.956 | 0.938 |
| Lincoln | window-cues-claude-cue | 81 (oracle) | 90.0% | 90.8% | 0.984 | 0.975 |
| Lincoln | window-or-fs-qwen3.5-27b | 81 (oracle) | 39.5% | 55.6% | 0.579 | 0.753 |
| Lincoln | window-or-fs-seg-2b | 81 (oracle) | 34.9% | 50.2% | 0.517 | 0.623 |
| Lincoln | window-or-fs-seg-4b | 81 (oracle) | 46.7% | 62.8% | 0.643 | 0.763 |
| Lincoln | window-or-fs-seg-date-2b | 81 (oracle) | 34.1% | 49.8% | 0.529 | 0.625 |
| CREST | window-cues-claude | 31 (oracle) | 84.4% | 87.5% | 0.913 | 0.933 |
| CREST | window-or-fs-qwen3.5-27b | 31 (oracle) | 95.3% | 92.2% | 0.930 | 0.954 |
| CREST | window-or-fs-seg-2b | 31 (oracle) | 91.4% | 91.4% | 0.860 | 0.860 |
| CREST | window-or-fs-seg-4b | 31 (oracle) | 98.4% | 93.8% | 0.952 | 0.930 |
| CREST | window-or-fs-seg-date-2b | 31 (oracle) | 85.2% | 96.1% | 0.908 | 0.925 |

Development boxes, the oracle count (pooled):

| source | pages exact as answered | with the oracle count | change |
|---|---|---|---|
| whole-gemini | 93.1% | 90.5% | -2.5 pts |
| window-or-fs-seg-4b-pilot | 92.5% | 92.5% | +0.0 pts |
| window-cues-codex | 91.3% | 91.5% | +0.2 pts |
| window-gemini-3.8-flash-low | 90.7% | 90.7% | +0.0 pts |
| window-claude | 90.7% | 90.5% | -0.2 pts |
| window-or-fs-seg-2b | 90.5% | 88.4% | -2.1 pts |
| window-local-seg-2b-8bit | 90.3% | 89.8% | -0.6 pts |
| window-or-glm5.3-flash | 90.2% | 85.5% | -4.6 pts |
| window-or-fs-qwen3.5-27b | 90.2% | 88.8% | -1.4 pts |
| window-or-gpt5.6-luna | 90.0% | 89.2% | -0.8 pts |
| whole-gemini-c10 | 89.4% | 90.3% | +1.0 pts |
| window-local-seg-date-2b-8bit | 89.4% | 85.7% | -3.7 pts |
| window-or-fs-seg-4b | 89.2% | 87.1% | -2.1 pts |
| window-local-seg-4b-8bit | 87.8% | 87.6% | -0.2 pts |
| window-local-seg-4b | 86.5% | 85.1% | -1.4 pts |
| window-local-seg-2b | 85.5% | 84.0% | -1.5 pts |
| window-or-qwen3.5-flash | 84.9% | 84.0% | -1.0 pts |
| window-gemini-3.1-flash-lite-minimal | 84.6% | 86.1% | +1.5 pts |
| window-or-fs-qwen3.5-4b | 67.6% | 71.2% | +3.7 pts |

## Sources with an incomplete cache somewhere

Not collected on every box (each box lists only what it holds): whole-gemini (Lincoln, CREST), whole-gemini-c10 (Stanton, RG165, Lincoln, CREST), window-claude (Lincoln, CREST), window-cues-claude (Dean, Herrnstein, Stanton, RG165), window-cues-claude-cue (CREST), window-cues-codex (Lincoln, CREST), window-cues-codex-cue (Lincoln, CREST), window-cues-opus (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.1-flash-lite-minimal (Stanton, RG165, Lincoln, CREST), window-gemini-3.5-flash-lite-minimal (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.8-flash-high (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-gemini-3.8-flash-low (Lincoln, CREST), window-local-gemma4-12b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-qwen3-vl-8b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-qwen3.5-4b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-local-seg-2b (Stanton, RG165, Lincoln, CREST), window-local-seg-2b-8bit (Stanton, RG165, Lincoln, CREST), window-local-seg-4b (Stanton, RG165, Lincoln, CREST), window-local-seg-4b-8bit (Stanton, RG165, Lincoln, CREST), window-local-seg-date-2b-8bit (Stanton, RG165, Lincoln, CREST), window-or-fs-qwen3.5-2b (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-fs-qwen3.5-4b (Stanton, RG165, Lincoln, CREST), window-or-fs-seg-4b-pilot (Stanton, RG165, Lincoln, CREST), window-or-fs-seg-date-2b (Dean, Deaver, Herrnstein, Stanton, RG165), window-or-gemini3.1-flash-lite (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemini3.5-flash-lite (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemma4-26b-a4b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gemma4-31b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-glm5.3-flash (Lincoln, CREST), window-or-gpt5.4-mini (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gpt5.4-nano (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-gpt5.6-luna (Lincoln, CREST), window-or-llama4-maverick (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-mistral-small (Dean, Deaver, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-122b-a10b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-27b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.5-flash (Lincoln, CREST), window-or-qwen3.6-35b-a3b (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.6-35b-a3b-fp4 (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST), window-or-qwen3.6-flash (Dean, Herrnstein, Stanton, RG165, Lincoln, CREST).

