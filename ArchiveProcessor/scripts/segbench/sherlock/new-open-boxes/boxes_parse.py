#!/usr/bin/env python3
"""W46.ocr-new-open-boxes: each box-emitting reader's reply as reading text plus its boxes.

The three readers answer in their own markup: Unlimited-OCR in DeepSeek-OCR's `<|ref|>`/`<|det|>` tags, Nemotron-Parse
2.0 in `<x_><y_> … <x_><y_><class_>` runs, granite-docling in DocTags. `parse(kind, model_raw, ...)` returns
`(text, boxes)`: the text is what the scorers read as a native reply (farmshare_expanded_report.reading, normal()
only), and each box is `{'cls', 'box': [x1, y1, x2, y2], 'units', 'text'}` in the model's own coordinates, with the
units named so W46.place-print converts them (Unlimited-OCR 0-999 of the image; Nemotron 0-1 of its padded
1664x2048 canvas, which `transform_bbox_to_original` in the model's postprocessing.py maps back; DocTags 0-500 of
the page). Plain Python, no model: the GPU runner (boxes_run.py) and the Mac arm both call it, and
test_boxes_parse.py checks it on hand-written replies.
"""
from __future__ import annotations

import re

# Unlimited-OCR (modeling_unlimitedocr.py, read 2026-10-31): a referenced block is <|ref|>cls<|/ref|><|det|>[[…]]<|/det|>
# followed by its text; the det-only form is <|det|>cls [x1, y1, x2, y2]<|/det|>. Coordinates are /999 of the image.
UOCR_REF = re.compile(r'<\|ref\|>(.*?)<\|/ref\|><\|det\|>(.*?)<\|/det\|>', re.S)
UOCR_DET = re.compile(r'<\|det\|>\s*([A-Za-z_][\w-]*)\s*(\[[^\]]+\])\s*<\|/det\|>', re.S)
UOCR_ANY = re.compile(r'<\|/?(?:ref|det|grounding)\|>|<｜end▁of▁sentence｜>|<\|end▁of▁sentence\|>')
NUM = re.compile(r'-?\d+(?:\.\d+)?')

# Nemotron-Parse 2.0 (postprocessing.py extract_classes_bboxes, read 2026-10-31).
NEMO = re.compile(r'<x_(\d+(?:\.\d+)?)><y_(\d+(?:\.\d+)?)>(.*?)<x_(\d+(?:\.\d+)?)><y_(\d+(?:\.\d+)?)><class_([^>]+)>', re.S)
NEMO_TAG = re.compile(r'</?s>|<pad>|<x_\d+(?:\.\d+)?>|<y_\d+(?:\.\d+)?>|<class_[^>]+>|<predict_[^>]+>|<output_[^>]+>')

# DocTags: an element is <tag><loc_a><loc_b><loc_c><loc_d>content</tag>; loc values are 0-500 of the page.
DOCTAG_EL = re.compile(r'<([a-z_]+)>((?:<loc_\d+>){4})(.*?)</\1>', re.S)
LOC = re.compile(r'<loc_(\d+)>')
DOCTAG_ANY = re.compile(r'<[^<>\s]+>')


def _boxes4(spec):
    """Every run of four numbers in a det payload ('[[a, b, c, d], [e, f, g, h]]' or 'a, b, c, d')."""
    nums = [float(x) for x in NUM.findall(spec)]
    return [nums[i:i + 4] for i in range(0, len(nums) - len(nums) % 4, 4)]


def unlimited(raw):
    """Text with every tag removed, blocks kept in emitted order; boxes from both tag forms."""
    boxes = []
    pieces = []
    pos = 0
    events = sorted([(m.start(), m.end(), m.group(1).strip(), m.group(2)) for m in UOCR_REF.finditer(raw)] +
                    [(m.start(), m.end(), m.group(1).strip(), m.group(2)) for m in UOCR_DET.finditer(raw)])
    spans = []
    for start, end, cls, spec in events:
        if spans and start < spans[-1][1]:
            continue  # a det inside a ref already taken
        spans.append((start, end, cls, spec))
    for i, (start, end, cls, spec) in enumerate(spans):
        pieces.append(raw[pos:start])
        nxt = spans[i + 1][0] if i + 1 < len(spans) else len(raw)
        body = UOCR_ANY.sub('', raw[end:nxt]).strip()
        for b in _boxes4(spec):
            boxes.append({'cls': cls, 'box': b, 'units': 'unlimited-999', 'text': body})
        pos = end
    pieces.append(raw[pos:])
    text = UOCR_ANY.sub('', ''.join(pieces))
    return _tidy(text), boxes


def nemotron(raw, postprocess_text=None):
    """Each block's text through the model's own postprocess_text (markdown text, markdown tables) when given,
    joined by blank lines in emitted order. A reply with no box runs is its text with the tags removed."""
    boxes = []
    blocks = []
    for m in NEMO.finditer(raw):
        x1, y1, body, x2, y2, cls = m.groups()
        cls = 'Formula' if cls == 'Inline-formula' else cls
        body = body.strip()
        if postprocess_text is not None:
            try:
                body = postprocess_text(body, cls=cls, text_format='markdown', table_format='markdown')
            except Exception:  # the model's table converter on a malformed table: keep the block as written
                pass
        boxes.append({'cls': cls, 'box': [float(x1), float(y1), float(x2), float(y2)], 'units': 'nemotron-canvas-1',
                      'text': body})
        blocks.append(body)
    if not boxes:
        return _tidy(NEMO_TAG.sub('', raw)), []
    return _tidy('\n\n'.join(b for b in blocks if b.strip())), boxes


def doctags_boxes(raw):
    out = []
    for m in DOCTAG_EL.finditer(raw):
        tag, locs, body = m.groups()
        out.append({'cls': tag, 'box': [float(x) for x in LOC.findall(locs)], 'units': 'doctags-500',
                    'text': _tidy(DOCTAG_ANY.sub(' ', body))})
    return out


def doctags(raw, to_markdown=None):
    """granite-docling: the text through docling-core's DocTags-to-Markdown export when given (the card's route),
    else the element texts in order with the tags removed; boxes from the element loc runs either way."""
    boxes = doctags_boxes(raw)
    if to_markdown is not None:
        return _tidy(to_markdown(raw)), boxes
    if boxes:
        return _tidy('\n\n'.join(b['text'] for b in boxes if b['text'])), boxes
    return _tidy(DOCTAG_ANY.sub(' ', raw)), boxes


def docling_markdown(raw, image):
    """The card's DocTags route: docling-core's DocTagsDocument for the (DocTags, page image) pair, exported to
    Markdown. `image` is a PIL image (the page the model read). Imported here, so the parsers above need nothing."""
    from docling_core.types.doc.document import DoclingDocument, DocTagsDocument
    pair = DocTagsDocument.from_doctags_and_image_pairs([raw], [image])
    return DoclingDocument.load_from_doctags(pair, document_name='page').export_to_markdown()


def _tidy(text):
    lines = [ln.rstrip() for ln in text.replace('\r\n', '\n').split('\n')]
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()


def parse(kind, raw, **kw):
    return {'unlimited': unlimited, 'nemotron': nemotron, 'doctags': doctags}[kind](raw, **kw)
