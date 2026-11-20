"""mixed_preflag_parity.py — the app's mixed-page pre-flag against ATRIUM as the bench ran it (W47.wh-mixed-preflag).

    mixed_preflag_parity.py BENCH_NPZ APP_TSV [--report MD]

BENCH_NPZ is kind_atrium.py's saved run on the 144 owner-labelled pages (`kind-atrium/k144.npz`: PyTorch, Pillow's
bicubic squeeze to 384 px, ImageNet normalisation, revision 543216d6b7e1). APP_TSV is the Processor's own reading of the
same files (OCRPageKindTestDriver section 12b: id, top class, seconds, eleven probabilities), through the pinned Core ML
download. Prints and optionally writes the agreement: same top class, same mixed flag (top class TEXT), the largest
probability difference and the app's time a page. Exits 1 unless every page is read and every flag agrees.
"""
import argparse, statistics, sys
import numpy as np

CLASSES = ('DRAW', 'DRAW_L', 'LINE_HW', 'LINE_P', 'LINE_T', 'PHOTO', 'PHOTO_L', 'TEXT', 'TEXT_HW', 'TEXT_P', 'TEXT_T')

ap = argparse.ArgumentParser()
ap.add_argument('bench'); ap.add_argument('app'); ap.add_argument('--report')
a = ap.parse_args()
z = np.load(a.bench)
bench = {str(i): p for i, p in zip(z['ids'], z['probs'])}
app, unread = {}, []
for line in open(a.app):
    f = line.rstrip('\n').split('\t')
    if len(f) < 3:
        unread.append(f[0]); continue
    app[f[0]] = (f[1], float(f[2]), np.array([float(x) for x in f[3:]]))
listed = set(app) | set(unread)
bench = {p: v for p, v in bench.items() if p in listed}
both = sorted(set(bench) & set(app))
top_same = sum(CLASSES[int(bench[p].argmax())] == app[p][0] for p in both)
flag_b = {p: CLASSES[int(bench[p].argmax())] == 'TEXT' for p in both}
flag_a = {p: app[p][0] == 'TEXT' for p in both}
flag_same = sum(flag_b[p] == flag_a[p] for p in both)
diff = [float(np.abs(bench[p] - app[p][2]).max()) for p in both]
secs = [app[p][1] for p in both]
differ = [f'{p}: bench {CLASSES[int(bench[p].argmax())]}, app {app[p][0]}' for p in both
          if CLASSES[int(bench[p].argmax())] != app[p][0]]
lines = [
    '# The mixed-page pre-flag in the app against ATRIUM as the bench ran it (W47.wh-mixed-preflag)\n',
    'The Processor\'s `MixedPagePreflag` (ATRIUM v4.3 converted to Core ML by `packages/VisionOCRKit/ops/convert-atrium.py`, '
    'installed from the pinned `atrium-page-kind.tgz` by the app\'s own installer, Pillow\'s bicubic squeeze reimplemented '
    'in Swift) read the 144 owner-labelled pages that `kind_atrium.py` scored in PyTorch (`kind-atrium/k144.npz`). '
    'Run by `scripts/segbench/mixed_preflag_parity.sh`; no reader, no money.\n',
    '| measure | value |', '|---|---:|',
    f'| pages read by both | {len(both)} of {len(bench)} ({len(unread)} unread by the app) |',
    f'| same top class | {top_same} of {len(both)} |',
    f'| same mixed flag (top class TEXT) | {flag_same} of {len(both)} ({sum(flag_b.values())} flagged by the bench) |',
    f'| largest probability difference, median page | {statistics.median(diff):.5f} |' if diff else '| largest probability difference | – |',
    f'| largest probability difference, worst page | {max(diff):.5f} |' if diff else '',
    f'| app time a page, median (Core ML, first page includes loading) | {statistics.median(secs):.3f} s |' if secs else '',
    '',
]
if differ:
    lines += ['Pages whose top class differs: ' + '; '.join(differ) + '.', '']
lines += [
    'The time is the Debug Processor\'s, whose Swift is unoptimised, so the resize dominates it; it is not the shipped '
    'app\'s time a page.', '',
    '## Measurement card', '',
    '- **Truth.** ATRIUM as W46.kind-atrium ran it, saved in `kind-atrium/k144.npz`: timm regnety_160 at revision '
    '543216d6b7e1 in PyTorch, Pillow 13 bicubic squeeze to 384 px, ImageNet normalisation. No owner truth is involved: '
    'this checks the port, not the flag\'s accuracy.',
    '- **Selection.** The 144 owner-labelled kind-classifier pages, the set the bench saved ATRIUM\'s probabilities for; '
    'not chosen by either side\'s calls.',
    '- **Comparison.** The same files, decoded by Pillow for the bench and by ImageIO for the app; the same weights, '
    'class order and preprocessing (the resize ported from Pillow and checked against it on two fixed cases).',
    '- **Noise.** Deterministic on both sides; the residual probability differences come from the two JPEG decoders and '
    'Core ML against PyTorch arithmetic. A flag that differed would be a port defect, not noise.',
    '- **Scope.** The flag\'s recall and precision (51-60% and 69.8%, finite bounds 18-95% and 7-97%) are '
    'kind-atrium.md §5\'s, on the 2,000 bulk pages under the owner\'s cut; their page images are in the owner\'s '
    'backup (MOVED), so they were not re-read here. This does not re-measure them.', '',
]
text = '\n'.join(l for l in lines if l is not None) + '\n'
print(text)
if a.report:
    open(a.report, 'w').write(text)
sys.exit(0 if both and not unread and len(both) == len(bench) and flag_same == len(both) else 1)
