
## W36.seg-whole — one long-context call per folder, as a third voter (development set)

Model gemini-3.8-flash, thinkingLevel low, temperature 0, prompt wh1; folders from the truth's label photos (truth photo labels). Detail: whole-gemini-report.md.

Pages in an exact document, pooled: whole-gemini 93.1%, the same model and prompt over pieces of at most 10 pages 89.4%, window-claude 90.3%.

Voting with window-claude: 7 boundaries flagged (1.3 per 100 pages), 9 errors left among the agreed, 94.2% after reviewing the flagged; 98% pooled after 30 reviews (5.4 per 100 pages). All three voters: 27 flagged, 6 errors left among the agreed, 96.3% after reviewing the flagged; 98% pooled after 44 reviews.
