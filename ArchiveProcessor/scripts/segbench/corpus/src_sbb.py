"""SBB newspaper annotations (Zenodo 2583866, CC0): excluded from OCR truth after visual audit.

The record calls these OCR/OLR ground truth, but gt_page.zip's TextEquiv has systematic wrong words in
readable scan text (00675574, 00675515, 00675581, 00675590) and FineReader Engine 10 provenance.
It is not reliable whole-page transcription truth. Keep the parser for inspecting that finding, but
contribute NO candidates, rather than removing just low-scoring pages. W43.corpus-build-more, 2026-10-18.

50 newspaper pages from the Europeana Newspapers project: gt_page.zip (PAGE 2010-03-19, pc-<id>.xml) and
img_full.zip (<id>.tif, full-resolution scans), both small and read from CACHE/raw/sbb/ (downloaded whole if
missing). ocr_full.zip / ocr_bin.zip (FineReader output) and img_bin.zip are not used.

Parser observations (not evidence of corrected transcription):
- The text is region-level: each TextRegion has one TextEquiv whose Unicode holds the region's lines separated
  by '\\n'; there are no TextLines. The ReadingOrder is an UnorderedGroup of OrderedGroups (and nested
  UnorderedGroups of plain RegionRefs, which common.page_xml_text does not rank). So truth() walks the
  ReadingOrder itself: groups in the order they are written, an OrderedGroup's members by index; the few
  regions no group names (usually a page number) go last, in document order.
- The text includes long s, MUFI private-use ligatures (U+F502 'ch', U+F4F9 'll', U+EEC4 'ck', ...), '⸗'
  and U+FFFD. The initial parser rejected pages with more than 1% U+FFFD (6 pages) or a TableRegion (3 pages).
  That was insufficient: readable words in the remaining 41 are also mistranscribed.
- Neither the file names (a running image number) nor the PAGE metadata name the newspaper or its date; the
  title appears only on pages that carry the masthead. So era is the year most often named in the page's own
  text (inferred, 1799-1940 across the set, wider than L9's 1850-1920), and collection is that year's decade.
"""
from __future__ import annotations

import collections
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

import common
import zretry

SOURCE = 'sbb'
RECORD = 'https://zenodo.org/records/2583866'
FILES = 'https://zenodo.org/api/records/2583866/files/{}/content'
GT_ZIP, IMG_ZIP = 'gt_page.zip', 'img_full.zip'
MAX_ILLEGIBLE = 0.01
_YEAR = re.compile(r'(?<!\d)(1[78]\d\d|19[0-4]\d)(?!\d)')


def _local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def _unicode_of(el) -> str:
    for child in el:
        if _local(child.tag) == 'TextEquiv':
            for u in child:
                if _local(u.tag) == 'Unicode':
                    return u.text or ''
    return ''


def _order(group) -> list[str]:
    """Region ids in reading order under one ReadingOrder group, nested groups expanded where they stand."""
    kids = [k for k in group if _local(k.tag) != 'Labels']
    if _local(group.tag).startswith('OrderedGroup'):
        kids.sort(key=lambda k: int(k.get('index', 0)))
    out = []
    for k in kids:
        t = _local(k.tag)
        if t in ('RegionRef', 'RegionRefIndexed'):
            out.append(k.get('regionRef'))
        elif 'Group' in t:
            out.extend(_order(k))
    return out


def parse(xml_bytes: bytes) -> tuple[str, bool]:
    """(page text, has a TableRegion)."""
    root = ET.fromstring(xml_bytes)
    regions = [e for e in root.iter() if _local(e.tag) == 'TextRegion']
    by_id = {r.get('id'): r for r in regions}
    ids = []
    for ro in (e for e in root.iter() if _local(e.tag) == 'ReadingOrder'):
        ids.extend(_order(ro))
    seen, ordered = set(), []
    for i in ids + [r.get('id') for r in regions]:
        if i in by_id and i not in seen:
            seen.add(i)
            ordered.append(by_id[i])
    blocks = [t.strip('\n') for t in (_unicode_of(r) for r in ordered)]
    text = '\n\n'.join(b for b in blocks if b.strip())
    return text.strip(), any(_local(e.tag) == 'TableRegion' for e in root.iter())


def truth(xml_bytes: bytes) -> str:
    """Supplied text, regions in ReadingOrder; characters (MUFI PUA, U+FFFD, ſ, ⸗) kept as written."""
    return parse(xml_bytes)[0]


def year_of(text: str) -> str:
    """The year the page names most often (ties: the later), or '' when it names none."""
    years = collections.Counter(_YEAR.findall(text))
    if not years:
        return ''
    return max(years.items(), key=lambda kv: (kv[1], kv[0]))[0]


def usable(text: str, has_table: bool) -> bool:
    return bool(text) and not has_table and text.count('�') <= MAX_ILLEGIBLE * len(text)


def list_pages(gt: zipfile.ZipFile, image_names) -> list[tuple[str, str, str, str]]:
    """(id, xml member, image member, year) for every usable page with an image."""
    images = {n.rsplit('/', 1)[-1].rsplit('.', 1)[0]: n for n in image_names if n.lower().endswith('.tif')}
    out = []
    for n in sorted(gt.namelist()):
        m = re.match(r'(?:.*/)?pc-(\d+)\.xml$', n)
        if not m or m.group(1) not in images:
            continue
        text, table = parse(gt.read(n))
        if usable(text, table):
            out.append((m.group(1), n, images[m.group(1)], year_of(text)))
    return out


def _zip(name: str) -> Path:
    path = common.CACHE / 'raw' / SOURCE / name
    if not path.exists():
        zretry.retry(common.download, FILES.format(name), f'raw/{SOURCE}/{name}')
    return path


def candidates() -> list[common.Candidate]:
    return []  # Source-wide truth-quality exclusion, not a score-based page filter.


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    with zipfile.ZipFile(_zip(f['gt_zip'])) as gt:
        text = truth(gt.read(f['xml']))
    out = common.CACHE / 'pages' / SOURCE / (re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id) + '.tif')
    if not out.exists():
        with zipfile.ZipFile(_zip(f['img_zip'])) as im:
            common.cached(str(out.relative_to(common.CACHE)), im.read(f['image']))
    return out, text
