# ArchiveOCRBench — potential features

Presentation ideas not yet built. None is queued, except where noted: page difficulty, failures apart from
accuracy and a routing rule are queued as `W41.bench-difficulty` in `SUITE_TODO.md`. New measured results are not on this list: the standing rule
in the root `CLAUDE.md` (owner, 2026-10-15) adds those as they land. That includes the FarmShare run (priced from
its measured pages per hour per GPU) and the Mac-local 4-bit run.
- **Measure Sonnet's API price.** Replace the estimate in `data/inputs.json` with a token count from the API's
  free `count_tokens` call on the 99 panel images, or a small paid run.
- **Price each page kind on its own.** The local CSV already carries a cost per group; the cloud CSV would need
  the same, so a kind chart could use that kind's real price.
- **More kinds and tags.** Clippings, tables and table forms are in the groups CSVs already. Mixed pages (2) are
  too few to chart.
- **Newspapers.** NewsBench is the lab's newspaper truth set (`W41.farmshare-news-layout`); its scores would make
  a fifth chart.
- **A checking chart for segmentation.** Checks per 100 pages against pages right after checking, if the table
  turns out to be hard to read. Claude only and Claude with ChatGPT sit on the same point there.
- **Share it publicly.** Publish `site/index.html` on GitHub Pages, if the owner wants a public link.
