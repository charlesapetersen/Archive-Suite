"""W43.corpus-build — `read2017`: READ ICDAR 2017 HTR competition set (Zenodo 835489, CC-BY-4.0). Stratum L6.

Reads the already-extracted tarballs under CACHE/raw/read2017/<set>/ (Test-A, Test-B1, Test-B2, Train-A, fetched
and unpacked by hand before this converter was written); nothing is fetched here, and materialise() copies the
JPEG from there to CACHE/pages/read2017/. Train-B (two 1.9 GB .tbz2, page-level text only) was not fetched.

Surprises:
- Only Train-A (50 pages) carries text. Test-A has its 1,574 TextLines with baselines but no TextEquiv, and
  Test-B1/Test-B2 have region geometry only: the competition withheld the test transcripts. The listing keeps any
  page with text, so a test set fetched later with its transcripts would be picked up.
- Every page is from the Alfred Escher letter edition (letters to and from Alfred Escher, Zurich; German, some
  French and Italian), not the 15th-19th c. mix the plan's "German Kurrent" row suggests. Neither the PAGE metadata
  nor the numeric file names say so; the letter texts do ("Mein theurer Escher!", "Sigr Dr Alfredo Escher").
  So there is one collection, and the era is the span of years the transcriptions name (1838-1877): the pages
  themselves are not dated.
- 21 of the 50 PAGE files are not well-formed XML: a bare '&' (the letters' own et-sign) is not escaped.
  truth() escapes a bare '&' before parsing. Train-A/<stem>.xml and Train-A/page/<stem>.xml are byte-identical.
- No editorial markup. Diplomatic: ß, umlauts, 'u.' and other abbreviations as written; an interlinear insertion
  is its own line where it stands; two fullwidth 'ｆ' (U+FF46) are the transcribers' and are kept.
"""
from __future__ import annotations

from pathlib import Path
import re
import shutil

import common

SOURCE = 'read2017'
RECORD = 'https://zenodo.org/records/835489'
SETS = ('Train-A', 'Test-A', 'Test-B1', 'Test-B2')
ERA = '1838-1877'
_BARE_AMP = re.compile(rb'&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);)')


def raw_dir() -> Path:
    return common.CACHE / 'raw' / SOURCE


def truth(xml_bytes: bytes) -> str:
    """Page text in reading order, after escaping the bare '&' that leaves many of these files malformed."""
    return common.page_xml_text(_BARE_AMP.sub(b'&amp;', xml_bytes))


def list_pages(root: Path) -> list[tuple[str, str, Path, Path]]:
    """(set, stem, image, xml) for every page whose JPEG exists and whose PAGE file has text."""
    out = []
    for s in SETS:
        d = root / s
        if not d.is_dir():
            continue
        for xml in sorted((d / 'page').glob('*.xml')):
            img = d / (xml.stem + '.jpg')
            if img.exists() and truth(xml.read_bytes()):
                out.append((s, xml.stem, img, xml))
    return out


def candidates() -> list[common.Candidate]:
    out = []
    for s, stem, img, xml in list_pages(raw_dir()):
        out.append(common.Candidate(
            source=SOURCE, collection='AlfredEscherBriefe', page_id=f'{s}/{stem}', stratum='L6',
            licence='CC-BY-4.0', item_url=RECORD,
            convention='PAGE lines, diplomatic, abbreviations as written, no markup',
            contamination='low', publish_image=True, script='Latn', era=ERA, kind='handwritten',
            fetch={'image': str(img.relative_to(common.CACHE)), 'xml': str(xml.relative_to(common.CACHE))}))
    return out


def materialise(c: common.Candidate) -> tuple[Path, str]:
    f = c.fetch
    text = truth((common.CACHE / f['xml']).read_bytes())
    out = common.CACHE / 'pages' / SOURCE / (re.sub(r'[^A-Za-z0-9._-]', '_', c.page_id) + '.jpg')
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + '.part')
        shutil.copyfile(common.CACHE / f['image'], tmp)
        tmp.replace(out)
    return out, text
