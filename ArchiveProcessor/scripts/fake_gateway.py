#!/usr/bin/env python3
"""W40.d1 — a stand-in OpenAI-compatible gateway, so the bulk OCR journey's gateway route can be proved for $0.

Usage: fake_gateway.py <port> <log file> [completion_tokens] [key] [failing tagging calls]

Serves POST /v1/chat/completions on 127.0.0.1 only. An OCR request (the prompt's TRANSCRIBE task) gets a reply in
the app's OCR format, its classification taken in turn from a fixed cycle (box, folder, then documents), so the
split it produces means nothing; a tagging request gets the tag JSON. Every reply carries an OpenAI-shaped `usage`
(1,000 prompt tokens, `completion_tokens` as given, default 500), which is what the driver's spend meter reads.
A request without `Authorization: Bearer <key>` (default `stand-in-key`, the key file the journey's fake route
hands over) gets a 401, so the run proves the key reached every call. The tagging calls numbered in the fifth argument
(comma-separated, counted from 1 in arrival order; W49.proc-fix-s042) get a provider 500 with no usage, so a run can
prove a failed tagging call is reported rather than filed as tagged. A Pre-OCRed run's classification-only request takes
its class from the same cycle, and FAKE_GATEWAY_TAGS_JSON replaces the tag JSON (W49.proc-suspects-filing). Each request is one line in the log, with the
start of its prompt. It runs in the VM guest, started by `ops/gui/vm-gui-runner.sh` when
W40D1_FAKE_GATEWAY=1; it is never pointed at real material and sends nothing anywhere.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CYCLE = ['box_label', 'folder_label', 'document_start', 'document_continuation', 'document_start', 'document_start']
lock = threading.Lock()
count = {'ocr': 0, 'tags': 0, 'other': 0}


def prompt_text(body):
    out = []
    for m in body.get('messages', []):
        c = m.get('content')
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, list):
            out += [p.get('text', '') for p in c if isinstance(p, dict)]
    return '\n'.join(out)


def answer(text, cls, page):
    """The stand-in's reply to one prompt, as (kind, text): an OCR transcription with the given classification, the
    tag JSON, or 'ok'. Shared with fake_local_agent.py (W40.d2)."""
    if 'TRANSCRIBE' in text:
        return 'ocr', f'[{cls}]\n[rotate_0]\nW40.d1 stand-in transcription, page {page}.'
    if 'You are classifying a page' in text:
        return 'ocr', f'[{cls}]'
    if 'subject_tags' in text:
        if os.environ.get('FAKE_GATEWAY_TAGS_JSON'):
            return 'tags', os.environ['FAKE_GATEWAY_TAGS_JSON']
        return 'tags', json.dumps({'year': '1918', 'month': '3', 'day': '12', 'date_uncertain': False,
                                   'subject_tags': ['War Department', 'Military Intelligence'],
                                   'format': 'Letter'})
    return 'other', 'ok'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.headers.get('Authorization') != f'Bearer {KEY}':
            with open(LOG, 'a', encoding='utf-8') as f:
                f.write(f'unauthorized\t{body.get("model")}\t0\t{self.headers.get("Authorization", "")[:12]!r}\n')
            self.send_response(401)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        text = prompt_text(body)
        with lock:
            kind, reply = answer(text, CYCLE[count['ocr'] % len(CYCLE)], count['ocr'] + 1)
            count[kind] += 1
            fail = kind == 'tags' and count[kind] in FAIL_TAGS
            with open(LOG, 'a', encoding='utf-8') as f:
                head = ' '.join(text.split())[:90].replace('\t', ' ')
                f.write(f'{kind}{"-500" if fail else ""}\t{body.get("model")}\t{count[kind]}\t{head}\n')
        if fail:
            err = b'{"error": {"message": "stand-in upstream error", "code": 500}}'
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return
        out = json.dumps({'id': 'fake', 'object': 'chat.completion', 'model': body.get('model'),
                          'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': reply},
                                       'finish_reason': 'stop'}],
                          'usage': {'prompt_tokens': 1000, 'completion_tokens': COMPLETION,
                                    'total_tokens': 1000 + COMPLETION}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == '__main__':
    port, LOG = int(sys.argv[1]), sys.argv[2]
    COMPLETION = int(sys.argv[3]) if len(sys.argv) > 3 else 500
    KEY = sys.argv[4] if len(sys.argv) > 4 else 'stand-in-key'
    FAIL_TAGS = {int(n) for n in sys.argv[5].split(',') if n} if len(sys.argv) > 5 else set()
    ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
