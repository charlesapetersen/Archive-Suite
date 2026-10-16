"""W43.corpus-build — `bentham`: Bentham Dataset R0 (HTRtS 2014), Zenodo record 44519, CC-BY-4.0. Stratum L2.

Jeremy Bentham's manuscripts (UCL Bentham Papers, c.1760-1832), transcribed by Transcribe Bentham volunteers and
line-annotated by tranScriptorium. Two bzip2 tarballs, no zip: BenthamDatasetR0-GT.tbz (1.45 GB: PAGE 2010 XML for
433 pages, partitions, line images, line transcripts) and BenthamDatasetR0-Images.tbz (2.0 GB: the colour page
JPEGs). A bzip2 stream cannot seek, so `fetch_raw()` streams each tarball once through tar and keeps only the
members needed: every PAGE file, then the page JPEGs of a seeded subset (`pick`). candidates() and materialise()
read only from CACHE/raw/bentham/; they never touch the network.

Surprises:
- The GT README says the TextLines in the PAGE files are NOT in reading order (and line ids do not match
  geometry). `truth()` re-orders them the README's way: lines in a region by the mean y of their polygon, regions
  by the mean y of their highest line, ties by leftmost x.
- Editorial markup is inline in the Unicode text: `<gap/>` (70x, illegible) becomes the panel's `[illegible]`;
  `<del>…</del>` (once in the set) loses its tags but keeps the struck word, which is on the image. Square
  brackets are Bentham's own (marginal headings, `[+]`) and stay. `&`, `£`, `§` and Bentham's `=` line-end
  hyphen stay. Trailing spaces on lines are dropped.
- The images are ~4.6 MB each (2.0 GB for 433), so the cache budget, not the 433, limits how many are kept.
- Collection is the UCL box (the first three digits of the name, e.g. 071_181_001 is box 71, folio 181); box 071
  holds 124 of the 433 pages, so `pick` caps any box at a quarter of the subset.
"""
from __future__ import annotations

from collections import Counter
import os
from pathlib import Path
import random
import re
import subprocess
import xml.etree.ElementTree as ET

import common

SOURCE = 'bentham'
RECORD = 'https://zenodo.org/records/44519'
GT_URL = 'https://zenodo.org/api/records/44519/files/BenthamDatasetR0-GT.tbz/content'
IMAGES_URL = 'https://zenodo.org/api/records/44519/files/BenthamDatasetR0-Images.tbz/content'
RAW = common.CACHE / 'raw' / SOURCE
PAGE_DIR = RAW / 'BenthamDatasetR0-GT' / 'PAGE'
IMG_DIR = RAW / 'images'
SEED = 'W43.corpus-build/bentham'
N_PAGES = 52          # ~4.9 MB a page: what the 400 MB cache budget (shared with voc) allowed
_NAME = re.compile(r'^(\d{3})_\d{3}_\d{3}$')


def _local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def _points(el) -> list[tuple[int, int]]:
    """Polygon of an element: PAGE 2010 `<Point x y/>` children (most files) or a `points` attribute (33 files)."""
    for c in el:
        if _local(c.tag) == 'Coords':
            if c.get('points'):
                return [tuple(int(float(v)) for v in p.split(',')) for p in c.get('points').split()]
            return [(int(float(p.get('x'))), int(float(p.get('y')))) for p in c if _local(p.tag) == 'Point']
    return []


def _unicode(el) -> str:
    for c in el:
        if _local(c.tag) == 'TextEquiv':
            for u in c:
                if _local(u.tag) == 'Unicode':
                    return u.text or ''
    return ''


def clean(line: str) -> str:
    """One line's text without Transcribe Bentham's inline markup."""
    line = re.sub(r'<gap\s*/>', '[illegible]', line)
    line = re.sub(r'</?del>', '', line)
    return line.rstrip()


def truth(xml_bytes: bytes) -> str:
    """Page text, re-ordered geometrically (the README's top-down rule), markup cleaned."""
    root = ET.fromstring(xml_bytes)
    regions = []
    for reg in root.iter():
        if _local(reg.tag) != 'TextRegion':
            continue
        lines = []
        for ln in reg.iter():
            if _local(ln.tag) != 'TextLine':
                continue
            text = clean(_unicode(ln))
            pts = _points(ln)
            if not text.strip() or not pts:
                continue
            lines.append((sum(y for _, y in pts) / len(pts), min(x for x, _ in pts), text))
        if not lines:
            continue
        lines.sort()
        rpts = _points(reg) or [(x, 0) for _, x, _ in lines]
        regions.append((lines[0][0], min(x for x, _ in rpts), [t for _, _, t in lines]))
    regions.sort(key=lambda r: (r[0], r[1]))
    return '\n\n'.join('\n'.join(ls) for _, _, ls in regions).strip()


def box(stem: str) -> str:
    return 'box' + stem[:3]


def pick(stems, n: int = N_PAGES) -> list[str]:
    """The seeded subset: shuffle the sorted names, keep the first n with no box over a quarter of n."""
    order = sorted(s for s in stems if _NAME.match(s))
    random.Random(SEED).shuffle(order)
    cap, per, out = max(1, n // 4), Counter(), []
    for s in order:
        if len(out) == n:
            break
        if per[box(s)] < cap:
            per[box(s)] += 1
            out.append(s)
    return sorted(out)


def list_pages(xml_stems, image_names) -> list[tuple[str, str]]:
    """(stem, image file name) for every PAGE stem whose JPEG has been extracted."""
    images = {n.rsplit('.', 1)[0]: n for n in image_names if n.lower().endswith('.jpg') and not n.startswith('.')}
    return [(s, images[s]) for s in sorted(xml_stems) if _NAME.match(s) and s in images]


def _stream(url: str, patterns: list[str], dest: Path, seconds: int = 3600) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    cmd = f'timeout {seconds} "{common.FETCH}" --stream "{url}" | tar -xjf - -C "{dest}" ' + \
        ' '.join(f"'{p}'" for p in patterns)
    subprocess.run(['bash', '-c', cmd], check=False)


def fetch_raw() -> list[str]:
    """One-time cache fill (two long streams). Keeps every PAGE file, then the subset's JPEGs flat in images/,
    then deletes the PAGE files outside the subset to save space. Returns the subset."""
    if not PAGE_DIR.exists():
        _stream(GT_URL, ['BenthamDatasetR0-GT/PAGE', 'BenthamDatasetR0-GT/Partitions',
                         'BenthamDatasetR0-GT/README.txt'], RAW)
    parts = PAGE_DIR.parent / 'Partitions'   # the 433 names, still there after the PAGE files are pruned
    stems = [s for f in ('Train', 'Validation', 'Test') for s in (parts / f'{f}.lst').read_text().split()]
    chosen = pick(stems)
    staging = RAW / 'images-tar'
    _stream(IMAGES_URL, [f'*/{s}.jpg' for s in chosen], staging)
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    for p in staging.rglob('*.jpg'):
        p.replace(IMG_DIR / p.name)
    keep = {s for s in chosen if (IMG_DIR / f'{s}.jpg').exists()}
    for p in PAGE_DIR.glob('*.xml'):
        if p.stem not in keep:
            os.remove(p)
    return sorted(keep)


def candidates() -> list[common.Candidate]:
    stems = [p.stem for p in PAGE_DIR.glob('*.xml')]
    names = os.listdir(IMG_DIR) if IMG_DIR.exists() else []
    out = []
    for stem, img in list_pages(stems, names):
        if not truth((PAGE_DIR / f'{stem}.xml').read_bytes()):   # none are empty today; guard anyway
            continue
        out.append(common.Candidate(
            source=SOURCE, collection=box(stem), page_id=stem, stratum='L2', licence='CC-BY-4.0',
            item_url=RECORD,
            convention='PAGE lines, diplomatic (Transcribe Bentham), geometric reading order, <gap/> -> [illegible]',
            contamination='high', publish_image=True, script='Latn', era='1760-1832', kind='handwritten',
            fetch={'xml': f'raw/{SOURCE}/BenthamDatasetR0-GT/PAGE/{stem}.xml', 'image': f'raw/{SOURCE}/images/{img}'}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    """Hard-link the extracted JPEG (bytes unchanged, no second copy on disk) from CACHE/raw into CACHE/pages.
    No network: the image must already be in CACHE/raw/bentham/images/ (fetch_raw)."""
    f = c.fetch
    text = truth((common.CACHE / f['xml']).read_bytes())
    src = common.CACHE / f['image']
    out = common.CACHE / 'pages' / SOURCE / f"{re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id)}{src.suffix.lower()}"
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, out)
        except OSError:
            common.cached(str(out.relative_to(common.CACHE)), src.read_bytes())
    return out, text
