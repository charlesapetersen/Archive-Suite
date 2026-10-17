"""OCR-D gt_structure_text (github.com/OCR-D/gt_structure_text, branch master), stratum L8.

Licence: CC-BY-SA-4.0. 69 early-modern and 19th-century printed documents (de/la/fr/en/he), one folder each:
data/<author_title_year>/GT-PAGE/<doc>_NNNN.tif + <doc>_NNNN.xml (PAGE 2019, in the repo, TIFFs about 10 MB,
not LFS). Surprising: some folders also hold <doc>_NNNN_B.tif (a binarised copy) with no XML of its own; only
the tif whose stem matches an .xml is the page image. Truth is the TextLine TextEquiv in reading order (regions
by ReadingOrder); pages with no line-level text (region TextEquiv only) are dropped, as are empty pages. Long s,
ligatures and other GT characters are kept as written. The language is the majority TextRegion
primaryLanguage (else `language`), recorded in fetch['language'] and in the convention string.
"""
from __future__ import annotations

import collections
import re
import xml.etree.ElementTree as ET

import common
import ghtree

SOURCE = 'ocrd'
OWNER, REPO, BRANCH = 'OCR-D', 'gt_structure_text', 'master'


def _local(t: str) -> str:
    return t.rsplit('}', 1)[-1]


def line_count(xml: bytes) -> int:
    """TextLines that carry their own text (page_xml_text falls back to region text, which we refuse)."""
    n = 0
    for ln in ET.fromstring(xml).iter():
        if _local(ln.tag) != 'TextLine':
            continue
        for ch in ln:
            if _local(ch.tag) == 'TextEquiv' and any(_local(u.tag) == 'Unicode' and (u.text or '').strip() for u in ch):
                n += 1
                break
    return n


def truth(xml: bytes) -> str:
    return common.page_xml_text(xml) if line_count(xml) else ''


def language(xml: bytes) -> str:
    """Majority primaryLanguage (else language) over the TextRegions; when no region sets one (some pages put
    it on the Page/TextLine/Word only), over all elements that do; '' when none is set."""
    regions, anywhere = collections.Counter(), collections.Counter()
    for r in ET.fromstring(xml).iter():
        lang = r.get('primaryLanguage') or r.get('language')
        if lang:
            anywhere[lang] += 1
            if _local(r.tag) == 'TextRegion':
                regions[lang] += 1
    c = regions or anywhere
    return c.most_common(1)[0][0] if c else ''


def era_of(folder: str) -> str:
    m = re.search(r'_(\d{4})(?:_|$)', folder)    # also hohberg_georgica01_1682_teil1
    return m.group(1) if m else ''


def pairs(items: list[dict]) -> list[tuple[str, str]]:
    """(tif, xml) where the xml has the same stem; '<stem>_B.tif' binarised copies are not pages."""
    names = {i['name'] for i in items if i.get('contentType') == 'file'}
    return sorted((n, n[:-4] + '.xml') for n in names if n.endswith('.tif') and n[:-4] + '.xml' in names)


def _xml(folder: str, xml: str) -> bytes:
    dest = f'raw/{SOURCE}/xml/{folder}/{xml}'
    if not (common.CACHE / dest).exists():
        common.cached(dest, common.get(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE/{xml}')))
    return (common.CACHE / dest).read_bytes()


def candidates() -> list[common.Candidate]:
    out = []
    for d in ghtree.listing(SOURCE, OWNER, REPO, BRANCH, 'data'):
        if d.get('contentType') != 'directory':
            continue
        folder = d['name']
        sub = ghtree.listing(SOURCE, OWNER, REPO, BRANCH, f'data/{folder}')
        if not any(i['name'] == 'GT-PAGE' for i in sub):
            continue
        ps = pairs(ghtree.listing(SOURCE, OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE'))
        if not ps or not ghtree.probe_not_lfs(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE/{ps[0][0]}')):
            continue
        for tif, xml in ps:
            data = _xml(folder, xml)
            if not truth(data):
                continue    # no line-level text: dropped
            lang = language(data)
            out.append(common.Candidate(
                source=SOURCE, collection=folder, page_id=f'{folder}/{tif[:-4]}', stratum='L8',
                licence='CC-BY-SA-4.0',
                item_url=ghtree.html_url(OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE/{tif}'),
                convention=f'PAGE TextLine text, OCR-D GT, long s and ligatures as written; language {lang or "unset"}',
                contamination='medium', publish_image=True, script='Latn', era=era_of(folder), kind='print',
                fetch={'image': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE/{tif}'),
                       'xml': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/GT-PAGE/{xml}'),
                       'ext': 'tif', 'language': lang}))
    return out


def materialise(c: common.Candidate):
    safe = re.sub(r'[^\w.-]+', '_', c.page_id)
    dest = common.CACHE / 'pages' / SOURCE / f"{safe}.{c.fetch['ext']}"
    t = truth(common.get(c.fetch['xml']))
    if not dest.exists():
        _download(c, dest)
        if ghtree.is_lfs_pointer(dest.open('rb').read(1024)):
            dest.unlink()
            raise IOError(f'{c.key}: Git LFS pointer')
    return dest, t


def _download(c: common.Candidate, dest) -> None:
    """Whole tif, straight to the cache (fetch.sh writes a .part and renames it). Most are about 10 MB, but six of
    the 80 drawn on 2026-10-17 were over the 20 MB that `get` (fetch.sh --stdout) allows, and failed every time."""
    common.download(c.fetch['image'], str(dest.relative_to(common.CACHE)))
