#!/usr/bin/env python3
"""W46.marks-detect on Sherlock: a YOLO11m marks detector trained on AnnoPage and SignverOD.

  python3 marks_detect_cluster.py check --root PACK                 # Mac dry run: the pack is complete
  python3 marks_detect_cluster.py prep --root ROOT --data DATA      # CPU: both public sets -> one YOLO dataset
  python3 marks_detect_cluster.py train --root ROOT --data DATA --epochs N --hours H [--name NAME]
  python3 marks_detect_cluster.py predict --root ROOT --name NAME   # the 32 evaluation pages -> out/NAME.json

Classes: 0 handwritten (AnnoPage's handwritten-inscription class), 1 stamp (AnnoPage), 2 signature and 3 initials
(SignverOD ids 1 and 2), 4 redaction (3), 5 date (4). The scorer on the Mac is class-agnostic, so the map only has
to keep marks apart from everything AnnoPage also labels (print decorations, images, tables), which are dropped.
AnnoPage pages with neither target class are kept as negatives, at most as many as the positives, chosen by seed.
No evaluation page is ever a training page: the evaluation images are only corpus pages, and the training data is
only the two public sets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
import zipfile
from pathlib import Path

TARGET = {"handwritten": 0, "stamp": 1}
SIGNVER = {1: 2, 2: 3, 3: 4, 4: 5}
NAMES = ["handwritten", "stamp", "signature", "initials", "redaction", "date"]
IMG = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
SEED = 46


def anno_class_map(names):
    """AnnoPage class index -> ours. Exactly one handwritten-inscription class and one stamp class must exist."""
    out = {}
    for i, n in enumerate(names):
        low = n.lower()
        if re.search(r"handwrit", low):
            out[i] = TARGET["handwritten"]
        elif re.fullmatch(r"\W*stamps?\W*", low) or low.startswith("stamp"):
            out[i] = TARGET["stamp"]
    got = sorted(out.values())
    if got != [0, 1]:
        raise SystemExit(f"AnnoPage classes: expected one handwritten and one stamp class, got {names}")
    return out


def find_names(tree: Path):
    """The class list from the dataset's YAML (names: list or dict) or a classes.txt."""
    for y in sorted(tree.rglob("*.yaml")) + sorted(tree.rglob("*.yml")):
        import yaml
        d = yaml.safe_load(y.read_text())
        if isinstance(d, dict) and "names" in d:
            n = d["names"]
            return [n[k] for k in sorted(n)] if isinstance(n, dict) else list(n)
    for c in sorted(tree.rglob("classes.txt")):
        return [l.strip() for l in c.read_text().splitlines() if l.strip()]
    raise SystemExit(f"no class list under {tree}")


def label_for(im: Path):
    """YOLO's pairing: .../images/<split>/x.jpg -> .../labels/<split>/x.txt, else x.txt beside the image."""
    parts = list(im.parts)
    if "images" in parts:
        i = len(parts) - 1 - parts[::-1].index("images")
        lab = Path(*parts[:i], "labels", *parts[i + 1:]).with_suffix(".txt")
        if lab.exists():
            return lab
    lab = im.with_suffix(".txt")
    return lab if lab.exists() else None


def split_of(path: Path):
    parts = {p.lower() for p in path.parts}
    return "val" if parts & {"val", "valid", "validation"} else "test" if "test" in parts else "train"


def prep_annopage(zip_path: Path, data: Path, out: Path, log):
    tree = data / "annopage"
    if not (tree / ".unzipped").exists():
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(tree)
        (tree / ".unzipped").touch()
    cmap = anno_class_map(find_names(tree))
    pos, neg, unpaired = [], [], 0
    for im in sorted(p for p in tree.rglob("*") if p.suffix.lower() in IMG):
        lab = label_for(im)
        if lab is None:
            unpaired += 1
            continue
        rows = []
        for line in lab.read_text().split("\n"):
            f = line.split()
            if len(f) == 5 and int(f[0]) in cmap:
                rows.append(" ".join([str(cmap[int(f[0])])] + f[1:]))
        (pos if rows else neg).append((im, rows))
    if not pos:
        raise SystemExit(f"AnnoPage: no page carries a target class ({unpaired} images without a label file)")
    rng = random.Random(SEED)
    rng.shuffle(neg)
    keep = pos + neg[:len(pos)]
    has_val = any(split_of(im) != "train" for im, _ in keep)
    for k, (im, rows) in enumerate(keep):
        orig = split_of(im)
        # Without a held-out split of its own, every tenth page (after the seeded shuffle of the negatives) is
        # validation, so best.pt is not chosen on SignverOD's classes alone.
        val = orig in ("val", "test") if has_val else k % 10 == 0
        put(out, "val" if val else "train", f"anno-{orig}-{im.stem}", im, rows)
    log["annopage"] = dict(classes=len(cmap), unpaired_images=unpaired, positive_pages=len(pos),
                           negative_pages_kept=min(len(neg), len(pos)),
                           negative_pages_seen=len(neg),
                           boxes={NAMES[c]: sum(r.startswith(f"{c} ") for _, rs in pos for r in rs) for c in (0, 1)})


def prep_signver(parquets, out: Path, log):
    import io
    import pyarrow.parquet as pq
    from PIL import Image
    rows_all = []
    for p in sorted(parquets):
        rows_all += pq.read_table(p, columns=["image", "width", "height", "objects", "image_id"]).to_pylist()
    rng = random.Random(SEED)
    ids = sorted(r["image_id"] for r in rows_all)
    val = set(rng.sample(ids, len(ids) // 10))
    counts = {}
    for r in rows_all:
        w, h = r["width"], r["height"]
        lines = []
        for (x, y, bw, bh), c in zip(r["objects"]["bbox"], r["objects"]["category"]):
            if c not in SIGNVER or bw <= 0 or bh <= 0:
                continue
            x0, y0, x1, y1 = max(0, x), max(0, y), min(w, x + bw), min(h, y + bh)
            if x1 <= x0 or y1 <= y0:
                continue
            k = SIGNVER[c]
            counts[NAMES[k]] = counts.get(NAMES[k], 0) + 1
            lines.append(f"{k} {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {(x1 - x0) / w:.6f} {(y1 - y0) / h:.6f}")
        sp = "val" if r["image_id"] in val else "train"
        dest = out / "images" / sp / f"signver-{r['image_id']}.jpg"
        dest.parent.mkdir(parents=True, exist_ok=True)
        Image.open(io.BytesIO(r["image"]["bytes"])).convert("RGB").save(dest, quality=92)
        lab = out / "labels" / sp / f"signver-{r['image_id']}.txt"
        lab.parent.mkdir(parents=True, exist_ok=True)
        lab.write_text("\n".join(lines) + ("\n" if lines else ""))
    log["signverod"] = dict(images=len(rows_all), val=len(val), boxes=counts)


def put(out, sp, stem, im, rows):
    d = out / "images" / sp / (stem + im.suffix.lower())
    d.parent.mkdir(parents=True, exist_ok=True)
    if not d.exists():
        d.symlink_to(im.resolve())
    lab = out / "labels" / sp / (stem + ".txt")
    lab.parent.mkdir(parents=True, exist_ok=True)
    lab.write_text("\n".join(rows) + ("\n" if rows else ""))


def prep(root: Path, data: Path):
    out = data / "yolo"
    if (out / "data.yaml").exists():
        print(f"dataset already built: {out}")
        return
    log = {}
    zips = sorted(data.glob("AnnoPage*.zip"))
    parquets = sorted((data / "signverod").rglob("*.parquet"))
    if len(zips) != 1 or not parquets:
        raise SystemExit(f"expected one AnnoPage zip and the SignverOD parquets under {data}")
    prep_annopage(zips[0], data, out, log)
    prep_signver(parquets, out, log)
    for sp in ("train", "val"):
        log[f"{sp}_images"] = len(list((out / "images" / sp).iterdir()))
    (out / "data.yaml").write_text(json.dumps(dict(path=str(out), train="images/train", val="images/val",
                                                   names=NAMES)))
    (root / "out").mkdir(exist_ok=True)
    (root / "out" / "dataset.json").write_text(json.dumps(log, indent=1))
    print(json.dumps(log))


def train(root: Path, data: Path, epochs: int, hours: float, name: str, weights: str):
    from ultralytics import YOLO
    model = YOLO(weights)
    model.train(data=str(data / "yolo" / "data.yaml"), epochs=epochs, time=hours, imgsz=1024, batch=16,
                seed=SEED, deterministic=False, workers=8, project=str(root / "runs"), name=name, exist_ok=True,
                plots=False)


def predict(root: Path, name: str):
    from ultralytics import YOLO
    model = YOLO(str(root / "runs" / name / "weights" / "best.pt"))
    pages = json.loads((root / "eval" / "pages.json").read_text())
    out = {}
    for pid in pages:
        r = model.predict(str(root / "eval" / "images" / f"{pid}.jpg"), imgsz=1024, conf=0.05, verbose=False)[0]
        out[pid] = [dict(box=[round(float(v), 5) for v in b], cls=NAMES[int(c)], conf=round(float(s), 4))
                    for b, c, s in zip(r.boxes.xyxyn.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist())]
    res = root / "out"
    res.mkdir(exist_ok=True)
    (res / f"{name}.json").write_text(json.dumps(dict(model=f"YOLO11m {name}", imgsz=1024, conf_floor=0.05,
                                                      pages=out)))
    print(f"{name}: {sum(map(len, out.values()))} boxes on {len(out)} pages")


def check(root: Path):
    """Mac dry run: the pack has the evaluation images its page list names, with the recorded hashes."""
    pages = json.loads((root / "eval" / "pages.json").read_text())
    freeze = json.loads((root / "freeze.json").read_text())
    if set(pages) != set(freeze["images"]):
        raise SystemExit("pages.json and freeze.json disagree")
    for pid in pages:
        f = root / "eval" / "images" / f"{pid}.jpg"
        if hashlib.sha256(f.read_bytes()).hexdigest() != freeze["images"][pid]:
            raise SystemExit(f"{f}: hash differs from freeze.json")
    for s in ("marks_detect_cluster.py", "setup-job.sh", "job.sh", "submit.sh"):
        if not (root / s).exists():
            raise SystemExit(f"missing {s}")
    print(f"pack ok: {len(pages)} evaluation pages, scripts present")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["check", "prep", "train", "predict"])
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--data", type=Path)
    p.add_argument("--epochs", type=int, default=80)
    p.add_argument("--hours", type=float, default=6.0)
    p.add_argument("--name", default="public")
    p.add_argument("--weights", default="yolo11m.pt")
    a = p.parse_args(argv)
    if a.cmd == "check":
        check(a.root)
    elif a.cmd == "prep":
        prep(a.root, a.data)
    elif a.cmd == "train":
        train(a.root, a.data, a.epochs, a.hours, a.name, a.weights)
    else:
        predict(a.root, a.name)


if __name__ == "__main__":
    sys.exit(main())
