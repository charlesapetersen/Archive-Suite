#!/usr/bin/env python3
"""W46.marks-detect-own: build the Colab/cluster YOLO11m fine-tuning pack from the 110 non-core marks-set pages.

  python3 marks_detect_own_pack.py build [--out ARTIFACT_DIR] [--iou 0.3]

Reads ONLY cached JSON replies and images on the Mac (no network, $0, never prints mark text):
  - Two drafters' replies on the 150-page marks set (Gemini 3.7 Flash + Qwen3-VL 8B MLX)
  - 110 non-core page images from marks-scan-20261029/images/ (strictly disjoint from the 40 owner-core pages)
  - 32 held-out owner-core evaluation images + freeze.json + public YOLO11m base weights (`best.pt`) from
    marks-detect-20261104/

Labeling rule (high-precision box-matched agreement):
  - Greedy 1-to-1 IoU matching (threshold default 0.30, verified 22/23 = 95.7% precision on owner-core truth).
  - For each matched pair, emit the mean box [x0, y0, x1, y1] mapped into YOLO11m's 6 public class slots
    (annotation/marginal_note/other -> 0 handwritten, stamp -> 1 stamp, signature_initials -> 2 signature,
    redaction -> 4 redaction; class priority when drafters disagree on class takes Gemini's class).
  - Keep positive pages (>=1 agreed box) AND clean negative pages (both drafters emitted 0 marks).
  - Exclude unagreed-only pages (one drafter saw a mark, the other did not) and missing-draft pages so YOLO
    is never trained with false-negative background labels on real single-drafter marks.
  - Stratified 85/15 train/val split (deterministic seed 46) across positive and clean-negative pages.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEGBENCH = HERE.parent
if str(SEGBENCH) not in sys.path:
    sys.path.insert(0, str(SEGBENCH))
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import marks_detect_own_cluster as MC  # noqa: E402

DEFAULT_ARTIFACTS = Path.home() / ".local" / "state" / "archive-autonomous" / "artifacts"
DEFAULT_OUT = DEFAULT_ARTIFACTS / "marks-detect-own-20261127"
DEFAULT_PUBLIC_PACK = DEFAULT_ARTIFACTS / "marks-detect-20261104"
DEFAULT_SCAN = DEFAULT_ARTIFACTS / "marks-scan-20261029"
DEFAULT_MARKS_SET = Path.home() / "Library" / "Caches" / "ArchiveSuiteRehearsal" / "marks-set"
SEED = 46

# Map marks_set 6 classes into public YOLO11m's 6 slots:
#   0 handwritten, 1 stamp, 2 signature, 3 initials, 4 redaction, 5 date
CLASS_TO_YOLO = {
    "annotation": 0,
    "marginal_note": 0,
    "other": 0,
    "stamp": 1,
    "signature_initials": 2,
    "redaction": 4,
}


def iou(a: list[float], b: list[float]) -> float:
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def match_agreed_marks(marks_a: list[dict], marks_b: list[dict], thr: float = 0.30) -> list[dict]:
    """Greedy 1-to-1 IoU matching between two drafters' mark lists; returns agreed YOLO boxes."""
    pairs = sorted(
        ((iou(a["box"], b["box"]), i, j) for i, a in enumerate(marks_a) for j, b in enumerate(marks_b)),
        reverse=True,
    )
    used_a: set[int] = set()
    used_b: set[int] = set()
    agreed: list[dict] = []
    for score, i, j in pairs:
        if score < thr:
            break
        if i in used_a or j in used_b:
            continue
        used_a.add(i)
        used_b.add(j)
        ba, bb = marks_a[i]["box"], marks_b[j]["box"]
        box = [round((ba[k] + bb[k]) / 2.0, 6) for k in range(4)]
        cls_name = marks_a[i]["cls"]
        agreed.append({
            "box": box,
            "cls_a": cls_name,
            "cls_b": marks_b[j]["cls"],
            "yolo_cls": CLASS_TO_YOLO.get(cls_name, 0),
            "iou": round(score, 4),
        })
    return agreed


def to_yolo_line(mark: dict) -> str:
    x0, y0, x1, y1 = mark["box"]
    cx = (x0 + x1) / 2.0
    cy = (y0 + y1) / 2.0
    w = max(1e-6, x1 - x0)
    h = max(1e-6, y1 - y0)
    return f"{mark['yolo_cls']} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}"


def audit_core_misses(core_truth: dict, gemini_by_id: dict, qwen_by_id: dict, thr: float = 0.30) -> dict:
    """Measure how many owner-core truth marks BOTH drafters missed, and agreed-box precision on core."""
    total_truth = 0
    both_missed_10 = 0
    both_missed_30 = 0
    agree_total = 0
    agree_hit_10 = 0
    for pid, rec in sorted(core_truth.items()):
        gm = gemini_by_id.get(pid) or []
        qm = qwen_by_id.get(pid) or []
        gboxes = [m["box"] for m in gm]
        qboxes = [m["box"] for m in qm]
        for mk in rec["marks"]:
            total_truth += 1
            gb = max((iou(mk["box"], b) for b in gboxes), default=0.0)
            qb = max((iou(mk["box"], b) for b in qboxes), default=0.0)
            if gb < 0.1 and qb < 0.1:
                both_missed_10 += 1
            if gb < 0.3 and qb < 0.3:
                both_missed_30 += 1
        for ag in match_agreed_marks(gm, qm, thr=thr):
            agree_total += 1
            if any(iou(ag["box"], mk["box"]) >= 0.1 for mk in rec["marks"]):
                agree_hit_10 += 1
    return {
        "eval_pages": len(core_truth),
        "truth_marks": total_truth,
        "both_drafters_missed_iou10": both_missed_10,
        "both_drafters_missed_iou30": both_missed_30,
        "agreed_boxes_on_core": agree_total,
        "agreed_boxes_hitting_truth_iou10": agree_hit_10,
        "agreed_precision_on_core": round(agree_hit_10 / agree_total, 4) if agree_total else None,
    }


def split_stratified(pos_ids: list[str], neg_ids: list[str], val_frac: float = 0.15, seed: int = SEED) -> tuple[set[str], set[str]]:
    rng = random.Random(seed)
    p = sorted(pos_ids)
    n = sorted(neg_ids)
    rng.shuffle(p)
    rng.shuffle(n)
    nv_p = max(1, round(len(p) * val_frac)) if len(p) > 1 else 0
    nv_n = max(1, round(len(n) * val_frac)) if len(n) > 1 else 0
    val = set(p[:nv_p] + n[:nv_n])
    train = set(p[nv_p:] + n[nv_n:])
    return train, val


def build_pack(out_dir: Path, marks_set_dir: Path, scan_dir: Path, public_pack_dir: Path,
               iou_thr: float = 0.30, val_frac: float = 0.15, force: bool = False,
               core_truth: dict | None = None) -> dict:
    import marks_set as M  # noqa: E402

    if out_dir.exists():
        if not force:
            raise SystemExit(f"pack already exists at {out_dir} (pass --force to rebuild)")
        shutil.rmtree(out_dir)

    sel = json.loads((marks_set_dir / "selection.json").read_text(encoding="utf-8"))
    non_core = [r for r in sel["rows"] if not r.get("core")]
    core_ids = {r["id"] for r in sel["rows"] if r.get("core")}

    def _read_draft(path: Path, route: str):
        if not path.is_file():
            return None
        rec = json.loads(path.read_text(encoding="utf-8"))
        d, _ = M.parse(rec.get("raw"), route)
        return d["marks"] if d is not None else None

    gemini_all = {}
    qwen_all = {}
    for r in sel["rows"]:
        pid = r["id"]
        gemini_all[pid] = _read_draft(marks_set_dir / "gemini" / "replies" / f"{pid}.json", "gemini")
        qwen_all[pid] = _read_draft(marks_set_dir / "qwen3-vl-8b-mlx4" / f"{pid}.json", "local")

    # Core drafter-miss audit
    if core_truth is None:
        import marks_detect as D
        core_truth = D.truth() if (D.RECORD / "reconciled.json").is_file() else {}
    core_audit = audit_core_misses(core_truth, gemini_all, qwen_all, thr=iou_thr) if core_truth else {}

    # Build agreed labels on the 110 non-core pages
    pos_pages: dict[str, list[dict]] = {}
    neg_pages: list[str] = []
    skipped_unagreed: list[str] = []
    skipped_missing_draft: list[str] = []
    cls_counts = collections.Counter()

    for r in non_core:
        pid = r["id"]
        assert pid not in core_ids
        gm = gemini_all.get(pid)
        qm = qwen_all.get(pid)
        if gm is None or qm is None:
            skipped_missing_draft.append(pid)
            continue
        agreed = match_agreed_marks(gm, qm, thr=iou_thr)
        if agreed:
            pos_pages[pid] = agreed
            for mk in agreed:
                cls_counts[MC.NAMES[mk["yolo_cls"]]] += 1
        elif not gm and not qm:
            neg_pages.append(pid)
        else:
            skipped_unagreed.append(pid)

    train_ids, val_ids = split_stratified(list(pos_pages.keys()), neg_pages, val_frac=val_frac, seed=SEED)

    # Assemble pack directory
    out_dir.mkdir(parents=True, exist_ok=True)
    ds_dir = out_dir / "dataset"
    for sp in ("train", "val"):
        (ds_dir / "images" / sp).mkdir(parents=True, exist_ok=True)
        (ds_dir / "labels" / sp).mkdir(parents=True, exist_ok=True)

    scan_images = scan_dir / "images"
    for sp, id_set in (("train", train_ids), ("val", val_ids)):
        for pid in sorted(id_set):
            src_img = scan_images / f"{pid}.jpg"
            if not src_img.is_file():
                raise SystemExit(f"missing non-core image: {src_img}")
            shutil.copy2(src_img, ds_dir / "images" / sp / f"{pid}.jpg")
            lines = [to_yolo_line(mk) for mk in pos_pages.get(pid, [])]
            (ds_dir / "labels" / sp / f"{pid}.txt").write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")

    # Copy base public YOLO11m weights + held-out 32 eval pages + freeze.json
    base_weights_src = public_pack_dir / "runs" / "public" / "best.pt"
    if not base_weights_src.is_file():
        raise SystemExit(f"missing public base weights: {base_weights_src}")
    (out_dir / "base_weights").mkdir(parents=True, exist_ok=True)
    base_weights_dst = out_dir / "base_weights" / "best.pt"
    shutil.copy2(base_weights_src, base_weights_dst)

    shutil.copytree(public_pack_dir / "eval", out_dir / "eval")
    shutil.copy2(public_pack_dir / "freeze.json", out_dir / "freeze.json")
    shutil.copy2(HERE / "marks_detect_own_cluster.py", out_dir / "marks_detect_own_cluster.py")

    ds_meta = {
        "protocol": "marks-detect-own-v1",
        "seed": SEED,
        "iou_threshold": iou_thr,
        "non_core_total": len(non_core),
        "positive_pages": len(pos_pages),
        "clean_negative_pages": len(neg_pages),
        "skipped_unagreed_only": len(skipped_unagreed),
        "skipped_missing_draft": len(skipped_missing_draft),
        "train_images": len(train_ids),
        "val_images": len(val_ids),
        "agreed_boxes_total": sum(len(v) for v in pos_pages.values()),
        "agreed_boxes_by_yolo_class": dict(sorted(cls_counts.items())),
        "base_weights_source": str(base_weights_src),
        "base_weights_sha256": MC.sha256_file(base_weights_dst),
        "core_audit": core_audit,
    }
    (ds_dir / "dataset.json").write_text(json.dumps(ds_meta, indent=1) + "\n", encoding="utf-8")
    (ds_dir / "data.yaml").write_text(
        json.dumps({"path": ".", "train": "images/train", "val": "images/val", "names": MC.NAMES}, indent=1) + "\n",
        encoding="utf-8",
    )
    (out_dir / "pack-type.json").write_text(
        json.dumps({
            "pack_type": "yolo-marks",
            "item_tag": "W46.marks-detect-own",
            "script": "marks_detect_own_cluster.py",
            "pilot_epochs": 1,
            "train_epochs": 40,
            "lr0": 0.001,
            "batch": 16,
            "imgsz": 1024,
            "run_name": "own",
        }, indent=2) + "\n",
        encoding="utf-8",
    )
    # Run the pack's own integrity check immediately
    MC.check(out_dir)
    return ds_meta


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_b = sub.add_parser("build")
    p_b.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p_b.add_argument("--marks-set", type=Path, default=DEFAULT_MARKS_SET)
    p_b.add_argument("--scan", type=Path, default=DEFAULT_SCAN)
    p_b.add_argument("--public-pack", type=Path, default=DEFAULT_PUBLIC_PACK)
    p_b.add_argument("--iou", type=float, default=0.30)
    p_b.add_argument("--val-frac", type=float, default=0.15)
    p_b.add_argument("--force", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        meta = build_pack(a.out, a.marks_set, a.scan, a.public_pack,
                          iou_thr=a.iou, val_frac=a.val_frac, force=a.force)
        print(json.dumps(meta, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
