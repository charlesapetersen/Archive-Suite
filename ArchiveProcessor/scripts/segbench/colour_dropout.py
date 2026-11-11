#!/usr/bin/env python3
"""W46.ocr-input-colour-dropout. The colour cue, the dropout OCR input and the mark layer: pure image arithmetic, no
reader. ocr_colour_dropout.py runs the item; this module holds what an app would apply, so it is tested apart
(test_colour_dropout.py).

The cue, on an image scaled to SURVEY px on its long side:
  paper   the per-channel 95th percentile, so a cream or grey sheet counts as white and its own tint is no hue;
  n       the image divided by paper, clipped to [0, 1];
  chroma  max(n) - min(n) per pixel; luminance the mean of n;
  mark    chroma >= SAT and luminance >= 0.12, in components that touch no image edge (a table, a folder or a
          wall behind the sheet) and are under BLOB of the image each;
  ink     chroma < INK_CHROMA and luminance < INK_LUM: dark, uncoloured text;
  over    the share of mark pixels with ink within NEAR px: a stamp printed across text is high, a coloured note in
          a margin is low;
  hue     the mark pixels' dominant hue (36 bins of 10 degrees, the peak bin and its two neighbours either side) and
          the share inside it, conc: one ink is high, a colour photograph is low;
  colour_share  mark / (mark + ink): where the coloured ink is the text, it is most of the ink.

The gate (the rule an app would apply): a STAMP page has a mark of one hue over dark text, and the dark text is most
of the ink. A CONTROL page has the coloured ink as its text. Neither is a label a reader gave; both are this
arithmetic, and the item measures what the gate does on each.

The dropout input keeps the image's size (R02.2), so Vision's boxes on it apply to the reading copy: the single
channel, divided by paper, in which the mark is lightest. Red ink is near white in the red channel, blue ink in the
blue one; dark ink stays dark in every channel. The mark layer is the mark mask at full size, drawn black on white,
for a reader to read the mark's own text (kept as a mark, not as page text).
"""
from __future__ import annotations

import numpy as np

SURVEY = 800
SAT = 0.30
INK_CHROMA, INK_LUM = 0.16, 0.50
NEAR = 3                    # px at SURVEY: about a stroke's width
BLOB = 0.25
MIN_MARK = 0.0015           # of the image's pixels
MAX_MARK = 0.15
CONC = 0.60
STAMP_OVER, STAMP_SHARE, STAMP_INK = 0.15, 0.45, 0.008
CONTROL_SHARE, CONTROL_PIECES = 0.65, 40


def load(path, side=SURVEY):
    """RGB uint8 array, EXIF-upright, long side `side` (draft decoding for JPEG, so a 12 MP photo loads fast)."""
    from PIL import Image, ImageOps
    im = Image.open(path)
    if im.format == 'JPEG':
        im.draft('RGB', (side, side))
    im = ImageOps.exif_transpose(im).convert('RGB')
    s = side / max(im.size)
    if s < 1:
        im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    return np.asarray(im)


def paper(rgb):
    return np.maximum(np.percentile(rgb.reshape(-1, 3), 95, axis=0).astype(float), 1.0)


def normalised(rgb, white=None):
    white = paper(rgb) if white is None else white
    return np.clip(rgb.astype(float) / white, 0, 1)


def hue(n):
    """Hue in degrees [0, 360) of normalised RGB."""
    r, g, b = n[..., 0], n[..., 1], n[..., 2]
    mx, mn = n.max(-1), n.min(-1)
    d = np.where(mx - mn == 0, 1e-9, mx - mn)
    h = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4))
    return (h * 60) % 360


def masks(n):
    """(mark, ink) boolean masks of a normalised image."""
    from scipy import ndimage
    chroma, lum = n.max(-1) - n.min(-1), n.mean(-1)
    sat = (chroma >= SAT) & (lum >= 0.12)
    lab, k = ndimage.label(sat)
    if k:
        h, w = sat.shape
        edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
        sizes = np.bincount(lab.ravel(), minlength=k + 1)
        bad = np.zeros(k + 1, bool)
        bad[list(edge)] = True
        bad[sizes > BLOB * h * w] = True
        bad[0] = True
        sat = ~bad[lab]
    ink = (chroma < INK_CHROMA) & (lum < INK_LUM)
    return sat, ink


def dominant_hue(hues):
    """(centre in degrees, share of hues within the peak bin and two bins either side)."""
    if not len(hues):
        return None, 0.
    hist = np.bincount((hues // 10).astype(int) % 36, minlength=36)
    win = np.array([sum(hist[(i + d) % 36] for d in range(-2, 3)) for i in range(36)])
    i = int(win.argmax())
    return i * 10 + 5, float(win[i] / len(hues))


def cue(rgb):
    """The page's colour cue, a dict of plain numbers, and its class: 'stamp', 'control' or None."""
    from scipy import ndimage
    n = normalised(rgb)
    mark, ink = masks(n)
    px = mark.size
    m, k = int(mark.sum()), int(ink.sum())
    near = ndimage.binary_dilation(ink, iterations=NEAR) if k else ink
    centre, conc = dominant_hue(hue(n)[mark])
    pieces = int(ndimage.label(mark)[1]) if m else 0
    out = {'mark_frac': m / px, 'ink_frac': k / px, 'over': float((mark & near).sum() / m) if m else 0.,
           'hue': centre, 'conc': conc, 'colour_share': m / (m + k) if m + k else 0., 'pieces': pieces}
    out['class'] = classify(out)
    return out


def classify(c):
    if not (MIN_MARK <= c['mark_frac'] <= MAX_MARK) or c['conc'] < CONC:
        return None
    if c['over'] >= STAMP_OVER and c['colour_share'] <= STAMP_SHARE and c['ink_frac'] >= STAMP_INK:
        return 'stamp'
    if c['colour_share'] >= CONTROL_SHARE and c['pieces'] >= CONTROL_PIECES:
        return 'control'
    return None


def channel(rgb, mark=None):
    """The channel (0 R, 1 G, 2 B) in which the mark is lightest against paper, and the mark mask used."""
    n = normalised(rgb)
    if mark is None:
        mark, _ = masks(n)
    if not mark.any():
        return None, mark
    return int(n[mark].mean(0).argmax()), mark


def dropout(rgb, ch):
    """The OCR input: channel `ch` as it is, a grey RGB image of the same size. The plain channel, as the owner's
    note measured it on UIUC 00156; dividing it by paper first (a brighter image) was tried on 00156 alone before the
    run and lost 48 of its 157 words under the stamp in Vision, so it was not used. The channel is chosen on
    paper-normalised values (channel())."""
    g = np.ascontiguousarray(rgb[..., ch])
    return np.repeat(g[..., None], 3, -1)


def mark_layer(rgb, ch):
    """The mark alone, dark on white, same size: what a reader reads as the mark's own text. The mark's colour
    excess, channel `ch` over the brighter of the other two (paper-normalised): paper and black ink are near zero,
    the mark's ink is high. Scaled so the 99.9th percentile of the excess is full black. A hard mask of saturated
    pixels was tried first and read nothing on UIUC 00156 (the mask breaks into speckle at full size)."""
    n = normalised(rgb)
    others = np.delete(n, ch, axis=-1).max(-1)
    excess = np.clip(n[..., ch] - others, 0, None)
    top = np.percentile(excess, 99.9) or 1.
    g = 255 - (np.clip(excess / top, 0, 1) * 255).round().astype(np.uint8)
    return np.repeat(g[..., None], 3, -1)
