#!/usr/bin/env python3
"""W46.marks-detect-own cluster/Colab runner: fine-tune public YOLO11m on our own 110 non-core marks pages.

  python3 marks_detect_own_cluster.py check   --pack PACK
  python3 marks_detect_own_cluster.py train   --pack PACK --out RES_DIR --epochs 40 --name own [--lr0 0.001]
  python3 marks_detect_own_cluster.py predict --pack PACK --out RES_DIR --name own

Preserves the exact 6-class slot layout of W46.marks-detect's public YOLO11m (`best.pt`), so fine-tuning
keeps the pretrained detection head intact while adapting to our own archival marks. Evaluation runs strictly
on the 32 held-out owner-core pages (`eval/images/`), verified by SHA-256 against `freeze.json`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

NAMES = ["handwritten", "stamp", "signature", "initials", "redaction", "date"]
SEED = 46


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check(pack: Path) -> dict:
    """Verify pack integrity: freeze hashes on eval pages, dataset split files, and base weights."""
    eval_pages = json.loads((pack / "eval" / "pages.json").read_text(encoding="utf-8"))
    freeze = json.loads((pack / "freeze.json").read_text(encoding="utf-8"))
    if set(eval_pages) != set(freeze["images"]):
        raise SystemExit("eval/pages.json and freeze.json disagree")
    for pid in eval_pages:
        img = pack / "eval" / "images" / f"{pid}.jpg"
        if not img.is_file():
            raise SystemExit(f"missing eval image: {img}")
        if sha256_file(img) != freeze["images"][pid]:
            raise SystemExit(f"hash mismatch on eval image: {img}")

    ds_meta = json.loads((pack / "dataset" / "dataset.json").read_text(encoding="utf-8"))
    train_imgs = sorted((pack / "dataset" / "images" / "train").glob("*.jpg"))
    val_imgs = sorted((pack / "dataset" / "images" / "val").glob("*.jpg"))
    train_ids = {p.stem for p in train_imgs}
    val_ids = {p.stem for p in val_imgs}
    eval_set = set(eval_pages)
    if (train_ids | val_ids) & eval_set:
        raise SystemExit(f"leakage: eval pages inside training dataset: {(train_ids | val_ids) & eval_set}")
    if train_ids & val_ids:
        raise SystemExit(f"overlap between train and val splits: {train_ids & val_ids}")
    for p in train_imgs + val_imgs:
        split = p.parent.name
        lab = pack / "dataset" / "labels" / split / f"{p.stem}.txt"
        if not lab.is_file():
            raise SystemExit(f"missing label file: {lab}")

    weights = pack / "base_weights" / "best.pt"
    if not weights.is_file():
        raise SystemExit(f"missing base weights: {weights}")
    if ds_meta.get("base_weights_sha256") and sha256_file(weights) != ds_meta["base_weights_sha256"]:
        raise SystemExit("base_weights/best.pt sha256 mismatch")

    summary = {
        "eval_pages": len(eval_pages),
        "train_images": len(train_imgs),
        "val_images": len(val_imgs),
        "base_weights_mb": round(weights.stat().st_size / (1024 * 1024), 2),
    }
    print("pack check ok:", json.dumps(summary), flush=True)
    return summary


def write_runtime_yaml(pack: Path, work_dir: Path) -> Path:
    """Write a runtime data.yaml pointing to the actual mounted dataset directory."""
    ds_dir = (pack / "dataset").resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    yaml_path = work_dir / "data.yaml"
    yaml_path.write_text(
        json.dumps({"path": str(ds_dir), "train": "images/train", "val": "images/val", "names": NAMES}, indent=1) + "\n",
        encoding="utf-8",
    )
    return yaml_path


def train(pack: Path, out: Path, epochs: int, name: str, lr0: float, batch: int, imgsz: int, hours: float) -> Path:
    from ultralytics import YOLO

    check(pack)
    out.mkdir(parents=True, exist_ok=True)
    yaml_path = write_runtime_yaml(pack, out / "runtime")
    weights = pack / "base_weights" / "best.pt"
    model = YOLO(str(weights))
    model.train(
        data=str(yaml_path),
        epochs=epochs,
        time=hours,
        imgsz=imgsz,
        batch=batch,
        lr0=lr0,
        lrf=0.05,
        warmup_epochs=2.0,
        patience=15,
        seed=SEED,
        deterministic=False,
        workers=4,
        project=str(out / "runs"),
        name=name,
        exist_ok=True,
        plots=False,
    )
    best = out / "runs" / name / "weights" / "best.pt"
    if not best.is_file():
        best = out / "runs" / name / "weights" / "last.pt"
    return best


def predict(pack: Path, out: Path, name: str, imgsz: int = 1024) -> Path:
    from ultralytics import YOLO

    weights = out / "runs" / name / "weights" / "best.pt"
    if not weights.is_file():
        weights = out / "runs" / name / "weights" / "last.pt"
    if not weights.is_file():
        raise SystemExit(f"trained weights not found under {out / 'runs' / name / 'weights'}")
    model = YOLO(str(weights))
    pages = json.loads((pack / "eval" / "pages.json").read_text(encoding="utf-8"))
    preds = {}
    for pid in pages:
        r = model.predict(str(pack / "eval" / "images" / f"{pid}.jpg"), imgsz=imgsz, conf=0.05, verbose=False)[0]
        preds[pid] = [
            {"box": [round(float(v), 5) for v in b], "cls": NAMES[int(c)], "conf": round(float(s), 4)}
            for b, c, s in zip(r.boxes.xyxyn.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist())
        ]
    res_dir = out / "out"
    res_dir.mkdir(parents=True, exist_ok=True)
    target = res_dir / f"{name}.json"
    target.write_text(
        json.dumps({"model": f"YOLO11m {name} (fine-tuned from public best.pt)", "imgsz": imgsz,
                    "conf_floor": 0.05, "pages": preds}, indent=1) + "\n",
        encoding="utf-8",
    )
    status = {
        "state": "done",
        "name": name,
        "eval_pages": len(preds),
        "total_boxes": sum(len(v) for v in preds.values()),
        "weights": str(weights.relative_to(out)),
    }
    (res_dir / f"{name}-status.json").write_text(json.dumps(status, indent=1) + "\n", encoding="utf-8")
    print(f"{name}: {status['total_boxes']} boxes on {len(preds)} eval pages -> {target}", flush=True)
    return target


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "train", "predict"])
    ap.add_argument("--pack", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--name", default="own")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--hours", type=float, default=2.0)
    ap.add_argument("--lr0", type=float, default=0.001)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--imgsz", type=int, default=1024)
    a = ap.parse_args(argv)
    if a.cmd == "check":
        check(a.pack)
    elif a.cmd == "train":
        if a.out is None:
            raise SystemExit("--out is required for train")
        train(a.pack, a.out, a.epochs, a.name, a.lr0, a.batch, a.imgsz, a.hours)
    else:
        if a.out is None:
            raise SystemExit("--out is required for predict")
        predict(a.pack, a.out, a.name, a.imgsz)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
