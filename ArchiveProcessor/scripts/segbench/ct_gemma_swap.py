#!/usr/bin/env python3
"""W49.proc-gemma-swap-time: time Gemma label reads and local page OCR, one model resident at a time.

mlx-vlm 0.7.4's automatic switch keeps the outgoing model while it loads the next one, so on the
18 GB Mac Gemma 3 12B and the OCR model were resident together and the session was stopped at
13.0 GB (Qwen3-VL 8B) and 12.0 GB (Qwen3.5 4B). This harness never asks a server for a second
model: it stops the server and starts a fresh one with the next model. Each step (stop, cold load,
first read, warm read) is timed and its peak physical footprint recorded, and each row is written
as it completes. A step whose footprint passes 10 GiB kills the server and ends the run.

Run under ops/autonomous/heavy-run.py with the MLX lab Python (mlx-vlm 0.7.4). Pass two upright
label photos and two document photos from scratch. The output holds timings and sizes only.
"""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
from importlib.metadata import version
from pathlib import Path
from urllib.request import Request

import ct_gemma_route_fields as labels
import model_store

GEMMA = labels.G.MODEL
OCR = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
OCR_REVISION = "c43ee1d65576a5d98de1e8405cac93c371a655c1"
REVISIONS = {GEMMA: labels.MODEL_REVISION, OCR: OCR_REVISION}
# GiB, the unit of Agent Manager's memory guard (its 11.7 GB limit is 65% of this Mac's 18 GiB).
GIB = 2**30
LIMIT = 10 * GIB
ENCODER = """
import Foundation

let photo = URL(fileURLWithPath: CommandLine.arguments[1])
let jpeg = CommandLine.arguments[2] == "label"
    ? ImageEncoding.uprightJPEG(url: photo, rotationDegrees: 0, longEdge: 1600)
    : ImageEncoding.loadImageAsJPEG(url: photo, maxDimension: 900)
guard let jpeg else { fatalError("Could not encode photo") }
FileHandle.standardOutput.write(jpeg)
"""


class OverLimit(RuntimeError):
    pass


def request_body(encoder, photo, model):
    is_label = model == GEMMA
    jpeg = subprocess.check_output([encoder, photo, "label" if is_label else "page"])
    body = labels.server_body(model, jpeg)
    if not is_label:
        # The first-page prompt has no preceding page or custom context.
        source = (labels.APP / "OCR/OCRPrompt.swift").read_text()
        prompt = source.split('var prompt = """\n', 1)[1].split('"""', 1)[0]
        body["messages"][0]["content"][1]["text"] = textwrap.dedent(prompt).rstrip()
        body.update(max_tokens=4096, stream=True)
    return body


class Watch:
    """Sample the server's physical footprint every 0.1 s during one step; kill it past LIMIT."""

    def __init__(self, child):
        self.child, self.footprint = child, labels.footprint_reader(child.pid)

    def __enter__(self):
        self.stop, self.peak, self.over = threading.Event(), 0, False
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()
        return self

    def sample(self):
        while True:
            try:
                self.peak = max(self.peak, self.footprint())
            except OSError:
                return  # the server exited; the step itself reports why
            if self.peak > LIMIT:
                self.over = True
                self.child.kill()
                return
            if self.stop.wait(0.1):
                return

    def __exit__(self, kind, error, trace):
        self.stop.set()
        self.thread.join()
        if self.over:
            raise OverLimit(f"Server footprint passed 10 GiB ({self.peak / GIB:.2f} GiB)")


def start(model, port):
    """Start a fresh server with one model preloaded; return it once it answers, with the load time."""
    env = dict(os.environ, HF_HUB_CACHE=str(model_store.HUB), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    with socket.socket() as probe:
        # Fails only if something listens; the previous server's closed connections may sit in TIME_WAIT.
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))
    began = time.monotonic()
    child = subprocess.Popen(
        [sys.executable, "-m", "mlx_vlm.server", "--host", "127.0.0.1", "--port", str(port), "--model", model],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}/v1"
    try:
        with Watch(child) as watch:
            while True:
                if child.poll() is not None:
                    raise RuntimeError(f"MLX server exited during startup ({child.returncode})")
                if time.monotonic() - began > 600:
                    raise RuntimeError("MLX server did not become ready")
                try:
                    listed = labels.json_request(base + "/models")["data"]
                    break
                except OSError:
                    time.sleep(0.2)
        load = time.monotonic() - began
        resident = [m["id"] for m in listed if m.get("loaded")]
        if resident != [model]:
            raise RuntimeError(f"Expected only {model} loaded, found {resident}")
    except BaseException:
        stop(child)
        raise
    return child, base, dict(seconds=round(load, 3), peak_gib=round(watch.peak / GIB, 3))


def stop(child):
    began = time.monotonic()
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(60)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    return round(time.monotonic() - began, 3)


def time_read(base, body):
    request = Request(base + "/chat/completions", data=json.dumps(body).encode(), method="POST",
                      headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    began = time.monotonic()
    first = finish = None
    parts = []
    with labels.LOCAL.open(request, timeout=600 if body["stream"] else 180) as response:
        if body["stream"]:
            for line in response:
                if not line.startswith(b"data: "):
                    continue
                if line.strip() == b"data: [DONE]":
                    break
                for choice in json.loads(line[6:]).get("choices", []):
                    if choice.get("finish_reason"):
                        finish = choice["finish_reason"]
                    if content := (choice.get("delta") or {}).get("content"):
                        if first is None:
                            first = time.monotonic() - began
                        parts.append(content)
        else:
            choice = json.load(response)["choices"][0]
            finish = choice.get("finish_reason")
            parts.append(choice["message"].get("content") or "")
    wall = time.monotonic() - began
    raw = "".join(parts)
    answered = any((labels.R.parse(raw) or {}).values()) if body["model"] == GEMMA else bool(raw.strip())
    if not answered or finish != "stop":
        raise RuntimeError(f"Unusable {body['model']} reply (finish={finish}, answered={answered})")
    return dict(seconds=round(wall, 3), first_token_s=None if first is None else round(first, 3),
                reply_chars=len(raw))


def run(bodies, port, emit):
    """Gemma first (no server before it), then four blocks of OCR then Gemma, each after a restart.
    Image order alternates (0, 1, 1, 0) so each image is the first read after a load twice."""
    child = None
    schedule = [(GEMMA, 0)] + [(model, first) for first in (0, 1, 1, 0) for model in (OCR, GEMMA)]
    try:
        for step, (model, first) in enumerate(schedule):
            previous = None
            stopped = None
            if child is not None:
                previous = OCR if model == GEMMA else GEMMA
                stopped = stop(child)
                child = None
            print(f"Loading {model} (step {step})", file=sys.stderr, flush=True)
            child, base, load = start(model, port)
            emit(dict(step=step, model=model, switched_from=previous, stop_s=stopped, load=load))
            reads = []
            for image in (first, 1 - first):
                with Watch(child) as watch:
                    reads.append(dict(image=image + 1, **time_read(base, bodies[model][image])))
                reads[-1]["peak_gib"] = round(watch.peak / GIB, 3)
            resident = [m["id"] for m in labels.json_request(base + "/models")["data"] if m.get("loaded")]
            if resident != [model]:
                raise RuntimeError(f"Expected only {model} loaded after reads, found {resident}")
            cold, warm = reads
            row = dict(step=step, model=model, first_read=cold, warm_read=warm,
                       switch_s=None if previous is None else round(stopped + load["seconds"] + cold["seconds"], 3))
            emit(row)
            print(f"{model}: load {load['seconds']} s ({load['peak_gib']} GiB), first {cold['seconds']} s, "
                  f"warm {warm['seconds']} s", file=sys.stderr, flush=True)
    finally:
        if child is not None:
            stop(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", nargs=2, type=Path, required=True)
    parser.add_argument("--page", nargs=2, type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True, help="JSON lines, one row per completed step")
    parser.add_argument("--port", type=int, default=18091)
    args = parser.parse_args()
    if version("mlx-vlm") != labels.SERVER_VERSION:
        raise RuntimeError(f"This comparison needs mlx-vlm {labels.SERVER_VERSION}")
    model_store.use()
    for repo, revision in REVISIONS.items():
        snapshot = model_store.snapshot(repo, revision)
        if not snapshot.is_dir() or (snapshot.parents[1] / "refs/main").read_text().strip() != revision:
            raise RuntimeError(f"Expected cached revision for {repo}")
    with tempfile.TemporaryDirectory(prefix="ct-gemma-swap-") as tmp:
        folder = Path(tmp)
        (folder / "main.swift").write_text(ENCODER)
        encoder = folder / "encode"
        subprocess.run(["swiftc", str(labels.APP / "OCR/ImageEncoding.swift"), str(folder / "main.swift"),
                        "-o", str(encoder)], check=True)
        bodies = {model: [request_body(encoder, photo, model) for photo in photos]
                  for model, photos in ((GEMMA, args.label), (OCR, args.page))}
    with args.out.open("a") as out:
        def emit(row):
            out.write(json.dumps(row) + "\n")
            out.flush()
            print(json.dumps(row), flush=True)

        emit({"mlx_vlm": version("mlx-vlm"), "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "label_sha256": [hashlib.sha256(p.read_bytes()).hexdigest() for p in args.label],
              "page_sha256": [hashlib.sha256(p.read_bytes()).hexdigest() for p in args.page]})
        try:
            run(bodies, args.port, emit)
        except OverLimit as error:
            emit({"stopped": str(error)})
            raise


if __name__ == "__main__":
    main()
