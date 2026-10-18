#!/usr/bin/env python3
"""W43.script-specialists — a TrOCR line model on kraken's lines (run with the kraken venv's python).

  trocr_lines.py MODEL_DIR JOBS.tsv     # each row: <segmentation PAGE XML>\t<output text>

TrOCR reads one cropped line per call (its card: a whole page is not an input it has), so the page is cut on
the baselines specialists.py segment cached, with kraken's own polygon extraction, and the lines are written in
the segmentation's order, one per line. A line kraken's polygon extraction refuses (no boundary, a baseline
under 5 px) is skipped, as kraken's recogniser skips it. A page whose output exists is skipped. Greedy decoding, batches of 16.
"""
import dataclasses
import math
import sys
from pathlib import Path

import torch
from kraken.lib import segmentation, xml
from PIL import Image
from transformers import TrOCRProcessor, VisionEncoderDecoderModel

BATCH = 16


def usable(baseline):
    return len(baseline) >= 2 and sum(math.dist(a, b) for a, b in zip(baseline, baseline[1:])) >= 5


def main(model_dir, jobs):
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    proc = TrOCRProcessor.from_pretrained(model_dir)
    model = VisionEncoderDecoderModel.from_pretrained(model_dir).to(device).eval()
    for row in Path(jobs).read_text().splitlines():
        seg_xml, out = (Path(x) for x in row.split('\t'))
        if out.exists():
            continue
        seg = xml.XMLPage(seg_xml).to_container()
        # extract_polygons raises on a line with no boundary or a baseline under 5 px, ending the whole page;
        # kraken's own recogniser skips such a line, so this does too.
        seg = dataclasses.replace(seg, lines=[ln for ln in seg.lines if ln.boundary is not None and usable(ln.baseline)])
        with Image.open(seg.imagename) as im:
            crops = [c.convert('RGB') for c, _ in segmentation.extract_polygons(im, seg)]
        lines = []
        for i in range(0, len(crops), BATCH):
            px = proc(images=crops[i:i + BATCH], return_tensors='pt').pixel_values.to(device)
            with torch.no_grad():
                ids = model.generate(px, max_new_tokens=128)
            lines += proc.batch_decode(ids, skip_special_tokens=True)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix('.part')
        tmp.write_text('\n'.join(lines) + '\n')
        tmp.rename(out)
        print(f'{out.name}: {len(lines)} lines', flush=True)


if __name__ == '__main__':
    main(*sys.argv[1:])
