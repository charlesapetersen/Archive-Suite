"""PP-DocLayoutV3's newspaper regions (W46.layout-newspapers), without reading any text.

Run by NewspaperLayout in the shared runtime, with a checked, pinned local snapshot. The load and
detect are the bench's layout.py operations: 1024 px, conf 0.5, native reading order. All labels,
pictures included, are returned. No model loader or hub API runs, and nothing is downloaded.
"""
import argparse
import json
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("image")
ap.add_argument("out")
ap.add_argument("--model", required=True)
a = ap.parse_args()

import mlx.core as mx
from mlx_vlm.models.pp_doclayout_v3 import Model
from mlx_vlm.models.pp_doclayout_v3.config import ModelConfig
from PIL import Image

mx.set_cache_limit(256 * 2**20)
weights = Path(a.model)
cfg = json.loads((weights / "config.json").read_text())
model = Model(ModelConfig.from_dict(cfg))
model.load_weights(list(model.sanitize(mx.load(str(weights / "model.safetensors"))).items()), strict=True)
model.eval()
with Image.open(a.image) as image:
    image.draft("RGB", (1024, 1024))
    regions = model.detect(image.convert("RGB"), conf=0.5, img_size=1024)
Path(a.out).write_text(json.dumps(regions, allow_nan=False))
