"""W41.farmshare-news-layout. Layout-first newspaper reading: the pipeline behind NewsBench's 0.970 row.

That row (`glm-ocr-doclayout`) is the `newspaper-ocr` library run with DocLayout-YOLO finding the regions and GLM-OCR
reading each one, in the library's reading order. Its own docstring gives the figure (DocLayout-YOLO + GLM-OCR 0.970
against PaddleX + GLM-OCR 0.937). This module runs that pipeline unchanged, with two differences that only concern
speed: GLM-OCR is served by vLLM on the same GPU (the library's `api` mode) instead of loaded into transformers, and a
page's regions are sent to the server at the same time instead of one after another. vLLM applies the checkpoint's
own generation defaults, as transformers' generate() did in the measured run.

cluster_ocr.py uses LayoutReader in place of its panel Server when a mode is given --layout (the `glm-ocr` preset sets it).
LayoutReader.read() returns the Server's (reply, meta) shape, so run_all, scoring, resume and the dead-server stop are
the same code for both routes. Needs `bash setup.sh --layout` (newspaper-ocr and doclayout-yolo in the venv).
"""
from __future__ import annotations
from collections import Counter
import concurrent.futures as cf
import io
import threading
import time

NPO_VERSION = '0.11.0'      # the version setup.sh --layout installs; its docstring states the 0.970
REGION_TIMEOUT = 600        # s per region request; regions queue behind each other on the server
REGION_WORKERS = 48         # region requests in flight across all pages at once


def open_rgb(src):
    """A page as an RGB PIL image, at full resolution: the detector and GLM-OCR crop from the original scan.
    src: a path or the image's bytes. Raises on a file Pillow cannot read (run_all makes that the page's failure)."""
    from PIL import Image
    im = Image.open(io.BytesIO(src) if isinstance(src, (bytes, bytearray)) else src)
    im.load()
    return im.convert('RGB')


class LockedDetector:
    """One page detected at a time: the YOLO model is shared by the page threads, and detection is the short step."""
    def __init__(self, inner):
        self.inner, self.lock = inner, threading.Lock()

    def detect(self, image):
        with self.lock:
            return self.inner.detect(image)


def concurrent_recognizer(workers=REGION_WORKERS, **kw):
    """GlmOcrRecognizer that reads a page's regions concurrently, through the library's own `recognize_regions`
    hook (Pipeline.analyze calls it when present). Each region still goes through the library's recognize(): its
    retries, the code-fence strip and the repetition check are unchanged."""
    from newspaper_ocr.recognizers.glm_ocr import GlmOcrRecognizer

    class ConcurrentGlmOcr(GlmOcrRecognizer):
        def __init__(self):
            super().__init__(**kw)
            self.pool = cf.ThreadPoolExecutor(workers)

        def recognize_regions(self, page_image, regions):
            return list(self.pool.map(self.recognize, regions))

    return ConcurrentGlmOcr()


def build_pipeline(url, model, detector=None, workers=REGION_WORKERS, timeout=REGION_TIMEOUT):
    """The 0.970 configuration: the library's defaults, DocLayout-YOLO (its default 1280 checkpoint), GLM-OCR.
    `model` is the served name vLLM answers to (the library sends it as `mlx_model_id`)."""
    from newspaper_ocr import Pipeline
    if detector is None:
        from newspaper_ocr.detectors.doclayout import DocLayoutYoloDetector
        detector = DocLayoutYoloDetector()
    rec = concurrent_recognizer(workers, mode='api', api_url=url.rstrip('/') + '/v1/chat/completions',
                                model_id=model, mlx_model_id=model, timeout=timeout)
    return Pipeline(detector=LockedDetector(detector), recognizer=rec)


class LayoutReader:
    """cluster_ocr.Server's interface over the layout pipeline. read(image) -> (reply, meta), where meta['status'] is:
    ok       every region answered (a region the library marked timeout or repetition is kept, as the measured
             run kept it; the counts are in meta['region_status'])
    error    no region answered: the server is gone, the page is still to do (cluster_ocr's dead-server rule counts these)
    partial  some regions got no answer: not written as done, so a rerun reads the page again
    empty    no text on the page at all
    failed   the pipeline raised (the message is in meta['error'])"""

    def __init__(self, pipeline):
        self.pipe = pipeline

    def read(self, image, timeout=None):  # timeout: the per-region one applies; kept for Server's signature
        t0 = time.time()
        try:
            layout = self.pipe.analyze(image)
            text = self.pipe.formatter.format(layout)
        except Exception as e:
            return None, {'status': 'failed', 'error': repr(e)[:300], 'wall_s': round(time.time() - t0, 3)}
        st = Counter(r.status for r in layout.regions)
        n = len(layout.regions)
        status = ('error' if n and st['error'] == n else 'partial' if st['error'] else
                  'empty' if not text.strip() else 'ok')
        meta = {'status': status, 'regions': n, 'region_status': dict(st), 'finish': None,
                'prompt_tokens': None, 'completion_tokens': None, 'wall_s': round(time.time() - t0, 3)}
        parsed = {'text': text, 'kind': 'newspaper', 'table': None} if status == 'ok' else None
        return {'raw': text, 'parsed': parsed}, meta


def versions():
    from importlib import metadata
    out = {}
    for pkg in ('newspaper-ocr', 'doclayout-yolo'):
        try:
            out[pkg] = metadata.version(pkg)
        except metadata.PackageNotFoundError:
            out[pkg] = None
    return out
