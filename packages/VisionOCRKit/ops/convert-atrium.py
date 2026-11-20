"""convert-atrium.py — ATRIUM's page classifier to the Core ML model `MixedPagePreflag` runs (W47.wh-mixed-preflag).

    python convert-atrium.py <out.mlpackage>

Called by make-atrium.sh, which compiles the package and makes the download. Weights: `ufal/vit-historical-page` at
revision 543216d6b7e1 (v4.3, timm regnety_160, eleven classes; the card says MIT, its SWAG RegNetY-16GF base weights are CC BY-NC 4.0), the revision W46.kind-atrium and
W46.mixed-def measured. The model takes the page already squeezed to 384 x 384 as RGB in 0-1 (`pixels`) and does the
ImageNet normalisation itself, so the app only resizes; it returns the eleven softmax probabilities (`probs`), in
ATRIUM_CLASSES order. The bench's mixed call is the top class being TEXT. Measured in the shared torch env
(`segbench/torch-env.sh`: torch 2.15.0, timm 1.0.31, coremltools 9.0).
"""
import sys, torch, timm, coremltools as ct
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file

REPO = 'ufal/vit-historical-page'
REV = '543216d6b7e12552b164372e9124ceb168b06b98'
CLASSES = ('DRAW', 'DRAW_L', 'LINE_HW', 'LINE_P', 'LINE_T', 'PHOTO', 'PHOTO_L', 'TEXT', 'TEXT_HW', 'TEXT_P', 'TEXT_T')
SIDE = 384
MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)


class Wrap(torch.nn.Module):
    def __init__(self, n):
        super().__init__()
        self.n = n
        self.register_buffer('mean', torch.tensor(MEAN).reshape(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor(STD).reshape(1, 3, 1, 1))

    def forward(self, x):
        return torch.softmax(self.n((x - self.mean) / self.std), 1)


def model():
    m = timm.create_model('regnety_160', num_classes=len(CLASSES), pretrained=False)
    m.load_state_dict(load_file(hf_hub_download(REPO, 'model.safetensors', revision=REV)))
    return m.eval()


if __name__ == '__main__':
    net = Wrap(model()).eval()
    traced = torch.jit.trace(net, torch.rand(1, 3, SIDE, SIDE))
    ml = ct.convert(traced, inputs=[ct.TensorType(name='pixels', shape=(1, 3, SIDE, SIDE))],
                    outputs=[ct.TensorType(name='probs')], convert_to='mlprogram',
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS13)
    ml.short_description = ('ATRIUM page classifier (ufal/vit-historical-page v4.3, revision 543216d6b7e1; MIT, base weights CC BY-NC 4.0): '
                            'RGB 0-1 at 384 x 384 in, eleven class probabilities out: ' + ' '.join(CLASSES))
    ml.license = 'MIT (ATRIUM); base weights timm/regnety_160.swag_ft_in1k CC BY-NC 4.0'
    ml.save(sys.argv[1])
