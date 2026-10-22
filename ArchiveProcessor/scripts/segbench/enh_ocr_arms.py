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
import sys
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


class _inside:
    """Run a method's own code from its clone: its directory first on sys.path and as the working directory."""
    def __init__(self, d):
        self.d = str(d)

    def __enter__(self):
        import os
        self.cwd = os.getcwd()
        sys.path.insert(0, self.d)
        os.chdir(self.d)

    def __exit__(self, *exc):
        import os
        os.chdir(self.cwd)
        sys.path.remove(self.d)


def gcdrnet(img, base: Path):
    """GCDRNet (MIT, ZZZHANG-jx/GCDRNet 415c97a9; weights from the Hugging Face mirror FahNos/GCDRnet, the README's
    own link being OneDrive) as infer.py: pad top and left to a multiple of 32, gcnet's shading map divided out,
    then drnet on the image and the shading-corrected image; full resolution, deterministic."""
    import torch.nn.functional as F
    root = base / 'src' / 'GCDRNet'
    if 'gcdrnet' not in _models:
        with _inside(root):
            sys.path.append(str(root / 'models/UNeXt'))
            from utils import convert_state_dict
            from models.UNeXt.unext import UNext_full_resolution_padding, UNext_full_resolution_padding_L_py_L
            m1 = UNext_full_resolution_padding(num_classes=3, input_channels=3, img_size=512)
            m1.load_state_dict(convert_state_dict(torch.load('checkpoints/gcnet/checkpoint.pkl', map_location='cpu')['model_state']))
            m2 = UNext_full_resolution_padding_L_py_L(num_classes=3, input_channels=6, img_size=512)
            m2.load_state_dict(convert_state_dict(torch.load('checkpoints/drnet/checkpoint.pkl', map_location='cpu')['model_state']))
        _models['gcdrnet'] = (m1.eval().to(DEVICE), m2.eval().to(DEVICE))
    m1, m2 = _models['gcdrnet']
    bgr, ph, pw = stride_integral(np.ascontiguousarray(img[..., ::-1]), 32)
    h, w = bgr.shape[:2]
    with torch.no_grad():
        x = torch.from_numpy(bgr.transpose(2, 0, 1) / 255).unsqueeze(0).float().to(DEVICE)
        sh = F.interpolate(m1(x), (h, w))
        pred = m2(torch.cat((x, torch.clamp(x / sh, 0, 1)), 1))[0]
    out = (pred[0].permute(1, 2, 0).cpu().numpy() * 255).astype(np.uint8)[ph:, pw:]  # infer.py: no clamp
    return np.ascontiguousarray(out[..., ::-1])


def seed_all(seed):
    import random
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def resshift(img, base: Path, seed):
    """PreP-OCR's restorer: ResShift (zsyOAOA/ResShift bb03b7d2, S-Lab non-commercial: a research run only) with
    PreP-OCR's deblur_gopro256.yaml and its released weights (ShuhaoGuan/prep-ocr-resshift-deblur), 4 steps,
    256 px chops at stride 224. The paper's multi-direction median fusion is not in the released code, so this is
    plain chopping. Reseeded before every page, so a page's noise does not depend on the order pages are made."""
    import tempfile
    from PIL import Image
    root = base / 'src' / 'ResShift'
    with _inside(root):
        if 'resshift' not in _models:
            from omegaconf import OmegaConf
            from sampler import ResShiftSampler
            cfg = OmegaConf.load(str(base / 'src/PreP-OCR/configs/deblur_gopro256.yaml'))
            cfg.model.ckpt_path = str(base / 'weights/prep-ocr/resshift_deblur_prep_ocr.pth')
            cfg.autoencoder.ckpt_path = str(base / 'weights/prep-ocr/autoencoder_vq_f4.pth')
            _models['resshift'] = ResShiftSampler(cfg, sf=1, chop_size=256, chop_stride=224, chop_bs=1, use_amp=False,
                                                  seed=seed, padding_offset=cfg.model.params.lq_size)
        with tempfile.TemporaryDirectory() as d:
            src, out = Path(d) / 'in.png', Path(d) / 'out'
            Image.fromarray(img).save(src)
            seed_all(seed)
            _models['resshift'].inference(str(src), str(out), bs=1, noise_repeat=False)
            with Image.open(out / 'in.png') as im:
                return np.asarray(im.convert('RGB'))


def nafdpm(img, base: Path, seed, steps=20):
    """NAF-DPM (MIT, ispamm/NAF-DPM 06fe76a6) deblurring with its FINETUNING-BEST_CER weights, as Tester.test with
    NATIVE_RESOLUTION: 256 px tiles without overlap, white-padded, DPM-Solver++ at the conf's 20 steps on the
    linear 100-step schedule, init predictor plus the sampled residual. torch.manual_seed(seed) before each page."""
    import types
    root = base / 'src' / 'NAF-DPM'
    ck = str(base / 'weights/naf/NAF-DPM/Checkpoints Deblurring/FINETUNING-BEST_CER_model_%s.pth')
    with _inside(root):
        if 'nafdpm' not in _models:
            for m in ('pyiqa', 'wandb'):
                sys.modules.setdefault(m, types.ModuleType(m))
            from Deblurring.schedule.schedule import Schedule
            from Deblurring.model.NAFDPM import NAFDPM
            from Deblurring.src.tester import dpm_solver
            net = NAFDPM(input_channels=6, mode=0, n_channels=32, middle_blk_num=1, enc_blk_nums=[1, 1, 1, 1],
                         dec_blk_nums=[1, 1, 1, 1])
            net.init_predictor.load_state_dict(torch.load(ck % 'init', map_location='cpu', weights_only=False)['model_state_dict'])
            net.denoiser.load_state_dict(torch.load(ck % 'denoiser', map_location='cpu', weights_only=False)['model_state_dict'])
            _models['nafdpm'] = (net.eval().to(DEVICE), Schedule('linear', 100), dpm_solver)
        net, sched, solver = _models['nafdpm']
        seed_all(seed)
        x = torch.from_numpy(img.transpose(2, 0, 1)[None] / 255.).float()
        H, W = x.shape[2:]
        S = 256
        nh, nw = H // S + 1, W // S + 1
        pad = torch.ones((1, 3, nh * S, nw * S))
        pad[:, :, :H, :W] = x
        tiles = [pad[:, :, i * S:(i + 1) * S, j * S:(j + 1) * S] for i in range(nh) for j in range(nw)]
        res = []
        with torch.no_grad():
            for k in range(0, len(tiles), 8):
                b = torch.cat(tiles[k:k + 8], 0).to(DEVICE)
                ip = net.init_predictor(b)
                sm = solver(sched.get_betas(), net.denoiser, torch.randn_like(b), steps, ip, {})
                res += list(torch.clamp(sm + ip, 0, 1).cpu().split(1, 0))
        full = torch.cat([torch.cat(res[i * nw:(i + 1) * nw], 3) for i in range(nh)], 2)[0, :, :H, :W]
        return np.ascontiguousarray((full.numpy() * 255).round().astype(np.uint8).transpose(1, 2, 0))


def enhance(arm, img, base: Path):
    """One arm's image from the raw RGB image, the same size. base holds src/ (the clones) and weights/."""
    if arm == 'shading':
        return shading(img)
    if arm in ('docres-appearance', 'docres-deshadow'):
        return docres(img, arm.split('-')[1], base / 'src')
    if arm == 'gcdrnet':
        return gcdrnet(img, base)
    method, _, seed = arm.rpartition('-s')
    if method == 'resshift':
        return resshift(img, base, int(seed))
    if method == 'nafdpm':
        return nafdpm(img, base, int(seed))
    raise KeyError(arm)


def main():
    """enh_ocr_arms.py ARM BASE RAW_DIR OUT_DIR PAGE...: one arm on the Mac or the cluster, in whichever venv has the
    method's packages; an image already made is skipped. JPEG 90, as the raw image was saved."""
    from PIL import Image
    arm, base, raw, out, *ids = sys.argv[1:]
    for p in ids:
        dest = Path(out) / arm / f'{p}.jpg'
        if dest.exists():
            continue
        with Image.open(Path(raw) / f'{p}.jpg') as im:
            img = np.asarray(im.convert('RGB'))
        res = enhance(arm, img, Path(base))
        if res.shape != img.shape:
            raise SystemExit(f'{arm}/{p}: {res.shape} is not the raw image\'s {img.shape}')
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix('.tmp')
        Image.fromarray(res).save(tmp, 'JPEG', quality=90)
        tmp.replace(dest)
        print(arm, p, flush=True)


if __name__ == '__main__':
    main()
