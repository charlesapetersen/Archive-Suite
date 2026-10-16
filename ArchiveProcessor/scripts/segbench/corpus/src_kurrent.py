"""W43.corpus-build — `kurrent`: German Kurrent, 19th century (Zenodo 17252677, one 7.7 GB zip).

Full-page images + PAGE-XML under data/pages/<collection>/(pageAndXml|pngAndXml)/<stem>.(png|xml); the
annotatedJpeg folders, data/lines (line crops), __MACOSX and .DS_Store are ignored. The zip is read member by
member (RemoteZip), never downloaded.

Licence (data/README.md and each collection's README.md): images CC0 / public domain throughout; text per
collection, DTA collections CC BY 4.0, Bayerische Schriftkunde collections (Heroldenamt, Maria Theresia,
Reichsstadt Nuernberg) transcriptions CC BY-NC-SA 4.0, Senatsprotokolle (Tuebingen) images public domain with
the text under the record's CC BY 4.0. Transcription follows OCR-D level 2 (diplomatic: long s and abbreviations
kept). Senatsprotokolle_LowBoundingBoxQuality has poor line boxes only; its text is complete, so it stays.
PNG page images are large (the Senatsprotokolle ones are 5692x9032).
"""
from __future__ import annotations

from pathlib import Path
import re

import common
import zretry

SOURCE = 'kurrent'
RECORD = 'https://zenodo.org/records/17252677'
ZIP_URL = 'https://zenodo.org/api/records/17252677/files/data.zip/content'
STRATUM = 'L6'
CONTAMINATION = 'medium'

# collection folder -> (licence of the text, era, kind). From each collection's README.md.
COLLECTIONS = {
    'AuerbachBertholdBrief': ('CC-BY-4.0', '1869-1880'),
    'ErbkamTagebuch': ('CC-BY-4.0', '1842'),
    'HufelandOtto': ('CC-BY-4.0', '1829'),
    'LibeltKarolKosmos': ('CC-BY-4.0', '1828'),
    'HeroldenamtAkten': ('CC-BY-NC-SA-4.0', '1894'),
    'MariaTheresia': ('CC-BY-NC-SA-4.0', '1824'),
    'ReichsstadtNuernbergRatsverlaesse': ('CC-BY-NC-SA-4.0', '1806'),
    'Senatsprotokolle': ('CC-BY-4.0', '1799-1847'),
    'Senatsprotokolle_LowBoundingBoxQuality': ('CC-BY-4.0', '1799-1847'),
}
_PAGE = re.compile(r'^data/pages/([^/]+)/(?:pageAndXml|pngAndXml)/([^/]+)\.(png|xml)$')


def truth(xml_bytes: bytes) -> str:
    """Page text from the PAGE-XML: lines in region reading order; no markup in this set to strip."""
    return common.page_xml_text(xml_bytes)


def list_pages(names) -> list[tuple[str, str, str, str]]:
    """(collection, stem, image member, xml member) for every stem that has both files."""
    found: dict[tuple[str, str], dict[str, str]] = {}
    for n in names:
        m = _PAGE.match(n)
        if m and '__MACOSX' not in n and not n.rsplit('/', 1)[-1].startswith('._'):
            found.setdefault((m.group(1), m.group(2)), {})[m.group(3)] = n
    return [(c, s, f['png'], f['xml']) for (c, s), f in sorted(found.items()) if 'png' in f and 'xml' in f]


def candidates() -> list[common.Candidate]:
    z = zretry.open_zip(ZIP_URL)
    out = []
    for coll, stem, img, xml in list_pages(z.names()):
        licence, era = COLLECTIONS.get(coll, ('CC-BY-NC-SA-4.0', ''))
        out.append(common.Candidate(
            source=SOURCE, collection=coll, page_id=f'{coll}/{stem}', stratum=STRATUM, licence=licence,
            item_url=RECORD, convention='PAGE lines, OCR-D level 2 diplomatic (long s, abbreviations kept)',
            contamination=CONTAMINATION, publish_image=True, script='Latn', era=era, kind='handwritten',
            fetch={'zip': ZIP_URL, 'image': img, 'xml': xml}))
    return out


def materialise(c: common.Candidate):
    f = c.fetch
    dest = common.CACHE / 'pages' / SOURCE / (re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id) + '.png')
    z = zretry.open_zip(f['zip'])
    t = truth(zretry.member(z, f['xml']))
    if not dest.exists():
        common.cached(f'pages/{SOURCE}/{dest.name}', zretry.member(z, f['image']))
    return dest, t
