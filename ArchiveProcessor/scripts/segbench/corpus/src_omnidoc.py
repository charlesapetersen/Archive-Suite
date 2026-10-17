"""OmniDocBench v1.6 (huggingface.co/datasets/opendatalab/OmniDocBench), stratum N5.

1,651 annotated pages in OmniDocBench.json (42 MB): per page `page_info` (image_path, page_attribute.language and
.data_source) and `layout_dets`, blocks with a category_type, a reading `order` and `text`. Images are
images/<image_path> (PNG), redirected by Hugging Face to its CDN (allowed by the owner, 2026-10-16).

N5 is Chinese print, modern and historical: pages in simplified or traditional Chinese from books, newspapers,
magazines, research reports, historical documents and academic papers (slides, exam papers, textbooks and notes
are left out). A page with a table, a displayed equation or a masked region is left out too, because its truth
would be HTML or LaTeX, or would miss text the page shows; so is a page whose text has inline LaTeX ($ or \\).
Figures are allowed (157 pages rather than 37); words inside a figure are not in the truth.
Truth is every text block's `text`, in `order`, one block per paragraph. The collection for the quarter cap is
the data source. Licence: research use only, not commercial (the card), so scores only. Contamination 'high': a
public OCR benchmark since 2024.
"""
from __future__ import annotations

import json
import re

import common

SOURCE = 'omnidoc'
BASE = 'https://huggingface.co/datasets/opendatalab/OmniDocBench/resolve/main'
RECORD = 'https://huggingface.co/datasets/opendatalab/OmniDocBench'
LANGUAGES = {'simplified_chinese', 'traditional_chinese'}
SOURCES = {'book', 'newspaper', 'magazine', 'research_report', 'historical_document', 'academic_literature'}
NOT_TEXT = re.compile(r'^(table|equation_isolated|equation_semantic)$|_mask$')


def _pages() -> list[dict]:
    p = common.download(f'{BASE}/OmniDocBench.json', f'raw/{SOURCE}/OmniDocBench.json')
    return json.loads(p.read_text(encoding='utf-8'))


def truth(page: dict) -> str | None:
    """The page's text in reading order, or None when the page is left out (see the module docstring)."""
    blocks = page['layout_dets']
    if any(NOT_TEXT.search(b['category_type']) for b in blocks):
        return None
    texts = [(int(b['order']), (b.get('text') or '').strip()) for b in blocks
             if b.get('order') not in (None, '', 'None') and (b.get('text') or '').strip()]
    if any('$' in t or '\\' in t for _, t in texts):
        return None
    return '\n\n'.join(t for _, t in sorted(texts, key=lambda x: x[0])) or None


def candidates() -> list[common.Candidate]:
    out = []
    for page in _pages():
        info = page['page_info']
        attr = info['page_attribute']
        if attr.get('language') not in LANGUAGES or attr.get('data_source') not in SOURCES or not truth(page):
            continue
        name = info['image_path']
        out.append(common.Candidate(
            source=SOURCE, collection=attr['data_source'], page_id=name.rsplit('.', 1)[0], stratum='N5',
            licence='research use only, not commercial (OmniDocBench card)', item_url=RECORD,
            convention='OmniDocBench block text in reading order; pages with tables, equations or masks left out',
            contamination='high', publish_image=False, script='Hans' if attr['language'] == 'simplified_chinese' else 'Hant',
            era='historical' if attr['data_source'] == 'historical_document' else 'modern', kind='print',
            fetch={'image': f'{BASE}/images/{name}', 'ext': name.rsplit('.', 1)[-1].lower()}))
    return out


def materialise(c: common.Candidate):
    page = next(p for p in _pages() if p['page_info']['image_path'].rsplit('.', 1)[0] == c.page_id)
    out = common.CACHE / 'pages' / SOURCE / f"{c.page_id}.{c.fetch['ext']}"
    if not out.exists():
        common.cached(str(out.relative_to(common.CACHE)), common.get(c.fetch['image']))
    return out, truth(page)
