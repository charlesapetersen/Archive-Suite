"""W46.enh-ocr-input: the enhancement arms, run in the enh-dewarp venv (torch, OpenCV). Imported by enh_ocr_input.py.

Every arm takes the panel's frozen raw image (2400 px ceiling, JPEG 90: the one every saved route read) as an RGB
array and returns an RGB array of the same size, so the page's geometry is unchanged: Vision's word boxes, the
regions PP-DocLayoutV3 found on raw and the mark boxes all apply to the enhanced image as they are. The strand's
classes (D-enhancement.md §6.1):

  shading            contrast-only, the control: each channel divided by its background, the background being the
                     channel dilated 7 x 7 then median-filtered 21 x 21 at 1024 x 1024 (DocRes's own prompt
                     construction, inference.py deshadow_prompt's bg_imgs), resized back. A gain field: it rescales
                     a mark, it cannot erase one.
  docres-appearance  DocRes (MIT, ZZZHANG-jx/DocRes d3e3a18c, docres.pkl) appearance task, its inference code
  docres-deshadow    DocRes deshadow task; both resize to 1,600 square, predict, and divide the full image by the
                     ratio (the code's large-image branch, which every raw image takes). Content-removing.
  gcdrnet            GCDRNet (MIT), trained on RealDAE's real camera pairs. Content-removing (stage two predicts pixels).
  sbb                SBB binarisation (Apache-2.0, OCR-D's standard), black on white, as three equal channels.
"""
from __future__ import annotations
import importlib.util
from collections import OrderedDict
from pathlib import Path

import cv2
import numpy as np
import torch

# CUDA on the cluster, where the learned arms run (DocRes at 1,600 square needs more than this Mac's 18 GB); the
# classical arm needs no torch at all.
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
DOCRES_SIZE = 1600  # inference.py MAX_SIZE
_models = {}


def background(img, size=1024, dilate=7, median=21):
    """DocRes's shading estimate, per channel, at the image's size (uint8)."""
    h, w = img.shape[:2]
    small = cv2.resize(img, (size, size))
    bg = [cv2.medianBlur(cv2.dilate(p, np.ones((dilate, dilate), np.uint8)), median) for p in cv2.split(small)]
    return cv2.resize(cv2.merge(bg), (w, h))


def shading(img):
    bg = np.maximum(background(img).astype(np.float64), 1)
    return np.clip(img.astype(np.float64) / bg * 255, 0, 255).astype(np.uint8)


def appearance_prompt(img_bgr):
    """inference.py appearance_prompt: the normalised difference from the background, per channel."""
    h, w = img_bgr.shape[:2]
    small = cv2.resize(img_bgr, (1024, 1024))
    out = []
    for p in cv2.split(small):
        bg = cv2.medianBlur(cv2.dilate(p, np.ones((7, 7), np.uint8)), 21)
        diff = 255 - cv2.absdiff(p, bg)
        out.append(cv2.normalize(diff, None, alpha=0, beta=255, norm_type=cv2.NORM_MINMAX, dtype=cv2.CV_8UC1))
    return cv2.resize(cv2.merge(out), (w, h))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _strip(state):
    return OrderedDict((k[7:] if k.startswith('module.') else k, v) for k, v in state.items())


def docres_net(src: Path):
    if 'docres' not in _models:
        root = src / 'DocRes'
        arch = _load('restormer_arch', root / 'models/restormer_arch.py')
        net = arch.Restormer(inp_channels=6, out_channels=3, dim=48, num_blocks=[2, 3, 3, 4], num_refinement_blocks=4,
                             heads=[1, 2, 4, 8], ffn_expansion_factor=2.66, bias=False, LayerNorm_type='WithBias',
                             dual_pixel_task=True)
        net.load_state_dict(_strip(torch.load(root / 'checkpoints/docres.pkl', map_location='cpu')['model_state']))
        _models['docres'] = net.eval().half().to(DEVICE)  # inference.py runs the model in half
    return _models['docres']


def stride_integral(img, stride=8):
    """data/preprocess/crop_merge_image.py: replicate-pad the top and the left to a multiple of `stride`."""
    h, w = img.shape[:2]
    ph, pw = (-h) % stride, (-w) % stride
    return cv2.copyMakeBorder(img, ph, 0, pw, 0, borderType=cv2.BORDER_REPLICATE), ph, pw


def docres(img, task, src: Path):
    """DocRes appearance or deshadow on an RGB image, inference.py appearance / deshadowing: below 1,600 px the
    padded image is predicted directly; at or above, the 1,600-square prediction becomes a ratio the full image is
    divided by."""
    bgr = np.ascontiguousarray(img[..., ::-1])
    h, w = bgr.shape[:2]
    prompt = appearance_prompt(bgr) if task == 'appearance' else background(bgr)  # deshadow_prompt returns bg_imgs
    x = np.concatenate([bgr, prompt], -1)
    small = max(w, h) < DOCRES_SIZE
    if small:
        x, ph, pw = stride_integral(x, 8)
    else:
        x = cv2.resize(x, (DOCRES_SIZE, DOCRES_SIZE))
    with torch.no_grad():
        t = torch.from_numpy((x / 255.0).transpose(2, 0, 1)).unsqueeze(0).half().to(DEVICE)
        pred = torch.clamp(docres_net(src)(t), 0, 1)[0].permute(1, 2, 0).float().cpu().numpy()
    pred = (pred * 255).astype(np.uint8)
    if small:
        out = pred[ph:, pw:]
    else:
        pred[pred == 0] = 1
        shadow = cv2.resize(cv2.resize(bgr, (DOCRES_SIZE, DOCRES_SIZE)).astype(float) / pred.astype(float), (w, h))
        shadow[shadow == 0] = 0.00001
        out = np.clip(bgr.astype(float) / shadow, 0, 255).astype(np.uint8)
    return np.ascontiguousarray(out[..., ::-1])


def enhance(arm, img, src: Path):
    """One arm's image from the raw RGB image, the same size."""
    if arm == 'shading':
        return shading(img)
    if arm in ('docres-appearance', 'docres-deshadow'):
        return docres(img, arm.split('-')[1], src)
    raise KeyError(arm)
