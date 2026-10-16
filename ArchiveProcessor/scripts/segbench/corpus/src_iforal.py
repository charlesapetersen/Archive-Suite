"""iForal — medieval Portuguese forais (github.com/Arch-W/iForal-Dataset, branch main), stratum L5.

Licence: CC-BY-4.0 per the HTR-United catalogue (the repo itself has no LICENSE file, so the licence string
says so). 67 forais 1217-1491, one folder each: data/foral_de_<town>_<year>/N.jpg + N.xml (PAGE, eScriptorium).
Truth is TextLine TextEquiv in document order, diplomatic (abbreviation signs and the tironian et kept as the
transcribers typed them). Pages with no line text are dropped. The era is the year in the folder name, which
is the foral's date, not necessarily the manuscript copy's.
"""
from __future__ import annotations

import re

import common
import ghtree

SOURCE = 'iforal'
OWNER, REPO, BRANCH = 'Arch-W', 'iForal-Dataset', 'main'
LICENCE = 'CC-BY-4.0 (HTR-United catalogue)'


def truth(xml: bytes) -> str:
    return common.page_xml_text(xml)


def era_of(folder: str) -> str:
    m = re.search(r'_(\d{4})$', folder)
    return m.group(1) if m else ''


def pairs(items: list[dict]) -> list[tuple[str, str]]:
    """(image, xml) for every N.jpg with N.xml, numerically ordered."""
    names = {i['name'] for i in items if i.get('contentType') == 'file'}
    ps = [(n, n[:-4] + '.xml') for n in names if n.lower().endswith('.jpg') and n[:-4] + '.xml' in names]
    return sorted(ps, key=lambda p: (len(p[0]), p[0]))


def _xml(folder: str, xml: str) -> bytes:
    dest = f'raw/{SOURCE}/xml/{folder}/{xml}'
    if not (common.CACHE / dest).exists():
        common.cached(dest, common.get(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{xml}')))
    return (common.CACHE / dest).read_bytes()


def candidates() -> list[common.Candidate]:
    out = []
    for d in ghtree.listing(SOURCE, OWNER, REPO, BRANCH, 'data'):
        if d.get('contentType') != 'directory':
            continue
        folder = d['name']
        ps = pairs(ghtree.listing(SOURCE, OWNER, REPO, BRANCH, f'data/{folder}'))
        if not ps or not ghtree.probe_not_lfs(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{ps[0][0]}')):
            continue
        for img, xml in ps:
            if not truth(_xml(folder, xml)):
                continue    # no transcribed lines: dropped
            out.append(common.Candidate(
                source=SOURCE, collection=folder, page_id=f'{folder}/{img[:-4]}', stratum='L5', licence=LICENCE,
                item_url=ghtree.html_url(OWNER, REPO, BRANCH, f'data/{folder}/{img}'),
                convention='PAGE lines, diplomatic, abbreviations unexpanded (medieval Portuguese/Latin)',
                contamination='low', publish_image=True, script='Latn', era=era_of(folder), kind='handwritten',
                fetch={'image': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{img}'),
                       'xml': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{xml}'), 'ext': 'jpg'}))
    return out


def materialise(c: common.Candidate):
    safe = re.sub(r'[^\w.-]+', '_', c.page_id)
    dest = common.CACHE / 'pages' / SOURCE / f"{safe}.{c.fetch['ext']}"
    t = truth(common.get(c.fetch['xml']))
    if not dest.exists():
        data = common.get(c.fetch['image'])
        if ghtree.is_lfs_pointer(data):
            raise IOError(f'{c.key}: Git LFS pointer')
        common.cached(str(dest.relative_to(common.CACHE)), data)
    return dest, t
