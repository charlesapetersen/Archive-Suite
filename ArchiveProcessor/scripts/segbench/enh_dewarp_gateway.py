#!/usr/local/bin/python3
"""W46.enh-dewarp-paid. Gemini 3.7 Flash through the Stanford AI API gateway on the dewarp arms of W46.enh-dewarp.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python
  $V enh_dewarp_gateway.py probe     # one image, to check the request and the ledger
  $V enh_dewarp_gateway.py run       # every image the Sherlock readers read, raw excepted
  $V enh_dewarp.py report            # then adds the gemini3.7-flash-gw reader to enh-dewarp.md / .json

The images are enh_dewarp.cluster_jobs(), the exact set Qwen3.6-27B, LightOnOCR-3 4B and PP-OCRv6 read: quad,
UVDoc and DocRes on the 96, the app's encoder at 2048/0.85 and 1600/0.90, the four hand crops and the ladder's
three quarter rungs. The request is gateway_gemini's (the cloud panel's prompt, temperature 0, low reasoning, 8,192
output tokens). The raw arm is not read again: its image and prompt are byte for byte those W46.fix-ocr-scorers-paid
read (gateway-gemini/panel/<page>-original.json), which raw_reply() checks against the image hash.

Money: this item's ledger is CACHE/calls.jsonl, apart from gateway_gemini's, and CAP is this item's whole spend,
counted at the 3.8 list price gateway_gemini takes as a ceiling (the gateway returns no bill). Every call checks the
cap first. Images and replies stay in CACHE (the owner's material); committed results hold page ids and numbers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

import gateway_gemini as G  # noqa: E402

ROUTE = G.LABEL
CACHE = G.REHEARSAL / 'enh-dewarp-gateway'
CAP = 2.90  # the item's whole spend, under the $3 rule; filed at about $2.25
SET = 'enh-dewarp'


def _own_ledger():
    """Point gateway_gemini's cache, ledger and cap at this item's."""
    G.CACHE, G.CAP = CACHE, CAP


def jobs():
    import enh_dewarp as E
    return [(a, p) for a, p in E.cluster_jobs() if a != 'raw']


def reply_path(arm, page):
    return CACHE / 'replies' / arm / (page + '.json')


def raw_reply(page):
    """The 96's raw reading from W46.fix-ocr-scorers-paid, after checking it read this item's raw image."""
    import enh_dewarp as E
    m, panel = G.panel_manifest()
    j = next(j for j in panel if j['page'] == page)
    if hashlib.sha256(E.arm_image('raw', page).read_bytes()).hexdigest() != j['sha256']:
        raise ValueError(page + ': the raw arm is not the image gateway_gemini read')
    if m['prompt'] != E.P.PROMPT:
        raise ValueError('the cloud panel prompt is not ocr_panel.PROMPT')
    f = G.REHEARSAL / 'gateway-gemini' / 'panel' / (j['id'] + '.json')
    return json.loads(f.read_text()) if f.exists() else None


def run(todo):
    import enh_dewarp as E
    _own_ledger()
    m, _ = G.panel_manifest()
    G.run(SET, [(f'{a}/{p}', E.arm_image(a, p).read_bytes(), reply_path(a, p)) for a, p in todo], m['prompt'])


def status_of(meta, parsed):
    """A reply's status in cluster_rows' terms: error (HTTP), cap (finish length), ok (parsed) or blank."""
    if meta.get('http') != 200:
        return 'error'
    if meta.get('finish') == 'length':
        return 'cap'
    return 'ok' if parsed else 'blank'


def rows():
    """{(arm, page): score row} in cluster_rows' shape, raw included; None if any image is still unread.
    A failed, capped or unparsed reply scores empty and stays in the denominator."""
    import enh_dewarp as E
    import ocr_panel_score as S
    out = {}
    for arm, p in E.cluster_jobs():
        f = reply_path(arm, p)
        reply = raw_reply(p) if arm == 'raw' else (json.loads(f.read_text()) if f.exists() else None)
        if reply is None:
            return None
        meta = reply.get('meta') or {}
        parsed = G.parsed(reply)
        text = parsed['text'] if parsed else ''
        status = status_of(meta, parsed)
        truth = (E.P.TRUTH / 'truth' / (p + '.txt')).read_text()
        usage = meta.get('usage') or {}
        out[arm, p] = {'page': p, 'arm': arm, 'reader': ROUTE, 'read': True, 'status': status, 'ok': bool(text),
                       'prompt_tokens': usage.get('prompt_tokens') or 0,
                       'completion_tokens': usage.get('completion_tokens') or 0, 'cost': meta.get('cost', 0.0),
                       **S.score(truth, text)}
    return out


def spent():
    _own_ledger()
    return G.spent()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['probe', 'run', 'spent'])
    cmd = ap.parse_args().cmd
    if cmd == 'probe':
        run(jobs()[:1])
    elif cmd == 'run':
        run(jobs())
    print(f'${spent():.4f} of ${CAP} spent on this item')


if __name__ == '__main__':
    main()
