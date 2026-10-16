"""Late medieval Castilian HTR dataset (Gille Levenson 2023), Zenodo record 8406222 (v2), CC-BY-NC-SA-4.0.
Stratum L5.

One 2.1 GB zip (data_v2.zip), read by member. Pages sit in corpus/in_domain/<manuscript>/[<hand or unit>/]
and corpus/out_of_domain/ (one or two pages each from ~20 other manuscripts), each as an image plus two ALTO
files: `<page>.xml` (allographetic: ꝺ, ſ, ꝛ, ⁊ kept apart) and `<page>.normalized.xml` (graphematic: each
allograph reduced to its grapheme by the dataset's conversion_table.csv, abbreviations NOT expanded). The
graphematic file is used, as the closer match to the panel's diplomatic prompt.

Surprises:
- The HTR-United catalogue says CC-BY-SA; the Zenodo record says CC-BY-NC-SA-4.0 for the transcriptions and
  that the images are reproduced by permission of each library (© Salamanca, Lázaro Galdiano, Valladolid,
  Escorial). So the licence recorded is the Zenodo one and publish_image is False.
- Esc_M has transcriptions but no image ("pending permission from the library"), so it yields no candidate.
- Images are a mix of jpg, jpeg, png and two tif; the original bytes are kept.
- No per-manuscript date is in the zip or the record; era is the dataset's "late medieval" (inferred
  'c.1250-1500').
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import time

import common

SOURCE = 'castilian'
RECORD = 'https://zenodo.org/records/8406222'
ZIP_URL = 'https://zenodo.org/api/records/8406222/files/data_v2.zip/content'
CD_INDEX = f'raw/{SOURCE}/data_v2.cd.json'
ROOT = 'data_v2/corpus/'
IMAGE_EXT = ('.jpg', '.jpeg', '.png', '.tif', '.tiff')


def truth(xml_bytes: bytes) -> str:
    """Page text, ALTO block by block; the graphematic files carry no editorial markup to strip."""
    return common.alto_text(xml_bytes)


def _directory() -> dict[str, list]:
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = common.RemoteZip(ZIP_URL)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    return json.loads(path.read_text())['entries']


def collection_of(member: str) -> str:
    """The manuscript: the in_domain folder, or for out_of_domain the file stem without its page suffix."""
    rel = member[len(ROOT):].split('/')
    if rel[0] == 'in_domain':
        return rel[1]
    stem = re.sub(r'(\.normalized)?\.[a-z]+$', '', rel[-1])
    stem = re.sub(r'\.pdf_page_\d+$', '', stem)
    return 'ood_' + re.sub(r'_\d{1,2}$|_\d+[rv]$', '', stem)   # calila_2, sem_tob_78r; not Ms_2086


def list_pages(names) -> list[tuple[str, str, str]]:
    """(page id, graphematic ALTO member, image member) for every page that has both."""
    names = set(names)
    out = []
    for n in sorted(names):
        if not n.startswith(ROOT) or not n.endswith('.normalized.xml'):
            continue
        base = n[:-len('.normalized.xml')]
        image = next((base + e for e in IMAGE_EXT if base + e in names), None)
        if image is None:      # Esc_M: transcription without an image
            continue
        out.append((base[len(ROOT):], n, image))
    return out


def _xml(page_id: str, member: str, entry) -> bytes:
    """The graphematic ALTO, cached under raw/ (about 45 KB each, ~16 MB for the source)."""
    path = common.CACHE / 'raw' / SOURCE / 'xml' / f"{re.sub(r'[^A-Za-z0-9._-]', '_', page_id)}.normalized.xml"
    if not path.exists():
        common.cached(str(path.relative_to(common.CACHE)), _member(ZIP_URL, member, entry))
    return path.read_bytes()


def candidates() -> list[common.Candidate]:
    """Fetches every graphematic ALTO once (cached), to drop pages whose text is empty."""
    entries = _directory()
    pages = list_pages(entries)
    with ThreadPoolExecutor(2) as pool:
        texts = list(pool.map(lambda p: truth(_xml(p[0], p[1], entries[p[1]])), pages))
    out = []
    for (page_id, xml, image), text in zip(pages, texts):
        if not text:
            continue
        out.append(common.Candidate(
            source=SOURCE, collection=collection_of(xml), page_id=page_id, stratum='L5',
            licence='CC-BY-NC-SA-4.0', item_url=RECORD,
            convention='ALTO lines, graphematic (allographs merged), abbreviations unexpanded',
            contamination='low', publish_image=False, script='Latn', era='c.1250-1500', kind='handwritten',
            fetch={'zip_url': ZIP_URL, 'xml_member': xml, 'xml_entry': entries[xml],
                   'image_member': image, 'image_entry': entries[image]}))
    return out


def _member(url: str, name: str, entry, tries: int = 4) -> bytes:
    """One zip member in ONE range request (local header guessed at 30 + name + 256 bytes of extra field,
    which RemoteZip.member then trims), retried with a pause: Zenodo answers 429 past ~130 requests/min."""
    method, csize, usize, off = entry
    window = 30 + len(name.encode()) + 256 + csize
    blob = None
    for i in range(tries):
        try:
            blob = common.get_range(url, off, off + window - 1)
            break
        except (subprocess.CalledProcessError, IOError):
            if i == tries - 1:
                raise
            time.sleep(20 * (i + 1))
    z = common.RemoteZip.__new__(common.RemoteZip)
    z.url, z.entries = url, {name: (method, csize, usize, 0)}
    z.read = lambda a, b: blob[a:b + 1]
    return z.member(name)


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    text = truth(_xml(c.page_id, f['xml_member'], f['xml_entry']))
    safe = re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id)
    ext = f['image_member'].rsplit('.', 1)[-1].lower()
    out = common.CACHE / 'pages' / SOURCE / f'{safe}.{ext}'
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), _member(f['zip_url'], f['image_member'], f['image_entry']))
    return out, text
