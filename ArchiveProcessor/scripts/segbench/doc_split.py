"""doc-split-v1 (nutrientdocs/doc-split-v1, Apache-2.0) on the bench's boxes: per-page embeddings, then the head.

    <lab venv>/bin/python doc_split.py embed owner              # the five owner boxes
    <lab venv>/bin/python doc_split.py embed public ROOT        # Lincoln and CREST (ROOT = the public-segmentation cache)

ONNX on the Mac's CPU, no calls, no money. The model is downloaded once from Hugging Face into
``~/Library/Caches/ArchiveSuiteRehearsal/doc-split/model`` (``huggingface_hub.snapshot_download``); the embeddings
of every page are cached beside it, ``emb/<box>.npz``, so the head and every refit run in seconds.

Inputs follow the model card's usage code exactly: the page image resized to 512x512 and normalised to [-1, 1]; the
text tower given ``"query: " + text`` truncated at 512 tokens, with the page's Apple Vision text from the bench's own
OCR cache (the same text every window source reads); the OCR gate 0 for a page with no text. One change: the image is
turned upright by its EXIF orientation first, as the bench's thumbnails and Vision are.

The head sees one stream at a time. On the owner boxes the stream is a run of document pages between label photos
(the photos are the truth's, as ``truth_photos`` has them in every window source), so every run starts a document;
Lincoln and CREST are one stream each. Page 0 of a stream is forced to a boundary, as the card does.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np

import data
from score import PHOTO

HOME = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/doc-split"
MODEL = HOME / "model"
EMB = HOME / "emb"
REPO_ID = "nutrientdocs/doc-split-v1"
# The card's beta calibration: p_cal = sigmoid(a ln p + b ln(1-p) + c).
BETA = (0.516, -0.402, -0.155)


def model_dir() -> Path:
    if not (MODEL / "head.onnx").exists():
        from huggingface_hub import snapshot_download
        snapshot_download(REPO_ID, local_dir=str(MODEL))
    return MODEL


def _sessions():
    import onnxruntime as ort
    d = model_dir()
    opt = ort.SessionOptions()
    s = lambda f: ort.InferenceSession(str(d / f), opt, providers=["CPUExecutionProvider"])  # noqa: E731
    return s("image_model.onnx"), s("text_model.onnx")


def _image(path: Path) -> np.ndarray:
    from PIL import Image, ImageOps
    im = Image.open(path)
    im.draft("RGB", (1024, 1024))
    im = ImageOps.exif_transpose(im).convert("RGB").resize((512, 512))
    return ((np.asarray(im, np.float32) / 255 - .5) / .5).transpose(2, 0, 1)


def embed_collection(col, text_of, out: Path, batch: int = 8) -> None:
    """Every page's image and text embedding, and its OCR gate -> out (npz). Skips a box already embedded."""
    if out.exists():
        print(f"{col.name}: already embedded ({out})")
        return
    from transformers import AutoTokenizer
    img, txt = _sessions()
    tok = AutoTokenizer.from_pretrained(str(model_dir()))
    n = len(col.pages)
    vi, vt, gate = np.zeros((n, 768), np.float32), np.zeros((n, 384), np.float32), np.zeros(n, np.float32)
    t0 = time.time()
    for a in range(0, n, batch):
        idx = list(range(a, min(n, a + batch)))
        arr = np.stack([_image(col.pages[i].path) for i in idx]).astype(np.float32)
        vi[idx] = img.run(["image_embed"], {"pixel_values": arr})[0]
        texts = [text_of(i) or "" for i in idx]
        b = tok(["query: " + (t if t.strip() else " ") for t in texts], padding=True, truncation=True,
                max_length=512, return_tensors="np")
        vt[idx] = txt.run(["text_embed"], {"input_ids": b["input_ids"].astype(np.int64),
                                           "attention_mask": b["attention_mask"].astype(np.int64)})[0]
        gate[idx] = [1. if t.strip() else 0. for t in texts]
        print(f"  {col.name} {idx[-1] + 1}/{n}  {time.time() - t0:.0f} s", flush=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez(out, img=vi, txt=vt, gate=gate, n=np.array([p.n for p in col.pages]))
    print(f"{col.name}: {n} pages in {time.time() - t0:.0f} s -> {out}")


def load_emb(name: str) -> dict:
    z = np.load(EMB / f"{name}.npz")
    return {k: z[k] for k in z.files}


def streams(labels) -> list[list[int]]:
    """Runs of document pages between label photos (page indices)."""
    runs, cur = [], []
    for i, t in enumerate(labels):
        if t in PHOTO:
            if cur:
                runs.append(cur)
            cur = []
        else:
            cur.append(i)
    if cur:
        runs.append(cur)
    return runs


class Head:
    def __init__(self):
        import onnxruntime as ort
        self.s = ort.InferenceSession(str(model_dir() / "head.onnx"), providers=["CPUExecutionProvider"])
        self.crf = json.loads((model_dir() / "crf.json").read_text())

    def logits(self, emb: dict, labels) -> np.ndarray:
        """Per page index: the head's raw boundary logit (nan on photos); page 0 of each stream forced to 30."""
        out = np.full(len(labels), np.nan)
        for run in streams(labels):
            g = emb["gate"][run]
            vt = emb["txt"][run] * g[:, None]
            bl = self.s.run(["boundary_logit"], {"v_img": emb["img"][run][None], "v_txt": vt[None],
                                                  "gate": g[None], "mask": np.ones((1, len(run)), np.float32)})[0][0]
            bl[0] = 30.0
            out[run] = bl
        return out


def _lse(x, ax):
    m = x.max(ax, keepdims=True)
    return (m + np.log(np.exp(x - m).sum(ax, keepdims=True))).squeeze(ax)


def marginals(bl: np.ndarray, crf: dict, scale: float = 1.0, bias: float = 0.0) -> np.ndarray:
    """The card's forward-backward over the two-tag chain; emission (0, scale*bl + bias). P(boundary) per page."""
    T, s, e_ = np.asarray(crf["trans"]), np.asarray(crf["start"]), np.asarray(crf["end"])
    N = len(bl)
    em = np.stack([np.zeros(N), scale * bl + bias], 1)
    em[0, 1] = bl[0]                      # the forced first page is not rescaled
    a = np.zeros((N, 2))
    a[0] = s + em[0]
    for t in range(1, N):
        a[t] = _lse(a[t - 1][:, None] + T, 0) + em[t]
    b = np.zeros((N, 2))
    b[N - 1] = e_
    for t in range(N - 2, -1, -1):
        b[t] = _lse(T + (em[t + 1] + b[t + 1])[None, :], 1)
    m = a + b
    m -= m.max(1, keepdims=True)
    p = np.exp(m)
    return (p / p.sum(1, keepdims=True))[:, 1]


def beta_cal(p: np.ndarray, abc=BETA) -> np.ndarray:
    p = np.clip(p, 1e-6, 1 - 1e-6)
    a, b, c = abc
    return 1 / (1 + np.exp(-(a * np.log(p) + b * np.log(1 - p) + c)))


def main(argv) -> int:
    if argv[:2] == ["embed", "owner"]:
        for name in data.COLLECTIONS:
            col = data.load(name, with_exif=False)
            embed_collection(col, col.text, EMB / f"{name}.npz")
    elif argv[:2] == ["embed", "public"] and len(argv) == 3:
        import public_segmentation as P
        root = Path(argv[2])
        for box in ("lincoln", "crest"):
            col, _ = P.load(box, root)
            ocr = root / "cache/ocr" / col.name

            def text_of(i, col=col, ocr=ocr):
                f = ocr / f"{col.pages[i].n}.txt"
                if not f.exists():
                    raise FileNotFoundError(f"no Vision text for {col.name} page {col.pages[i].n}")
                return f.read_text(encoding="utf-8")
            embed_collection(col, text_of, EMB / f"{col.name}.npz")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
