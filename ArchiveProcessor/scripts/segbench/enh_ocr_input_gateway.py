#!/usr/local/bin/python3
"""W46.enh-ocr-input-paid. Gemini 3.7 Flash through the Stanford AI API gateway on the enhancement arms of
W46.enh-ocr-input.

  V=/usr/local/bin/python3           # needs requests
  $V enh_ocr_input_gateway.py probe  # one image, to check the request and the ledger
  $V enh_ocr_input_gateway.py run    # every enhanced arm on the 96
  $V enh_ocr_input.py report         # then adds the gemini3.7-flash-gw reader to enh-ocr-input.md / .json

Scope: the item was filed as "the 50 pages where Vision gained most", at about $1.65. W46.enh-ocr-input found no arm
that moves Vision beyond noise on the 96, so a top-50-by-Vision-gain set would be picked on noise and would bias
Gemini's paired Δ by the selection. The five arms on all 96 cost about the same (480 calls; W46.enh-dewarp-paid's
544 came to $1.94) and give the same paired, unselected comparison every other reader has, so that is what runs.

The images are enh_ocr_input.arm_image(): shading, GCDRNet, SBB, DocRes appearance and deshadow, each the size of
the panel's raw image. The request is gateway_gemini's (the cloud panel's prompt, temperature 0, low reasoning,
8,192 output tokens). The raw arm is not read again: its image and prompt are byte for byte those
W46.fix-ocr-scorers-paid read (gateway-gemini/panel/<page>-original.json), which raw_reply() checks against the
image hash.

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
CACHE = G.REHEARSAL / 'enh-ocr-input-gateway'
CAP = 2.50  # the item's whole spend, under the $7 rule; filed at about $1.65
SET = 'enh-ocr-input'


def _own_ledger():
    """Point gateway_gemini's cache, ledger and cap at this item's."""
    G.CACHE, G.CAP = CACHE, CAP


def jobs():
    import enh_ocr_input as E
    return [(a, p) for a in E.ARMS if a != 'raw' for p in E.pages()]


def reply_path(arm, page):
    return CACHE / 'replies' / arm / (page + '.json')


def raw_reply(page):
    """The 96's raw reading from W46.fix-ocr-scorers-paid, after checking it read this item's raw image."""
    import enh_ocr_input as E
    m, panel = G.panel_manifest()
    j = next(j for j in panel if j['page'] == page)
    if hashlib.sha256(E.arm_image('raw', page).read_bytes()).hexdigest() != j['sha256']:
        raise ValueError(page + ': the raw arm is not the image gateway_gemini read')
    if m['prompt'] != E.P.PROMPT:
        raise ValueError('the cloud panel prompt is not ocr_panel.PROMPT')
    f = G.REHEARSAL / 'gateway-gemini' / 'panel' / (j['id'] + '.json')
    return json.loads(f.read_text()) if f.exists() else None


def run(todo):
    import enh_ocr_input as E
    _own_ledger()
    m, _ = G.panel_manifest()
    G.run(SET, [(f'{a}/{p}', E.arm_image(a, p).read_bytes(), reply_path(a, p)) for a, p in todo], m['prompt'])


def readings():
    """({(arm, page): text}, {(arm, page): (prompt, completion tokens)}, Counter of statuses), raw included; None if
    any image is still unread. A failed, capped or unparsed reply reads as '' and stays in the denominator."""
    import collections
    import enh_ocr_input as E
    text, tokens, status = {}, {}, collections.Counter()
    for arm in E.ARMS:
        for p in E.pages():
            f = reply_path(arm, p)
            reply = raw_reply(p) if arm == 'raw' else (json.loads(f.read_text()) if f.exists() else None)
            if reply is None:
                return None
            meta = reply.get('meta') or {}
            parsed = G.parsed(reply)
            text[arm, p] = parsed['text'] if parsed else ''
            usage = meta.get('usage') or {}
            tokens[arm, p] = (usage.get('prompt_tokens') or 0, usage.get('completion_tokens') or 0)
            status['error' if meta.get('http') != 200 else 'cap' if meta.get('finish') == 'length'
                   else 'ok' if parsed else 'blank'] += 1
    return text, tokens, status


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
