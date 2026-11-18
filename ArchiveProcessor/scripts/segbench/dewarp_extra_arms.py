"""W46.dewarp-placement: extra research dewarper arms (DvD, DocTr++), research only, never bundled.

Same contract as dewarp_arms.uvdoc_arm: input RGB uint8 image, returns (out RGB uint8 at the input size, grid) where
grid is (GH, GW, 2) of source positions (x / W, y / H), one per output lattice node (corners included). Normalised
exactly as uvdoc_arm: a network grid g in [-1, 1] under align_corners=True maps to (g + 1) / 2 * ((W-1)/W, (H-1)/H).
`out` is F.grid_sample(img, bilinear-upsample(g, align_corners=True), align_corners=True), as the models' own code.

DvD (hanquansanren/DvD, AGPL-3.0): its own sampling loop from train_settings/dvd/evaluation.py, run per image on CPU
(mpi4py stubbed; `.cuda()` calls in geotr_core.py / position_encoding.py patched to the input's device).
DocTr++ (fh2019ustc/DocTr-Plus): code present, but the authors publish no weights; see doctrpp_arm.
"""
from __future__ import annotations
import logging
import os
import sys
import types
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn.functional as F

DEVICE = torch.device('cpu')
_models = {}


class _Log:
    def __init__(self):
        self._l = logging.getLogger('dvd')

    def info(self, *a, **k): pass
    def log(self, *a, **k): pass


def _stub_mpi():
    if 'mpi4py' in sys.modules:
        return
    class _Comm:
        rank, size = 0, 1
        def Get_rank(self): return 0
        def bcast(self, x, root=0): return x
    m = types.ModuleType('mpi4py'); MPI = types.ModuleType('mpi4py.MPI'); MPI.COMM_WORLD = _Comm()
    m.MPI = MPI
    sys.modules['mpi4py'] = m; sys.modules['mpi4py.MPI'] = MPI


def _stub_mmcv():
    """mmcv has no Mac wheel; DvD only uses mmcv.cnn.ConvModule(conv -> BN -> ReLU), keys `.conv` and `.bn`."""
    if 'mmcv' in sys.modules:
        return
    import torch.nn as nn

    class ConvModule(nn.Module):
        def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0, dilation=1, groups=1,
                     bias='auto', norm_cfg=None, act_cfg=dict(type='ReLU'), **kw):
            super().__init__()
            if bias == 'auto':
                bias = norm_cfg is None
            self.conv = nn.Conv2d(in_channels, out_channels, kernel_size, stride, padding, dilation, groups, bias=bias)
            if norm_cfg is not None:
                self.bn = nn.BatchNorm2d(out_channels)
            self.activate = nn.ReLU(inplace=True) if act_cfg is not None else None

        def forward(self, x):
            x = self.conv(x)
            if hasattr(self, 'bn'):
                x = self.bn(x)
            return self.activate(x) if self.activate is not None else x

    m = types.ModuleType('mmcv'); cnn = types.ModuleType('mmcv.cnn'); cnn.ConvModule = ConvModule; m.cnn = cnn
    sys.modules['mmcv'] = m; sys.modules['mmcv.cnn'] = cnn


def _load_dvd(src: Path):
    root = str(src / 'DvD')
    _stub_mpi()
    _stub_mmcv()
    if root not in sys.path:
        sys.path.insert(0, root)
    cwd = os.getcwd()
    os.chdir(root)  # the repo's settings use paths relative to its root
    try:
        import admin.settings as ws
        from train_settings.dvd.improved_diffusion import dist_util
        from train_settings.dvd.improved_diffusion.script_util import (
            args_to_dict, create_model_and_diffusion, model_and_diffusion_defaults)
        from train_settings.dvd.feature_backbones.VGG_features import VGGPyramid
        from train_settings.models.geotr.geotr_core import GeoTr_Seg_Inf, Seg, reload_segmodel
        from train_settings.models.geotr.unet_model import UNet
        settings = ws.Settings()
        env = settings.env
        ck = Path(root) / 'checkpoints'
        env.model_path, env.seg_model_path = str(ck / 'model1852000.pt'), str(ck / 'seg.pth')
        env.line_seg_model_path, env.new_seg_model_path = str(ck / 'line_model2.pth'), str(ck / 'seg_model.pth')
        dev = torch.device('cpu')
        model, diffusion = create_model_and_diffusion(
            device=dev, train_mode=env.train_mode, tv=env.time_variant,
            **args_to_dict(settings, model_and_diffusion_defaults().keys()))
        diffusion.settings = settings
        res = model.cpu().load_state_dict(torch.load(env.model_path, map_location='cpu'), strict=False)
        print('DvD load: missing', len(res.missing_keys), 'unexpected', len(res.unexpected_keys),
              res.missing_keys[:4], res.unexpected_keys[:4], file=sys.stderr)
        model.to(dev).eval()
        dewarp = GeoTr_Seg_Inf()
        reload_segmodel(dewarp.msk, env.seg_model_path)
        dewarp.to(dev).eval()
        line = UNet(n_channels=3, n_classes=1)
        line.load_state_dict(torch.load(env.line_seg_model_path, map_location='cpu')['model'], strict=True)
        seg = Seg()
        seg.load_state_dict(torch.load(env.new_seg_model_path, map_location='cpu')['model'], strict=True)
        line.to(dev).eval(); seg.to(dev).eval()
        pyramid = VGGPyramid(train=False).to(dev)
    finally:
        os.chdir(cwd)
    return dict(settings=settings, diffusion=diffusion, model=model, dewarp=dewarp, line=line, seg=seg,
                pyramid=pyramid)


def dvd_arm(img, src: Path):
    """DvD on `img` (RGB uint8). Returns the dewarped image and the 64 x 64 backward-map lattice."""
    cwd = os.getcwd()
    (src / 'DvD' / 'vis_hp' / 'debug_vis').mkdir(parents=True, exist_ok=True)
    os.chdir(src / 'DvD')  # the repo's sampler writes debug PNGs to a relative vis_hp/debug_vis (inside the cache)
    try:
        return _dvd_run(img, src)
    finally:
        os.chdir(cwd)


def _dvd_run(img, src: Path):
    if 'dvd' not in _models:
        _models['dvd'] = _load_dvd(src)
    m = _models['dvd']
    from train_settings.dvd.evaluation import run_sample_lr_dewarping, coords_grid_tensor
    from train_settings.dvd.eval_utils import extract_raw_features_single2
    env = m['settings'].env
    h, w = img.shape[:2]
    x = img.astype(np.float32)
    s512 = torch.from_numpy(cv2.resize(img, (512, 512)).astype(np.float32).transpose(2, 0, 1)).unsqueeze(0) / 255.
    S = 64
    with torch.inference_mode():
        s288 = F.interpolate(s512, size=288, mode="bilinear", align_corners=True)
        _, mask_x = m['dewarp'](s288)
        init_flow = torch.zeros((1, 2, S, S))
        init_feat = torch.zeros((1, 256, S, S))
        s256 = F.interpolate(s512, size=(256, 256), mode='area')
        mskx, d0, hx6, hx5d, hx4d, hx3d, hx2d, hx1d = m['seg'](s288)
        seg_all = torch.cat([F.interpolate(t, size=S, mode='bilinear', align_corners=False)
                             for t in (hx6, hx5d, hx4d, hx3d, hx2d, hx1d)], dim=1)
        line_map, _ = m['line'](mskx)
        line_map = F.interpolate(line_map, size=S, mode='bilinear', align_corners=False)
        c20 = None  # env.train_VGG is True: the model extracts its own VGG features from y512
        sample = run_sample_lr_dewarping(
            m['settings'], _Log(), m['diffusion'], m['model'], 4, s512, S, None, init_flow, c20, None,
            m['pyramid'], mask_x, seg_all, line_map, init_feat)  # (1, 2, 64, 64) offsets, [-1, 1]
        # the repo's base lattice: x then y in [0, 1], 512-pixel version upsampled; at 64 it is a linspace
        lin = torch.linspace(0, 1, S)
        by, bx = torch.meshgrid(lin, lin, indexing='ij')
        base = torch.stack([bx, by])[None]
        g = ((sample.cpu() + base) * 2 - 1) * 0.987  # (1, 2, 64, 64), align_corners=True coordinates
        up = F.interpolate(g, size=(h, w), mode='bilinear', align_corners=True)
        out = F.grid_sample(torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0), up.permute(0, 2, 3, 1),
                            mode='bilinear', padding_mode='zeros', align_corners=True)
    out = out[0].numpy().transpose(1, 2, 0).clip(0, 255).astype(np.uint8)
    gg = g[0].numpy().transpose(1, 2, 0)
    return out, (gg + 1) / 2 * ((w - 1) / w, (h - 1) / h)


def doctrpp_arm(img, src: Path):
    """DocTr++ (fh2019ustc/DocTr-Plus). Needs src/DocTrPlus/model_pretrained/DocTrP.pth, which the authors do not
    publish (README says only 'put the pretrained model there'; no link in any commit, release or mirror)."""
    wpath = src / 'DocTrPlus' / 'model_pretrained' / 'DocTrP.pth'
    if not wpath.exists():
        raise FileNotFoundError(f'DocTr++ weights not available: {wpath} (authors publish none)')
    if 'doctrpp' not in _models:
        root = str(src / 'DocTrPlus')
        if root not in sys.path:
            sys.path.insert(0, root)
        from GeoTr import GeoTr
        net = GeoTr()
        sd = torch.load(wpath, map_location='cpu')
        sd = {(k[7:] if k.startswith('module.') else k): v for k, v in sd.items()}
        net.load_state_dict({k: v for k, v in sd.items() if k in net.state_dict()}, strict=False)
        _models['doctrpp'] = net.eval().to(DEVICE)
    h, w = img.shape[:2]
    x = img.astype(np.float32) / 255
    inp = torch.from_numpy(cv2.resize(x, (288, 288)).transpose(2, 0, 1)).unsqueeze(0)
    with torch.no_grad():
        bm = _models['doctrpp'](inp)
        g = (2 * (bm / 286.8) - 1) * 0.99  # (1, 2, 36?, 36?) as inference.py
        up = F.interpolate(g, size=(h, w), mode='bilinear', align_corners=True)
        out = F.grid_sample(torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0), up.permute(0, 2, 3, 1),
                            align_corners=True)
    out = (out[0].numpy().transpose(1, 2, 0) * 255).clip(0, 255).astype(np.uint8)
    gg = g[0].numpy().transpose(1, 2, 0)
    return out, (gg + 1) / 2 * ((w - 1) / w, (h - 1) / h)


# W46.licence-freed-sweep: DocScanner-L and DocGeoNet (fh2019ustc, Hao Feng's own non-commercial licence), the authors'
# Google Drive weights in src/DocScanner/model_pretrained and src/DocGeoNet/model_pretrained. Each runs its repo's
# inference.Net (U2NETP page mask, then the rectifier) at the repo's input size on CPU. The backward map is upsampled
# with align_corners like doctrpp_arm; the repos' own cv2 resize and 3 x 3 blur of the full-size map are left out, so
# the lattice is the network's own. The two repos share module names (model, seg, extractor), so each import starts
# from a clean slate.
_FH_MODULES = ('model', 'seg', 'extractor', 'update', 'unet', 'position_encoding', 'inference')


def _fh_net(name: str, src: Path):
    if name in _models:
        return _models[name]
    root = src / {'docscanner': 'DocScanner', 'docgeonet': 'DocGeoNet'}[name]
    for m in _FH_MODULES:
        sys.modules.pop(m, None)
    sys.path.insert(0, str(root))
    real_cuda = torch.Tensor.cuda
    torch.Tensor.cuda = lambda self, *a, **k: self  # DocGeoNet's forward calls .cuda() on fresh tensors
    try:
        import inference as inf
        if name == 'docscanner':
            net = inf.Net()
            seg_w, rec_w, rec_strip = 'seg.pth', 'DocScanner-L.pth', 0
        else:
            net = inf.Net(None)
            seg_w, rec_w, rec_strip = 'preprocess.pth', 'DocGeoNet.pth', 7
        rec_part = net.bm if name == 'docscanner' else net.DocTr
        for part, w, strip in ((net.msk, seg_w, 6), (rec_part, rec_w, rec_strip)):
            sd = torch.load(root / 'model_pretrained' / w, map_location='cpu')
            own = part.state_dict()
            got = {k[strip:]: v for k, v in sd.items() if k[strip:] in own}
            assert len(got) == len(own), f'{name} {w}: {len(got)} of {len(own)} tensors matched'
            part.load_state_dict(got)
    finally:
        torch.Tensor.cuda = real_cuda
        sys.path.remove(str(root))
        for m in _FH_MODULES:
            sys.modules.pop(m, None)
    _models[name] = net.eval().to(DEVICE)
    return _models[name]


def _fh_arm(name: str, img, src: Path):
    net = _fh_net(name, src)
    size = 288 if name == 'docscanner' else 256
    h, w = img.shape[:2]
    x = img.astype(np.float32) / 255
    inp = torch.from_numpy(cv2.resize(x, (size, size)).transpose(2, 0, 1)).unsqueeze(0)
    saved = torch.Tensor.cuda
    torch.Tensor.cuda = lambda self, *a, **k: self
    try:
        with torch.no_grad():
            g = net(inp)  # (1, 2, size, size) in [-1, 1], align_corners=True, as the repo's Net returns it
            up = F.interpolate(g, size=(h, w), mode='bilinear', align_corners=True)
            out = F.grid_sample(torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0), up.permute(0, 2, 3, 1),
                                align_corners=True)
    finally:
        torch.Tensor.cuda = saved
    out = (out[0].numpy().transpose(1, 2, 0) * 255).clip(0, 255).astype(np.uint8)
    gg = g[0].numpy().transpose(1, 2, 0)
    return out, (gg + 1) / 2 * ((w - 1) / w, (h - 1) / h)


def docscanner_arm(img, src: Path):
    return _fh_arm('docscanner', img, src)


def docgeonet_arm(img, src: Path):
    return _fh_arm('docgeonet', img, src)
