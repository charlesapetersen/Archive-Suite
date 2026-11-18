"""W46.licence-freed-sweep: pilots of models first left out on their licence alone (owner call 12, 2026-11-17).

Each subcommand is one screen, on the inputs an earlier item already scored, so only the new arm is new:

    PY=$(torch-env.sh)    # torch-env.sh add rapidfuzz scikit-learn
    python3 ops/autonomous/heavy-run.py run -- $PY licence_sweep.py layoutreader

``layoutreader`` — LayoutReader (hantian/layoutreader, LayoutLMv3-large fine-tuned on ReadingBank, CC BY-NC-SA 4.0)
as one more orderer in ``layout_order.py``'s three panels (benchmark lines, benchmark regions, L9 newspapers), every
other orderer rerun beside it on the same boxes. Boxes go in top to bottom, scaled to 0-1000 by the page size, as
MinerU feeds it; a page with more than 510 boxes keeps the top-to-bottom order and is counted. CPU, a few seconds a
page. Full figures go to the cache; ``segbench-results/licence-sweep-layoutreader.json`` keeps the summaries.
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


if __name__ == "__main__":
    cmds = {"layoutreader": layoutreader}
    if len(sys.argv) == 2 and sys.argv[1] in cmds:
        sys.exit(cmds[sys.argv[1]]())
    print(__doc__)
    sys.exit(2)
