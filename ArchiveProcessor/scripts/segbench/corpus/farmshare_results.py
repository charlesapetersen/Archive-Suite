#!/usr/bin/env python3
"""Import the 2026-10-18 cluster OCR outputs; score with the frozen 440-page reference.

  python farmshare_results.py --run DIR --cache DIR

DIR contains results/ocr/<label>/*.json, downloaded without modifying remote/source data.
Raw replies and extracted specialist text stay in --cache; only numbers enter the repo.
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import routes as R
import specialists as SP
import ocr_panel_score as S


def churro_text(raw):
    """CHURRO's reference XML extraction: Page Header/Body/Footer, excluding descriptive metadata.
    Matches official tooling/evaluation/xml_utils.py's text rules (checked 2026-10-18).
    """
    if 'HistoricalDocument' not in raw:
        return raw.strip()
    for tag in ('Description', 'Deletion', 'Illegible', 'Gap'):
        raw = re.sub(rf'<{tag}\b[^>]*>.*?</{tag}>', '', raw, flags=re.DOTALL)
        raw = re.sub(rf'<{tag}\b[^>]*/>', '', raw)
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return ''
    name = lambda el: el.tag.rsplit('}', 1)[-1]
    pages = []
    for page in root.iter():
        if name(page) != 'Page':
            continue
        sections = []
        for child in page.iter():
            if name(child) in {'Header', 'Body', 'Footer'}:
                lines = [t.strip() for t in child.itertext() if t.strip()]
                if lines:
                    sections.append('\n'.join(lines))
        if sections:
            pages.append('\n'.join(sections))
    return '\n\n'.join(pages).strip()


def reading(record, mode):
    if not record or record.get('status') != 'ok' or record.get('finish') != 'stop':
        return ''
    raw = record.get('raw', '')
    if mode == 'churro':
        return churro_text(raw)
    if mode == 'panel':
        parsed = R.P.T.parse_draft(raw)
        return parsed['text'].strip() if parsed else ''
    return raw.strip()


def read_records(folder):
    out = {}
    for p in sorted(folder.glob('*.json')):
        r = json.loads(p.read_text())
        if 'id' not in r:
            continue
        if r['id'] in out:
            raise ValueError(f'duplicate output id: {r["id"]}')
        out[r['id']] = r
    return out


def join_lines(records, expected):
    """A capped/missing line fails its whole page; retain the raw line records for diagnosis.
    Exact 1..N identities prevent silently omitting a missing middle or final crop.
    """
    by = collections.defaultdict(dict)
    for r in records.values():
        if r['line'] in by[r['page']]:
            raise ValueError('duplicate line ordinal')
        by[r['page']][r['line']] = r
    out = {}
    for page, n in expected.items():
        lines = by[page]
        if set(lines) != set(range(1, n + 1)) or not n:
            out[page] = ''
            continue
        text = [reading(lines[i], 'german') for i in range(1, n + 1)]
        out[page] = '\n'.join(text) if all(text) else ''
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--cache', type=Path, required=True)
    ap.add_argument('--line-counts', type=Path, required=True)
    a = ap.parse_args()
    truth = R.frozen()  # verifies every original image/truth checksum
    specs = [('churro', 'fs-churro', 'churro'), ('qari', 'fs-qari', 'qari'),
             ('fanar', 'fs-fanar', 'fanar'), ('german', 'fs-german-xix', 'german'),
             *[(k, k, 'panel') for k in ('qwen3.6-27b', 'qwen3.5-27b', 'qwen3.6-35b-a3b')]]
    page_rows = []
    for label, key, mode in specs:
        records = read_records(a.run / 'results/ocr' / label)
        if mode == 'german':
            texts = join_lines(records, json.loads(a.line_counts.read_text()))
        else:
            texts = {jid: reading(r, mode) for jid, r in records.items()}
        strata = SP.MODELS[key]['strata'] if key in SP.MODELS else sorted({r['stratum'] for r in truth})
        for r in truth:
            if r['stratum'] not in strata:
                continue
            jid = R.job_id(r)
            text = texts.get(jid, '')
            if key in SP.MODELS:
                dest = a.cache / 'text' / key / (jid + '.txt')
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(text)
            page_rows.append({'route': key, 'page': jid, 'stratum': r['stratum'], 'source': r['source'],
                              'ok': bool(text), **S.score(Path(r['truth']).read_text(), text, r['stratum'])})
    grouped = collections.defaultdict(list)
    for r in page_rows:
        grouped[(r['route'], r['stratum'])].append(r)
        grouped[(r['route'], 'all')].append(r)
    aggregates = []
    for (route, stratum), rr in sorted(grouped.items()):
        row = {'route': route, 'stratum': stratum, **S.aggregate(rr)}
        aggregates.append(row)
        print(f'{route:22s} {stratum:3s} n={row["n"]:3d} ok={row["ok"]:3d} NES={100*row["nes"]:5.1f}')
    S.write_csv(R.RESULTS / 'farmshare.csv', aggregates,
                ['route', 'stratum', 'n', 'ok', 'failed', 'nes', 'nes_answered', 'chrf'])
    S.write_csv(R.RESULTS / 'farmshare-pages.csv', page_rows,
                ['route', 'page', 'stratum', 'source', 'ok', 'nes', 'nes_mapped', 'nes_no_marks', 'chrf'])
    # Existing Mac specialist outputs are read through symlinks; preserve them, write new texts in our own cache.
    for key in SP.MODELS:
        old = SP.RUN / 'text' / key
        dest = a.cache / 'text' / key
        if old.is_dir() and not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(old, target_is_directory=True)
    SP.RUN = a.cache
    SP.report()


if __name__ == '__main__':
    main()
