"""Muharaf, public part — handwritten Arabic manuscripts, letters, diaries and ledgers, 19th-20th c.
(Saeed et al. 2024), Zenodo record 11492215, CC-BY-NC-SA-2.0 (record metadata). Stratum N1.

One 3.1 GB zip (public_data_files.zip), read by member: 1,216 pages under public/, each as <stem>.jpg or .JPG,
<stem>.xml (PAGE 2019) and two to three JSON files: <stem>.json (the tool's working state), <stem>_tagged.json
(line text + region tags) and <stem>_annotate_<transcriber>.json (one transcriber's pass). The PAGE-XML is the
export of the tagged file after QA (its Metadata names taggingBy and transcription_QA) and is the only file with
a ReadingOrder, so it is the truth used here.

Surprises:
- The ReadingOrder nests OrderedGroupIndexed "records" (one per letter or entry on the page), each restarting
  its RegionRefIndexed index at 0, so common.page_xml_text's flat sort would interleave records; truth() walks
  the groups in order instead.
- Each TextLine carries its text in TextEquiv/Unicode only; regions have none. There is no editorial markup.
  Line-end spaces are trimmed and the tabs transcribers used for a gap or indent (about 1 line in 60) become one
  space; nothing else changes: harakat, Arabic-Indic digits, '(١)' footnote marks, and the '__' / '____' runs
  that stand for a drawn dash between sentences stay as written.
- Some lines are print (letterheads, a printed book page: production="printed", ~4% of lines), the rest
  handwritten-cursive; kind is 'handwritten' for every page.
- The collection is the file-name prefix (archive box/collection code, e.g. AR56, JoM, kc0066); the KJoseph
  letters carry their date in the prefix (KJoseph19040819) and are folded into one 'KJoseph' collection.
- Images and text share the record's CC-BY-NC-SA-2.0, so publish_image is True, non-commercial page only.
- No per-page date in the zip; era is the dataset's 1800-2000 (inferred from the plan table).
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import time
import xml.etree.ElementTree as ET

import common
import zretry

SOURCE = 'muharaf'
RECORD = 'https://zenodo.org/records/11492215'
ZIP_URL = 'https://zenodo.org/api/records/11492215/files/public_data_files.zip/content'
CD_INDEX = f'raw/{SOURCE}/cd.json'
ROOT = 'public/'
PAUSE = 1.0          # seconds between Zenodo requests; other readers share the rate limit


def _local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def _order(el) -> list[str]:
    """Region ids from a ReadingOrder subtree, groups and refs taken by their index, depth first."""
    kids = [k for k in el if _local(k.tag) in
            ('OrderedGroup', 'OrderedGroupIndexed', 'UnorderedGroup', 'UnorderedGroupIndexed',
             'RegionRef', 'RegionRefIndexed')]
    kids.sort(key=lambda k: int(k.get('index', 0)))     # stable: unindexed keep document order
    out = []
    for k in kids:
        if _local(k.tag).startswith('RegionRef'):
            out.append(k.get('regionRef'))
        else:
            out.extend(_order(k))
    return out


def truth(xml_bytes: bytes) -> str:
    """Page text: text regions in ReadingOrder (unlisted ones after, in document order), a blank line between
    regions, the region's TextLines in document order."""
    root = ET.fromstring(xml_bytes)
    regions = {r.get('id'): r for r in root.iter() if _local(r.tag) == 'TextRegion'}
    ro = next((e for e in root.iter() if _local(e.tag) == 'ReadingOrder'), None)
    ids = [i for i in (_order(ro) if ro is not None else []) if i in regions]
    ids = list(dict.fromkeys(ids)) + [i for i in regions if i not in ids]
    blocks = []
    for rid in ids:
        lines = []
        for ln in regions[rid]:
            if _local(ln.tag) != 'TextLine':
                continue
            u = next((u for te in ln if _local(te.tag) == 'TextEquiv'
                      for u in te if _local(u.tag) == 'Unicode'), None)
            t = re.sub(r' *\t[\t ]*', ' ', u.text or '').strip() if u is not None else ''
            if t:
                lines.append(t)
        if lines:
            blocks.append('\n'.join(lines))
    return '\n\n'.join(blocks)


def collection_of(stem: str) -> str:
    """File-name prefix up to the first '_' or '-'; KJoseph<yyyymmdd> letters folded into one."""
    head = re.split(r'[_-]', stem, maxsplit=1)[0]
    return re.sub(r'^KJoseph\d{8}$', 'KJoseph', head)


def _directory() -> dict[str, list]:
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = zretry.open_zip(ZIP_URL)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    return json.loads(path.read_text())['entries']


def list_pages(names) -> list[tuple[str, str, str]]:
    """(page id = file stem, PAGE-XML member, image member) for every page with both."""
    names = set(names)
    out = []
    for n in sorted(names):
        if not n.startswith(ROOT) or not n.endswith('.xml'):
            continue
        image = next((n[:-4] + e for e in ('.jpg', '.JPG', '.jpeg', '.JPEG') if n[:-4] + e in names), None)
        if image is None:
            continue
        out.append((n[len(ROOT):-4], n, image))
    return out


def _member(name: str, entry) -> bytes:
    """One zip member in ONE range request (local header guessed at 30 + name + 256 bytes of extra field)."""
    method, csize, usize, off = entry
    window = 30 + len(name.encode()) + 256 + csize
    blob = zretry.get_range(ZIP_URL, off, off + window - 1)
    time.sleep(PAUSE)
    z = common.RemoteZip.__new__(common.RemoteZip)
    z.url, z.entries = ZIP_URL, {name: (method, csize, usize, 0)}
    z.read = lambda a, b: blob[a:b + 1]
    return z.member(name)


def _xml(page_id: str, member: str, entry) -> bytes:
    """The PAGE-XML, cached under raw/ (about 15 KB each, ~20 MB for the source)."""
    path = common.CACHE / 'raw' / SOURCE / 'xml' / f"{re.sub(r'[^A-Za-z0-9._-]', '_', page_id)}.xml"
    if not path.exists():
        common.cached(str(path.relative_to(common.CACHE)), _member(member, entry))
    return path.read_bytes()


def candidates() -> list[common.Candidate]:
    """Fetches every PAGE-XML once (cached; ~20 minutes at one request a second), to drop empty pages."""
    entries = _directory()
    out = []
    for page_id, xml, image in list_pages(entries):
        if not truth(_xml(page_id, xml, entries[xml])):
            continue
        out.append(common.Candidate(
            source=SOURCE, collection=collection_of(page_id), page_id=page_id, stratum='N1',
            licence='CC-BY-NC-SA-2.0', item_url=RECORD,
            convention='PAGE lines in ReadingOrder, logical-order Unicode, expert-transcribed and QA-checked',
            contamination='low', publish_image=True, script='Arab', era='1800-2000', kind='handwritten',
            fetch={'zip_url': ZIP_URL, 'xml_member': xml, 'xml_entry': entries[xml],
                   'image_member': image, 'image_entry': entries[image]}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    text = truth(_xml(c.page_id, f['xml_member'], f['xml_entry']))
    safe = re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id)
    ext = f['image_member'].rsplit('.', 1)[-1]
    out = common.CACHE / 'pages' / SOURCE / f'{safe}.{ext}'
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), _member(f['image_member'], f['image_entry']))
    return out, text
