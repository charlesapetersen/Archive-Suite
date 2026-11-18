"""W46.licence-freed-sweep: pilots of models first left out on their licence alone (owner call 12, 2026-11-17).

Each subcommand is one screen, on the inputs an earlier item already scored, so only the new arm is new:

    PY=$(torch-env.sh)    # torch-env.sh add rapidfuzz scikit-learn
    python3 ops/autonomous/heavy-run.py run -- $PY licence_sweep.py layoutreader

``layoutreader`` — LayoutReader (hantian/layoutreader, LayoutLMv3-large fine-tuned on ReadingBank, CC BY-NC-SA 4.0)
as one more orderer in ``layout_order.py``'s three panels (benchmark lines, benchmark regions, L9 newspapers), every
other orderer rerun beside it on the same boxes. Boxes go in top to bottom, scaled to 0-1000 by the page size, as
MinerU feeds it; a page with more than 510 boxes keeps the top-to-bottom order and is counted. CPU, a few seconds a
page. Full figures go to the cache; ``segbench-results/licence-sweep-layoutreader.json`` keeps the summaries.

``hunyuan-prep`` — the HunyuanOCR-1.5 folder ``ocr_mac_local.py``'s ``hunyuanocr-1.5-bf16`` loads (see there).
The readers then run on the 96 through ``ocr_mac_local.py collect --model KEY --limit N`` (FastVLM from this item's
own venv, ``licence-freed-sweep/venv-fastvlm``: mlx 0.32.3 and mlx-vlm 0.7.4 as the lab's, plus torch and timm, which
its processor code imports).
"""
from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
CACHE = Path(os.environ.get("ARCHIVE_SEGBENCH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal"))
WORK = CACHE / "licence-freed-sweep"
RES = HERE.parent.parent / "segbench-results"
os.environ.setdefault("HF_HOME", str(WORK / "hf"))

LR_REPO, LR_REV = "hantian/layoutreader", "629be376d86fbab624ddc4020804a4e93b5515bc"
MAX_LEN = 510
_lr = {}
overflow = []


def _layoutreader():
    if not _lr:
        import torch
        from huggingface_hub import snapshot_download
        from transformers import LayoutLMv3ForTokenClassification
        path = snapshot_download(LR_REPO, revision=LR_REV)
        m = LayoutLMv3ForTokenClassification.from_pretrained(path).eval()
        _lr.update(model=m, torch=torch)
    return _lr["model"], _lr["torch"]


def parse_logits(logits, length: int) -> list[int]:
    """The authors' v3/helpers.parse_logits, ties broken by the higher logit; the indices of the boxes in reading
    order."""
    logits = logits[1:length + 1, :length]
    orders = logits.argsort(descending=False).tolist()
    ret = [o.pop() for o in orders]
    while True:
        clash = defaultdict(list)
        for idx, order in enumerate(ret):
            clash[order].append(idx)
        clash = {k: v for k, v in clash.items() if len(v) > 1}
        if not clash:
            return ret
        for order, idxes in clash.items():
            ranked = sorted(idxes, key=lambda i: float(logits[i, order]), reverse=True)
            for i in ranked[1:]:
                ret[i] = orders[i].pop()


def order_layoutreader(boxes, width=None, height=None, **_):
    import layout_order as lo
    given = lo.order_topbottom(boxes)
    if not boxes:
        return []
    if len(boxes) > MAX_LEN:
        overflow.append(len(boxes))
        return given
    w = width or max(b[2] for b in boxes)
    h = height or max(b[3] for b in boxes)
    def s(v, d):
        return max(0, min(1000, round(v / d * 1000)))
    norm = [[s(boxes[i][0], w), s(boxes[i][1], h), s(boxes[i][2], w), s(boxes[i][3], h)] for i in given]
    norm = [[l, t, max(r, l), max(b, t)] for l, t, r, b in norm]
    model, torch = _layoutreader()
    n = len(norm)
    inputs = {"bbox": torch.tensor([[[0, 0, 0, 0]] + norm + [[0, 0, 0, 0]]]),
              "input_ids": torch.tensor([[0] + [3] * n + [2]]),
              "attention_mask": torch.ones(1, n + 2, dtype=torch.long)}
    with torch.no_grad():
        logits = model(**inputs).logits.cpu().squeeze(0)
    # MinerU reads the result as the reading sequence (``[boxes[i] for i in orders]``); a two-column synthetic page
    # confirms it: read the other way it interleaves the columns.
    return [given[i] for i in parse_logits(logits, n)]


def layoutreader() -> int:
    import layout_order as lo
    base = lo.all_orders

    def all_orders(pages):
        res = base(pages)
        res["layoutreader"] = [order_layoutreader(b, width=w, height=h) for b, w, h in pages]
        return res

    lo.all_orders = all_orders
    full = WORK / "layoutreader-full.json"
    full.parent.mkdir(parents=True, exist_ok=True)
    lo.OUT = full
    rc = lo.run()
    res = json.loads(full.read_text())
    out = {"item": "W46.licence-freed-sweep", "stage": "reading order", "model": f"{LR_REPO}@{LR_REV[:8]}",
           "licence": "CC BY-NC-SA 4.0", "sources": res["sources"], "guard": res["guard"],
           "overflow_pages": overflow,
           **{k: {"summary": res[k]["summary"]} for k in ("bench_lines", "bench_regions", "l9")},
           "pages": {k: res[k]["pages"] for k in ("bench_lines", "bench_regions", "l9")}}
    (RES / "licence-sweep-layoutreader.json").write_text(json.dumps(out, indent=1) + "\n")
    print("overflow pages:", overflow)
    return rc


HY_REPO, HY_REV = "tencent/HunyuanOCR", "47644ecc4fc854efa4f505155158831f36773ee4"


def hunyuan_prep() -> int:
    """HunyuanOCR-1.5 for mlx-vlm 0.7.4, whose hunyuan_vl reads 1.0's config: a folder of links to the snapshot in
    the shared model cache, with only config.json rewritten (vision_config.model_type back to ``hunyuan_vl``)."""
    import model_store
    src = model_store.snapshot(HY_REPO, HY_REV)
    dst = WORK / "hunyuanocr-1.5-patched"
    dst.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if f.name != "config.json" and not (dst / f.name).exists():
            (dst / f.name).symlink_to(f.resolve())
    cfg = json.loads((src / "config.json").read_text())
    assert cfg["vision_config"]["model_type"] == "hunyuan_vl_vision", cfg["vision_config"]["model_type"]
    cfg["vision_config"]["model_type"] = "hunyuan_vl"
    (dst / "config.json").write_text(json.dumps(cfg, indent=1) + "\n")
    print(dst)
    return 0


NEW_READERS = ["hunyuanocr-1.5-bf16", "fastvlm-0.5b-bf16"]
BASE_READERS = ["apple-vision", "lightonocr-3-4b-mlx8", "paddleocr-vl1.6-bf16", "xiaomi-ocr-0-bf16",
                "qwen3-vl-8b-mlx4", "granite-docling-258m-mlx", "ppocrv6-medium"]


def _boot(diffs, seed=0, n=2000):
    import random
    rnd = random.Random(seed)
    means = sorted(sum(rnd.choice(diffs) for _ in diffs) / len(diffs) for _ in range(n))
    return round(sum(diffs) / len(diffs), 4), round(means[int(n * .025)], 4), round(means[int(n * .975) - 1], 4)


def readers() -> int:
    """The new Mac readers on the pages they read so far, strict NES (a failure scores 0), each paired against the
    96's incumbents from ocr-scorers-pages.csv. Scored with ocr_mac_local.hw_pairs, the scorer the W41 Mac rows used;
    the LightOnOCR 8-bit row rescored the same way is checked against its row in the CSV first."""
    import csv
    import ocr_mac_local as M
    csvrows = [r for r in csv.DictReader(open(RES / "ocr-scorers-pages.csv")) if r["set"] == "owner96"]
    base = {(r["route"], r["page"]): float(r["nes"]) for r in csvrows}
    check = [abs(p["local"]["nes"] - base[("lightonocr-3-4b-mlx8", p["page"])]) for p in M.hw_pairs("lightonocr-3-4b-mlx8")]
    out = {"item": "W46.licence-freed-sweep", "set": "owner96 (the 96 accuracy pages)", "metric": "strict NES",
           "scorer_check": {"route": "lightonocr-3-4b-mlx8", "pages": len(check), "max_abs_diff": round(max(check), 6)},
           "readers": {}}
    print("scorer check, LightOnOCR 8-bit rescored against the CSV: max |diff|", out["scorer_check"]["max_abs_diff"])
    for key in NEW_READERS:
        rows = [p for p in M.hw_pairs(key) if p["local_attempted"]]
        if not rows:
            continue
        metas = [p["local_meta"] for p in rows]
        cell = {"name": M.HW[key]["name"], "pages": len(rows), "failed": sum(not p["local"]["ok"] for p in rows),
                "nes": round(sum(p["local"]["nes"] if p["local"]["ok"] else 0.0 for p in rows) / len(rows), 4),
                "wall_s_median": sorted(m["wall_s"] for m in metas)[len(metas) // 2],
                "mlx_peak_gb_max": max(m["mlx_peak_gb"] for m in metas),
                "by_kind": {}, "against": {}}
        for kind in sorted({p["kind"] for p in rows}):
            ks = [p for p in rows if p["kind"] == kind]
            cell["by_kind"][kind] = {"pages": len(ks), "nes": round(sum(p["local"]["nes"] if p["local"]["ok"] else 0.0
                                                                          for p in ks) / len(ks), 4)}
        for b in BASE_READERS:
            pairs = [(p["local"]["nes"] if p["local"]["ok"] else 0.0, base[(b, p["page"])]) for p in rows
                     if (b, p["page"]) in base]
            if pairs:
                mean, lo, hi = _boot([a - c for a, c in pairs])
                cell["against"][b] = {"pages": len(pairs), "base_nes": round(sum(c for _, c in pairs) / len(pairs), 4),
                                      "diff": mean, "lo": lo, "hi": hi}
        out["readers"][key] = cell
        print(f"\n{key}: {cell['pages']} pages, {cell['failed']} failed, strict NES {cell['nes']:.4f}, "
              f"median {cell['wall_s_median']} s a page, peak {cell['mlx_peak_gb_max']} GB")
        for b, c in cell["against"].items():
            print(f"  vs {b:<26} {c['base_nes']:.4f}  diff {c['diff']:+.4f} ({c['lo']:+.4f} to {c['hi']:+.4f})")
    (RES / "licence-sweep-readers.json").write_text(json.dumps(out, indent=1) + "\n")
    return 0


BLN = WORK / "bln600"
SEGBENCH_OCR = CACHE / "segbench" / "bin" / "segbench-ocr"


def bln600(n: int = 40, seed: int = 20261118) -> int:
    """BLN600 (Sheffield ORDA 25439023 v2, CC BY-NC-ND 4.0; the zip's published password is ``BLN600``) as test
    material: a seeded sample of n of its 600 excerpts, read by Apple Vision at the app's settings (segbench-ocr) and
    scored against the human transcription with the panel's scorer. GALE's own OCR in the zip is not read."""
    import random
    import subprocess
    import ocr_panel_score as S
    root = BLN / "x"  # the zip is AES-encrypted, which zipfile cannot read: tar -xf BLN600.zip -C x --passphrase BLN600
    images = {p.stem: p for p in (root / "Images").iterdir() if p.is_file()}
    truth = {p.stem: p for p in (root / "Ground Truth").glob("*.txt")}
    ids = sorted(set(images) & set(truth))
    pick = sorted(random.Random(seed).sample(ids, n))
    work = BLN / "pilot"
    work.mkdir(parents=True, exist_ok=True)
    jobs = []
    for i in pick:
        jobs.append(f"{images[i]}\t{work / (i + '.vision.txt')}")
    (work / "jobs.tsv").write_text("\n".join(jobs) + "\n")
    subprocess.run([str(SEGBENCH_OCR), str(work / "jobs.tsv")], check=True)
    rows = []
    for i in pick:
        t = truth[i].read_text(encoding="utf-8", errors="replace")
        r = S.score(t, (work / (i + ".vision.txt")).read_text())
        rows.append({"id": i, "nes": round(r["nes"], 4), "words": r["words"]})
    nes = [r["nes"] for r in rows]
    mean, lo, hi = _boot(nes)
    out = {"item": "W46.licence-freed-sweep", "dataset": "BLN600 v2 (ORDA 25439023), CC BY-NC-ND 4.0",
           "excerpts": len(ids), "sample": n, "seed": seed, "reader": "Apple Vision, app settings (segbench-ocr)",
           "nes_mean": mean, "nes_ci": [lo, hi], "nes_median": sorted(nes)[len(nes) // 2],
           "under_0.9": sum(v < 0.9 for v in nes), "rows": rows}
    (RES / "licence-sweep-bln600.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"BLN600: {len(ids)} excerpts, {n} read; Vision NES {mean:.4f} ({lo:.4f} to {hi:.4f}), "
          f"median {out['nes_median']:.4f}, {out['under_0.9']} under 0.9")
    return 0


SIG_REPO, SIG_REV = "tech4humans/conditional-detr-50-signature-detector", "9582471a22"


def signature() -> int:
    """The named tech4humans YOLOv8s signature detector (AGPL-3.0) is gated: its weights need a logged-in Hugging
    Face account that has accepted the terms. Its ungated sibling from the same authors, a Conditional DETR-50
    trained on the same Tobacco800 + signatures data (Apache-2.0), stands in for it on marks_detect's 32 owner-core
    pages: class-agnostic recall against every mark, as marks-detect scores the YOLO11m arm, at its floors."""
    import torch
    from huggingface_hub import snapshot_download
    from PIL import Image
    from transformers import AutoImageProcessor, AutoModelForObjectDetection
    import marks_detect as M
    root = Path(snapshot_download(SIG_REPO, allow_patterns=["*.json", "*.safetensors"],
                                  ignore_patterns=["eval/*", "train/*"]))
    assert root.name.startswith(SIG_REV), root
    src = root if (root / "model.safetensors").exists() else root / "best_checkpoint"
    proc = AutoImageProcessor.from_pretrained(src)
    model = AutoModelForObjectDetection.from_pretrained(src).eval()
    t = M.truth()
    pages = {}
    for pid in t:
        im = Image.open(M.IMAGES / f"{pid}.jpg").convert("RGB")
        W, H = im.size
        with torch.no_grad():
            out = model(**proc(images=im, return_tensors="pt"))
        res = proc.post_process_object_detection(out, threshold=0.05, target_sizes=[(H, W)])[0]
        pages[pid] = [{"box": [round(float(b[0]) / W, 5), round(float(b[1]) / H, 5), round(float(b[2]) / W, 5),
                               round(float(b[3]) / H, 5)],
                       "cls": model.config.id2label[int(l)], "conf": round(float(c), 4)}
                      for b, l, c in zip(res["boxes"], res["labels"], res["scores"])]
    store = {"model": f"{SIG_REPO}@{SIG_REV}", "licence": "Apache-2.0", "conf_floor": 0.05, "pages": pages}
    (WORK / "signature-detr.json").write_text(json.dumps(store) + "\n")
    res = {"item": "W46.licence-freed-sweep", "model": store["model"], "licence": store["licence"],
           "stands_in_for": "tech4humans/yolov8s-signature-detector (AGPL-3.0, gated)", "pages": len(t),
           "marks": sum(len(p["marks"]) for p in t.values()), "by_floor": {}}
    for conf in (0.05, 0.25, 0.5):
        arm = dict(pages="all")
        sc = M.score(t, M.boxes(pages, conf), arm)
        res["by_floor"][str(conf)] = {"boxes": sum(len(v) for v in M.boxes(pages, conf).values()), **sc}
        a = sc["hit"]["all"]
        print(f"floor {conf}: {res['by_floor'][str(conf)]['boxes']} boxes; loose-hit recall "
              f"{json.dumps(a)[:160]}")
    (RES / "licence-sweep-signature.json").write_text(json.dumps(res, indent=1) + "\n")
    return 0


def gutenocr_lines() -> int:
    """GutenOCR-3B's lines (place_hands.py detect gutenocr; align gutenocr ctc-mccatmus) scored as place_hands_lines
    scores every hypothesis, without rewriting its rows: only the gutenocr hypotheses are dragged here, and each is
    paired page by page with the shipped placer's rows already in lines-rows.jsonl (DEFAULT, blla + McCATMuS conf)."""
    import tempfile
    from concurrent.futures import ThreadPoolExecutor
    import place_hands as PH
    import place_hands_lines as L
    import subprocess
    if not L.FUNCTIONAL.exists():
        subprocess.run(["swiftc", "-O", str(HERE / "place_functional.swift"), "-o", str(L.FUNCTIONAL)], check=True)
    ps = [t for t in PH.pages() if PH.keep(t)]
    tls = {t["page"]: L.truth_lines(t) for t in ps}
    exps = {(t["page"], r): L.expected(t, r, tls[t["page"]]) for t in ps for r in L.READINGS}
    dirs = sorted((L.CACHE / "hyp").glob("gutenocr.*")) + sorted((L.CACHE / "hyp").glob(L.DEFAULT + ".*"))
    jobs = [(t, d) for d in dirs for t in ps
            if (d / f"{PH.key(t)}.json").exists() and exps.get((t["page"], d.name.split(".", 2)[2])) is not None]
    work = Path(tempfile.mkdtemp(prefix="phl-lf-", dir=L.CACHE))
    with ThreadPoolExecutor(int(os.environ.get("PHL_WORKERS", "6"))) as ex:
        new = sum(ex.map(lambda td: L.score_one(td[0], td[1], tls[td[0]["page"]],
                                                exps[(td[0]["page"], td[1].name.split(".", 2)[2])], work), jobs), [])
    work.rmdir()
    # The shipped placer re-dragged with this build of the writer and drag tool must give its stored rows.
    stored = {(r["page"], r["detector"], r["method"], r["reading"], r["writer"]): r["passed"] for r in L.load_rows()}
    replay = [(stored.get((r["page"], r["detector"], r["method"], r["reading"], r["writer"])), r["passed"])
              for r in new if r["detector"] != "gutenocr"]
    same = sum(a == b for a, b in replay)
    print(f"replay of {L.DEFAULT}: {same} of {len(replay)} page rows equal the stored ones")
    new = [r for r in new if r["detector"] == "gutenocr"]
    (WORK / "gutenocr-lines-rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in new))
    rows = [r for r in L.load_rows() if r["detector"] != "gutenocr"] + new
    keep = {L.DEFAULT, "ppocrv6.ctc-mccatmus-conf", "surya.ctc-mccatmus-conf", "orli.ctc-mccatmus-conf"}
    out = {"item": "W46.licence-freed-sweep", "detector": f"{PH.GUTEN[0]}@{PH.GUTEN[1]} (CC BY-NC 4.0), LINES prompt",
           "default": L.DEFAULT, "pairs": "pooled line pass, each route minus the default, page bootstrap",
           "replay": {"rows": len(replay), "equal": same}, "tables": {}}
    for w in L.WRITERS:
        for g in PH.GROUPS:
            for rd in L.READINGS:
                tb = L.table([r for r in rows if r["writer"] == w], g, rd)
                if tb:
                    out["tables"][f"{w}|{g}|{rd}"] = [x for x in tb if x["route"] in keep or x["route"].startswith("gutenocr.")]
    (RES / "licence-sweep-gutenocr.json").write_text(json.dumps(out, indent=1) + "\n")
    for k, tb in out["tables"].items():
        print(k)
        for x in tb:
            d = x["delta"]
            print(f"  {x['route']:<34} {100 * x['passed'] / max(1, x['lines']):5.1f} ({x['passed']}/{x['lines']})"
                  + (f"  {d[0]:+.1f} ({d[1]:+.1f} to {d[2]:+.1f})" if d else ""))
    return 0


def gutenocr_prep() -> int:
    """GutenOCR-3B for mlx-vlm (run from the lab venv): its two bf16 shards hold no lm_head while the config says
    untied; the repo's single-file copy carries one, range-read on 18 Nov and byte-identical to the shards'
    embed_tokens. So a folder that links the shards, copies the small files (writable: the converter rewrites the
    tokenizer) and declares the embeddings tied is exact. bf16 needs 7.5 GB and swapped past run-guarded's limit beside
    other sessions, so mlx-vlm converts it to 8-bit (vision tower left in bf16: 9.8 bits a weight, 4.3 GB)."""
    import shutil
    import subprocess
    import model_store
    import place_hands as PH
    src = model_store.snapshot(*PH.GUTEN)
    tied = WORK / "gutenocr-3b-tied"
    tied.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if f.name == "config.json" or (tied / f.name).exists():
            continue
        if f.suffix == ".safetensors":
            (tied / f.name).symlink_to(f.resolve())
        else:
            shutil.copyfile(f.resolve(), tied / f.name)
    cfg = json.loads((src / "config.json").read_text())
    cfg["tie_word_embeddings"] = True
    cfg.setdefault("text_config", {})["tie_word_embeddings"] = True
    (tied / "config.json").write_text(json.dumps(cfg, indent=1) + "\n")
    if not (PH.GUTEN_MLX / "config.json").exists():
        subprocess.run([sys.executable, "-m", "mlx_vlm", "convert", "--hf-path", str(tied), "--mlx-path",
                        str(PH.GUTEN_MLX), "-q", "--q-bits", "8"], check=True)
    print(PH.GUTEN_MLX)
    return 0


if __name__ == "__main__":
    cmds = {"gutenocr-prep": gutenocr_prep, "gutenocr-lines": gutenocr_lines, "signature": signature, "layoutreader": layoutreader, "hunyuan-prep": hunyuan_prep, "readers": readers, "bln600": bln600}
    if len(sys.argv) == 2 and sys.argv[1] in cmds:
        sys.exit(cmds[sys.argv[1]]())
    print(__doc__)
    sys.exit(2)
