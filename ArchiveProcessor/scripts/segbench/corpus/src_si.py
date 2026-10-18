"""Smithsonian Freedmen's Bureau registers, L4. Scores only, noncommercial research.

The modern transcription PDF export has an asset ID and a Transcription marker;
long transcriptions continue on following PDF pages. Group by asset, not physical
PDF page. Embedded scans are tiny; fetch matching NMAAHC IDs at ids.si.edu instead.
The four projects are property/plantation registers, not registered letters.
PHaEDRA's older PDF format exposes only ADS ELECTR image IDs, with no verified
full-size image URI on the allowed hosts, so it is not silently substituted here.
"""
from __future__ import annotations

import re
import subprocess
from urllib.parse import urlencode

import common

SOURCE = 'si'
PROJECTS = {
    63356: 'Registers of Abandoned Property, Vol. 2',
    63359: 'Registers of Abandoned Property, Vol. 3',
    63442: 'Registers of Plantations, Vol. 1',
    63444: 'Registers of Plantations, Vol. 2',
}
ASSET = re.compile(r'^NMAAHC-[\w.-]+$', re.M)


def clean(text):
    # PDF line wrapping can split a [[tag]]; whitespace inside tag names is not text.
    def markup(m):
        compact = re.sub(r'\s+', '', m.group(1)).lower()
        if compact in ('illegible', '?'):
            return '[illegible]'
        if compact.startswith(('/', 'strik', 'under', 'note', 'preprinted', 'stamp', 'label', 'table', 'superscript')) or \
                compact == 'endtable' or re.fullmatch(r'\d+column\w*', compact):
            return ''
        return m.group(1)  # insertions, ditto explanations, uncertain words stay
    text = re.sub(r'\[\[([^\]]*)\]\]', markup, text)
    # All remaining bracket markup is editorial; keep its content (insertions, ditto, uncertain words).
    text = text.replace('[[', '').replace(']]', '').replace('^', '')
    lines = []
    for line in text.splitlines():
        if re.fullmatch(r'[|\s:-]+', line):
            continue  # Markdown table rule, not visible text
        line = re.sub(r'\s*\|\s*', ' ', line).strip()
        if line:
            lines.append(line)
    return '\n'.join(lines)


def pages(raw):
    """asset ID -> transcription across PDF page breaks; refuse duplicate starts."""
    out, current = {}, None
    for physical in raw.split('\f'):
        body = re.sub(r'^Generated on[^\n]*\n?', '', physical.strip())
        body = re.split(r'\n?transcription\.si\.edu \| transcribe@si\.edu', body)[0].strip()
        ids = ASSET.findall(body)
        if ids:
            if len(ids) != 1 or 'Transcription:' not in body:
                raise ValueError('asset page has no unique transcription marker')
            current = ids[0]
            if current in out:
                raise ValueError('duplicate asset: ' + current)
            body = body.split('Transcription:', 1)[1]
            out[current] = []
        elif current is None:
            continue  # generated cover, never a source page
        if body:
            out[current].append(body)
    return {k: clean('\n'.join(v)) for k, v in out.items()}


def project_pages(pid):
    pdf = common.download(f'https://edan.si.edu/transcription/pdf_files/{pid}.pdf', f'raw/si/{pid}.pdf')
    raw = subprocess.run(['pdftotext', '-raw', str(pdf), '-'], check=True, capture_output=True, text=True).stdout
    return pages(raw)


def candidates():
    out = []
    for pid, title in PROJECTS.items():
        for asset, text in project_pages(pid).items():
            # Omit blank/volume targets and cover leaves, not full register entries.
            if len(text) < 100 or ('NATIONAL ARCHIVES AND RECORDS' in text and 'MICROFILM PUBLICATIONS' in text):
                continue
            out.append(common.Candidate(
                source=SOURCE, collection=str(pid), page_id=asset, stratum='L4',
                licence='Smithsonian personal, educational and noncommercial use; cite Freedmen\'s Bureau and project',
                item_url=f'https://transcription.si.edu/project/{pid}',
                convention='Smithsonian PDF transcription grouped by asset; editorial tags and table rules removed; cells in row order',
                contamination='high', publish_image=False, script='Latn', era='1860s', kind='ledger',
                fetch={'project': pid, 'title': title, 'image': 'https://ids.si.edu/ids/deliveryService?' +
                       urlencode({'max_w': 4000, 'id': asset})}))
    return out


def materialise(c):
    text = project_pages(c.fetch['project'])[c.page_id]
    dest = common.CACHE / 'pages/si' / (c.page_id + '.jpg')
    if not dest.exists():
        common.cached(str(dest.relative_to(common.CACHE)), common.get(c.fetch['image']))
    return dest, text
