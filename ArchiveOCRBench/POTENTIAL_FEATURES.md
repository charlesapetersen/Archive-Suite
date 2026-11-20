# ArchiveOCRBench — potential features

Presentation ideas not yet built. None is queued. Page difficulty, failures apart from accuracy and cascades are
part 5 of the page (`W41.bench-difficulty`); a model-independent page kind for it is queued as
`W41.bench-vision-kind`. New measured results are not on this list: the standing rule
in the root `CLAUDE.md` (owner, 2026-10-15) adds those as they land. That includes the FarmShare run (priced from
its measured pages per hour per GPU) and the Mac-local 4-bit run.
- **Kind prices for the rest.** The cloud and local panels are priced by kind (`W49.bench-kind-price`). The gateway's
  Gemini 3.7 Flash, Gemini 4 Hydrogen and the FarmShare/Sherlock runs still use their price over all 96 on the kind
  charts; their per-page tokens would give each its own.
- **More kinds and tags.** Clippings, tables and table forms are in the groups CSVs already. Mixed pages (2) are
  too few to chart.
- **Newspapers.** NewsBench is the lab's newspaper truth set (`W41.farmshare-news-layout`); its scores would make
  a fifth chart.
- **A checking chart for segmentation.** Checks per 100 pages against pages right after checking, if the table
  turns out to be hard to read. Claude only and Claude with ChatGPT sit on the same point there.
- **Share it publicly.** Publish `site/index.html` on GitHub Pages, if the owner wants a public link.
