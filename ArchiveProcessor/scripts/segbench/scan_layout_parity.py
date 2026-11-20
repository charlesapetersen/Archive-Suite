"""W47.wh-yolo-scans — does the app's scanned-newspaper detector give the regions W46.ocr-regions measured?

  scan_layout_parity.py oracle --npo NPO_SRC --pages PAGES.TSV --out ORACLE.json   # in the conversion venv
  scan_layout_parity.py compare ORACLE.json APP_DIR [--report OUT.md]               # any python3

`oracle` runs the measured route itself, unchanged: newspaper-ocr 0.11.0's DocLayoutYoloDetector (its default
imgsz1280-2501 checkpoint, conf 0.2) through PyTorch, then the library's LayoutProcessor, then the bench arm's
keep_regions (corpus/regions_cluster.py: no pictures, none 90% inside a larger kept one), as
`regions_cluster.py detect-yolo` and `crops_for` did on Sherlock. It keeps the detector's raw boxes too.
`compare` reads the app's dump (NewspaperLayoutTestDriver, SCAN_LAYOUT_DUMP: the Core ML detections and the regions
`ScanNewspaperLayout.detect` returns) and matches both, page by page, in order. $0: no reader, network or money.
"""
from __future__ import annotations
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'corpus'))


def iou(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - ix * iy
    return ix * iy / u if u > 0 else 1.0


def cmd_oracle(a):
    sys.path.insert(0, str(Path(a.npo)))
    from PIL import Image
    from newspaper_ocr.detectors.doclayout import DocLayoutYoloDetector
    from newspaper_ocr.layout_processor import LayoutProcessor
    from regions_cluster import keep_regions
    det, proc = DocLayoutYoloDetector(), LayoutProcessor()
    out = {}
    for line in Path(a.pages).read_text().splitlines():
        pid, path = line.split('\t')
        im = Image.open(path).convert('RGB'); w, h = im.size
        layout = det.detect(im)
        raw = [{'label': r.label, 'score': r.confidence, 'box': list(r.bbox.to_tuple())} for r in layout.regions]
        layout = proc.process(layout)
        rows = [{'label': r.label, 'score': round(float(r.confidence), 3),
                 'box': [r.bbox.x0 / w, r.bbox.y0 / h, r.bbox.x1 / w, r.bbox.y1 / h]} for r in layout.regions]
        out[pid] = {'width': w, 'height': h, 'raw': raw, 'regions': keep_regions(rows)}
        print(pid, len(raw), 'raw,', len(out[pid]['regions']), 'kept', flush=True)
    Path(a.out).write_text(json.dumps(out, indent=1))


def match_raw(want, got):
    """Detections paired greedily by IoU within a label: (paired, best IoUs, score gaps, unpaired on each side)."""
    left, ious, gaps = list(got), [], []
    for w in sorted(want, key=lambda r: -r['score']):
        best = max((g for g in left if g['label'] == w['label']), key=lambda g: iou(w['box'], g['box']), default=None)
        if best is None or iou(w['box'], best['box']) < 0.5:
            continue
        left.remove(best); ious.append(iou(w['box'], best['box'])); gaps.append(abs(w['score'] - best['score']))
    return len(ious), ious, gaps, len(want) - len(ious), len(left)


def cmd_compare(a):
    oracle = json.loads(Path(a.oracle).read_text())
    lines, worst, same_order = [], 1.0, 0
    n_raw = miss_raw = extra_raw = 0
    raw_ious, raw_gaps = [], []
    for pid, want in oracle.items():
        got = json.loads((Path(a.app) / f'{pid}.json').read_text())
        k, ious, gaps, miss, extra = match_raw(want['raw'], got['raw'])
        n_raw += len(want['raw']); miss_raw += miss; extra_raw += extra; raw_ious += ious; raw_gaps += gaps
        w_regions, g_regions = want['regions'], got['regions']
        ordered = len(w_regions) == len(g_regions) and all(
            x['label'] == y['label'] and iou(x['box'], y['box']) >= 0.9 for x, y in zip(w_regions, g_regions))
        page_iou = min((iou(x['box'], y['box']) for x, y in zip(w_regions, g_regions)), default=1.0)
        same_order += ordered
        worst = min(worst, page_iou if ordered else 0.0)
        lines.append(f'| {pid} | {len(want["raw"])} / {len(got["raw"])} | {miss} / {extra} | '
                     f'{len(w_regions)} / {len(g_regions)} | {"yes" if ordered else "no"} | {page_iou:.4f} |')
    raw_ious.sort(); raw_gaps.sort()
    pct = lambda xs, q: xs[min(len(xs) - 1, int(q * len(xs)))] if xs else float('nan')
    head = [
        '# W47.wh-yolo-scans — the app\'s scanned-newspaper detector against the measured route, on the 15 L9 scans',
        '',
        'Measured route: newspaper-ocr 0.11.0 (DocLayout-YOLO imgsz1280-2501, conf 0.2, PyTorch on the CPU), its',
        'LayoutProcessor and the bench arm\'s keep_regions. App: `ScanNewspaperLayout` (the Core ML conversion,',
        '`packages/VisionOCRKit/ops/convert-scan-layout.py`; the vendored LayoutProcessor in the shared runtime). $0.',
        '',
        f'- Raw detections: {n_raw - miss_raw} of {n_raw} paired at IoU 0.5 or more within their label, {miss_raw} '
        f'unpaired, {extra_raw} extra in the app; paired IoU median {pct(raw_ious, 0.5):.4f}, 1st percentile '
        f'{pct(raw_ious, 0.01):.4f}; score gap median {pct(raw_gaps, 0.5):.4f}, 99th percentile {pct(raw_gaps, 0.99):.4f}.',
        f'- Final regions in reading order: the same list (count, labels, order, each box IoU 0.9 or more) on '
        f'{same_order} of {len(oracle)} pages; worst box IoU on those {worst:.4f}.',
        '',
        '| page | raw (route / app) | unpaired / extra | regions (route / app) | same list | min IoU |',
        '|---|---:|---:|---:|---|---:|',
    ]
    text = '\n'.join(head + lines) + '\n'
    print(text)
    if a.report:
        Path(a.report).write_text(text)
    if same_order < len(oracle) * a.min_share:
        raise SystemExit(f'only {same_order} of {len(oracle)} pages give the measured regions')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    o = sub.add_parser('oracle'); o.add_argument('--npo', required=True); o.add_argument('--pages', required=True)
    o.add_argument('--out', required=True)
    c = sub.add_parser('compare'); c.add_argument('oracle'); c.add_argument('app'); c.add_argument('--report')
    c.add_argument('--min-share', type=float, default=1.0)
    a = ap.parse_args()
    {'oracle': cmd_oracle, 'compare': cmd_compare}[a.cmd](a)
