#!/usr/bin/env python3
"""The cluster reader end to end on a synthetic pack, against a stub OpenAI-style server on localhost.

  python3 test_mixed_route_cluster.py      (needs Pillow; run from this folder or with it on sys.path)

Checks the two ways this pack differs from layout-photo's: its own arms, and a mark box inside another is still read.
"""
import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent.parent / "corpus"


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        img = b["messages"][0]["content"][0]["image_url"]["url"].split(",", 1)[1]
        from PIL import Image
        w, h = Image.open(io.BytesIO(base64.b64decode(img))).size
        chunk = {"choices": [{"delta": {"content": f"{w}x{h}"}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\ndata: [DONE]\n\n")

    def log_message(self, *a):
        pass


class ClusterRead(unittest.TestCase):
    def test_read(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for f in ("regions_cluster.py", "layout_photo_cluster.py"):
                (root / f).write_bytes((CORPUS / f).read_bytes())
            (root / "mixed_route_cluster.py").write_bytes((HERE / "mixed_route_cluster.py").read_bytes())
            (root / "images").mkdir()
            img = root / "images" / "P-1.jpg"
            Image.new("RGB", (1000, 2000), "white").save(img)
            (root / "pages.jsonl").write_text(json.dumps(dict(
                id="P-1", image=str(img), sha256=hashlib.sha256(img.read_bytes()).hexdigest(), set="marks-core",
                stratum=None)) + "\n")
            (root / "prompt.txt").write_text("read")
            (root / "routes.json").write_text(json.dumps({"glm-ocr": dict(model="m", served="s",
                                                                          prompt=str(root / "prompt.txt"), vllm_args="")}))
            (root / "regions").mkdir()
            big, inner = [0.1, 0.1, 0.9, 0.5], [0.2, 0.2, 0.4, 0.3]
            regions = {"whole": {"P-1": [dict(label="page", order=1, score=1.0, box=[0, 0, 1, 1])]},
                       "oracle": {"P-1": [dict(label="P-1#0", order=1, score=1.0, box=big),
                                          dict(label="P-1#1", order=2, score=1.0, box=inner)]},
                       "det25": {"P-1": []},
                       "det05": {"P-1": [dict(label="P-1#1", order=1, score=1.0, box=inner)]}}
            for arm, pages in regions.items():
                (root / "regions" / f"{arm}.json").write_text(json.dumps(dict(detector=arm, pages=pages)))
            srv = HTTPServer(("127.0.0.1", 0), Stub)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            env = {**os.environ, "FS_URL": f"http://127.0.0.1:{srv.server_port}", "FS_SERVED": "s"}
            try:
                subprocess.run([sys.executable, str(root / "mixed_route_cluster.py"), "check", "--root", str(root),
                                "--strict"], check=True, env=env, capture_output=True)
                subprocess.run([sys.executable, str(root / "mixed_route_cluster.py"), "read", "--root", str(root),
                                "--route", "glm-ocr", "--concurrency", "2"], check=True, env=env, capture_output=True)
            finally:
                srv.shutdown()
                srv.server_close()
            out = root / "out" / "glm-ocr"
            got = {arm: sorted(json.loads(f.read_text())["label"] for f in (out / arm / "P-1").glob("*.json"))
                   for arm in ("whole", "oracle", "det05") if (out / arm / "P-1").is_dir()}
            self.assertEqual(got, {"whole": ["page"], "oracle": ["P-1#0", "P-1#1"], "det05": ["P-1#1"]})
            self.assertFalse((out / "det25" / "P-1").exists())
            rec = json.loads((out / "whole" / "P-1" / "000.json").read_text())
            self.assertEqual((rec["raw"], rec["status"]), ("1000x2000", "ok"))


if __name__ == "__main__":
    unittest.main()
