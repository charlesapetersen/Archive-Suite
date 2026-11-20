#!/usr/bin/env python3
"""W49.bench-sonnet-price: Claude Sonnet 5.5's input tokens on the 99 cloud-panel images, counted by
Anthropic's free count_tokens call (no message is generated, nothing is billed).

The panel ran Sonnet through `claude -p`, so it has no API price. This counts what the API would charge as
input for each page sent the way the OpenRouter routes were: the panel's JPEG (2,400 px cap) as a base64 image
block followed by the panel prompt. It counts the prompt alone too, so the image's share is known. Output
tokens are not something count_tokens can measure; ArchiveOCRBench/data/inputs.json keeps the claude -p mean.

Key: the Processor's Anthropic key in the login Keychain (service com.archiveprocessor.app, account Anthropic).
Usage: sonnet_count_tokens.py [--out PATH]
"""
from __future__ import annotations
import argparse
import base64
import json
from pathlib import Path
import statistics
import subprocess
import time
import urllib.error
import urllib.request

CACHE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/ocr-panel-cloud"
MODEL = "claude-sonnet-5-5"
URL = "https://api.anthropic.com/v1/messages/count_tokens"
DEFAULT_OUT = Path(__file__).resolve().parents[2] / "segbench-results/ocr-panel-sonnet-tokens.json"


def key() -> str:
    k = subprocess.run(["security", "find-generic-password", "-s", "com.archiveprocessor.app", "-a", "Anthropic",
                        "-w"], capture_output=True, text=True, timeout=20).stdout.strip()
    if not k:
        raise SystemExit("no Anthropic key in the Keychain")
    return k


def count(api_key: str, content: list) -> int:
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": content}]}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["input_tokens"]
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529) and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise SystemExit(f"count_tokens failed: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")
    raise SystemExit("unreachable")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    a = ap.parse_args()
    manifest = json.loads((CACHE / "manifest.json").read_text())
    prompt = manifest["prompt"]
    images = sorted((CACHE / "images").glob("p*-original.jpg"))
    if len(images) != 99:
        raise SystemExit(f"expected 99 panel images, found {len(images)}")
    k = key()
    prompt_only = count(k, [{"type": "text", "text": prompt}])
    pages = {}
    for img in images:
        data = base64.standard_b64encode(img.read_bytes()).decode()
        pages[img.name.split("-")[0]] = count(k, [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}},
            {"type": "text", "text": prompt}])
    totals = list(pages.values())
    out = {
        "model": MODEL, "endpoint": URL, "counted": time.strftime("%Y-%m-%d"),
        "images": "ocr-panel-cloud/images (the panel's JPEGs, 2,400 px cap)", "n": len(totals),
        "prompt_only_tokens": prompt_only,
        "mean_input_tokens": round(statistics.mean(totals), 1),
        "median_input_tokens": statistics.median(totals), "min_input_tokens": min(totals),
        "max_input_tokens": max(totals), "pages": pages,
    }
    a.out.write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps({k2: v for k2, v in out.items() if k2 != "pages"}, indent=1))


if __name__ == "__main__":
    main()
