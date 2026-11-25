#!/usr/bin/env python3
"""W46.ocr-gemma3-12b. Gemma 3 12B (the Processor's 4-bit MLX label reader) on the 895 frozen public pages.

  python3 ocr_gemma3_public.py prepare   # the 895's inputs, as ocr_gemini37_public.py prepare made them
  heavy-run.py run -- run-guarded.sh --label mac-local-gemma3-public --need-gb 8 -- \
      <lab venv>/bin/python ocr_gemma3_public.py collect [--limit N] [--minutes M]

The owner's 96 are read by `ocr_mac_local.py collect --model gemma3-12b-mlx4`; this reads the 895 with the same
entry (ocr_mac_local.HW): the pinned build, the panel's prompt, 8,192 tokens and temperature 0. The inputs are
the reference routes' 2,400 px JPEGs, as W46.ocr-gemini37-895-paid read them: the 440 the reference routes read,
byte for byte and checked against their run manifest, and the other 455 made from the frozen pages by the same code
(ocr_gemini37_public.image_bytes; that run's own copies are in the owner's backup, so they are made again here). In
the corpus's run order, so a partial run is spread over the strata. No network, no money. Readings (raw text included) stay in
CACHE; ocr_rescore.py scores them beside every route on the 895, and ocr_gemma3_report.py writes the report.
Resumable: a page with a saved reading is not read again.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_mac_local as M   # noqa: E402  (sets the model cache before mlx_vlm is imported)
import ocr_panel as P       # noqa: E402
import routes as R          # noqa: E402

KEY = 'gemma3-12b-mlx4'
REHEARSAL = P.CACHE.parent
ITEM = REHEARSAL / 'ocr-gemma3-12b'
INPUTS = ITEM / 'inputs'                        # the manifest and the 455 images made here
REF = R.RUN                                     # the reference routes' run: the 440's images (read only)
OUT = ITEM / 'public'                           # this item's readings, one JSON per page


def image_bytes(r):
    """ocr_gemini37_public.image_bytes (corpus/routes.py prepare's encoding), unchanged."""
    import io
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    with Image.open(r['image']) as im:
        im = im.convert('RGB')
        im.thumbnail((P.SIDE, P.SIDE), Image.Resampling.LANCZOS)
        out = io.BytesIO(); im.save(out, 'JPEG', quality=90)
        return out.getvalue()


def prepare():
    R.MANIFEST = R.RESULTS / 'manifest.jsonl'
    ref = {j['id']: j for j in json.loads((REF / 'manifest.json').read_text())['jobs']}
    out = []
    for r in R.frozen():
        jid = R.job_id(r)
        if jid in ref:
            b = (REF / 'images' / (jid + '.jpg')).read_bytes()
            if P.digest(b) != ref[jid]['sha256']:
                raise SystemExit('a reference image changed: ' + jid)
            src = 'reference'
        else:
            b = image_bytes(r)
            dest = INPUTS / 'images' / (jid + '.jpg')
            if dest.exists() and dest.read_bytes() != b:
                raise SystemExit('a prepared image changed: ' + jid)
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists():
                dest.write_bytes(b)
            src = 'new'
        out.append({'id': jid, 'sha256': P.digest(b), 'images': src, 'stratum': r['stratum'], 'script': r['script']})
    if len(out) != 895 or sum(j['images'] == 'reference' for j in out) != 440:
        raise SystemExit(f'expected 895 pages, 440 of them reference: {len(out)}')
    m = {'jobs': R.run_order(out), 'prompt': P.PROMPT, 'manifest_sha256': R.C.sha256(R.MANIFEST)}
    dest = INPUTS / 'manifest.json'
    if dest.exists() and json.loads(dest.read_text()) != json.loads(json.dumps(m)):
        raise SystemExit('run manifest changed: keep the existing run separate')
    P.save(dest, m)
    print(f'{len(out)} inputs, {sum(j["images"] == "new" for j in out)} made here')


def jobs():
    m = json.loads((INPUTS / 'manifest.json').read_text())
    if len(m['jobs']) != 895 or m['prompt'] != P.PROMPT:
        raise SystemExit('the 895 run manifest is not the frozen one')
    return m['jobs']


def image_of(job):
    """The page's frozen JPEG; ocr_mac_local.collect checks it against the manifest's sha256 before reading."""
    return (REF if job['images'] == 'reference' else INPUTS) / 'images' / (job['id'] + '.jpg')


def readings():
    """{job id: (meta, text or None)} for the pages read so far."""
    out = {}
    for j in jobs():
        f = OUT / (j['id'] + '.json')
        if f.exists():
            meta, parsed = M.load_reading(f)
            out[j['id']] = (meta, parsed['text'] if parsed else None)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['prepare', 'collect', 'status'])
    ap.add_argument('--limit', type=int)
    ap.add_argument('--minutes', type=float, help='stop before a new page once this long has passed')
    a = ap.parse_args()
    if a.command == 'prepare':
        prepare()
    elif a.command == 'collect':
        M.collect(a.limit, KEY, pages=jobs(), out=OUT, image_of=image_of, minutes=a.minutes)
    else:
        got = readings()
        print(f'{len(got)}/895 read, {sum(1 for m, _ in got.values() if m.get("status") == "ok")} ok')


if __name__ == '__main__':
    main()
