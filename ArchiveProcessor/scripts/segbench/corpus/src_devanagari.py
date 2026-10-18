"""Naval Kishore Press Devanagari print (heiDATA doi:10.11588/data/EGOKEI), N6.

CC BY 4.0. Nineteen book archives contain full-page JPEGs with same-stem transcriptions
(18 ALTO v4 books, one PAGE), not just line crops. Read their central directories and XML only;
fetch images only for the seeded draw. Each book is a collection for the quarter cap.
The truth is the ALTO blocks/lines in file order, with original Devanagari retained.
Contamination is unmeasured (the plan's 'low' label), not a clean held-out set.
"""
from __future__ import annotations

import json
import re
import zipfile

import common
from src_castilian import _member

SOURCE = 'devanagari'
RECORD = 'https://heidata.uni-heidelberg.de/dataset.xhtml?persistentId=doi:10.11588/data/EGOKEI'
API = 'https://heidata.uni-heidelberg.de/api'


def files():
    path = common.CACHE / 'raw/devanagari/files.json'
    if not path.exists():
        data = json.loads(common.get(API + '/datasets/:persistentId/?persistentId=doi:10.11588/data/EGOKEI'))
        rows = [f['dataFile'] for f in data['data']['latestVersion']['files']]
        rows = [{k: f[k] for k in ('id', 'filename', 'filesize')} for f in rows if f['filename'].endswith('.zip')]
        common.cached('raw/devanagari/files.json', json.dumps(rows).encode())
    return json.loads(path.read_text())


def directory(f):
    path = common.CACHE / 'raw/devanagari' / (f['filename'] + '.cd.json')
    if not path.exists():
        z = common.RemoteZip(f"{API}/access/datafile/{f['id']}", size=f['filesize'])
        common.cached(str(path.relative_to(common.CACHE)), json.dumps(z.entries).encode())
    return json.loads(path.read_text())


def pairs(names):
    """Pair ALTO with its sibling page image, never metadata.xml or mets.xml."""
    names = set(names)
    out = []
    for xml in sorted(names):
        folder = '/alto/' if '/alto/' in xml else '/page/'
        if folder not in xml or not xml.endswith('.xml'):
            continue
        prefix, name = xml.rsplit(folder, 1)
        image = prefix + '/' + name[:-4] + '.jpg'
        if image in names:
            out.append((xml, image))
    return out


def xml_bytes(f, member, entry):
    book = f['filename'][:-4]
    path = common.CACHE / 'raw/devanagari/alto' / book / member.rsplit('/', 1)[-1]
    if not path.exists():
        common.cached(str(path.relative_to(common.CACHE)), _member(f"{API}/access/datafile/{f['id']}", member, entry))
    return path.read_bytes()


def truth(data):
    return common.alto_text(data) if b'<alto' in data[:2000] else common.page_xml_text(data)


def candidates():
    out = []
    for f in files():
        entries = directory(f)
        book = f['filename'][:-4]
        for xml, image in pairs(entries):
            text = truth(xml_bytes(f, xml, entries[xml]))
            if not text:
                continue
            year = re.search(r'(\d{4})$', book)
            out.append(common.Candidate(
                source=SOURCE, collection=book, page_id=book + '/' + image.rsplit('/', 1)[-1][:-4],
                stratum='N6', licence='CC-BY-4.0', item_url=RECORD,
                convention='Naval Kishore Press ALTO/PAGE blocks and lines in file order; original Devanagari',
                contamination='low', publish_image=True, script='Deva', era=year.group(1) if year else '', kind='print',
                fetch={'file': f, 'xml': xml, 'image': image, 'xml_entry': entries[xml], 'image_entry': entries[image]}))
    return out


def materialise(c):
    f = c.fetch['file']
    text = truth(xml_bytes(f, c.fetch['xml'], c.fetch['xml_entry']))
    dest = common.CACHE / 'pages/devanagari' / (c.page_id.replace('/', '__') + '.jpg')
    if not dest.exists():
        archive = common.CACHE / 'raw/devanagari' / f['filename']
        if archive.exists():
            with zipfile.ZipFile(archive) as z:
                data = z.read(c.fetch['image'])
        else:
            data = _member(f"{API}/access/datafile/{f['id']}", c.fetch['image'], c.fetch['image_entry'])
        common.cached(str(dest.relative_to(common.CACHE)), data)
    return dest, text
