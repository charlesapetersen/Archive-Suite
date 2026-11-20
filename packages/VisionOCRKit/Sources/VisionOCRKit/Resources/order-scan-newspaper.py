"""The scanned-newspaper detector's layout processing (W47.wh-yolo-scans), without reading any text.

Run by ScanNewspaperLayout in the shared runtime on the Core ML detector's boxes: newspaper-ocr 0.11.0's
LayoutProcessor (vendored unchanged in npo_layout.py, MIT) as its Pipeline runs it after DocLayout-YOLO, then the
bench arm's keep_regions (ArchiveProcessor/scripts/segbench/corpus/regions_cluster.py): no pictures, and none 90%
inside a larger kept one. That is the region list W46.ocr-regions read on the 15 L9 scans. No model, no network.

    order-scan-newspaper.py IN.json OUT.json
IN:  {"width": W, "height": H, "detections": [{"label", "confidence", "box": [x0, y0, x1, y1] page pixels}]}
OUT: [{"label", "score", "box": [x0, y0, x1, y1] as shares of the page}], in reading order
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from PIL import Image  # noqa: E402
from npo_layout import BBox, LayoutProcessor, PageLayout, Region  # noqa: E402

DROP = {'figure', 'image', 'picture', 'header_image', 'footer_image'}


def inside(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    area = (a[2] - a[0]) * (a[3] - a[1])
    return ix * iy / area if area > 0 else 1.0


def keep_regions(regions):
    cand = [r for r in regions if r['label'] not in DROP and r['box'][2] > r['box'][0] and r['box'][3] > r['box'][1]]
    area = lambda r: (r['box'][2] - r['box'][0]) * (r['box'][3] - r['box'][1])
    kept = []
    for r in sorted(cand, key=area, reverse=True):
        if not any(inside(r['box'], k['box']) >= 0.9 for k in kept):
            kept.append(r)
    ids = {id(r) for r in kept}
    return [r for r in cand if id(r) in ids]


src = json.loads(Path(sys.argv[1]).read_text())
w, h = int(src['width']), int(src['height'])
# The processor crops merged blocks from the page image; nothing here reads those crops, so a blank stands in.
blank = Image.new('RGB', (1, 1))
regions = [Region(bbox=BBox(*[int(v) for v in d['box']]), image=blank, label=d['label'], lines=[],
                  confidence=float(d['confidence'])) for d in src['detections']]
layout = LayoutProcessor().process(PageLayout(image=blank, regions=regions, width=w, height=h, lines_detected=False))
rows = [{'label': r.label, 'score': round(float(r.confidence), 3),
         'box': [r.bbox.x0 / w, r.bbox.y0 / h, r.bbox.x1 / w, r.bbox.y1 / h]} for r in layout.regions]
Path(sys.argv[2]).write_text(json.dumps(keep_regions(rows), allow_nan=False))
