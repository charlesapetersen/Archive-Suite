# W40.fix-reader-selected-row-contrast — completion evidence, 2026-10-24

Implementation: checkpoints `c6bc8c6b` and `19fd2c3f`, completed by this commit against baseline `ffd31c88`.
Read-only presentation change; all fixtures are generated scratch data. No real corpus or host GUI access.

## Headless pixels

`SelectedRowContrastTests` renders the real Read and File tags cells in an `NSTableView` in light/dark.
Its off-window row paints the system selection background because AppKit's cached off-window drawing omits
that highlight; the test separately asserts selection, emphasis, cell background style and sampled background.
Chip lettering is sampled inside the padding, separately from its outline, so an outline cannot pass for text.

Measured WCAG contrast ratios with this Mac's blue accent:

| Drawing | Light | Dark |
|---|---:|---:|
| Old accent-blue Unread on active selection (negative control) | 1.34 | 1.56 |
| Fixed Unread on active selection | 5.37 | 6.27 |
| Outlined chip title and border on active selection | 5.37 | 6.27 |
| Read on active selection (native secondary text mapping) | 4.79 | 5.58 |
| Unread on inactive selection before the completing patch | 2.93 | 2.35 |
| Unread on inactive selection after the completing patch | 15.31 | 9.44 |
| Read on inactive selection | 6.99 | 7.02 |
| Unread on ordinary rows (accent retained) | 4.02 | 4.15 |
| Chip lettering on ordinary rows | 9.92 | 8.61 |

The same cells pass active → inactive → ordinary → inactive again → active again. This checks both
selection and deselection while `backgroundStyle` stays `.normal`, as well as focus changes. The expected
colours are resolved per appearance/accent; the guard rejects the original accent-on-selection drawing.
The existing wrapping/clamping, native one-line height and one-shot row-height invalidation checks also pass.

Command: `./test-smoke.sh reader` (`ARCHIVE_UNATTENDED=1`, unit bundle only).
Result: **507 tests, 3 skipped, 0 failures**. No new compiler warnings; the existing AppIntents metadata
notices and scale-test QoS diagnostic remain. Run log:
`ArchiveReader/.maintenance/test-results/smoke-reader-20261024-140548.log` in the completing worktree.
Contrast transcript is retained in `selected-row-contrast-2026-10-24-unit.txt`.

## Off-screen VM

Command:

```sh
VISUAL_REVIEW=1 \
ONLY_TESTING=ArchiveReaderUITests/VisualReviewUITests/testSelectedRowContrastLightAndDark \
ART_DIR=/tmp/w40-reader-contrast-vm3 ops/gui/vm-gui-runner.sh reader xcuitest
```

The focused visual test clicks the row's date area, selects all rows, moves focus into the name filter,
then returns focus to the table and uses Up to collapse the selection to one row, in both appearances. It asserts selection and filter keyboard focus and
captures open/idle pairs. It changes no tags. Pixels, rather than accessibility, establish the colours.
A first draft assumed clicking into an inactive multiselection collapsed it; that failed in both appearances
because the first click preserves the group. The final test deliberately moves with Up and still asserts that
exactly one row is selected.

VM result: **1 test passed, 0 failures, 70.33 s**; no new suite crash/hang report. Six idle captures were
visually inspected: Read and Unread remain legible, active chips have distinct outlines and white lettering,
inactive chips have readable filled backgrounds, and returning to a single selection restores ordinary row
colours elsewhere. The first and last selected row have the same chip geometry.

| State | Light | Dark |
|---|---|---|
| All selected, active | [capture](selected-row-contrast-2026-10-24-light-selected-all.png) | [capture](selected-row-contrast-2026-10-24-dark-selected-all.png) |
| All selected, filter focused | [capture](selected-row-contrast-2026-10-24-light-inactive-selection.png) | [capture](selected-row-contrast-2026-10-24-dark-inactive-selection.png) |
| One selected again | [capture](selected-row-contrast-2026-10-24-light-selected-again.png) | [capture](selected-row-contrast-2026-10-24-dark-selected-again.png) |

Full run artifacts: `/tmp/w40-reader-contrast-vm3/reader/` (`xcuitest.log`, `uitest.xcresult`, 16 open/idle
captures). The selected unit and VM transcripts and six captures are committed beside this note.

## Review and safety checks

Independent read-only review found no blocking defect in the checkpoint implementation, the inactive-selection
patch or the test additions. The completing patch uses `NSTableRowView.isSelected` to distinguish inactive
selection from an ordinary row, both of which AppKit calls `.normal`; refreshing before drawing handles
same-style transitions, and colour equality avoids repeated setter-driven redraws.

`ArchiveReader/scripts/lint-write-surface.sh` passes; its mutation proof passes **22/22** checks.
This evidence does not promote a feature-ledger row to `works`; independent journey rechecks remain separate.
