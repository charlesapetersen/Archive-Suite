"""TAPUS — French typescripts (HTR-United/tapuscorpus), stratum L3.

Licence: CC-BY-4.0 (README: text and images, source works out of copyright). 154 image + PAGE pairs in
sub-corpora under data/<sub-corpus>/<img>.jpg (.jpeg/.png in the Europeana folder) + <img>.xml. Surprising:
despite the README's "PAGE XML" the files read are ALTO v4 (eScriptorium export), so truth() takes either; a
physical line is sometimes split into several ALTO TextLines (one per word group), each kept as its own line. Source images are Gallica / Archives nationales /
BLJD typescripts 1896-1984, plus a 'europeana-random-selection' folder of unknown date.

Annotation markup (README): `_` before an underlined word, `^` before a superscript word, and `~~~` (one per
word, space separated) for text that is not typewritten. truth() drops the `_` and `^` markers and keeps the
words, and drops each `~~~` span (the span, not its neighbours: the words around it stay). Non-typed text is
therefore absent from the truth; the count of dropped spans is not kept in the truth string but `nontyped()`
returns it. Pages whose text is only `~~~` are dropped as empty, and so are pages with more than MAX_NONTYPED
untyped words (138 of 154 pages kept, 2026-10-16).
"""
from __future__ import annotations

import re

import common
import ghtree

SOURCE = 'tapus'
OWNER, REPO, BRANCH = 'HTR-United', 'tapuscorpus', 'main'
# README table, "Date" column; X = unknown. Folder name -> era.
ERAS = {
    '20130043_87-1962-catalogue-dactylographié-des-enregistrements': '1962',
    'bljd-DSN390-DSN355-DSN113_(27)-DSN169': '1922-1945',
    '12148-btv1b10581912k': '19??',
    'AN-96AP_1-dossier_1-pièces_1_à_202-début-du-journal-dactylographié': '1914-1917',
    '12148-btv1b10583038c': '1896',
    '12148-btv1b10583138r': '1962',
    '12148-btv1b53097347b': '1984',
}
# A page with more untyped (handwritten) words than this is not a typescript page for scoring: the truth
# leaves them out, so a reader that reads them would be charged for it. Dropped at listing.
MAX_NONTYPED = 3
_NONTYPED = re.compile(r'(?:~~~\s*)+')


def nontyped(text: str) -> int:
    """How many `~~~` spans (one per untyped word) a raw line text holds."""
    return text.count('~~~')


def clean_line(s: str) -> str:
    s = _NONTYPED.sub(' ', s)
    s = s.replace('^', '')
    s = re.sub(r'(^|(?<=\s))_', '', s)
    return re.sub(r'[ \t]{2,}', ' ', s).strip()


def truth(xml: bytes) -> str:
    """Page text from the ALTO or PAGE XML with the TAPUS markup removed, lines kept, empty lines dropped."""
    raw = common.alto_text(xml) if b'<alto' in xml[:2000] else common.page_xml_text(xml)
    blocks = []
    for block in raw.split('\n\n'):
        lines = [clean_line(x) for x in block.split('\n')]
        lines = [x for x in lines if x]
        if lines:
            blocks.append('\n'.join(lines))
    return '\n\n'.join(blocks)


def pairs(items: list[dict]) -> list[tuple[str, str]]:
    """(image name, xml name) for every image (.jpg/.jpeg/.png) with a same-stem .xml."""
    names = {i['name'] for i in items if i.get('contentType') == 'file'}
    out = []
    for n in names:
        stem, _, ext = n.rpartition('.')
        if ext.lower() in ('jpg', 'jpeg', 'png') and stem + '.xml' in names:
            out.append((n, stem + '.xml'))
    return sorted(out)


def _xml(folder: str, xml: str) -> bytes:
    """The annotation file, cached under raw/tapus/ (candidates() needs it to drop pages with no typed text)."""
    dest = f'raw/{SOURCE}/xml/{folder}/{xml}'
    if not (common.CACHE / dest).exists():
        common.cached(dest, common.get(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{xml}')))
    return (common.CACHE / dest).read_bytes()


def candidates() -> list[common.Candidate]:
    out = []
    for d in ghtree.listing(SOURCE, OWNER, REPO, BRANCH, 'data'):
        if d.get('contentType') != 'directory':
            continue
        folder = d['name']
        ps = pairs(ghtree.listing(SOURCE, OWNER, REPO, BRANCH, d['path']))
        if not ps:
            continue
        if not ghtree.probe_not_lfs(ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{ps[0][0]}')):
            continue    # Git LFS pointer, unusable
        era = ERAS.get(folder, '')
        for img, xml in ps:
            raw = _xml(folder, xml)
            if not truth(raw):
                continue    # no typed text on the page (empty or all ~~~): dropped
            if raw.count(b'~~~') > MAX_NONTYPED:
                continue    # more handwriting than a stray word: a reader that transcribes it would be penalised
            out.append(common.Candidate(
                source=SOURCE, collection=folder, page_id=folder + '/' + img.rpartition('.')[0], stratum='L3',
                licence='CC-BY-4.0', item_url=ghtree.html_url(OWNER, REPO, BRANCH, f'data/{folder}/{img}'),
                convention='PAGE lines, French typescript; _ underline and ^ superscript markers stripped, '
                           '~~~ non-typed spans removed',
                contamination='low', publish_image=True, script='Latn', era=era, kind='typed',
                fetch={'image': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{img}'),
                       'xml': ghtree.raw_url(OWNER, REPO, BRANCH, f'data/{folder}/{xml}'), 'ext': img.rpartition('.')[2].lower()}))
    return out


def materialise(c: common.Candidate):
    safe = re.sub(r'[^\w.-]+', '_', c.page_id)
    dest = common.CACHE / 'pages' / SOURCE / f"{safe}.{c.fetch['ext']}"
    xml = common.get(c.fetch['xml'])
    t = truth(xml)
    if not dest.exists():
        data = common.get(c.fetch['image'])
        if ghtree.is_lfs_pointer(data):
            raise IOError(f'{c.key}: Git LFS pointer')
        common.cached(str(dest.relative_to(common.CACHE)), data)
    return dest, t
