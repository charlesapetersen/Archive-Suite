"""W43.corpus-build — `voc`: Dutch VOC and notarial ground truth, Zenodo record 6414086, CC-BY-4.0. Stratum L5.

Nationaal Archief / Noord-Hollands Archief Transkribus training set ("IJsberg" model): 4,735 VOC pages
(1.04.02, 17th-18th c.) and 1,615 notarial-deed pages (mostly NHA 1617 and 1972, 19th c.) in PAGE 2013 XML, in two
GT .7z files (144 MB and 54 MB, XML only), with the scans in two separate SOLID 7z archives (18.5 GB, 9 blocks;
7.2 GB, 4 blocks; LZMA2). The scans are not on any other allowed host: each PAGE's TranskribusMetadata imgUrl is
on files.transkribus.eu.

Surprises:
- A solid block decodes only from its start, so the reachable scans are the first few of each of the 13 blocks
  (sevenz.py: a sparse stand-in holding the headers, plus a range read of the block's first bytes). The sample is
  therefore the leading pages of each block in name order, not a random draw: `fetch_raw` takes PER_BLOCK of
  them (~4 MB a scan, so the cache budget sets it). Raising PER_BLOCK costs only bandwidth and disk.
- `fetch_raw` extracts the matching PAGE files from the GT 7z and then deletes both GT archives and the sparse
  stand-ins; candidates() and materialise() read only CACHE/raw/voc/ and never touch the network.
- The text is diplomatic, abbreviations unexpanded; `„` and `=` are the transcribers' line-end hyphens and
  stay, as do `¶` and dashes. There is no inline markup: `unclear`/`textStyle`/`supplied` live only in the
  TextLine `custom` attribute, which is not read. CRs inside Unicode (region-level text, mostly) are dropped.
- Collection is the archive + inventory number (the file name less its scan number), e.g. NL-HaNA_1.04.02_7815.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess

import common
import sevenz

SOURCE = 'voc'
RECORD = 'https://zenodo.org/records/6414086'
FILES = 'https://zenodo.org/api/records/6414086/files/{}/content'
RAW = common.CACHE / 'raw' / SOURCE
XML_DIR = RAW / 'xml'
IMG_DIR = RAW / 'images'
PER_BLOCK = 2
# part -> (GT 7z, images 7z, images 7z size, era)
PARTS = {
    'voc': ('VOC Ground truths of the trainingset in PAGE xml.7z', 'VOC Images of the trainingset.7z',
            18485261890, '1600-1799'),
    'notarial': ('Notarial deeds Ground Truths of the trainingset in PAGE xml.7z',
                 'Notarial deeds Images of the training set.7z', 7203628715, '1800-1899'),
}


def url(name: str) -> str:
    return FILES.format(name.replace(' ', '%20'))


def truth(xml_bytes: bytes) -> str:
    """Page text in the PAGE reading order. No inline markup in this set; a CR or line break left inside a
    line's text (the XML parser turns CR into LF) must not open a blank line, so runs of blank lines collapse."""
    text = '\n'.join(ln.rstrip() for ln in common.page_xml_text(xml_bytes).replace('\r', '').split('\n'))
    return re.sub(r'\n{3,}', '\n\n', text).strip()


def part_of(stem: str) -> str:
    return 'voc' if stem.startswith('NL-HaNA_1.04.02_') else 'notarial'


def collection(stem: str) -> str:
    """Archive + inventory: the stem less its trailing scan number (NL-0400410000_26_004011_000464 too)."""
    return stem.rsplit('_', 1)[0]


def choose(members: list[sevenz.Member], have_xml: set[str], k: int) -> dict[int, list[sevenz.Member]]:
    """Per block, the first k JPEG members (archive order) that have a PAGE file."""
    out: dict[int, list[sevenz.Member]] = {}
    for m in members:
        stem = m.name.rsplit('/', 1)[-1].rsplit('.', 1)[0]
        if m.name.lower().endswith('.jpg') and stem in have_xml and len(out.setdefault(m.block, [])) < k:
            out[m.block].append(m)
    return out


def _gt_names(archive: Path) -> set[str]:
    out = subprocess.run([sevenz.SEVENZ, 'l', '-ba', '-slt', str(archive)], check=True, capture_output=True,
                         text=True).stdout
    return {line[7:].rsplit('/', 1)[-1][:-4] for line in out.splitlines()
            if line.startswith('Path = ') and line.endswith('.xml')}


def fetch_raw(per_block: int = PER_BLOCK) -> int:
    """One-time cache fill: GT 7z down (198 MB), the leading scans of every image block by range, the matching
    PAGE files out; then the GT archives and sparse stand-ins are deleted. Returns the pages kept."""
    XML_DIR.mkdir(parents=True, exist_ok=True)
    for part, (gt_name, img_name, size, _) in PARTS.items():
        gt = common.download(url(gt_name), f'raw/{SOURCE}/{part}-gt.7z')
        have = _gt_names(gt)
        stand_in = sevenz.probe(url(img_name), RAW / f'{part}-images.sparse.7z', size)
        members, packed = sevenz.listing(stand_in)
        starts = sevenz.block_starts(packed)
        for block, chosen in sorted(choose(members, have, per_block).items()):
            todo = [m for m in chosen if not sevenz.intact(IMG_DIR / m.name.rsplit('/', 1)[-1], m)]
            if todo:
                need = sum(m.size for m in chosen)
                sevenz.fill(url(img_name), stand_in, starts[block], min(packed[block], int(need * 1.02) + 2_000_000))
                sevenz.extract(stand_in, chosen, IMG_DIR)
            names = [m.name.rsplit('/', 1)[-1].rsplit('.', 1)[0] + '.xml' for m in chosen]
            subprocess.run([sevenz.SEVENZ, 'e', '-y', f'-o{XML_DIR}', str(gt), *names], check=True,
                           capture_output=True)
        os.remove(gt)
        os.remove(stand_in)
    return len(candidates())


def list_pages(xml_stems, image_names) -> list[tuple[str, str]]:
    """(stem, image file name) for every PAGE stem whose scan has been extracted."""
    images = {n.rsplit('.', 1)[0]: n for n in image_names if n.lower().endswith('.jpg') and not n.startswith('.')}
    return [(s, images[s]) for s in sorted(xml_stems) if s in images]


def candidates() -> list[common.Candidate]:
    stems = [p.stem for p in XML_DIR.glob('*.xml')] if XML_DIR.exists() else []
    out = []
    for stem, img in list_pages(stems, os.listdir(IMG_DIR) if IMG_DIR.exists() else []):
        if not truth((XML_DIR / f'{stem}.xml').read_bytes()):   # an untranscribed page
            continue
        part = part_of(stem)
        out.append(common.Candidate(
            source=SOURCE, collection=collection(stem), page_id=stem, stratum='L5', licence='CC-BY-4.0',
            item_url=RECORD, convention='PAGE lines (Transkribus), diplomatic, abbreviations unexpanded, „ and = hyphens kept',
            contamination='medium', publish_image=True, script='Latn', era=PARTS[part][3], kind='handwritten',
            fetch={'xml': f'raw/{SOURCE}/xml/{stem}.xml', 'image': f'raw/{SOURCE}/images/{img}', 'part': part}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    """Hard-link the extracted scan (bytes unchanged) from CACHE/raw into CACHE/pages. No network: the scan
    must already be in CACHE/raw/voc/images/ (fetch_raw)."""
    f = c.fetch
    text = truth((common.CACHE / f['xml']).read_bytes())
    src = common.CACHE / f['image']
    out = common.CACHE / 'pages' / SOURCE / f"{re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id)}{src.suffix.lower()}"
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, out)
        except OSError:
            shutil.copyfile(src, out)
    return out, text
