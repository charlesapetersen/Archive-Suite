"""Library of Congress By the People transcription datasets, strata L1, L2 and L3.

Each dataset is a zip on tile.loc.gov (urls and sizes in execution-plans/benchmark-corpus/btp-datasets.tsv, read
from loc.gov through the owner's browser on 2026-10-16, newest version first) holding one or more campaign CSVs:
Campaign, Project, Item, ItemId, Asset, AssetId, AssetStatus, DownloadUrl, Transcription, Tags. Every
DownloadUrl is a page image on tile.loc.gov. Only `completed` assets with a transcription are candidates; a page
whose transcription is "nothing to transcribe" is not one.

Licence: the Library's datasets say transcriptions are CC0 and the images are public domain (no known
restrictions) -> 'CC0-1.0'. The record URL is https://www.loc.gov/item/<ItemId>/ (the datasets' README); the
page is the asset id. Contamination 'high': the transcriptions are on loc.gov beside the images.

Truth: volunteers transcribe as written, keep line breaks, and mark "?" for an illegible word, [deleted text] and
[*marginalia*]. A reader sees the struck and marginal words on the page, so their text stays and only the markup
goes: brackets and asterisks are removed, and a "?" standing alone (or as [?]) is dropped. Nothing else is changed.

Strata (the plan's table, 2026-10-16; the owner's candidate list on W43.corpus-build-more): L1 the handwritten
letters and diaries of 1850-1950, from the suffrage papers (Stanton, Anthony, Catt), the Garfield and Patton
diaries, Bourne, Dickinson and Blackwell; L2 the George Washington Papers, the only founding-era set; L3 the
typed campaigns, the WWII Rumor Project, Woodrow Wilson file 89 and the Federal Theatre Project. The L1 sets mix
in some typed and printed pages; a page whose volunteer tags or item title call it typed, printed or a transcript is
left out of L1 rather than guessed at (Patton's diaries come with typed "annotated transcripts"; tags are free
text, so this catches only the pages someone labelled). The quarter cap counts each project
(a campaign's series or volume) as a collection.
"""
from __future__ import annotations

import csv
import io
import re
import zipfile
from pathlib import Path

import common

SOURCE = 'btp'
LICENCE = 'CC0-1.0 (transcriptions; images public domain, Library of Congress By the People)'
TSV = Path(__file__).resolve().parents[4] / 'execution-plans' / 'benchmark-corpus' / 'btp-datasets.tsv'
# loc_item -> (stratum, kind, era); era only where the campaign gives the span, else ''
DATASETS = {
    '2020445592': ('L1', 'handwritten', ''),   # Elizabeth Cady Stanton Papers
    '2020445591': ('L1', 'handwritten', ''),   # Susan B. Anthony Papers
    '2019667239': ('L1', 'handwritten', ''),   # Carrie Chapman Catt Papers
    '2023527890': ('L1', 'handwritten', '1848-1881'),   # James A. Garfield papers, diaries
    '2021386762': ('L1', 'handwritten', '1910-1945'),   # George S. Patton papers, diaries
    '2019667237': ('L1', 'handwritten', ''),       # Wm. Oland Bourne Papers
    '2023527888': ('L1', 'handwritten', ''),   # Anna E. Dickinson papers
    '2023527889': ('L1', 'handwritten', ''),   # Blackwell family papers
    '2020446971': ('L2', 'handwritten', '1776-1798'),   # George Washington Papers
    '2022360466': ('L3', 'typed', '1942-1943'),         # WWII Rumor Project
    '2025474985': ('L3', 'typed', '1913-1921'),         # Woodrow Wilson Papers, file 89
    '2023514920': ('L3', 'typed', '1935-1939'),         # Federal Theatre Project
}
NOT_HAND = re.compile(r'\b(typed|typewrit\w*|typescripts?|transcripts?|printed|print)\b', re.I)


def zip_urls() -> dict[str, str]:
    """loc_item -> the newest version's zip URL, from the committed list."""
    out = {}
    for row in csv.DictReader(io.StringIO(TSV.read_text(encoding='utf-8')), delimiter='\t'):
        out[row['loc_item']] = row[next(k for k in row if k.startswith('zip'))].split(' | ')[0].split(' ')[0]
    return out


def truth(text: str) -> str:
    """The volunteer transcription with its markup removed (see the module docstring)."""
    t = text.replace('\r\n', '\n').replace('\r', '\n')
    t = t.replace('[*', '').replace('*]', '').replace('[', '').replace(']', '')
    t = '\n'.join(' '.join(w for w in line.split(' ') if w != '?') for line in t.split('\n'))
    return re.sub(r'[ \t]+\n', '\n', t).strip()


def scored(row: dict) -> bool:
    t = (row.get('Transcription') or '').strip()
    return (row.get('AssetStatus', '').lower() == 'completed' and bool(truth(t))
            and t.lower().strip(' .') != 'nothing to transcribe'
            and image_url(row.get('DownloadUrl') or '').startswith('https://tile.loc.gov/'))


def image_url(url: str) -> str:
    """The page image at full size over https. Some campaigns give an http URL, and the IIIF ones a half-size
    rendering (pct:50); the routes scale every input to 2400 px themselves."""
    url = re.sub(r'^http://', 'https://', url.strip())
    return re.sub(r'(/image-services/iiif/[^/]+/full/)pct:\d+(/)', r'\1pct:100\2', url)


def rows_of(zip_bytes: bytes) -> list[dict]:
    out, seen = [], set()
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        for name in sorted(z.namelist()):
            if not name.lower().endswith('.csv'):
                continue
            for r in csv.DictReader(io.StringIO(z.read(name).decode('utf-8-sig'))):
                if r.get('Asset') and r['Asset'] not in seen:
                    seen.add(r['Asset'])
                    out.append(r)
    return out


def candidates() -> list[common.Candidate]:
    urls, out = zip_urls(), []
    for item, (stratum, kind, era) in DATASETS.items():
        z = common.download(urls[item], f'raw/btp/{item}.zip')
        for r in rows_of(z.read_bytes()):
            if not scored(r):
                continue
            if stratum == 'L1' and NOT_HAND.search(f"{r.get('Tags') or ''} {r.get('Item') or ''}"):
                continue
            img = image_url(r['DownloadUrl'])
            ext = img.rsplit('.', 1)[-1].lower()
            out.append(common.Candidate(
                source=SOURCE, collection=f"{item}/{r['Project']}", page_id=r['Asset'], stratum=stratum,
                licence=LICENCE, item_url=f"https://www.loc.gov/item/{r['ItemId']}/",
                convention='By the People volunteer transcription, line breaks kept; ? and [ ] [* *] markup removed',
                contamination='high', publish_image=True, script='Latn', era=era, kind=kind,
                fetch={'zip': item, 'image': img, 'ext': ext}))
    return out


def materialise(c: common.Candidate):
    z = common.CACHE / 'raw' / 'btp' / f"{c.fetch['zip']}.zip"
    row = next(r for r in rows_of(z.read_bytes()) if r['Asset'] == c.page_id)
    dest = common.CACHE / 'pages' / SOURCE / f"{re.sub(r'[^\w.-]+', '_', c.page_id)}.{c.fetch['ext']}"
    if not dest.exists():
        common.cached(str(dest.relative_to(common.CACHE)), common.get(c.fetch['image']))
    return dest, truth(row['Transcription'])
