"""BiblIA — medieval Hebrew manuscripts (Stökl Ben Ezra et al., HIP@ICDAR 2021), Zenodo record 5167263,
CC-BY-NC-SA-4.0 (record metadata and README.txt). Stratum N4.

One 546 MB zip (BiblIA_dataset.zip), read by member. 202 ALTO 4.2 pages under BiblIA_dataset/<script style>/
(Ashkenazy, Italian, Sephardi), plus catalogue.txt (tab-separated: filename, script_type, library, Shelfmark,
Date, Biblical_or_Rabbinic, ...) and README.txt.

Surprises:
- Only the 132 BnF pages ship their .jpg; the 70 BAV pages are IIIF links only (digi.vatlib.it, not an allowed
  host and not reproducible), so they yield no candidate. Of the Italian hand, that leaves 13 pages.
- One String per TextLine (eScriptorium export), text in logical order. Every BnF block is tagged Main (BT2):
  only the biblical / main text columns are transcribed, NOT the masora or marginal notes, which most pages
  carry. So a model reading the whole page will emit text the truth lacks; the convention string says so.
- Editorial brackets and parentheses: see clean_line().
- 82 of the 132 BnF rows have no date; their era is 'medieval' (the dataset's own word).
- The BnF images ship inside the CC-BY-NC-SA-4.0 dataset (the BAV ones were left out "for copyright issues"),
  so publish_image is True, non-commercial page only (plan Part 1: "yes, NC-SA").
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import time

import common
import zretry

SOURCE = 'biblia'
RECORD = 'https://zenodo.org/records/5167263'
ZIP_URL = 'https://zenodo.org/api/records/5167263/files/BiblIA_dataset.zip/content'
CD_INDEX = f'raw/{SOURCE}/cd.json'
ROOT = 'BiblIA_dataset/'
CATALOGUE = ROOT + 'catalogue.txt'
PAUSE = 1.0          # seconds between Zenodo requests; other readers share the rate limit


_FILLER = re.compile(r'(?:^|\s)\[[^\]]*\]\s*$')     # a whole bracketed token ending the line
_STROKE = re.compile(r'\[[^\]]*/[^\]]*\]')         # a group holding a filler stroke, anywhere
_ADDED = re.compile(r'\[([^\]]*)\]')
_DELETED = re.compile(r'\(([^)]*)\)')


def clean_line(line: str) -> str:
    """The reading text of one line. The transcriptions mark, Leiden-style (inferred from 1,260 bracket and
    119 parenthesis groups, checked against the image of btv1b10539358v):
      `[x]` as a whole token at line end: a line filler (an anticipated fragment of the next line's first word,
             'ואת [הכר\']' then 'הכרעים', or a filler stroke '[/]', '[א/]') — dropped;
      `[../]` anywhere: a filler with its stroke, mid-line where a column break or a gap follows — dropped;
      `[x]` elsewhere: letters added above the line or in the margin, 'היר[י]עת' — kept, brackets dropped;
      `(x)`: letters the scribe cancelled, 'חז(ה)אל' — dropped.
    Everything else is kept as written: the apostrophe abbreviation mark, the cancellation dots '˙', ':'."""
    line = _FILLER.sub('', line)
    line = _STROKE.sub('', line)
    line = _DELETED.sub('', line)
    line = _ADDED.sub(r'\1', line)
    return re.sub(r'  +', ' ', line).strip()


def truth(xml_bytes: bytes) -> str:
    """Page text, ALTO block by block, each line through clean_line(). Vowel points and cantillation marks,
    where a transcriber kept them (one page of 132), stay. Blocks (the page's columns) are read right to left:
    the files list them in no fixed order (found by hand in the 2026-10-17 sanity pass: Deut. 3:28 before 3:23)."""
    blocks = []
    for blk in common.alto_text(xml_bytes, rtl=True).split('\n\n'):
        lines = [t for t in (clean_line(ln) for ln in blk.split('\n')) if t]
        if lines:
            blocks.append('\n'.join(lines))
    return '\n\n'.join(blocks)


def _directory() -> dict[str, list]:
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = zretry.open_zip(ZIP_URL)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    return json.loads(path.read_text())['entries']


def parse_catalogue(text: str) -> dict[str, dict]:
    """catalogue.txt rows keyed by the xml file name."""
    lines = [ln.rstrip('\r') for ln in text.split('\n') if ln.strip()]
    head = [h.strip() for h in lines[0].split('\t')]
    out = {}
    for ln in lines[1:]:
        row = dict(zip(head, (v.strip() for v in ln.split('\t'))))
        if row.get('filename'):
            out[row['filename']] = row
    return out


def list_pages(names) -> list[tuple[str, str, str]]:
    """(page id, ALTO member, image member) for every page whose .jpg is in the zip."""
    names = set(names)
    out = []
    for n in sorted(names):
        if not n.startswith(ROOT) or not n.endswith('.xml'):
            continue
        image = n[:-4] + '.jpg'
        if image not in names:          # BAV page: IIIF only
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


def _raw(member: str, entry) -> bytes:
    """A small member (ALTO, catalogue), cached under raw/<source>/."""
    path = common.CACHE / 'raw' / SOURCE / member[len(ROOT):]
    if not path.exists():
        common.cached(str(path.relative_to(common.CACHE)), _member(member, entry))
    return path.read_bytes()


def candidates() -> list[common.Candidate]:
    """Fetches the catalogue and every BnF ALTO once (cached, ~6 MB), to drop pages whose text is empty."""
    entries = _directory()
    cat = parse_catalogue(_raw(CATALOGUE, entries[CATALOGUE]).decode('utf-8'))
    out = []
    for page_id, xml, image in list_pages(entries):
        if not truth(_raw(xml, entries[xml])):
            continue
        row = cat.get(xml.rsplit('/', 1)[-1], {})
        style = row.get('script_type') or page_id.split('/')[0]
        genre = row.get('Biblical_or_Rabbinic', '')
        out.append(common.Candidate(
            source=SOURCE, collection=row.get('Shelfmark') or page_id, page_id=page_id, stratum='N4',
            licence='CC-BY-NC-SA-4.0', item_url=RECORD,
            convention=(f'ALTO lines, main text only (masora untranscribed), fillers and cancellations '
                        f'dropped, {style} hand' + (f', {genre}' if genre else '')),
            contamination='low', publish_image=True, script='Hebr', era=row.get('Date') or 'medieval',
            kind='handwritten',
            fetch={'zip_url': ZIP_URL, 'xml_member': xml, 'xml_entry': entries[xml],
                   'image_member': image, 'image_entry': entries[image]}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    text = truth(_raw(f['xml_member'], f['xml_entry']))
    safe = re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id)
    out = common.CACHE / 'pages' / SOURCE / f'{safe}.jpg'
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), _member(f['image_member'], f['image_entry']))
    return out, text
