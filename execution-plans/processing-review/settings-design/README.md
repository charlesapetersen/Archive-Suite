# The settings-design prototype

The working page the owner's calls of 2026-11-04 were made on (W46.settings-design-research). The design it
supports is `../12-settings-design.md`; read that first.

- `build_figures.py` reads the rule table, `ArchiveProcessor/segbench-results/settings-routes.json`
  (W46.settings-routes-table; rebuilt by `ArchiveProcessor/scripts/segbench/settings_routes.py`), and flattens its
  rows into `figures.json`. It enters no figure of its own; its hand-entered tables went into the table's stage notes
  or are carried there as unmeasured estimates. `ArchiveProcessor/scripts/test-settings-routes.sh` fails when
  `figures.json` is not what the table gives.
- `inject.py` puts `figures.json` into `prototype.template.html` and writes `prototype.html`.
- `prototype.html` is the page; open it in a browser. No app code, no network, no model call.

Rebuild from the repository root (the table first, when a stage note or a result file changed):

```
python3 ArchiveProcessor/scripts/segbench/settings_routes.py
python3 execution-plans/processing-review/settings-design/build_figures.py . execution-plans/processing-review/settings-design/figures.json
python3 execution-plans/processing-review/settings-design/inject.py execution-plans/processing-review/settings-design/prototype.template.html execution-plans/processing-review/settings-design/figures.json execution-plans/processing-review/settings-design/prototype.html
```
