"""model_store.py — the one Hugging Face cache the Mac-local segbench scripts load open models from.

On 30 Oct 2026 the same MLX models sat in three caches: ~/.cache/huggingface (a script that set no HF_HOME),
the Vision OCR lab's ~/.local/share/visionocr-ocrlab/hf and the bench cache's mlx-hf, 11.9 GB of duplicate blobs
with the disk at 11 GB free. They were merged into mlx-hf, and the lab's hf/hub is now a link to it.
ops/autonomous/README.md §"The bench cache" says what lives where.

    import model_store; model_store.use()            # before mlx_vlm.load(repo id)
    model_store.snapshot(repo, revision)             # a snapshot's folder, to load by path
"""
import os
import sys
from pathlib import Path

HF_HOME = Path(os.environ.get('ARCHIVE_MODEL_HF_HOME', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/mlx-hf'))
HUB = HF_HOME / 'hub'


def use():
    """Point huggingface_hub at the shared cache, unless the caller already chose one. huggingface_hub reads
    HF_HOME once, when it is imported (mlx_vlm imports it), so this runs before that import. Until 30 Oct four
    scripts set HF_HOME after importing mlx_vlm, read ~/.cache/huggingface instead, and downloaded there."""
    os.environ.setdefault('HF_HOME', str(HF_HOME))
    hub = sys.modules.get('huggingface_hub.constants')
    want = os.environ.get('HF_HUB_CACHE', os.path.join(os.environ['HF_HOME'], 'hub'))
    if hub is not None and os.path.realpath(hub.HF_HUB_CACHE) != os.path.realpath(want):
        raise RuntimeError(f'huggingface_hub was imported before model_store.use(); it reads {hub.HF_HUB_CACHE}')


def snapshot(repo, revision):
    return HUB / ('models--' + repo.replace('/', '--')) / 'snapshots' / revision
