"""W43.corpus-build — `eparchos`: EPARCHOS Greek minuscule (Zenodo 4095301, CC-BY-4.0). Stratum N3.

120 pages of one codex, British Library Add. MS 6791 (c.1500-1530), in two hands, Antonius Eparchos and Camillos
Zanettus (ff. 104r-174v); texts by Hierocles, Blastares and Psellos (the record's description). One zip,
eparchos.zip (115 MB): eparchos/image/6791 (N).png + eparchos/xml/6791 (N).xml. It is read by member over HTTP
ranges, never downloaded: the central directory is cached as JSON, and since the 120 PAGE files sit together in
the zip's last 637 KB they are fetched in one range read and cached, so listing checks every page's text cheaply.

Surprises:
- Each TextLine carries both its own TextEquiv and Word children with theirs; the Word elements are not in
  reading order, so the line text is used (common.page_xml_text reads only a line's direct TextEquiv).
- The file numbers (1-120) are not folio numbers, and nothing in the PAGE says which hand wrote a page, so the
  manuscript is one collection.
- Lines keep the transcription's runs of spaces (a gap left for a rubricated initial: 'Φ   ύσις'), polytonic
  accents and breathings, ':-' end marks and '´' numeral signs. Nothing is stripped.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

import common
import zretry

SOURCE = 'eparchos'
RECORD = 'https://zenodo.org/records/4095301'
ZIP_URL = 'https://zenodo.org/api/records/4095301/files/eparchos.zip/content'
CD_INDEX = f'raw/{SOURCE}/eparchos.cd.json'
XML_BLOCK = f'raw/{SOURCE}/xml-block.bin'
_PAGE = re.compile(r'^eparchos/(image|xml)/(.+)\.(png|xml)$')


def truth(xml_bytes: bytes) -> str:
    """Page text from the line-level TextEquiv, in document order; no markup in this set to strip."""
    return common.page_xml_text(xml_bytes)


def list_pages(names) -> list[tuple[str, str, str]]:
    """(stem, image member, xml member) for every stem with both a PNG and a PAGE file."""
    found: dict[str, dict[str, str]] = {}
    for n in names:
        m = _PAGE.match(n)
        if m and not m.group(2).startswith('.'):
            found.setdefault(m.group(2), {})[m.group(3)] = n
    key = lambda s: [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', s)]
    return [(s, f['png'], f['xml']) for s, f in sorted(found.items(), key=lambda kv: key(kv[0]))
            if 'png' in f and 'xml' in f]


def _zip() -> common.RemoteZip:
    """The remote zip, its directory from the cached JSON, XML members served from the cached block."""
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = zretry.open_zip(ZIP_URL)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    d = json.loads(path.read_text())
    entries = {n: tuple(v) for n, v in d['entries'].items()}
    xml = [v for n, v in entries.items() if n.endswith('.xml')]
    lo = min(v[3] for v in xml)
    hi = max(v[3] for v in xml) + max(v[1] for v in xml) + 1024   # last member's header + data, generously
    hi = min(hi, d['size'] - 1)
    block_path = common.CACHE / XML_BLOCK
    if not block_path.exists():
        common.cached(XML_BLOCK, json.dumps({'start': lo}).encode() + b'\n' + zretry.get_range(ZIP_URL, lo, hi))
    head, block = block_path.read_bytes().split(b'\n', 1)
    start = json.loads(head)['start']

    def read(a: int, b: int) -> bytes:
        if a >= start and b < start + len(block):
            return block[a - start:b - start + 1]
        return zretry.get_range(ZIP_URL, a, b)

    z = common.RemoteZip.__new__(common.RemoteZip)
    z.url, z.size, z.entries, z.read = ZIP_URL, d['size'], entries, read
    return z


def candidates() -> list[common.Candidate]:
    z = _zip()
    out = []
    for stem, img, xml in list_pages(z.names()):
        if not truth(z.member(xml)):     # an untranscribed page (none in the 2020 release)
            continue
        out.append(common.Candidate(
            source=SOURCE, collection='BL Add. MS 6791', page_id=stem.replace(' ', '_'), stratum='N3',
            licence='CC-BY-4.0', item_url=RECORD,
            convention='PAGE lines, polytonic Greek, abbreviations written out (inferred), spacing kept, no markup',
            contamination='low', publish_image=True, script='Grek', era='c.1500', kind='handwritten',
            fetch={'zip': ZIP_URL, 'image': img, 'xml': xml}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    z = _zip()
    text = truth(z.member(f['xml']))
    out = common.CACHE / 'pages' / SOURCE / (re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id) + '.png')
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), zretry.member(z, f['image']))
    return out, text
