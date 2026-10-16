"""Königsfelden Abbey charters (Staatsarchiv Aargau), Zenodo record 5179361, CC-BY-4.0. Stratum L7.

Transkribus PAGE exports of the U-17 charter series (u17_pageXML.zip, 21 MB) and of the two Kopialbücher
AA/0428 and AA/0429 (kbs_pageXML.zip, 8 MB), plus the images as one 21 GB zip64 (digitized_documents.zip,
read by member). Per-charter dates come from all_teis.zip (19 MB, one TEI per charter, `<origDate when>`).

Surprises:
- digitized_documents.zip holds only U-17, Stadtarchiv Brugg and FRAD068 images. The Kopialbücher pages
  (saa-0428_*.jpg, saa-AA0429_*.jpg) are not in it (their images are on e-codices, not an allowed host), and
  Brugg/FRAD have images but no PAGE in the two exports. So only U-17 charters are candidates.
- A PAGE file's imageFilename is matched to a JPEG member by file stem, case-insensitively: some PAGE files
  name a .TIF/.tiff original, and some name a bare stem ('0552_r.jpg') that the zip stores as 'U-17_0552_r.jpg'.
- The record runs to 1662; L7 is "before 1600", so charters dated 1600 or later by their TEI are dropped.
  Charters with no TEI date are kept with era '1308-1662'.
- The text is diplomatic, abbreviations unexpanded (expansions live only in the TextLine `custom` attribute,
  which is not read). '✳' is the edition's sign for the charter's own punctus/separators, '¬' its line-end
  hyphen; both are kept, as are MUFI private-use characters (U+F2F7 etc.). Archival stamps and shelf notes
  that are on the image are transcribed as regions and kept.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import zipfile

import common

SOURCE = 'koenigsfelden'
RECORD = 'https://zenodo.org/records/5179361'
FILES = 'https://zenodo.org/api/records/5179361/files/{}/content'
IMAGES_URL = FILES.format('digitized_documents.zip')
XML_ZIPS = ('u17_pageXML.zip', 'kbs_pageXML.zip')
CD_INDEX = f'raw/{SOURCE}/digitized_documents.cd.json'
LATEST_YEAR = 1599


def truth(xml_bytes: bytes) -> str:
    """Page text in reading order; the source has no editorial markup to strip."""
    return common.page_xml_text(xml_bytes)


def _image_directory() -> dict[str, list]:
    """Member name -> (method, csize, usize, offset) of the 21 GB image zip, cached as JSON after one read."""
    path = common.CACHE / CD_INDEX
    if not path.exists():
        z = common.RemoteZip(IMAGES_URL)
        common.cached(CD_INDEX, json.dumps({'size': z.size, 'entries': z.entries}).encode())
    return json.loads(path.read_text())['entries']


def image_index(names) -> dict[str, str]:
    """Lower-case file stem -> member name, for the JPEGs in the image zip."""
    out = {}
    for n in names:
        base = n.rsplit('/', 1)[-1]
        if base.startswith('.') or not base.lower().endswith('.jpg'):
            continue
        out[base.rsplit('.', 1)[0].lower()] = n
    return out


def match_image(image_filename: str, doc: str, index: dict[str, str]) -> str | None:
    """The JPEG member for a PAGE imageFilename, trying the bare stem and the document-prefixed stem."""
    stem = image_filename.rsplit('/', 1)[-1].rsplit('.', 1)[0].lower()
    for key in (stem, 'u-17_' + stem):
        if key in index:
            return index[key]
    return None


def tei_dates(tei_zip: zipfile.ZipFile) -> dict[str, str]:
    """Charter name (lower case, e.g. 'u-17_0059b') -> its origDate year or date string."""
    out = {}
    for n in tei_zip.namelist():
        if n.startswith('__MACOSX') or not n.endswith('.xml'):
            continue
        m = re.search(rb'<origDate\b[^>]*?\b(?:when|notBefore|from)="(-?\d{3,4})', tei_zip.read(n))
        if m:
            out[n.rsplit('/', 1)[-1][:-4].lower()] = m.group(1).decode()
    return out


def list_pages(xml_zip: zipfile.ZipFile, index: dict[str, str], dates: dict[str, str]):
    """Yield (doc, page XML member, image member, era) for every page with text, a matched image and a
    date before 1600 (or no date)."""
    for n in xml_zip.namelist():
        parts = n.split('/')
        if len(parts) < 2 or parts[-2] != 'page' or not n.endswith('.xml'):
            continue
        doc = parts[-3]
        data = xml_zip.read(n)
        m = re.search(rb'imageFilename="([^"]+)"', data)
        if not m:
            continue
        member = match_image(m.group(1).decode(), doc, index)
        if member is None or not truth(data):   # no image in the zip, or an untranscribed page
            continue
        year = dates.get(doc.lower())
        if year and int(year) > LATEST_YEAR:
            continue
        yield doc, n, member, year or '1308-1662'


def candidates() -> list[common.Candidate]:
    entries = _image_directory()
    index = image_index(entries)
    tei = common.download(FILES.format('all_teis.zip'), f'raw/{SOURCE}/all_teis.zip')
    with zipfile.ZipFile(tei) as t:
        dates = tei_dates(t)
    out, seen = [], set()
    for zip_name in XML_ZIPS:
        local = common.download(FILES.format(zip_name), f'raw/{SOURCE}/{zip_name}')
        with zipfile.ZipFile(local) as z:
            for doc, xml_member, img_member, era in list_pages(z, index, dates):
                page_id = img_member.rsplit('/', 1)[-1].rsplit('.', 1)[0]
                if page_id in seen:    # the same image exported twice: keep the first
                    continue
                seen.add(page_id)
                out.append(common.Candidate(
                    source=SOURCE, collection=re.sub(r'^u-17', 'U-17', doc), page_id=page_id,
                    stratum='L7', licence='CC-BY-4.0', item_url=RECORD,
                    convention='PAGE lines (Transkribus), diplomatic, abbreviations unexpanded, ✳ and ¬ kept',
                    contamination='low', publish_image=True, script='Latn', era=era, kind='handwritten',
                    fetch={'xml_zip': zip_name, 'xml_member': xml_member, 'image_url': IMAGES_URL,
                           'image_member': img_member, 'image_entry': entries[img_member]}))
    return out


def _remote_member(url: str, name: str, entry) -> bytes:
    z = common.RemoteZip.__new__(common.RemoteZip)
    z.url, z.entries = url, {name: tuple(entry)}
    z.read = lambda a, b: common.get_range(url, a, b)
    return z.member(name)


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    with zipfile.ZipFile(common.download(FILES.format(f['xml_zip']), f"raw/{SOURCE}/{f['xml_zip']}")) as z:
        text = truth(z.read(f['xml_member']))
    ext = f['image_member'].rsplit('.', 1)[-1].lower()
    out = common.CACHE / 'pages' / SOURCE / f'{re.sub(r"[^A-Za-z0-9._-]", "_", c.page_id)}.{ext}'
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)),
                      _remote_member(f['image_url'], f['image_member'], f['image_entry']))
    return out, text
