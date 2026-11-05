# The settings-design prototype

The working page the owner's calls of 2026-11-04 were made on (W46.settings-design-research). The design it
supports is `../12-settings-design.md`; read that first.

- `build_figures.py` reads the bench page's `ArchiveOCRBench/data/panel-data.json` and adds the facts the bench keeps
  in prose (Mac seconds a page and peak memory, cluster throughput, what each route needs, segmentation timing),
  each with its source, and writes `figures.json`.
- `inject.py` puts `figures.json` into `prototype.template.html` and writes `prototype.html`.
- `prototype.html` is the page; open it in a browser. No app code, no network, no model call.

Rebuild from the repository root:

```
python3 execution-plans/processing-review/settings-design/build_figures.py . execution-plans/processing-review/settings-design/figures.json
python3 execution-plans/processing-review/settings-design/inject.py execution-plans/processing-review/settings-design/prototype.template.html execution-plans/processing-review/settings-design/figures.json execution-plans/processing-review/settings-design/prototype.html
```
