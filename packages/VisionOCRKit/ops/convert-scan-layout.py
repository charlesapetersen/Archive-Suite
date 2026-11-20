"""convert-scan-layout.py — newspaper-ocr's DocLayout-YOLO checkpoint to the Core ML model `ScanNewspaperLayout` runs.

    python convert-scan-layout.py <weights.pt> <out.mlpackage>

Called by make-scan-newspaper-layout.sh, which fetches the weights, compiles the package and makes the download.
Weights: `juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501`, `doclayout_yolo_docstructbench_imgsz1280_2501.pt`
(AGPL-3.0), the default checkpoint of newspaper-ocr 0.11.0 (`detectors/doclayout.py`, `DEFAULT_VARIANT`), which
W46.ocr-regions measured (W47.wh-yolo-scans). The same conversion as the vision-ocr lab's `convert-layout.py` for the
1,024 checkpoint the regions arrangement runs, with the input range raised to 1,280 a side: the one-to-one head before
selection, `[1, 14, anchors]` (left, top, right, bottom in grid cells, then 10 class scores); the app makes the anchors
and the top-300 selection (`LayoutModel.decode`). Measured in a venv of torch 2.7.0, torchvision 0.22.0, coremltools
9.0 and doclayout-yolo 0.0.4.
"""
import sys, torch, coremltools as ct
from doclayout_yolo import YOLOv10
from doclayout_yolo.nn.modules import block, head

SIDE = 1280


def raw(self, x):
    y = self.forward_feat([xi.detach() for xi in x], self.one2one_cv2, self.one2one_cv3)
    box, cls = torch.cat([yi.flatten(2) for yi in y], 2).split((self.reg_max * 4, self.nc), 1)
    return torch.cat((self.dfl(box), cls.sigmoid()), 1)


def attention(self, x):
    q, k, v = self.qkv(x).flatten(2).unflatten(1, (self.num_heads, -1)).split(
        [self.key_dim, self.key_dim, self.head_dim], dim=2)
    attn = ((q.transpose(-2, -1) @ k) * self.scale).softmax(dim=-1)
    return self.proj((v @ attn.transpose(-2, -1)).flatten(1, 2).reshape_as(x) + self.pe(v.flatten(1, 2).reshape_as(x)))


head.v10Detect.forward = raw
block.Attention.forward = attention
_load = torch.load
torch.load = lambda *a, **k: _load(*a, **{**k, 'weights_only': False})   # the checkpoint pickles its model class
net = YOLOv10(sys.argv[1]).model.float().eval()
torch.load = _load
names = [net.names[i] for i in range(len(net.names))]
assert names == ['title', 'plain text', 'abandon', 'figure', 'figure_caption', 'table', 'table_caption',
                 'table_footnote', 'isolate_formula', 'formula_caption'], names


class Wrap(torch.nn.Module):
    def __init__(self, n):
        super().__init__(); self.n = n

    def forward(self, x):
        y = self.n(x)
        return y[0] if isinstance(y, (tuple, list)) else y


traced = torch.jit.trace(Wrap(net).eval(), torch.rand(1, 3, SIDE, 960), check_trace=False, strict=False)
side = lambda d: ct.RangeDim(32, SIDE, default=d)
ml = ct.convert(traced, inputs=[ct.TensorType(name="images", shape=(1, 3, side(SIDE), side(960)))],
                outputs=[ct.TensorType(name="raw")], convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                minimum_deployment_target=ct.target.macOS13, skip_model_load=True)
ml.short_description = ("DocLayout-YOLO DocStructBench imgsz1280-2501 (AGPL-3.0, "
                        "juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501): one-to-one head, [1, 14, anchors]: "
                        "ltrb distances in grid cells, then 10 class scores")
ml.license = "AGPL-3.0"
ml.save(sys.argv[2])
