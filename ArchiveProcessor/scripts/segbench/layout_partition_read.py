"""W46.layout-partition-score, step 2: one small open reader on three arms of the 15 L9 scans.

  heavy-run.py run -- "$HOME/Library/Application Support/ArchiveSuite/VisionOCRKit/Runtime/bin/python3" \
      ArchiveProcessor/scripts/segbench/layout_partition_read.py [--arms whole raw partition] [--pages N]

Run by the app's own runtime python (its mlx-vlm), offline, against Vision OCR's installed PaddleOCR-VL 1.6 4-bit.
The generation loop is the app's `read-model.py` (prompt `OCR:` through the chat template, temperature 0, streamed,
one image a request), with the model loaded once rather than once a request. Every image is shrunk to a 2,048 px
longest side, the Processor's page-reader ceiling (ImageEncoding.maxOCRDimension).

Arms, all cut from the same frozen original:
  whole      the page, 8,192 tokens.
  raw        the measured raw-region baseline (W46.ocr-regions' PP arm): the same detection's regions without
             pictures, a region 90% inside a larger one dropped (regions_cluster.keep_regions), unmasked, the
             detector's order, no fill; 4,096 tokens a crop.
  partition  the app's plan images, exactly as NewspaperPagePlan.prepare wrote them (layout_partition_plans.sh):
             its regions, then its fill: since W46.layout-partition-fix small outside crops (4,096 tokens), or the
             masked whole-page fill (8,192) on a page with no Vision line; 4,096 tokens a region.
One JSON a request under WORK/reads/<arm>/<page>/<nnn>.json, written atomically; an existing one is not read again.
Raw text stays in the private cache; the committed results are scores only. No network, no money.
"""
import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'corpus'))
import regions_cluster as C   # noqa: E402  (stdlib only at import)

WORK = Path(os.environ.get('ARCHIVE_BENCH_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal')) / 'layout-partition-score'
MODELS = Path.home() / 'Library/Application Support/ArchiveSuite/VisionOCRKit/Models'
REPO = 'mlx-community/PaddleOCR-VL-1.6-4bit'
REVISION = 'c8987b277bdd8aaec8bd265d154f391bd03ad165'
PROMPT = 'OCR:'
MAX_SIDE = 2048
PAGE_TOKENS, CROP_TOKENS = 8192, 4096
SECONDS = 540
ARMS = ('whole', 'raw', 'partition')


def pages():
    rows = [line.split('\t') for line in (WORK / 'pages.tsv').read_text().splitlines() if line.strip()]
    return [(pid, Path(path), json.loads((WORK / 'plans' / pid / 'plan.json').read_text())) for pid, path in rows]


def jobs(arm, pid, original, plan):
    """(index, source image, pixel crop or None, max tokens) in reading order."""
    if arm == 'whole':
        return [(0, original, None, PAGE_TOKENS)]
    if arm == 'raw':
        w, h = plan['width'], plan['height']
        regions = sorted(plan['regions'], key=lambda r: r['order'])
        return [(i, original, C.pixel_box(r['box'], w, h, C.PAD), CROP_TOKENS)
                for i, r in enumerate(C.keep_regions(regions))]
    d = WORK / 'plans' / pid
    return [(i, d / name, None, PAGE_TOKENS if name == 'outside-regions.png' else CROP_TOKENS)
            for i, name in enumerate(plan['images'])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--arms', nargs='+', default=list(ARMS), choices=ARMS)
    ap.add_argument('--pages', type=int, default=0, help='the first N pages only (the pilot)')
    a = ap.parse_args()
    os.environ.update(HF_HOME=str(MODELS), HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    mx.set_cache_limit(256 * 2**20)
    snap = MODELS / 'hub' / ('models--' + REPO.replace('/', '--')) / 'snapshots' / REVISION
    assert snap.is_dir(), snap
    t0 = time.time()
    model, processor = load(REPO, trust_remote_code=True)
    print(f'loaded in {time.time() - t0:.1f} s', flush=True)
    prompt = apply_chat_template(processor, model.config, PROMPT, num_images=1)
    tmp = Path(tempfile.mkdtemp(prefix='lps-'))
    todo = pages()[:a.pages] if a.pages else pages()
    for arm in a.arms:
        for pid, original, plan in todo:
            out = WORK / 'reads' / arm / pid
            out.mkdir(parents=True, exist_ok=True)
            for i, src, box, max_tokens in jobs(arm, pid, original, plan):
                dest = out / f'{i:03d}.json'
                if dest.exists():
                    continue
                im = Image.open(src).convert('RGB')
                if box is not None:
                    im = im.crop(box)
                size = list(im.size)
                im.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
                shown = tmp / 'image.png'
                im.save(shown)
                started, piece, last, cut = time.time(), [], None, '-'
                try:
                    for r in stream_generate(model, processor, prompt, image=[str(shown)], max_tokens=max_tokens,
                                             temperature=0.0):
                        piece.append(r.text); last = r
                        if time.time() - started > SECONDS:
                            cut = 'seconds'; break
                    error = None
                except Exception as e:   # a failed request is a result, as the app counts it
                    error = repr(e)
                gen = getattr(last, 'generation_tokens', 0)
                if cut == '-' and last is not None and gen >= max_tokens:
                    cut = 'max_tokens'
                rec = {'arm': arm, 'page': pid, 'index': i, 'source': src.name, 'box': box, 'size': size,
                       'shown': list(im.size), 'max_tokens': max_tokens, 'text': ''.join(piece), 'cut': cut,
                       'error': error, 'seconds': round(time.time() - started, 2),
                       'prompt_tokens': getattr(last, 'prompt_tokens', 0), 'gen_tokens': gen,
                       'mlx_peak_gb': round(mx.get_peak_memory() / 2**30, 2)}
                part = dest.with_suffix('.part')
                part.write_text(json.dumps(rec))
                part.replace(dest)
            n = len(list(out.glob('*.json')))
            print(f'{arm} {pid}: {n} requests, {time.time() - t0:.0f} s elapsed', flush=True)


if __name__ == '__main__':
    main()
