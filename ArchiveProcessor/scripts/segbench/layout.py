"""PP-DocLayoutV3 regions for every bench page, cached (W46.fix-seg-scorers; E-layout test 6).

    <lab venv>/bin/python layout.py owner                 # the five owner boxes (914 pages)
    <lab venv>/bin/python layout.py public --root DIR     # Lincoln and CREST (389 pages)

The detector is mlx-vlm's MLX port of PP-DocLayoutV3 (Apache-2.0) from the Vision OCR lab's converted weights,
``~/.local/share/visionocr-ocrlab/layout/pp-doclayout-v3-mlx``, on the Mac's GPU, about 0.25 s a page. Each
page's regions (label, box in 0-1000 page coordinates, score, reading order), at the model's default score
floor of 0.5, are written to ``<cache>/layout/<collection>.json`` keyed by file number. Regions and their
classes only: no text, no pixels. A page already in the cache is not run again.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import data

WEIGHTS = Path.home() / ".local/share/visionocr-ocrlab/layout/pp-doclayout-v3-mlx"
MODEL_ID = "PP-DocLayoutV3 (mlx-vlm port), conf 0.5, 1024 px"


def cache_path(name: str) -> Path:
    return data.CACHE_DIR / "layout" / f"{name}.json"


def read(name: str) -> dict[int, list[dict]] | None:
    p = cache_path(name)
    if not p.exists():
        return None
    return {int(k): v for k, v in json.loads(p.read_text())["pages"].items()}


def load_model():
    import mlx.core as mx
    from mlx_vlm.models.pp_doclayout_v3 import Model
    from mlx_vlm.models.pp_doclayout_v3.config import ModelConfig
    cfg = json.loads((WEIGHTS / "config.json").read_text())
    model = Model(ModelConfig.from_dict(cfg))
    model.load_weights(list(model.sanitize(mx.load(str(WEIGHTS / "model.safetensors"))).items()), strict=True)
    model.eval()
    return model


def run(col, model) -> int:
    from PIL import Image
    p = cache_path(col.name)
    store = json.loads(p.read_text()) if p.exists() else {"model": MODEL_ID, "pages": {}}
    if store.get("model") != MODEL_ID:
        raise ValueError(f"{p} was made by {store.get('model')!r}; move it aside to rerun")
    todo = [pg for pg in col.pages if str(pg.n) not in store["pages"]]
    t0 = time.time()
    for k, pg in enumerate(todo, 1):
        im = Image.open(pg.path)
        im.draft("RGB", (1024, 1024))       # decode a JPEG at reduced size; the detector resizes to 1024
        store["pages"][str(pg.n)] = model.detect(im.convert("RGB"))
        if k % 50 == 0 or k == len(todo):
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(store))
            tmp.replace(p)
            print(f"  {col.name}: {k}/{len(todo)} pages, {(time.time() - t0) / k:.2f} s a page", flush=True)
    return len(todo)


def main(argv) -> int:
    if argv[:1] == ["owner"]:
        cols = [data.load(n, with_exif=False) for n in data.COLLECTIONS]
    elif argv[:1] == ["public"] and len(argv) == 3 and argv[1] == "--root":
        root = Path(argv[2])
        data.CACHE_DIR = root / "cache"
        import public_segmentation as P
        cols = [P.load(box, root)[0] for box in ("lincoln", "crest")]
    else:
        print(__doc__)
        return 2
    model = load_model()
    for col in cols:
        print(f"{col.name}: {run(col, model)} pages detected", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
