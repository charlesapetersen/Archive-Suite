#!/usr/bin/env python3
"""W46.p17-gemma-route-fields: score the Processor's local Gemma label route.

Run under heavy-run.py with the MLX lab Python. This uses the frozen upright
label photos and the app's Swift JPEG encoder, with a loopback-only MLX server.
The resumable cache holds per-photo correctness flags and timings only.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import ct_gemma_route as G
import ct_read as R
import model_store


BASELINE = 60
TOTAL = 195
IN_PROCESS = "gemma3-12b-mlx4"
OUT = Path(R.OUT) / "gemma-route-fields.json"
APP = Path(__file__).resolve().parents[2] / "macOS/Sources/ArchiveProcessor"
MODEL_REVISION = "86cc6a8dedbc456dd0e4af01a9d09f396f77e558"
SERVER_VERSION = "0.7.4"
ENCODER = """
import Foundation

let photo = URL(fileURLWithPath: CommandLine.arguments[1])
guard let jpeg = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: 0, longEdge: 1600) else {
    fatalError("Could not encode the benchmark photo")
}
FileHandle.standardOutput.write(jpeg)
"""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


LOCAL = build_opener(ProxyHandler({}), NoRedirect())


def json_request(url, body=None):
    if body is None:
        request = Request(url)
    else:
        request = Request(url, data=json.dumps(body).encode(), method="POST",
                          headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    with LOCAL.open(request, timeout=180 if body else 3) as response:
        return json.load(response)


def server_body(model, jpeg):
    data_url = "data:image/jpeg;base64," + base64.b64encode(jpeg).decode("ascii")
    return {
        "model": model, "temperature": 0, "max_tokens": R.MAX_TOKENS, "stream": False,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": data_url}},
            {"type": "text", "text": R.PROMPT},
        ]}],
        "enable_thinking": False, "chat_template_kwargs": {"enable_thinking": False}, "think": False,
    }


@contextmanager
def server(port):
    if version("mlx-vlm") != SERVER_VERSION:
        raise RuntimeError(f"This comparison needs mlx-vlm {SERVER_VERSION}")
    model_store.use()
    if Path(os.environ["HF_HOME"]).resolve() != model_store.HF_HOME.resolve():
        raise RuntimeError("Use the bench's pinned local model cache")
    if not model_store.snapshot(G.MODEL, MODEL_REVISION).is_dir():
        raise RuntimeError("Pinned Gemma snapshot missing from model cache")
    if (model_store.HUB / ("models--" + G.MODEL.replace("/", "--")) / "refs/main").read_text().strip() != MODEL_REVISION:
        raise RuntimeError("Cache's main ref differs from the benchmark snapshot")
    env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    base = f"http://127.0.0.1:{port}/v1"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))
    child = subprocess.Popen(
        [sys.executable, "-m", "mlx_vlm.server", "--host", "127.0.0.1", "--port", str(port), "--model", G.MODEL],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(180):
            if child.poll() is not None:
                raise RuntimeError(f"MLX server exited during startup ({child.returncode})")
            try:
                listed = [m["id"] for m in json_request(base + "/models")["data"]]
            except OSError:
                time.sleep(1)
                continue
            if child.poll() is not None or G.pick(listed) != G.MODEL:
                raise RuntimeError("The loopback server did not select the pinned Gemma model")
            yield base
            return
        raise RuntimeError("MLX server did not become ready")
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def encoder(folder):
    main = Path(folder) / "main.swift"
    main.write_text(ENCODER, encoding="utf-8")
    binary = Path(folder) / "encode"
    subprocess.run(["swiftc", str(APP / "OCR/ImageEncoding.swift"), str(main), "-o", str(binary)], check=True)
    return binary


def read_server(base, jpeg):
    start = time.monotonic()
    reply = json_request(base + "/chat/completions", server_body(G.MODEL, jpeg))["choices"][0]
    finish = reply.get("finish_reason")
    raw = reply["message"].get("content") or ""
    # Match LocalModelRoute for completed replies, then apply the same bench parser to all Gemma arms.
    while (opening := raw.find("<think>")) >= 0:
        closing = raw.find("</think>", opening)
        if closing < 0:
            raw = ""
            break
        raw = raw[:opening] + raw[closing + len("</think>"):]
    if "</think>" in raw:
        raw = raw.split("</think>", 1)[1]
    return (R.parse(raw) if finish != "length" else None), round(time.monotonic() - start, 2), finish


def inputs():
    rows = {r["id"]: r for r in R.truth()}
    ids = G.sample(TOTAL)
    if len(ids) != TOTAL or len(rows) != TOTAL:
        raise RuntimeError("The complete 195-photo truth and paired in-process replies are required")
    if not all(any((Path(d) / f"{mid}.json").is_file() for d in (R.FINAL_LINES, R.REV_LINES)) for mid in ids):
        raise RuntimeError("Vision line caches are missing from the frozen panel")
    return rows, ids


def correct(field, answer, truth):
    return R.same(field, (answer or {}).get(field), truth)


def original_panel(rows, ids):
    """Recover the pilot's per-field pairs, checking its stored pairing against today's inputs."""
    rec = json.loads(Path(G.OUT).read_text(encoding="utf-8"))
    if rec["photos"] != BASELINE or len(rec["calls"]) != BASELINE:
        raise RuntimeError("The original 60-photo counts are required")
    panel = []
    for mid, call in zip(ids[:BASELINE], rec["calls"]):
        row = rows[mid]
        vision = R.reading(row, "vision")
        in_process = R.reading(row, IN_PROCESS)
        expected = {f for f in G.FOUR if not R.cell_class(row, f).startswith("out")}
        if expected != call["right"].keys():
            raise RuntimeError("Pilot scoring mask differs from the current truth")
        cells = {}
        for field, (app, original) in call["right"].items():
            truth = row["fields"].get(field)
            if original != correct(field, in_process, truth):
                raise RuntimeError("Pilot pairing with the in-process reading has changed")
            cells[field] = [app, original, correct(field, vision, truth)]
        panel.append(dict(cells=cells, wall_s=call["wall_s"], parsed=call["parsed"]))
    return panel


def store(cache, record):
    temp = cache.with_suffix(".tmp")
    temp.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
    temp.replace(cache)


def collect(rows, ids, record, cache, port, limit):
    calls = record["holdout"]
    target = len(ids) if limit is None else min(len(ids), len(calls) + limit)
    if target == len(calls):
        return
    with tempfile.TemporaryDirectory(prefix="ct-gemma-encode-") as folder:
        binary = encoder(folder)
        with server(port) as base:
            print("Pinned Gemma server ready on loopback", flush=True)
            for index in range(len(calls), target):
                mid = ids[index]
                row = rows[mid]
                jpeg = subprocess.check_output([binary, R.page_of(mid)])
                answer, wall, finish = read_server(base, jpeg)
                original = R.reading(row, IN_PROCESS)
                vision = R.reading(row, "vision")
                cells = {}
                for field in G.FOUR:
                    source = R.cell_class(row, field)
                    if source.startswith("out"):
                        continue
                    want = row["fields"].get(field)
                    values = [(prediction or {}).get(field) for prediction in (answer, original, vision)]
                    cells[field] = {
                        "right": [R.same(field, value, want) for value in values],
                        "filled": [bool(value) for value in values],
                        "truth_filled": bool(want), "rule": source == "rule",
                    }
                calls.append(dict(cells=cells, folder=row["colour"] == "Purple",
                                  wall_s=wall, parsed=answer is not None, finish=finish))
                store(cache, record)
                print(f"Held-out label {index + 1}/{len(ids)}: {wall:.2f}s, parsed={answer is not None}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18091)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--cache", type=Path, default=OUT)
    args = parser.parse_args()
    rows, ids = inputs()
    original_panel(rows, ids)
    # No photo identifiers in the counts file. Pin selection and ordering across restarts.
    fingerprint = hashlib.sha256("\n".join(ids).encode()).hexdigest()
    cache = args.cache
    record = (json.loads(cache.read_text(encoding="utf-8")) if cache.exists()
              else {"schema": 1, "panel": fingerprint, "holdout": []})
    if record.get("schema") != 1 or record["panel"] != fingerprint:
        raise RuntimeError("The frozen panel has changed since the counts were recorded")
    collect(rows, ids[BASELINE:], record, cache, args.port, args.limit)


if __name__ == "__main__":
    main()
