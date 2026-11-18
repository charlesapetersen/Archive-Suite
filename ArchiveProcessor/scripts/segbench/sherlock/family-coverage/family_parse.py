#!/usr/bin/env python3
"""W46.ocr-family-coverage: each reader's reply reduced to the page's text, on Sherlock, before it is saved.

The scorers read a record's `raw` as a native reply (farmshare_expanded_report.reading: one whole-reply code fence
stripped, nothing else), so the markup a card's output format adds is removed here, once, and the reply as written is
kept beside it as `model_raw`. Markdown is left as written, as it was for every earlier native route (Xiaomi-OCR-0,
Infinity-Parser2-Pro); HTML is reduced to its text, because a tag is not a word on the page. Page furniture
(headers, footers, page numbers) is kept wherever the model wrote it: the truth includes it.

  olmocr    YAML front matter removed (olmocr's PageResponse.natural_text), HTML tables to text, figure links removed
  chandra   HTML to text (block tags and <br> end lines, cells joined by spaces; <img> dropped)
  dots      the layout JSON's elements in emitted order (the prompt asks for reading order), Picture left out,
            Table HTML to text; a reply that does not parse (a cap cut mid-string) keeps every complete "text" value
  deepseek  DeepSeek-OCR's <|ref|>/<|det|> grounding tags removed (Unlimited-OCR's rule, boxes_parse.unlimited)
  churro    CHURRO's reference XML extraction (farmshare_results.churro_text, copied: the pack carries no corpus code)
  mineru    MinerU2.5's two-step blocks in emitted order, image blocks left out, table HTML to text
"""
from html.parser import HTMLParser
from pathlib import Path
import json
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'new-open-boxes'))
import boxes_parse as B  # noqa: E402

BLOCK = {'p', 'div', 'br', 'li', 'tr', 'table', 'thead', 'tbody', 'ul', 'ol', 'blockquote', 'pre', 'hr', 'section',
         'header', 'footer', 'article', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'caption', 'figure', 'figcaption', 'dl',
         'dt', 'dd', 'center'}
CELL = {'td', 'th'}
SKIP = {'img', 'script', 'style'}
HTML_TAG = re.compile(r'</?(table|tr|td|th|br|div|p|span|b|i|u|sup|sub|ul|ol|li|h[1-6]|math|img)\b[^>]*>', re.I)


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip += tag != 'img'  # <img> is a void element: nothing to skip after it
        elif tag in BLOCK:
            self.out.append('\n')
        elif tag in CELL:
            self.out.append(' ')

    def handle_startendtag(self, tag, attrs):
        if tag in BLOCK:
            self.out.append('\n')

    def handle_endtag(self, tag):
        if tag in SKIP and tag != 'img':
            self.skip = max(0, self.skip - 1)
        elif tag in BLOCK:
            self.out.append('\n')
        elif tag in CELL:
            self.out.append(' ')

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)


def html_text(s):
    """The text of an HTML fragment, one line per block element, cells separated by spaces."""
    p = _Text()
    p.feed(s)
    p.close()
    return tidy(''.join(p.out))


def tidy(s):
    lines = [re.sub(r'[ \t ]+', ' ', x).strip() for x in s.replace('\r', '').split('\n')]
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()


def html_if_any(s):
    return html_text(s) if HTML_TAG.search(s) else tidy(s)


FRONT = re.compile(r'\A\s*---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)', re.S)
FIGURE = re.compile(r'!\[[^\]]*\]\([^)]*\)')


def olmocr(raw):
    m = FRONT.match(raw)
    body = raw[m.end():] if m else raw
    return html_if_any(FIGURE.sub('', body)), []


def chandra(raw):
    return html_text(raw), []


DOTS_TEXT = re.compile(r'"text"\s*:\s*("(?:[^"\\]|\\.)*")')


def dots(raw):
    s = raw.strip()
    fence = re.match(r'\A```[A-Za-z]*\s*\n(.*?)\n?```\s*\Z', s, re.S)
    if fence:
        s = fence.group(1)
    try:
        items = json.loads(s)
        if isinstance(items, dict):
            items = items.get('layout') or items.get('elements') or [items]
        if not isinstance(items, list):
            raise ValueError('not a list')
    except (ValueError, json.JSONDecodeError):
        # A reply cut at the token cap: every complete text value, in order; no boxes, since a box may lack its text.
        texts = []
        for m in DOTS_TEXT.finditer(s):
            try:
                texts.append(json.loads(m.group(1)))
            except json.JSONDecodeError:
                continue
        return tidy('\n\n'.join(html_if_any(t) for t in texts if t.strip())), []
    blocks, boxes = [], []
    for it in items:
        if not isinstance(it, dict):
            continue
        cls = str(it.get('category', ''))
        text = it.get('text') or ''
        if cls == 'Picture' or not isinstance(text, str):
            text = ''
        text = html_if_any(text) if cls == 'Table' or HTML_TAG.search(text) else tidy(text)
        if isinstance(it.get('bbox'), list) and len(it['bbox']) == 4:
            boxes.append({'cls': cls, 'box': it['bbox'], 'units': 'dots-px', 'text': text})
        if text:
            blocks.append(text)
    return tidy('\n\n'.join(blocks)), boxes


def deepseek(raw):
    text, boxes = B.unlimited(raw)
    for b in boxes:
        b['units'] = 'deepseek-999'
    return text, boxes


def churro(raw):
    """CHURRO's reference XML extraction: Page Header/Body/Footer, excluding descriptive metadata.
    A copy of farmshare_results.churro_text (test_family_parse checks they agree)."""
    if 'HistoricalDocument' not in raw:
        return raw.strip(), []
    for tag in ('Description', 'Deletion', 'Illegible', 'Gap'):
        raw = re.sub(rf'<{tag}\b[^>]*>.*?</{tag}>', '', raw, flags=re.DOTALL)
        raw = re.sub(rf'<{tag}\b[^>]*/>', '', raw)
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return '', []
    name = lambda el: el.tag.rsplit('}', 1)[-1]  # noqa: E731
    pages = []
    for page in root.iter():
        if name(page) != 'Page':
            continue
        sections = []
        for child in page.iter():
            if name(child) in {'Header', 'Body', 'Footer'}:
                lines = [t.strip() for t in child.itertext() if t.strip()]
                if lines:
                    sections.append('\n'.join(lines))
        if sections:
            pages.append('\n'.join(sections))
    return '\n\n'.join(pages).strip(), []


def mineru(blocks):
    """MinerU2.5 ContentBlocks (or their dicts): type, bbox in 0-1 of the page, content."""
    texts, boxes = [], []
    for b in blocks:
        d = b if isinstance(b, dict) else {k: getattr(b, k, None) for k in ('type', 'bbox', 'angle', 'content')}
        kind, content = str(d.get('type') or ''), d.get('content')
        text = '' if kind in ('image', 'chart') or not isinstance(content, str) else html_if_any(content)
        if d.get('bbox') is not None:
            boxes.append({'cls': kind, 'box': list(d['bbox']), 'units': 'mineru-unit', 'text': text})
        if text:
            texts.append(text)
    return tidy('\n\n'.join(texts)), boxes


REDUCE = {'olmocr': olmocr, 'chandra': chandra, 'dots': dots, 'deepseek': deepseek, 'churro': churro}
