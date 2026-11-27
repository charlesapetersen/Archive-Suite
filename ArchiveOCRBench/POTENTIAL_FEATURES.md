# ArchiveOCRBench — potential features

Presentation ideas not yet built. None is queued. Page difficulty, failures apart from accuracy and cascades are
part 5 of the page (`W41.bench-difficulty`); a model-independent page kind for it is queued as
`W41.bench-vision-kind`. New measured results are not on this list: the standing rule
in the root `CLAUDE.md` (owner, 2026-10-15) adds those as they land. That includes the FarmShare run (priced from
its measured pages per hour per GPU) and the Mac-local 4-bit run.
- **A checking chart for segmentation.** Checks per 100 pages against pages right after checking, if the table
  turns out to be hard to read. Claude only and Claude with ChatGPT sit on the same point there (queued: W49.bench-seg-check-chart behind
  nice-to-have, owner 2026-11-20).
- **Share it publicly.** — settled (owner, 2026-11-20, call 28): kept private for now. Publish `site/index.html` on GitHub Pages, if the owner wants a public link.
