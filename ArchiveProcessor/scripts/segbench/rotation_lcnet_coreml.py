#!/usr/bin/env python3
"""W46.rotation-default. PP-LCNet_x1_0_doc_ori (PaddleX, Apache-2.0) as the Core ML model the Processor ships.

  <paddle venv python> rotation_lcnet_coreml.py dump       # the inference program's weights + reference outputs
  <segbench/torch-env.sh python> rotation_lcnet_coreml.py convert   # PyTorch port, checked, then Core ML

The paddle venv needs only `paddlepaddle numpy pillow` (uv venv -p 3.12; PaddleX is not needed). The weights are
PaddleX's official download (~/.paddlex/official_models/PP-LCNet_x1_0_doc_ori, fetched once by `create_model`).

The port is PaddleClas's PPLCNet x1.0 with four classes, read off the inference program (op counts and attributes:
27 conv+BN+hardswish, 13 depthwise, two SE blocks, global average pool, 1x1 conv to 1280, hardswish, dropout 0.2 in
`downgrade_in_infer` mode, i.e. x * 0.8, then the 1280x4 linear and softmax). `convert` refuses to write the model
unless the port's probabilities match Paddle's own on every reference input (max abs difference under 1e-4).

The Core ML model takes the 224x224 RGB crop and does the ImageNet normalization itself; the app makes the crop as
PaddleX does (short side to 256, centre 224). Labels are the degrees the page is turned clockwise: 0, 90, 180, 270.
The app's check of the model against the bench's answers is ArchiveProcessorTests/RotationLCNetTests.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np

MODEL_DIR = Path(os.path.expanduser('~/.paddlex/official_models/PP-LCNet_x1_0_doc_ori'))
WORK = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/rotation-default'
OUT = (Path(__file__).resolve().parents[2] / 'macOS/Sources/ArchiveProcessor/Resources/PPLCNetDocOri.mlpackage')
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
# (kernel, in, out, stride, se) per block, PaddleClas NET_CONFIG at scale 1.0
BLOCKS = ([(3, 16, 32, 1, False), (3, 32, 64, 2, False), (3, 64, 64, 1, False), (3, 64, 128, 2, False),
           (3, 128, 128, 1, False), (3, 128, 256, 2, False)] + [(5, 256, 256, 1, False)] * 5
          + [(5, 256, 512, 2, True), (5, 512, 512, 1, True)])


def reference_inputs():
    """Deterministic inputs: noise and a few synthetic page-like patterns, already normalized (N, 3, 224, 224)."""
    rng = np.random.default_rng(46)
    xs = [rng.standard_normal((3, 224, 224)).astype(np.float32)]
    for k in range(5):
        img = np.ones((224, 224, 3), np.float32)
        for row in range(20 + k * 7, 210, 14 + k):
            img[row:row + 4, 20:20 + int(rng.integers(80, 190))] = 0.1
        img = np.rot90(img, k % 4).copy()
        xs.append(((img - MEAN) / STD).transpose(2, 0, 1))
    return np.stack(xs)


def dump():
    import paddle
    paddle.enable_static()
    exe = paddle.static.Executor(paddle.CPUPlace())
    prog, feeds, fetches = paddle.static.load_inference_model(str(MODEL_DIR / 'inference'), exe)
    scope = paddle.static.global_scope()
    params = {}
    for op in prog.global_block().ops:
        if op.name() == 'builtin.parameter':
            name = op.attrs()['parameter_name']
            params[name] = np.array(scope.find_var(name).get_tensor())
    x = reference_inputs()
    probs = exe.run(prog, feed={feeds[0]: x}, fetch_list=fetches)[0]
    WORK.mkdir(parents=True, exist_ok=True)
    np.savez(WORK / 'params.npz', **params)
    np.savez(WORK / 'reference.npz', x=x, probs=probs)
    print(f'dump: {len(params)} tensors, reference argmax {probs.argmax(1).tolist()}')


def build_torch():
    import torch
    from torch import nn

    class ConvBN(nn.Module):
        def __init__(self, cin, cout, k, stride, groups=1):
            super().__init__()
            self.conv = nn.Conv2d(cin, cout, k, stride, (k - 1) // 2, groups=groups, bias=False)
            self.bn = nn.BatchNorm2d(cout, eps=1e-5)
            self.act = nn.Hardswish()

        def forward(self, x):
            return self.act(self.bn(self.conv(x)))

    class SE(nn.Module):
        def __init__(self, c):
            super().__init__()
            self.pool = nn.AdaptiveAvgPool2d(1)
            self.conv1 = nn.Conv2d(c, c // 4, 1)
            self.conv2 = nn.Conv2d(c // 4, c, 1)

        def forward(self, x):
            s = torch.relu(self.conv1(self.pool(x)))
            return x * nn.functional.hardsigmoid(self.conv2(s))

    class Block(nn.Module):
        def __init__(self, k, cin, cout, stride, se):
            super().__init__()
            self.dw = ConvBN(cin, cin, k, stride, groups=cin)
            self.se = SE(cin) if se else nn.Identity()
            self.pw = ConvBN(cin, cout, 1, 1)

        def forward(self, x):
            return self.pw(self.se(self.dw(x)))

    class LCNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.conv1 = ConvBN(3, 16, 3, 2)
            self.blocks = nn.Sequential(*[Block(*b) for b in BLOCKS])
            self.pool = nn.AdaptiveAvgPool2d(1)
            self.last = nn.Conv2d(512, 1280, 1, bias=False)
            self.fc = nn.Linear(1280, 4)

        def forward(self, x):
            x = self.pool(self.blocks(self.conv1(x)))
            x = nn.functional.hardswish(self.last(x)).flatten(1) * 0.8   # dropout, downgrade_in_infer
            return torch.softmax(self.fc(x), dim=1)

    return LCNet()


def load_weights(model):
    import torch
    raw = np.load(WORK / 'params.npz')
    # Paddle names each tensor `<layer>.<w|b>_<n>_deepcopy_<i>`; i is creation order, which is the port's order.
    ordered = [raw[k] for k in sorted(raw.files, key=lambda k: int(k.rsplit('_', 1)[1]))]
    targets = []
    for name, t in model.state_dict().items():
        if name.endswith('num_batches_tracked'):
            continue
        targets.append((name, t))
    if len(targets) != len(ordered):
        sys.exit(f'convert: {len(targets)} port tensors, {len(ordered)} Paddle tensors')
    state = {}
    for (name, t), arr in zip(targets, ordered):
        if name == 'fc.weight':
            arr = arr.T   # Paddle's linear is (in, out)
        if tuple(t.shape) != arr.shape:
            sys.exit(f'convert: {name} {tuple(t.shape)} against {arr.shape}')
        state[name] = torch.from_numpy(np.ascontiguousarray(arr))
    model.load_state_dict(state, strict=False)
    return model.eval()


def convert():
    import coremltools as ct
    import torch
    model = load_weights(build_torch())
    ref = np.load(WORK / 'reference.npz')
    with torch.no_grad():
        got = model(torch.from_numpy(ref['x'])).numpy()
    diff = float(np.abs(got - ref['probs']).max())
    print(f'convert: port against Paddle, max |dprob| {diff:.2e}, argmax {got.argmax(1).tolist()}')
    if diff >= 1e-4:
        sys.exit('convert: the port does not match Paddle; no model written')

    class WithPrep(torch.nn.Module):
        """Input is RGB 0-255; Core ML's ImageType gives x * scale, so the per-channel std is applied here."""
        def __init__(self, inner):
            super().__init__()
            self.inner = inner
            self.register_buffer('mean', torch.tensor(MEAN * 255).view(1, 3, 1, 1))
            self.register_buffer('std', torch.tensor(STD * 255).view(1, 3, 1, 1))

        def forward(self, x):
            return self.inner((x - self.mean) / self.std)

    wrapped = WithPrep(model).eval()
    traced = torch.jit.trace(wrapped, torch.zeros(1, 3, 224, 224))
    ml = ct.convert(traced, inputs=[ct.ImageType(name='image', shape=(1, 3, 224, 224),
                                                 color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.TensorType(name='probs')], convert_to='mlprogram',
                    minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT16)
    ml.short_description = ('PP-LCNet_x1_0_doc_ori (PaddleX, Apache-2.0): how far a page is turned clockwise; '
                            'probs over 0, 90, 180, 270')
    ml.license = 'Apache-2.0 (PaddlePaddle/PaddleX)'
    ml.author = 'PaddlePaddle; converted by ArchiveProcessor/scripts/segbench/rotation_lcnet_coreml.py'
    # Check the Core ML model through the image path the app uses, against the (Paddle-exact) port on the same
    # 8-bit input. The noise input is skipped: clipped to 0-255 it is no longer the input Paddle saw.
    from PIL import Image
    worst = 0.0
    for x in ref['x'][1:]:
        rgb = np.clip((x.transpose(1, 2, 0) * STD + MEAN) * 255, 0, 255).round().astype(np.uint8)
        with torch.no_grad():
            p = wrapped(torch.from_numpy(rgb.transpose(2, 0, 1)[None].astype(np.float32))).numpy()[0]
        out = ml.predict({'image': Image.fromarray(rgb)})['probs'][0]
        worst = max(worst, float(np.abs(out - p).max()))
        if out.argmax() != p.argmax():
            sys.exit(f'convert: Core ML argmax differs from the port: {out} against {p}')
    print(f'convert: Core ML against the port (8-bit input, float16), max |dprob| {worst:.4f}')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    ml.save(str(OUT))
    print(f'convert: wrote {OUT}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['dump', 'convert'])
    {'dump': dump, 'convert': convert}[ap.parse_args().cmd]()
