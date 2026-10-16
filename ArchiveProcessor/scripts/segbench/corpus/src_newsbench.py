"""NewsBench (github.com/nealcaren/newsbench, branch main), stratum L9.

19 complete Library of Congress By the People newspaper pages with volunteer gold transcriptions:
images/<id>.jpg, txt/<id>.txt, newsbench.csv (image_name, collection, words, tier, exclude, newspaper_note).
Licence: images public domain, transcriptions CC0 (By the People; the repo README) -> 'CC0-1.0'. Rows with
exclude=partial_gold (4 pages whose gold stops mid-page) are dropped. Truth is the .txt exactly as shipped
(whole-page reading order, volunteer conventions). The record URL is the loc.gov resource URL only for NAWSA
assets (mss34132 + 5 digits, e.g. mss3413201417-17 -> mss34132.01417, ?sp=17) -- a derivation that could not be
checked (loc.gov answers 403 to fetch.sh); every other asset gets the repo file URL. Era is the year in
newspaper_note when it has one, else ''.
"""
from __future__ import annotations

import csv
import io
import re

import common
import ghtree

SOURCE = 'newsbench'
OWNER, REPO, BRANCH = 'nealcaren', 'newsbench', 'main'
LICENCE = 'CC0-1.0 (transcriptions; images public domain, LoC By the People)'


def era_of(note: str) -> str:
    m = re.search(r'\b(18[0-9]{2}|19[0-4][0-9])\b', note or '')
    return m.group(1) if m else ''


def loc_url(image_name: str) -> str | None:
    """loc.gov resource URL for a NAWSA asset name, else None (derived, not verified)."""
    m = re.fullmatch(r'mss(34132)(\d{5})-(\d+)\.jpg', image_name)
    return f'https://www.loc.gov/resource/mss{m.group(1)}.{m.group(2)}/?sp={m.group(3)}' if m else None


def rows(csv_text: str) -> list[dict]:
    """Manifest rows that are scored: exclude column empty."""
    return [r for r in csv.DictReader(io.StringIO(csv_text)) if not (r.get('exclude') or '').strip()]


def truth(txt: bytes) -> str:
    """The volunteer gold as shipped (decoded UTF-8, ends trimmed only)."""
    return txt.decode('utf-8').strip()


def candidates() -> list[common.Candidate]:
    dest = 'raw/newsbench/newsbench.csv'
    if not (common.CACHE / dest).exists():
        common.cached(dest, common.get(ghtree.raw_url(OWNER, REPO, BRANCH, 'newsbench.csv')))
    imgs = {i['name'] for i in ghtree.listing(SOURCE, OWNER, REPO, BRANCH, 'images')}
    txts = {i['name'] for i in ghtree.listing(SOURCE, OWNER, REPO, BRANCH, 'txt')}
    out = []
    for r in rows((common.CACHE / dest).read_text(encoding='utf-8')):
        name = r['image_name']
        stem = name.rsplit('.', 1)[0]
        if name not in imgs or f'{stem}.txt' not in txts or not int(r.get('words') or 0):
            continue
        out.append(common.Candidate(
            source=SOURCE, collection=r['collection'], page_id=stem, stratum='L9', licence=LICENCE,
            item_url=loc_url(name) or ghtree.html_url(OWNER, REPO, BRANCH, f'images/{name}'),
            convention='By the People volunteer gold, whole-page reading order, as shipped',
            contamination='high', publish_image=True, script='Latn', era=era_of(r['newspaper_note']),
            kind='newspaper',
            fetch={'image': ghtree.raw_url(OWNER, REPO, BRANCH, f'images/{name}'),
                   'txt': ghtree.raw_url(OWNER, REPO, BRANCH, f'txt/{stem}.txt'), 'ext': 'jpg',
                   'tier': r['tier'], 'note': r['newspaper_note']}))
    return out


def materialise(c: common.Candidate):
    dest = common.CACHE / 'pages' / SOURCE / f"{re.sub(r'[^\w.-]+', '_', c.page_id)}.{c.fetch['ext']}"
    t = truth(common.get(c.fetch['txt']))
    if not dest.exists():
        data = common.get(c.fetch['image'])
        if ghtree.is_lfs_pointer(data):
            raise IOError(f'{c.key}: Git LFS pointer')
        common.cached(str(dest.relative_to(common.CACHE)), data)
    return dest, t
