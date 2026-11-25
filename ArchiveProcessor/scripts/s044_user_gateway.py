#!/usr/bin/env python3
"""Independent S-044 UI check: deterministic letters, $0, guest loopback only.

No imports from the earlier reproduction. GET /calls exposes request kinds to the
UI test, and GET /images a SHA-256 of each OCR request's image parts (W49.proc-s048-check);
no request bodies, image bytes or credentials are retained.
"""
import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

calls = []
images = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path not in ('/calls', '/images'):
            return self.send_json({}, 404)
        with lock:
            self.send_json(calls if self.path == '/calls' else images)

    def do_POST(self):
        if self.path != '/v1/chat/completions' or self.headers.get('Authorization') != 'Bearer s044-stand-in':
            return self.send_json({}, 403)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        parts = []
        for message in body.get('messages', []):
            content = message.get('content', '')
            parts.extend([content] if isinstance(content, str) else
                         [part.get('text', '') for part in content if isinstance(part, dict)])
        prompt = '\n'.join(parts)
        if 'You are extracting correspondence metadata' in prompt:
            kind, reply = 'names', json.dumps({'sender': [{'name': 'Ada Lovelace', 'quote': 'Ada Lovelace'}],
                                               'recipient': [], 'sending_place': []})
        elif 'subject_tags' in prompt:
            kind, reply = 'tagging', json.dumps({'year': '1918', 'month': '3', 'day': '12',
                                                'date_uncertain': False, 'subject_tags': ['Letters'], 'format': 'Letter'})
        elif 'TRANSCRIBE' in prompt:
            kind, reply = 'ocr', '[document_start]\n[rotate_0]\n12 March 1918\nDear friend,\nA letter about mathematics.\nAda Lovelace'
        elif 'You are dating a document' in prompt:
            kind, reply = 'dating-trace', '{}'
        elif 'These are the first pages of one archival document' in prompt:
            kind, reply = 'dating-image', '{}'
        elif 'You are labelling catalogue fields' in prompt:
            kind, reply = 'item-fields', '{}'
        else:
            kind, reply = 'other', 'ok'
        digest = hashlib.sha256()
        for message in body.get('messages', []):
            for part in message.get('content', []) if isinstance(message.get('content'), list) else []:
                if isinstance(part, dict) and part.get('type') == 'image_url':
                    url = part.get('image_url')
                    digest.update(str(url.get('url', '') if isinstance(url, dict) else url).encode())
        with lock:
            calls.append({'kind': kind, 'model': body.get('model')})
            if kind == 'ocr':
                images.append(digest.hexdigest())
        self.send_json({'id': 's044', 'object': 'chat.completion', 'model': body.get('model'),
                        'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': reply}, 'finish_reason': 'stop'}],
                        'usage': {'prompt_tokens': 1000, 'completion_tokens': 500, 'total_tokens': 1500}})


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
