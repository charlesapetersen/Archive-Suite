"""Digital Peter (huggingface.co/datasets/ai-forever/Peter), stratum N2.

Letters and papers of Peter the Great, early 1700s Cyrillic cursive: 662 full pages in images.zip (980 MB, read
member by member; Hugging Face redirects the file to us.aws.cdn.hf.co, which the owner allowed on 2026-10-16) and
COCO line annotations in annotations_{train,val,test}.json. Each line's text is its `attributes` 'translation'
(a dict, or its Python literal), and `matched_crop_name` is <doc>_<page>_<line>.jpg, so a page's truth is its lines in line
order, one per row, as shipped (old letters such as ѣ kept). Some images show the edge of the facing page, which the
truth leaves out: a reader that transcribes it is penalised there. The collection for the quarter cap is the document (the first number of the file name).
Licence: MIT (the dataset card). Contamination 'medium': a public competition set since 2020.
"""
from __future__ import annotations

import ast
import collections
import json
import re

import common
from src_castilian import _member as zip_member   # one zip member in one range request, retried

SOURCE = 'peter'
BASE = 'https://huggingface.co/datasets/ai-forever/Peter/resolve/main'
RECORD = 'https://huggingface.co/datasets/ai-forever/Peter'
IMAGES = f'{BASE}/images.zip'
CD_INDEX = f'raw/{SOURCE}/images.cd.json'
SPLITS = ('train', 'val', 'test')


def _directory() -> dict[str, list]:
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = common.RemoteZip(IMAGES)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    return json.loads(path.read_text())['entries']


def line_text(attributes) -> str:
    """`attributes` is a dict in some files and its Python literal in others."""
    a = attributes if isinstance(attributes, dict) else ast.literal_eval(attributes)
    return (a.get('translation') or '').strip()


def pages(coco: dict) -> dict[str, str]:
    """file name -> page truth, the lines in their crop-name order."""
    names = {str(i['id']): i['file_name'] for i in coco['images']}
    lines = collections.defaultdict(list)
    for a in coco['annotations']:
        m = re.fullmatch(r'(.+)_(\d+)\.jpg', a.get('matched_crop_name') or '')
        name = names.get(str(a['image_id']))
        if not m or not name:
            continue
        lines[name].append((int(m.group(2)), line_text(a.get('attributes') or '{}')))
    return {n: '\n'.join(t for _, t in sorted(ls) if t) for n, ls in lines.items()}


def _truths() -> dict[str, str]:
    out = {}
    for s in SPLITS:
        p = common.download(f'{BASE}/annotations_{s}.json', f'raw/{SOURCE}/annotations_{s}.json')
        out.update(pages(json.loads(p.read_text(encoding='utf-8'))))
    return out


def candidates() -> list[common.Candidate]:
    entries, out = _directory(), []
    for name, text in sorted(_truths().items()):
        member = f'images/{name}'
        if not text or member not in entries:
            continue
        stem = name.rsplit('.', 1)[0]
        out.append(common.Candidate(
            source=SOURCE, collection=stem.split('_')[0], page_id=stem, stratum='N2', licence='MIT',
            item_url=RECORD, convention='Digital Peter line transcriptions, in line order, as shipped',
            contamination='medium', publish_image=True, script='Cyrl', era='1700s', kind='handwritten',
            fetch={'member': member, 'entry': entries[member]}))
    return out


def materialise(c: common.Candidate):
    text = _truths()[c.page_id + '.jpg']
    out = common.CACHE / 'pages' / SOURCE / f'{c.page_id}.jpg'
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), zip_member(IMAGES, c.fetch['member'], c.fetch['entry']))
    return out, text
