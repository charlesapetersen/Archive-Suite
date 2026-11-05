#!/usr/bin/env python3
"""W46.seg-adapt-lora: a second Lincoln box, the next catalogue items after the first.

The first box (public-segmentation/lincoln.json) is Shelf Order catalogue positions 2-73 of the saved
snapshot. This box starts at position 74 of the SAME snapshot and adds whole items while it holds fewer than
250 pages, the first box's stop rule. Corrections from box 1 are then scored on box 2.

loc.gov's item pages and IIIF manifests now sit behind a Cloudflare challenge that the approved fetch helper
cannot pass, so each item's canvas count comes from tile.loc.gov's image service instead: canvases
<item>:001, :002, ... are probed until the first 404. That rule matched the saved manifests' counts on the
first box (checked 2026-11-04 on 9 of its 72 items). Images come through corpus/fetch.sh only.

  lincoln_box2.py --root DIR inventory   # probe page counts, write DIR/lincoln2-inventory.json
  lincoln_box2.py --root DIR download    # fetch + verify every page, write DIR/lincoln2-pages.json
  lincoln_box2.py --root DIR draft       # write the unreviewed manifest, catalogue starts only
DIR is the public source cache (images never enter git). Nothing here reads or labels a page's content.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
FETCH = HERE / "corpus/fetch.sh"
MANIFESTS = HERE.parents[1] / "segbench-results/public-segmentation"
SNAPSHOT_SHA = "977661fff7af6ec6204acc1e2ca31eaa7b31fb717dc2284cb46ee378b91b168e"  # box 1's catalogue record
FIRST_POSITION, STOP_PAGES, MAX_CANVASES = 74, 250, 300
IIIF = "https://tile.loc.gov/image-services/iiif/service:mss:mal"


def service(item, page):
    num = item.removeprefix("mal")
    if not (item.startswith("mal") and num.isdigit() and len(num) == 7):
        raise ValueError(f"not a Lincoln Papers manuscript id: {item}")
    return f"{IIIF}:{num[:3]}:{num}:{page:03}"


def status(url):
    """HTTP status of a HEAD on url, with bounded retries for anything but 200/404."""
    for attempt in range(4):
        time.sleep(0.3)
        p = subprocess.run([str(FETCH), "--head", url], capture_output=True, text=True)
        first = p.stdout.split("\n", 1)[0].split()
        if len(first) > 1 and first[1] in ("200", "404"):
            return int(first[1])
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"no definite answer for {url}: {p.stderr[-300:]}")


def info(url):
    for attempt in range(4):
        time.sleep(0.3)
        p = subprocess.run([str(FETCH), "--stdout", f"{url}/info.json"], capture_output=True, text=True)
        if p.returncode == 0:
            return json.loads(p.stdout)
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"info.json failed for {url}: {p.stderr[-300:]}")


def snapshot(root):
    path = root / "raw/lincoln-catalogue-shelf-page1.json"
    if hashlib.sha256(path.read_bytes()).hexdigest() != SNAPSHOT_SHA:
        raise ValueError("catalogue snapshot differs from the one box 1 was selected from")
    return json.loads(path.read_text())["items"]


def inventory(root):
    items, first_box = snapshot(root), json.loads((MANIFESTS / "lincoln.json").read_text())
    taken = {d["id"] for d in first_box["source_documents"]}
    if first_box["catalogue"]["positions"][1] != FIRST_POSITION - 1:
        raise ValueError("box 1 no longer ends just before this box's first position")
    out, total = [], 0
    for position in range(FIRST_POSITION, len(items) + 1):
        if total >= STOP_PAGES:
            break
        link = items[position - 1]["links"][0]
        item = link["url"].rstrip("/").rsplit("/", 1)[-1]
        if item in taken:
            raise ValueError(f"{item} is already in box 1")
        pages = []
        while True:
            url = service(item, len(pages) + 1)
            if status(f"{url}/info.json") == 404:
                break
            meta = info(url)
            pages.append({"canvas": url, "width": meta["width"], "height": meta["height"]})
            if len(pages) > MAX_CANVASES:
                raise ValueError(f"{item}: no end found")
        if not pages:
            raise ValueError(f"{item} (position {position}) has no canvases")
        out.append({"id": item, "position": position, "title": link["text"], "pages": len(pages),
                    "canvases": pages})
        total += len(pages)
        print(position, item, len(pages), total, flush=True)
    if total < STOP_PAGES:
        raise ValueError(f"snapshot ran out at {total} pages")
    (root / "lincoln2-inventory.json").write_text(json.dumps(out, indent=2))
    print(f"{len(out)} items, {total} canvases, positions {FIRST_POSITION}-{out[-1]['position']}")


def download(root):
    from PIL import Image
    inv = json.loads((root / "lincoln2-inventory.json").read_text())
    env = {**os.environ, "BENCH_CORPUS_CACHE": str(root)}
    pages, n = [], 0
    for d in inv:
        for j, c in enumerate(d["canvases"], 1):
            n += 1
            url, rel = f"{c['canvas']}/full/!2000,2000/0/default.jpg", f"boxes/Lincoln2/{n:04}.jpg"
            dest = root / rel
            for attempt in range(3):
                if dest.exists():
                    break
                time.sleep(1)
                p = subprocess.run([str(FETCH), url, rel], env=env, capture_output=True, text=True)
                if p.returncode == 0:
                    break
                print(n, "attempt", attempt + 1, "failed", p.stderr[-300:], flush=True)
                time.sleep(10 * (attempt + 1))
            else:
                raise RuntimeError(f"page {n} not retrieved")
            with Image.open(dest) as im:
                im.verify()
            with Image.open(dest) as im:
                w, h = im.size
            if not (max(w, h) <= 2000 and min(w, h) > 50 and abs((w / h) / (c["width"] / c["height"]) - 1) < 0.01):
                raise ValueError(f"page {n}: {w}x{h} against canvas {c['width']}x{c['height']}")
            pages.append({"n": n, "id": d["id"], "page": j, "position": d["position"], "canvas": c["canvas"],
                          "source_image": f"{c['canvas']}/full/pct:100/0/default.jpg", "download_url": url,
                          "image": rel, "sha256": hashlib.sha256(dest.read_bytes()).hexdigest()})
        print(d["id"], d["pages"], "complete", n, flush=True)
    (root / "lincoln2-pages.json").write_text(json.dumps(pages, indent=2))
    print(f"all {n} canvases retrieved and verified")


def draft(root):
    inv = json.loads((root / "lincoln2-inventory.json").read_text())
    pages = json.loads((root / "lincoln2-pages.json").read_text())
    first = json.loads((MANIFESTS / "lincoln.json").read_text())
    manifest = {
        "version": 1, "box": "Lincoln2", "source": first["source"],
        "catalogue": {"url": first["catalogue"]["url"],
                      "positions": [inv[0]["position"], inv[-1]["position"]],
                      "total_catalogue_items": first["catalogue"]["total_catalogue_items"],
                      "catalogue_snapshot_sha256": SNAPSHOT_SHA,
                      "selection": (f"{len(inv)} consecutive manuscript items after box 1 (positions 2-73), all "
                                    f"{len(pages)} supplied canvases; whole items added while under "
                                    f"{STOP_PAGES} pages, box 1's stop rule."),
                      "canvas_counts": "tile.loc.gov image service probed to the first 404; loc.gov manifests "
                                       "are behind a Cloudflare challenge (W46.seg-adapt-lora, 2026-11-04).",
                      "limits": first["catalogue"]["limits"]},
        "rules": first["rules"], "rights": first["rights"], "render": first["render"],
        "source_documents": [{"id": d["id"], "pages": d["pages"], "position": d["position"],
                              "title": d["title"]} for d in inv],
        "audit": {"reviewed_through": 0, "new_starts": {},
                  "status": "catalogue starts only; internal starts not yet audited"},
        "pages": [{**p, "label": "New" if p["page"] == 1 else "Cont",
                   "archive_label": "New" if p["page"] == 1 else "Cont", "reviewed": False} for p in pages],
    }
    out = MANIFESTS / "lincoln2-draft.json"
    out.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")
    print(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, type=Path)
    ap.add_argument("cmd", choices=("inventory", "download", "draft"))
    a = ap.parse_args()
    {"inventory": inventory, "download": download, "draft": draft}[a.cmd](a.root.resolve())


if __name__ == "__main__":
    sys.exit(main())
