"""W46.enh-dewarp: the image arms, run in the item's own venv (torch, OpenCV). Imported by enh_dewarp.py.

Each arm takes the full-resolution truth image in its stored pixel order (no EXIF transform, as the panel's frozen
images and segbench-ocr) and returns the output image and its backward map: a GH x GW lattice of source positions,
normalised to the source (x / width, y / height), one per output lattice point (corners included, as UVDoc's own
grid and `align_corners=True`). The lattice is what a page would keep beside itself so the text layer can be mapped
between the two copies; every geometric figure in the report is computed from it, not from the dense map.

  quad    Apple's DetectDocumentSegmentation quad, perspective-corrected (a homography; OpenCV here, the same
          projective map Core Image's CIPerspectiveCorrection applies). No quad: the raw image, flagged.
  uvdoc   UVDoc (MIT, tanguymagne/UVDoc best_model.pkl) on the quad crop, as the strand advises (it assumes a tight
          crop); the lattice is UVDoc's own 45 x 31 grid carried back through the quad's homography.
  docres  DocRes's dewarp task (MIT, docres.pkl with the MBD mask model) on the raw image, its own inference code
          with the CUDA calls removed; the dense map sampled at the lattice.
"""
from __future__ import annotations
import importlib.util
import sys
from collections import OrderedDict
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn.functional as F

GH, GW = 45, 31  # UVDoc's GRID_SIZE: rows down the page, columns across
UVDOC_IN = (488, 712)  # UVDoc's IMG_SIZE, (width, height) for cv2.resize
DEVICE = torch.device('cpu')  # small models; CPU keeps the runs reproducible
_models = {}


def lattice_uv():
    """Output-normalised lattice positions, shape (GH, GW, 2) as (u, v)."""
    u, v = np.meshgrid(np.linspace(0, 1, GW), np.linspace(0, 1, GH))
    return np.stack([u, v], -1)


def homography(corners, out_w, out_h):
    """Output pixel -> source pixel for a quad given as TL, TR, BR, BL source pixels."""
    dst = np.float32([[0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1], [0, out_h - 1]])
    return cv2.getPerspectiveTransform(dst, np.float32(corners))


def apply_h(H, pts):
    p = np.concatenate([pts, np.ones(pts.shape[:-1] + (1,))], -1) @ H.T
    return p[..., :2] / p[..., 2:3]


def quad_arm(img, quad):
    h, w = img.shape[:2]
    if not quad.get('found'):
        return img, lattice_uv(), False
    c = np.float64(quad['corners']) * (w, h)
    tl, tr, br, bl = c
    out_w = int(round((np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2))
    out_h = int(round((np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2))
    H = homography(c, out_w, out_h)
    out = cv2.warpPerspective(img, H, (out_w, out_h), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP,
                              borderMode=cv2.BORDER_REPLICATE)
    uv = lattice_uv() * (out_w - 1, out_h - 1)
    return out, apply_h(H, uv) / (w, h), True


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _strip(state):
    return OrderedDict((k[7:] if k.startswith('module.') else k, v) for k, v in state.items())


def uvdoc_arm(img, src: Path):
    """UVDoc on `img` (RGB uint8). Returns the unwarped image and the grid in `img`'s normalised coordinates."""
    if 'uvdoc' not in _models:
        mod = _load('uvdoc_model', src / 'UVDoc' / 'model.py')
        net = mod.UVDocnet(num_filter=32, kernel_size=5)
        net.load_state_dict(torch.load(src / 'UVDoc/model/best_model.pkl', map_location='cpu')['model_state'])
        _models['uvdoc'] = net.eval().to(DEVICE)
    x = img.astype(np.float32) / 255
    inp = torch.from_numpy(cv2.resize(x, UVDOC_IN).transpose(2, 0, 1)).unsqueeze(0)
    with torch.no_grad():
        grid = _models['uvdoc'](inp)[0]  # (1, 2, GH, GW) in [-1, 1], align_corners=True
        h, w = img.shape[:2]
        up = F.interpolate(grid, size=(h, w), mode='bilinear', align_corners=True)
        out = F.grid_sample(torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0), up.permute(0, 2, 3, 1),
                            align_corners=True)
    out = (out[0].numpy().transpose(1, 2, 0) * 255).clip(0, 255).astype(np.uint8)
    g = grid[0].numpy().transpose(1, 2, 0)  # (GH, GW, 2) as (x, y) in [-1, 1]
    # align_corners: -1 and 1 are the first and last pixel centres
    return out, (g + 1) / 2 * ((w - 1) / w, (h - 1) / h)


def uvdoc_after_quad(img, quad, src: Path):
    q, qgrid, found = quad_arm(img, quad)
    out, g = uvdoc_arm(q, src)
    h, w = img.shape[:2]
    qh, qw = q.shape[:2]
    if not found:
        return out, g, False
    c = np.float64(quad['corners']) * (w, h)
    H = homography(c, qw, qh)
    return out, apply_h(H, g * (qw, qh)) / (w, h), True


def docres_arm(img_bgr, src: Path):
    root = src / 'DocRes'
    if 'docres' not in _models:
        sys.path.insert(0, str(root / 'data/MBD'))
        from model.deep_lab_model.deeplab import DeepLab
        sys.path.pop(0)
        seg = DeepLab(num_classes=1, backbone='resnet', output_stride=16, sync_bn=None, freeze_bn=False)
        seg.load_state_dict(_strip(torch.load(root / 'data/MBD/checkpoint/mbd.pkl', map_location='cpu')['model_state']))
        arch = _load('restormer_arch', root / 'models/restormer_arch.py')
        net = arch.Restormer(inp_channels=6, out_channels=3, dim=48, num_blocks=[2, 3, 3, 4], num_refinement_blocks=4,
                             heads=[1, 2, 4, 8], ffn_expansion_factor=2.66, bias=False, LayerNorm_type='WithBias',
                             dual_pixel_task=True)
        net.load_state_dict(_strip(torch.load(root / 'checkpoints/docres.pkl', map_location='cpu')['model_state']))
        _models['docres'] = (seg.eval(), net.eval().float())
    seg, net = _models['docres']
    h, w = img_bgr.shape[:2]
    # MBD mask, as data/MBD/infer.py net1_net2_infer_single_im (CUDA calls removed)
    m = cv2.cvtColor(cv2.GaussianBlur(cv2.resize(img_bgr, (448, 448)), (15, 15), 0, 0), cv2.COLOR_BGR2RGB)
    with torch.no_grad():
        pred = seg(torch.from_numpy(m.astype(np.float32).transpose(2, 0, 1) / 255).unsqueeze(0))
    mask = F.interpolate(pred[:, 0:1], (h, w))[0, 0].numpy()
    mask = (mask * 255).astype(np.uint8)
    k = np.ones((3, 3))
    mask = cv2.erode(cv2.dilate(mask, k, iterations=3), k, iterations=3)
    mask[mask > 100] = 255
    mask[mask < 100] = 0
    # inference.py dewarp_prompt and dewarping
    base = np.stack(np.meshgrid(np.arange(256), np.arange(256)), -1).astype(np.float32) / 256
    masked = img_bgr.copy()
    masked[mask == 0] = 0
    prompt = np.concatenate([base, cv2.resize(mask, (256, 256))[..., None] / 255], -1)
    x = torch.from_numpy((cv2.resize(masked, (256, 256)) / 255.).transpose(2, 0, 1)).unsqueeze(0).float()
    p = torch.from_numpy(prompt.transpose(2, 0, 1)).unsqueeze(0).float()
    with torch.no_grad():
        out = net(torch.cat([x, p], 1))[0][:2].permute(1, 2, 0).numpy() + base
    for _ in range(15):
        out = cv2.blur(out, (3, 3), borderType=cv2.BORDER_REPLICATE)
    dense = (cv2.resize(out, (w, h)) * (w, h)).astype(np.float32)
    res = cv2.remap(img_bgr, dense[..., 0], dense[..., 1], cv2.INTER_LINEAR)
    # the lattice: the dense map at the output lattice's pixels, normalised to the source
    uv = lattice_uv() * (w - 1, h - 1)
    g = cv2.remap(dense, uv[..., 0].astype(np.float32), uv[..., 1].astype(np.float32), cv2.INTER_LINEAR)
    return res, g / (w, h), float((mask > 0).mean())
