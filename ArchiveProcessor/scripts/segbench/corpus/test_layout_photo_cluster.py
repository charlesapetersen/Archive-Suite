"""W46.layout-photo: which crops the cluster job sends for each page and arm (layout_photo_cluster.py), and that a
real read sends them through regions_cluster's request unchanged. No model, no cluster: a stub server.

    python3 -m unittest test_layout_photo_cluster
"""
import argparse
import hashlib
import http.server
import io
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path

import layout_photo_cluster as LP
import regions_cluster as C

TEXT = {'label': 'plain text', 'order': 1, 'score': 0.9, 'box': [0.1, 0.1, 0.5, 0.4]}
FIG = {'label': 'figure', 'order': 2, 'score': 0.9, 'box': [0.5, 0.5, 0.9, 0.9]}


class Crops(unittest.TestCase):
    def test_arm_without_the_page_sends_nothing(self):
        regions = {'heron': {'a': [TEXT]}}
        self.assertEqual(LP.crops_for('heron', {'id': 'b'}, regions, 1000, 1000), [])

    def test_arm_with_the_page_is_regions_cluster_crops(self):
        regions = {'heron': {'a': [TEXT, FIG]}}
        got = LP.crops_for('heron', {'id': 'a'}, regions, 1000, 1000)
        self.assertEqual(got, C.crops_for('heron', {'id': 'a'}, regions, 1000, 1000))
        self.assertEqual([c['label'] for c in got], ['plain text'])     # the figure is not read

    def test_whole_page_is_one_crop_of_the_page(self):
        got = LP.crops_for('whole', {'id': 'a'}, {'whole': {'a': [{'label': 'page', 'order': 1, 'score': 1,
                                                                   'box': [0, 0, 1, 1]}]}}, 800, 1200)
        self.assertEqual([c['px'] for c in got], [(0, 0, 800, 1200)])


class _Stub(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        _Stub.seen.append(body)
        self.send_response(200); self.end_headers()
        chunk = {'choices': [{'delta': {'content': 'text'}, 'finish_reason': 'stop'}], 'usage': {'completion_tokens': 1}}
        self.wfile.write(b'data: ' + json.dumps(chunk).encode() + b'\n\ndata: [DONE]\n\n')

    def log_message(self, *a):
        pass


class Read(unittest.TestCase):
    def test_each_page_is_read_in_the_arms_that_name_it(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pages = []
            for pid in ('bench1', 'real1'):
                buf = io.BytesIO(); Image.new('RGB', (400, 600), 'white').save(buf, 'JPEG')
                f = root / f'{pid}.jpg'; f.write_bytes(buf.getvalue())
                pages.append({'id': pid, 'image': str(f), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest(), 'set': 'x'})
            (root / 'pages.jsonl').write_text(''.join(json.dumps(p) + '\n' for p in pages))
            (root / 'prompt.txt').write_text('read')
            (root / 'routes.json').write_text(json.dumps({'glm-ocr': {'prompt': str(root / 'prompt.txt')}}))
            (root / 'regions').mkdir()
            (root / 'regions' / 'whole.json').write_text(json.dumps({'pages': {'real1': [dict(TEXT, box=[0, 0, 1, 1])]}}))
            (root / 'regions' / 'heron.json').write_text(json.dumps({'pages': {'bench1': [TEXT, FIG], 'real1': [TEXT]}}))
            srv = http.server.HTTPServer(('127.0.0.1', 0), _Stub)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            os.environ.update(FS_URL=f'http://127.0.0.1:{srv.server_port}', FS_SERVED='glm-ocr')
            try:
                LP.cmd_read(argparse.Namespace(root=root, route='glm-ocr', shard='0/1', limit=0, concurrency=2))
            finally:
                srv.shutdown()
            got = sorted(str(p.relative_to(root / 'out' / 'glm-ocr')) for p in (root / 'out' / 'glm-ocr').rglob('0*.json'))
            self.assertEqual(got, ['heron/bench1/000.json', 'heron/real1/000.json', 'whole/real1/000.json'])
            rec = json.loads((root / 'out/glm-ocr/whole/real1/000.json').read_text())
            self.assertEqual((rec['status'], rec['raw'], rec['px']), ('ok', 'text', [0, 0, 400, 600]))
            self.assertEqual(_Stub.seen[0]['max_tokens'], C.MAX_TOKENS)


if __name__ == '__main__':
    unittest.main()
