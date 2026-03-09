"""
Archive Processor App
==============
• Pick a JPG → Claude Vision OCRs it → saves a 2-page PDF
  Page 1: the original image  |  Page 2: the extracted text

Requirements (run once before using):
    pip install anthropic google-genai reportlab Pillow beautifulsoup4 tkinterdnd2

Usage:
    python archive_processor.py
    (or double-click it on macOS/Windows if Python is associated with .py files)

You'll need an Anthropic API key: https://console.anthropic.com/
"""

import base64
import io
import json
import math
import os
import shutil
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed


class RecitationError(Exception):
    """Raised when the model refuses to transcribe due to copyright/recitation."""
    pass

# ---------------------------------------------------------------------------
# HTML → ReportLab helpers
# ---------------------------------------------------------------------------

def _inline_markup(tag) -> str:
    """Recursively convert a BeautifulSoup tag's children to ReportLab inline XML."""
    from bs4 import NavigableString, Tag
    parts = []
    for child in tag.children:
        if isinstance(child, NavigableString):
            text = str(child)
            text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            parts.append(text)
        elif isinstance(child, Tag):
            inner = _inline_markup(child)
            name = child.name
            if name in ("b", "strong"):
                parts.append(f"<b>{inner}</b>")
            elif name in ("i", "em"):
                parts.append(f"<i>{inner}</i>")
            elif name == "u":
                parts.append(f"<u>{inner}</u>")
            elif name == "br":
                parts.append("<br/>")
            elif name == "sup":
                parts.append(f"<super>{inner}</super>")
            elif name == "sub":
                parts.append(f"<sub>{inner}</sub>")
            else:
                parts.append(inner)
    return "".join(parts)


def _table_flowable(table_tag, col_width: float, cell_style):
    """Convert a <table> BeautifulSoup element to a ReportLab Table flowable."""
    from reportlab.platypus import Table, TableStyle, Paragraph
    from reportlab.lib import colors

    rows_data, header_indices = [], []
    for tr in table_tag.find_all("tr"):
        cells = tr.find_all(["td", "th"])
        if not cells:
            continue
        if any(c.name == "th" for c in cells):
            header_indices.append(len(rows_data))
        rows_data.append(
            [Paragraph(_inline_markup(c).strip() or " ", cell_style) for c in cells]
        )

    if not rows_data:
        return None

    n_cols = max(len(r) for r in rows_data)
    for row in rows_data:
        while len(row) < n_cols:
            row.append(Paragraph(" ", cell_style))

    col_w = col_width / n_cols
    style_cmds = [
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.grey),
        ("VALIGN",        (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING",    (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING",   (0, 0), (-1, -1), 6),
        ("RIGHTPADDING",  (0, 0), (-1, -1), 6),
    ]
    for idx in header_indices:
        style_cmds += [
            ("BACKGROUND", (0, idx), (-1, idx), colors.HexColor("#E8E8E8")),
            ("FONTNAME",   (0, idx), (-1, idx), "Helvetica-Bold"),
        ]
    tbl = Table(rows_data, colWidths=[col_w] * n_cols, repeatRows=len(header_indices))
    tbl.setStyle(TableStyle(style_cmds))
    return tbl


def _markdown_to_html(md: str) -> str:
    """Convert Mistral-style Markdown (with optional inline HTML tables) to HTML.

    Handles headings, bold, italic, code spans, fenced code blocks,
    unordered/ordered lists, and plain paragraphs.  HTML blocks (e.g.
    ``<table>…</table>``) are passed through unchanged.
    """
    import re

    lines = md.split("\n")
    html_parts: list[str] = []
    i = 0

    def _inline(text: str) -> str:
        """Convert inline Markdown formatting to HTML."""
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"__(.+?)__", r"<strong>\1</strong>", text)
        text = re.sub(r"\*(.+?)\*", r"<em>\1</em>", text)
        text = re.sub(r"_(.+?)_", r"<em>\1</em>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        return text

    while i < len(lines):
        line = lines[i]

        # Blank line — skip
        if not line.strip():
            i += 1
            continue

        # Fenced code block
        if line.strip().startswith("```"):
            code_lines: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing ```
            escaped = ("\n".join(code_lines)
                       .replace("&", "&amp;")
                       .replace("<", "&lt;")
                       .replace(">", "&gt;"))
            html_parts.append(f"<pre>{escaped}</pre>")
            continue

        # HTML block (e.g. <table>…</table>) — pass through unchanged
        stripped = line.strip()
        if stripped.startswith("<") and not stripped.startswith("<!"):
            # Collect until closing tag or until we hit a non-HTML line
            tag_match = re.match(r"<(\w+)", stripped)
            if tag_match:
                tag_name = tag_match.group(1).lower()
                block_lines = [line]
                # If not self-closing, gather until closing tag
                if f"</{tag_name}>" not in stripped:
                    i += 1
                    while i < len(lines):
                        block_lines.append(lines[i])
                        if f"</{tag_name}>" in lines[i]:
                            i += 1
                            break
                        i += 1
                    else:
                        pass  # EOF reached
                else:
                    i += 1
                html_parts.append("\n".join(block_lines))
                continue

        # ATX heading
        heading_m = re.match(r"^(#{1,6})\s+(.*)", line)
        if heading_m:
            level = min(len(heading_m.group(1)), 3)
            html_parts.append(
                f"<h{level}>{_inline(heading_m.group(2).strip())}</h{level}>")
            i += 1
            continue

        # Unordered list
        if re.match(r"^\s*[-*+]\s+", line):
            items: list[str] = []
            while i < len(lines) and re.match(r"^\s*[-*+]\s+", lines[i]):
                items.append(re.sub(r"^\s*[-*+]\s+", "", lines[i]))
                i += 1
            html_parts.append(
                "<ul>" + "".join(f"<li>{_inline(it)}</li>" for it in items) + "</ul>")
            continue

        # Ordered list
        if re.match(r"^\s*\d+[.)]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\s*\d+[.)]\s+", lines[i]):
                items.append(re.sub(r"^\s*\d+[.)]\s+", "", lines[i]))
                i += 1
            html_parts.append(
                "<ol>" + "".join(f"<li>{_inline(it)}</li>" for it in items) + "</ol>")
            continue

        # Plain paragraph — collect consecutive non-blank, non-special lines
        para_lines: list[str] = []
        while (i < len(lines)
               and lines[i].strip()
               and not lines[i].strip().startswith("#")
               and not lines[i].strip().startswith("```")
               and not re.match(r"^\s*[-*+]\s+", lines[i])
               and not re.match(r"^\s*\d+[.)]\s+", lines[i])
               and not (lines[i].strip().startswith("<")
                        and re.match(r"<\w+", lines[i].strip()))):
            para_lines.append(lines[i])
            i += 1
        if para_lines:
            html_parts.append(f"<p>{_inline(' '.join(para_lines))}</p>")

    return "\n".join(html_parts)


def _html_to_flowables(html_text: str, style_map: dict, usable_w: float) -> list:
    """Convert an HTML string into a list of ReportLab flowables."""
    from reportlab.platypus import Paragraph, Spacer
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import inch
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        raise ImportError("beautifulsoup4 is required: pip install beautifulsoup4")

    # Guard: if html_text is None or empty, return a single note paragraph
    if not html_text:
        return [Paragraph(
            "<i>No text was extracted from this image. The model may have "
            "refused the image, returned an empty response, or the image "
            "may not contain readable text.</i>",
            style_map["body"],
        )]

    # List-item style: indented body text — avoids ListFlowable which needs a canvas
    li_style = ParagraphStyle(
        "OCRLi", parent=style_map["body"],
        leftIndent=20, firstLineIndent=-12, spaceAfter=2,
    )

    soup = BeautifulSoup(html_text, "html.parser")
    body = soup.find("body") or soup
    flowables = []

    def process(el):
        name = getattr(el, "name", None)
        if not name:
            return

        if name in ("h1", "h2", "h3", "h4", "h5", "h6"):
            key = f"h{min(int(name[1]), 3)}"
            markup = _inline_markup(el).strip()
            if markup:
                flowables.append(Paragraph(markup, style_map[key]))
                flowables.append(Spacer(1, 0.06 * inch))

        elif name == "p":
            markup = _inline_markup(el).strip()
            if markup:
                flowables.append(Paragraph(markup, style_map["body"]))

        elif name in ("ul", "ol"):
            for i, li in enumerate(el.find_all("li", recursive=False)):
                markup = _inline_markup(li).strip()
                if markup:
                    prefix = "&#x2022;" if name == "ul" else f"{i + 1}."
                    flowables.append(Paragraph(f"{prefix}  {markup}", li_style))
            flowables.append(Spacer(1, 0.05 * inch))

        elif name == "table":
            tbl = _table_flowable(el, usable_w, style_map["body"])
            if tbl:
                flowables.append(tbl)
                flowables.append(Spacer(1, 0.1 * inch))

        elif name in ("pre", "code"):
            text = el.get_text()
            safe = (
                text.replace("&", "&amp;")
                    .replace("<", "&lt;")
                    .replace(">", "&gt;")
                    .replace("\n", "<br/>")
            )
            flowables.append(Paragraph(safe, style_map["code"]))
            flowables.append(Spacer(1, 0.05 * inch))

        elif name in ("div", "section", "article", "main", "body", "html"):
            for child in el.children:
                process(child)
        # skip: script, style, head, meta, etc.

    for child in body.children:
        process(child)

    return flowables


# ---------------------------------------------------------------------------
# PDF builder
# ---------------------------------------------------------------------------

def build_pdf(jpg_path: str, ocr_text: str, out_path: str,
              provider: str = "", model: str = "") -> None:
    """Create a 2-page PDF: page 1 = image, page 2 = rich OCR text (expands to fit)."""
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.lib import colors
    from reportlab.platypus import (
        BaseDocTemplate, Frame, PageTemplate, NextPageTemplate,
        Image, PageBreak, Paragraph, Spacer,
    )
    from PIL import Image as PILImage

    page_w, page_h = letter
    margin = 0.75 * inch
    frame_pad = 6  # Frame default padding (each side)
    usable_w = page_w - 2 * margin - 2 * frame_pad
    usable_h = page_h - 2 * margin - 2 * frame_pad

    # Scale image to fit within usable area, keeping aspect ratio
    with PILImage.open(jpg_path) as img:
        img_w, img_h = img.size
    scale = min(usable_w / img_w, usable_h / img_h)
    draw_w, draw_h = img_w * scale, img_h * scale

    # --- Paragraph styles ------------------------------------------------
    base = getSampleStyleSheet()
    body_style = ParagraphStyle(
        "OCRBody", parent=base["Normal"],
        fontSize=11, leading=16, spaceAfter=6, wordWrap="CJK",
    )
    h1_style = ParagraphStyle(
        "OCRH1", parent=base["Normal"],
        fontSize=18, leading=22, fontName="Helvetica-Bold",
        spaceBefore=12, spaceAfter=6,
    )
    h2_style = ParagraphStyle(
        "OCRH2", parent=base["Normal"],
        fontSize=15, leading=19, fontName="Helvetica-Bold",
        spaceBefore=10, spaceAfter=5,
    )
    h3_style = ParagraphStyle(
        "OCRH3", parent=base["Normal"],
        fontSize=13, leading=17, fontName="Helvetica-Bold",
        spaceBefore=8, spaceAfter=4,
    )
    code_style = ParagraphStyle(
        "OCRCode", parent=base["Normal"],
        fontSize=9, leading=12, fontName="Courier",
        backColor=colors.HexColor("#F4F4F4"),
        leftIndent=12, rightIndent=12, spaceAfter=4,
    )
    page_heading_style = ParagraphStyle(
        "OCRPageHeading", parent=base["Normal"],
        fontSize=14, leading=18, spaceBefore=0, spaceAfter=12, keepWithNext=0,
    )
    style_map = {
        "body": body_style,
        "h1": h1_style, "h2": h2_style, "h3": h3_style,
        "code": code_style,
    }

    subtitle_style = ParagraphStyle(
        "OCRSubtitle", parent=base["Normal"],
        fontSize=9, leading=12, fontName="Helvetica",
        textColor=colors.HexColor("#666666"),
        spaceBefore=0, spaceAfter=10,
    )

    import datetime
    today = datetime.date.today()
    date_str = today.strftime("%-d %B %Y")
    subtitle_parts = [p for p in [provider, model, date_str] if p]
    subtitle_text = " · ".join(subtitle_parts)

    # --- Build text flowables from HTML ----------------------------------
    text_flowables = [
        Paragraph("Extracted Text", page_heading_style),
    ]
    if subtitle_text:
        text_flowables.append(Paragraph(subtitle_text, subtitle_style))
    text_flowables.append(Spacer(1, 0.1 * inch))
    text_flowables += _html_to_flowables(ocr_text, style_map, usable_w)

    # --- Measure total height required -----------------------------------
    content_h = 0
    for f in text_flowables:
        _, h = f.wrap(usable_w, float("inf"))
        content_h += h
        if hasattr(f, "style"):
            content_h += getattr(f.style, "spaceAfter", 0)
            content_h += getattr(f.style, "spaceBefore", 0)

    # Text page grows as needed; never shrinks below letter height
    text_page_h = max(page_h, content_h + 2 * margin + 2 * frame_pad)

    # --- Page templates --------------------------------------------------
    img_frame  = Frame(margin, margin, page_w - 2*margin, page_h      - 2*margin, id="normal")
    text_frame = Frame(margin, margin, page_w - 2*margin, text_page_h - 2*margin, id="normal")

    doc = BaseDocTemplate(
        out_path, pagesize=letter,
        leftMargin=margin, rightMargin=margin,
        topMargin=margin, bottomMargin=margin,
    )
    doc.addPageTemplates([
        PageTemplate(id="ImagePage", frames=[img_frame], pagesize=letter),
        PageTemplate(id="TextPage",  frames=[text_frame], pagesize=(page_w, text_page_h)),
    ])

    story = [
        Image(jpg_path, width=draw_w, height=draw_h),
        NextPageTemplate("TextPage"),
        PageBreak(),
    ] + text_flowables
    doc.build(story)


# ---------------------------------------------------------------------------
# OCR back-ends
# ---------------------------------------------------------------------------

_CLAUDE_MAX_B64 = 4_900_000  # Claude's hard limit is 5 MB; stay comfortably under it


def _compress_to_limit(jpg_path: str, max_b64: int = _CLAUDE_MAX_B64):
    """Return (bytes, mime_type), compressing with PIL if the base64 size exceeds max_b64."""
    from PIL import Image as PILImage

    lower = jpg_path.lower()
    if lower.endswith(".png"):
        mime_type = "image/png"
    elif lower.endswith(".gif"):
        mime_type = "image/gif"
    elif lower.endswith(".webp"):
        mime_type = "image/webp"
    else:
        mime_type = "image/jpeg"

    with open(jpg_path, "rb") as f:
        raw = f.read()

    if len(base64.standard_b64encode(raw)) <= max_b64:
        return raw, mime_type  # already small enough

    # Compress to JPEG, iteratively reducing quality then scale until it fits
    img = PILImage.open(jpg_path)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    quality, scale = 85, 1.0
    while True:
        buf = io.BytesIO()
        w = max(1, int(img.width  * scale))
        h = max(1, int(img.height * scale))
        out = img.resize((w, h), PILImage.LANCZOS) if scale < 1.0 else img
        out.save(buf, format="JPEG", quality=quality)
        data = buf.getvalue()
        if len(base64.standard_b64encode(data)) <= max_b64:
            return data, "image/jpeg"
        if quality > 40:
            quality -= 15
        else:
            scale *= 0.75


# Shared prompt used by every provider
_OCR_PROMPT = (
    "Transcribe all text visible in this image as HTML, preserving "
    "the original document's structure and formatting as closely as possible.\n\n"
    "Use these HTML elements:\n"
    "  • <h1>–<h3> for headings (match their visual prominence)\n"
    "  • <p> for body paragraphs\n"
    "  • <table>, <tr>, <th>, <td> for tables\n"
    "  • <ul>/<ol> and <li> for bullet or numbered lists\n"
    "  • <strong> for bold, <em> for italic, <u> for underlined text\n"
    "  • <pre> for monospaced or code blocks\n\n"
    "Return only the HTML — no code fences, no commentary, "
    "no surrounding <html> or <body> tags."
)


def ocr_with_claude(jpg_path: str, api_key: str,
                    model: str = "claude-opus-4-6") -> str:
    """Send the image to Claude Vision and return extracted HTML."""
    import anthropic

    raw, media_type = _compress_to_limit(jpg_path)
    image_data = base64.standard_b64encode(raw).decode("utf-8")

    client = anthropic.Anthropic(api_key=api_key)
    message = client.messages.create(
        model=model,
        max_tokens=4096,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": media_type,
                            "data": image_data,
                        },
                    },
                    {"type": "text", "text": _OCR_PROMPT},
                ],
            }
        ],
    )
    return message.content[0].text


def ocr_with_gemini(jpg_path: str, api_key: str,
                    model: str = "gemini-2.5-flash",
                    thinking_budget: int = 1_024) -> str:
    """Send the image to Gemini Vision (google-genai SDK) and return extracted HTML."""
    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise ImportError("google-genai is required: pip install google-genai")

    lower = jpg_path.lower()
    if lower.endswith(".png"):
        mime_type = "image/png"
    elif lower.endswith(".gif"):
        mime_type = "image/gif"
    elif lower.endswith(".webp"):
        mime_type = "image/webp"
    else:
        mime_type = "image/jpeg"

    with open(jpg_path, "rb") as f:
        image_bytes = f.read()

    # thinking_config is only supported by the Gemini 2.5+ / 3+ series
    _THINKING_MODELS = {"gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-2.5-flash", "gemini-2.5-pro"}
    if model in _THINKING_MODELS:
        gen_config = types.GenerateContentConfig(
            thinking_config=types.ThinkingConfig(thinking_budget=thinking_budget)
        )
    else:
        gen_config = types.GenerateContentConfig()

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model=model,
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
            _OCR_PROMPT,
        ],
        config=gen_config,
    )
    # Check for recitation (copyright) block before accessing text
    if response.candidates:
        reason = response.candidates[0].finish_reason
        if hasattr(reason, 'name') and reason.name == "RECITATION":
            raise RecitationError(
                "Model refused to transcribe: copyright/recitation filter triggered.")
    text = response.text
    if text is None:
        return None
    return text


# ---------------------------------------------------------------------------
# Mistral OCR  (dedicated /v1/ocr endpoint)
# ---------------------------------------------------------------------------

def ocr_with_mistral(jpg_path: str, api_key: str,
                      model: str = "mistral-ocr-latest") -> str:
    """Send the image to Mistral OCR and return extracted HTML.

    Uses the dedicated ``/v1/ocr`` endpoint (not chat/completions).
    The endpoint returns Markdown (with optional HTML tables when
    ``table_format="html"``).  We convert to HTML so the downstream
    ``_html_to_flowables`` parser can handle it identically to the
    HTML produced by Anthropic / Gemini.
    """
    import httpx

    raw, media_type = _compress_to_limit(jpg_path)
    image_data = base64.standard_b64encode(raw).decode("utf-8")
    data_uri = f"data:{media_type};base64,{image_data}"

    resp = httpx.post(
        "https://api.mistral.ai/v1/ocr",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json={
            "model": model,
            "document": {
                "type": "image_url",
                "image_url": data_uri,
            },
            "table_format": "html",
        },
        timeout=120,
    )
    resp.raise_for_status()
    data = resp.json()

    # Concatenate all pages' markdown content
    pages = data.get("pages", [])
    if not pages:
        return None
    md_text = "\n\n".join(p.get("markdown", "") for p in pages)
    if not md_text:
        return None

    # Convert Markdown → HTML so the shared PDF builder can parse it
    return _markdown_to_html(md_text)


# ---------------------------------------------------------------------------
# Async Batch APIs  (Claude, Gemini, Mistral — 50 % discount)
# ---------------------------------------------------------------------------
# Each "submit" function returns a batch identifier string.
# Each "poll" function blocks until the batch finishes (or cancel_flag is
# set) and returns [(custom_id, ocr_text | None, error_msg | None), …].
# ---------------------------------------------------------------------------

def batch_submit_claude(items: list, api_key: str, model: str) -> str:
    """Submit an async message batch to Anthropic.

    *items* – [(custom_id, raw_bytes, media_type), …]
    Returns the batch id.
    """
    import anthropic

    requests = []
    for cid, raw, mtype in items:
        b64 = base64.standard_b64encode(raw).decode("utf-8")
        requests.append({
            "custom_id": cid,
            "params": {
                "model": model,
                "max_tokens": 4096,
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "image", "source": {
                            "type": "base64",
                            "media_type": mtype,
                            "data": b64,
                        }},
                        {"type": "text", "text": _OCR_PROMPT},
                    ],
                }],
            },
        })

    client = anthropic.Anthropic(api_key=api_key)
    batch = client.messages.batches.create(requests=requests)
    return batch.id


def batch_poll_claude(batch_id: str, api_key: str,
                      cancel_flag: threading.Event | None = None,
                      status_cb=None) -> list:
    """Poll an Anthropic batch until it ends.  Returns result triples."""
    import anthropic
    client = anthropic.Anthropic(api_key=api_key)
    t0 = time.time()

    while True:
        batch = client.messages.batches.retrieve(batch_id)
        if batch.processing_status == "ended":
            break
        if cancel_flag and cancel_flag.is_set():
            try:
                client.messages.batches.cancel(batch_id)
            except Exception:
                pass
            return []
        elapsed = int(time.time() - t0)
        if status_cb:
            status_cb(f"Waiting for Claude batch… ({elapsed}s elapsed)")
        time.sleep(30)

    results = []
    for entry in client.messages.batches.results(batch_id):
        cid = entry.custom_id
        if entry.result.type == "succeeded":
            msg = entry.result.message
            stop = getattr(msg, "stop_reason", None)
            if stop == "end_turn" or stop is None:
                text = msg.content[0].text if msg.content else None
                results.append((cid, text, None))
            else:
                results.append((cid, None, f"stop_reason={stop}"))
        elif entry.result.type == "errored":
            err = getattr(entry.result, "error", None)
            results.append((cid, None, str(err) if err else "Unknown error"))
        else:
            results.append((cid, None, f"result_type={entry.result.type}"))
    return results


def batch_submit_gemini(items: list, api_key: str, model: str,
                        thinking_budget: int = 1_024) -> str:
    """Submit an inline batch to Gemini.  Returns the job name."""
    from google import genai
    from google.genai import types

    _THINKING_MODELS = {
        "gemini-3-flash-preview", "gemini-3.1-pro-preview",
        "gemini-2.5-flash", "gemini-2.5-pro",
    }

    inline_requests = []
    for cid, raw, mtype in items:
        if model in _THINKING_MODELS:
            cfg = types.GenerateContentConfig(
                thinking_config=types.ThinkingConfig(
                    thinking_budget=thinking_budget))
        else:
            cfg = types.GenerateContentConfig()

        inline_requests.append(
            types.InlinedRequest(
                model=model,
                contents=[
                    types.Part.from_bytes(data=raw, mime_type=mtype),
                    _OCR_PROMPT,
                ],
                metadata={"key": cid},
                config=cfg,
            )
        )

    client = genai.Client(api_key=api_key)
    job = client.batches.create(
        model=model,
        src=inline_requests,
        config=types.CreateBatchJobConfig(
            display_name="ocr-to-pdf-batch"),
    )
    return job.name


def batch_poll_gemini(job_name: str, api_key: str,
                      cancel_flag: threading.Event | None = None,
                      status_cb=None) -> list:
    """Poll a Gemini batch job.  Returns result triples."""
    from google import genai
    client = genai.Client(api_key=api_key)
    t0 = time.time()

    while True:
        job = client.batches.get(name=job_name)
        state = str(getattr(job, "state", ""))
        if "SUCCEEDED" in state:
            break
        if "FAILED" in state or "CANCELLED" in state or "EXPIRED" in state:
            return [("__batch__", None, f"Batch ended with state: {state}")]
        if cancel_flag and cancel_flag.is_set():
            try:
                client.batches.cancel(name=job_name)
            except Exception:
                pass
            return []
        elapsed = int(time.time() - t0)
        if status_cb:
            status_cb(f"Waiting for Gemini batch… ({elapsed}s elapsed)")
        time.sleep(30)

    results = []
    if hasattr(job, "dest") and hasattr(job.dest, "inlined_responses"):
        for entry in job.dest.inlined_responses:
            # Extract the custom_id from metadata.key (may be dict or obj)
            meta = getattr(entry, "metadata", None) or {}
            if isinstance(meta, dict):
                rid = meta.get("key", "")
            else:
                rid = getattr(meta, "key", "")

            # Check for errors at the entry level
            entry_err = getattr(entry, "error", None)
            if entry_err:
                results.append((rid, None, str(entry_err)))
                continue

            resp = getattr(entry, "response", None)
            if resp is None:
                results.append((rid, None, "No response in entry"))
                continue

            # Check for recitation
            if resp.candidates:
                reason = resp.candidates[0].finish_reason
                if hasattr(reason, "name") and reason.name == "RECITATION":
                    results.append((rid, None, "RECITATION"))
                    continue

            try:
                parts = resp.candidates[0].content.parts
                text = "".join(p.text for p in parts if hasattr(p, "text"))
                results.append((rid, text or None, None))
            except Exception as exc:
                results.append((rid, None, str(exc)))
    return results


def batch_submit_mistral(items: list, api_key: str, model: str) -> str:
    """Submit a batch to Mistral OCR.  Returns batch id."""
    import httpx

    # Build JSONL — each line targets the /v1/ocr endpoint
    lines = []
    for cid, raw, mtype in items:
        b64 = base64.standard_b64encode(raw).decode("utf-8")
        data_uri = f"data:{mtype};base64,{b64}"
        line = json.dumps({
            "custom_id": cid,
            "body": {
                "model": model,
                "document": {
                    "type": "image_url",
                    "image_url": data_uri,
                },
                "table_format": "html",
            },
        })
        lines.append(line)
    jsonl_bytes = ("\n".join(lines)).encode("utf-8")

    headers = {"Authorization": f"Bearer {api_key}"}

    # Upload JSONL file
    upload = httpx.post(
        "https://api.mistral.ai/v1/files",
        headers=headers,
        files={"file": ("batch.jsonl", jsonl_bytes, "application/jsonl")},
        data={"purpose": "batch"},
        timeout=120,
    )
    upload.raise_for_status()
    file_id = upload.json()["id"]

    # Create batch targeting the OCR endpoint
    batch = httpx.post(
        "https://api.mistral.ai/v1/batches",
        headers={**headers, "Content-Type": "application/json"},
        json={
            "model": model,
            "input_file_id": file_id,
            "endpoint": "/v1/ocr",
        },
        timeout=60,
    )
    batch.raise_for_status()
    return batch.json()["id"]


def batch_poll_mistral(batch_id: str, api_key: str,
                       cancel_flag: threading.Event | None = None,
                       status_cb=None) -> list:
    """Poll a Mistral batch.  Returns result triples."""
    import httpx
    headers = {"Authorization": f"Bearer {api_key}"}
    t0 = time.time()

    while True:
        resp = httpx.get(
            f"https://api.mistral.ai/v1/batches/{batch_id}",
            headers=headers, timeout=30,
        )
        resp.raise_for_status()
        info = resp.json()
        status = info.get("status", "")

        if status in ("SUCCESS", "COMPLETED"):
            break
        if status in ("FAILED", "TIMEOUT_EXCEEDED", "CANCELLED",
                       "CANCELLATION_REQUESTED"):
            return [("__batch__", None, f"Batch ended: {status}")]
        if cancel_flag and cancel_flag.is_set():
            try:
                httpx.post(
                    f"https://api.mistral.ai/v1/batches/{batch_id}/cancel",
                    headers=headers, timeout=10,
                )
            except Exception:
                pass
            return []
        elapsed = int(time.time() - t0)
        if status_cb:
            status_cb(f"Waiting for Mistral batch… ({elapsed}s elapsed)")
        time.sleep(30)

    # Download results
    output_file_id = info.get("output_file_id") or info.get("output_file")
    if not output_file_id:
        return [("__batch__", None, "No output file in batch response")]

    dl = httpx.get(
        f"https://api.mistral.ai/v1/files/{output_file_id}/content",
        headers=headers, timeout=120,
    )
    dl.raise_for_status()

    results = []
    for raw_line in dl.text.strip().split("\n"):
        if not raw_line.strip():
            continue
        entry = json.loads(raw_line)
        cid = entry.get("custom_id", "")
        if entry.get("error"):
            results.append((cid, None, str(entry["error"])))
        else:
            try:
                body = entry["response"]["body"]
                # OCR endpoint returns {"pages": [{"markdown": "..."}]}
                pages = body.get("pages", [])
                md_text = "\n\n".join(p.get("markdown", "") for p in pages)
                # Convert Markdown → HTML for the shared PDF builder
                text = _markdown_to_html(md_text) if md_text else None
                results.append((cid, text, None))
            except (KeyError, IndexError, TypeError) as exc:
                results.append((cid, None, f"Parse error: {exc}"))
    return results


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

import tkinter as tk
from tkinter import filedialog, messagebox, ttk  # noqa: E402
from tkinterdnd2 import TkinterDnD, DND_FILES    # noqa: E402

_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
_IMAGE_FILETYPES = [("Image files", "*.jpg *.jpeg *.png *.gif *.webp"), ("All files", "*.*")]


class App(TkinterDnD.Tk):
    _PROVIDERS = {
        "Anthropic": "ANTHROPIC_API_KEY",
        "Gemini":    "GOOGLE_API_KEY",
        "Mistral":   "MISTRAL_API_KEY",
    }

    _API_KEY_LABELS = {
        "Anthropic": "Anthropic API key:",
        "Gemini":    "Google API key:",
        "Mistral":   "Mistral API key:",
    }

    # All models available per provider, in display order (first = default).
    _MODELS = {
        "Anthropic": [
            "claude-opus-4-6",
            "claude-sonnet-4-5",
        ],
        "Gemini": [
            "gemini-3-flash-preview",
            "gemini-3.1-flash-lite-preview",
            "gemini-3.1-pro-preview",
            "gemini-2.5-flash",
            "gemini-2.5-pro",
        ],
        "Mistral": [
            "mistral-ocr-latest",
        ],
    }

    # Gemini models that support thinking_config (2.5+ and 3+ series).
    _GEMINI_THINKING_MODELS = {
        "gemini-3-flash-preview", "gemini-3.1-pro-preview",
        "gemini-2.5-flash", "gemini-2.5-pro",
    }

    # Providers that support the async Batch API (50 % discount).
    _BATCH_PROVIDERS = {"Anthropic", "Gemini", "Mistral"}

    # Thinking budget presets shown in the dropdown (label → token budget).
    _THINKING_BUDGETS = [
        ("Low  (1 K tokens)",   1_024),
        ("High (8 K tokens)",   8_192),
    ]

    # Pricing per million tokens: (input_$/1M, output_$/1M).
    # Preview model prices are estimates (~).
    _PRICING = {
        # ── Anthropic ─────────────────────────────────────────────────────
        "claude-opus-4-6":   (15.00, 75.00),
        "claude-sonnet-4-5": ( 3.00, 15.00),
        # ── Gemini ────────────────────────────────────────────────────────
        "gemini-3-flash-preview":       ( 0.075,  0.30),  # ~
        "gemini-3.1-flash-lite-preview":( 0.0375, 0.15),  # ~
        "gemini-3.1-pro-preview":       ( 1.25,  10.00),  # ~
        "gemini-2.5-flash":             ( 0.075,  0.30),
        "gemini-2.5-pro":               ( 1.25,  10.00),
    }

    # Mistral OCR charges per page, not per token.
    # $2 / 1,000 pages immediate; $1 / 1,000 pages batch (50 % off).
    _PAGE_PRICING = {
        "mistral-ocr-latest":  0.002,   # $ per page (immediate)
    }

    def __init__(self):
        super().__init__()
        self.title("Archive Processor")
        self.resizable(True, True)
        self._key_cache = {
            p: os.environ.get(env, "") for p, env in self._PROVIDERS.items()
        }
        self._last_provider = "Gemini"
        self._cancel_flag = threading.Event()
        self._image_paths: list[str] = []   # original paths (for display & output naming)
        self._temp_dir = tempfile.mkdtemp(prefix="archive_processor_")
        self._staged: dict[str, str] = {}   # original_path → temp_path
        self._build_ui()

    # ---- UI construction ------------------------------------------------

    def _build_ui(self):
        PAD = 12
        frame = ttk.Frame(self, padding=PAD)
        frame.grid(sticky="nsew")
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        frame.columnconfigure(1, weight=1)
        frame.rowconfigure(4, weight=1)  # file-list row expands

        # ── Row 0: Provider ──────────────────────────────────────────────────
        ttk.Label(frame, text="Provider:").grid(row=0, column=0, sticky="w", pady=(0, 4))
        self.provider_var = tk.StringVar(value="Gemini")
        provider_cb = ttk.Combobox(
            frame, textvariable=self.provider_var,
            values=list(self._PROVIDERS.keys()),
            state="readonly", width=14,
        )
        provider_cb.grid(row=0, column=1, sticky="w", pady=(0, 4))
        provider_cb.bind("<<ComboboxSelected>>", self._on_provider_change)

        # Workers (concurrent API requests) — same row, right side
        ttk.Label(frame, text="Workers:").grid(
            row=0, column=2, sticky="e", padx=(12, 4), pady=(0, 4))
        self.workers_var = tk.IntVar(value=4)
        self._workers_spin = ttk.Spinbox(
            frame, from_=1, to=16, textvariable=self.workers_var,
            width=4, state="readonly",
        )
        self._workers_spin.grid(row=0, column=3, sticky="w", pady=(0, 4))

        # ── Row 1: Model ──────────────────────────────────────────────────────
        ttk.Label(frame, text="Model:").grid(row=1, column=0, sticky="w", pady=(0, 4))
        self.model_var = tk.StringVar(value="gemini-3.1-flash-lite-preview")
        self.model_cb = ttk.Combobox(
            frame, textvariable=self.model_var,
            values=self._MODELS["Gemini"],
            state="readonly", width=34,
        )
        self.model_cb.grid(row=1, column=1, columnspan=3, sticky="w", pady=(0, 4))
        self.model_cb.bind("<<ComboboxSelected>>", self._on_model_change)

        # ── Row 2: Thinking budget + Mode selector ──────────────────────────
        self.thinking_label = ttk.Label(frame, text="Thinking:")
        self.thinking_label.grid(row=2, column=0, sticky="w", pady=(0, 4))
        self.thinking_var = tk.StringVar(value=self._THINKING_BUDGETS[0][0])
        self.thinking_cb = ttk.Combobox(
            frame, textvariable=self.thinking_var,
            values=[label for label, _ in self._THINKING_BUDGETS],
            state="disabled", width=22,
        )
        self.thinking_cb.grid(row=2, column=1, sticky="w", pady=(0, 4))

        # Mode: Immediate (concurrent) vs Batch (async, 50% off)
        ttk.Label(frame, text="Mode:").grid(
            row=2, column=2, sticky="e", padx=(12, 4), pady=(0, 4))
        self.mode_var = tk.StringVar(value="Immediate")
        self.mode_cb = ttk.Combobox(
            frame, textvariable=self.mode_var,
            values=["Immediate", "Batch (50% off)"],
            state="readonly", width=16,
        )
        self.mode_cb.grid(row=2, column=3, sticky="w", pady=(0, 4))
        self.mode_cb.bind("<<ComboboxSelected>>", self._on_mode_change)

        # ── Row 3: API key ────────────────────────────────────────────────────
        self.api_key_label = ttk.Label(frame, text="Google API key:")
        self.api_key_label.grid(row=3, column=0, sticky="w", pady=(0, 4))
        self.api_key_var = tk.StringVar(value=self._key_cache["Gemini"])
        api_entry = ttk.Entry(frame, textvariable=self.api_key_var, width=52, show="*")
        api_entry.grid(row=3, column=1, columnspan=2, sticky="ew", pady=(0, 4))
        ttk.Checkbutton(
            frame, text="Show",
            command=lambda: api_entry.config(
                show="" if api_entry.cget("show") == "*" else "*"
            ),
        ).grid(row=3, column=3, padx=(4, 0), pady=(0, 4))

        # ── Row 4: File list (drag-and-drop target) ───────────────────────────
        list_frame = ttk.LabelFrame(frame, text="Images — drag & drop files here, or Browse")
        list_frame.grid(row=4, column=0, columnspan=4, sticky="nsew", pady=(4, 0))
        list_frame.columnconfigure(0, weight=1)
        list_frame.rowconfigure(0, weight=1)

        self.file_list = tk.Listbox(list_frame, selectmode=tk.EXTENDED, height=12)
        self.file_list.grid(row=0, column=0, sticky="nsew")
        sb = ttk.Scrollbar(list_frame, orient="vertical", command=self.file_list.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.file_list.configure(yscrollcommand=sb.set)

        self.file_list.drop_target_register(DND_FILES)
        self.file_list.dnd_bind("<<Drop>>", self._on_drop)

        # ── Row 5: File management buttons ────────────────────────────────────
        btn_frame = ttk.Frame(frame)
        btn_frame.grid(row=5, column=0, columnspan=4, sticky="w", pady=(4, 0))
        ttk.Button(btn_frame, text="Browse…",         command=self._browse_images).pack(side="left", padx=(0, 4))
        ttk.Button(btn_frame, text="Remove selected", command=self._remove_selected).pack(side="left", padx=(0, 4))
        ttk.Button(btn_frame, text="Clear all",       command=self._clear_list).pack(side="left")

        # ── Row 6: Output folder ──────────────────────────────────────────────
        ttk.Label(frame, text="Output folder:").grid(row=6, column=0, sticky="w", pady=(8, 4))
        self.out_dir_var = tk.StringVar(value="")
        out_entry = ttk.Entry(frame, textvariable=self.out_dir_var, width=44)
        out_entry.grid(row=6, column=1, sticky="ew", pady=(8, 4))
        ttk.Button(frame, text="Browse…", command=self._browse_output_dir).grid(
            row=6, column=2, padx=(4, 0), pady=(8, 4)
        )
        ttk.Button(frame, text="Clear", command=lambda: self.out_dir_var.set("")).grid(
            row=6, column=3, padx=(4, 0), pady=(8, 4)
        )
        ttk.Label(
            frame, text="Leave blank to save each PDF alongside its source image.",
            foreground="gray", font=("TkDefaultFont", 9),
        ).grid(row=7, column=1, columnspan=3, sticky="w")

        # ── Row 8: Progress bar ───────────────────────────────────────────────
        self.progress = ttk.Progressbar(frame, mode="determinate", maximum=100)
        self.progress.grid(row=8, column=0, columnspan=4, sticky="ew", pady=(8, 4))

        # ── Row 9: Status label ───────────────────────────────────────────────
        self.status_var = tk.StringVar(value="Ready — add images to begin.")
        ttk.Label(frame, textvariable=self.status_var, foreground="gray").grid(
            row=9, column=0, columnspan=4, sticky="w"
        )

        # ── Row 10: Generate / Cancel buttons ─────────────────────────────────
        action_frame = ttk.Frame(frame)
        action_frame.grid(row=10, column=0, columnspan=4, pady=(10, 0))
        self.estimate_btn = ttk.Button(
            action_frame, text="Estimate Cost", command=self._estimate_cost
        )
        self.estimate_btn.pack(side="left", padx=(0, 8))
        self.gen_btn = ttk.Button(
            action_frame, text="Generate PDFs", command=self._start_processing
        )
        self.gen_btn.pack(side="left", padx=(0, 8))
        self.cancel_btn = ttk.Button(
            action_frame, text="Cancel", command=self._request_cancel, state="disabled"
        )
        self.cancel_btn.pack(side="left")

    # ---- Provider / model / thinking helpers ----------------------------

    def _on_provider_change(self, *_):
        self._key_cache[self._last_provider] = self.api_key_var.get()
        new = self.provider_var.get()
        self._last_provider = new
        self.api_key_label.config(text=self._API_KEY_LABELS.get(new, "API key:"))
        self.api_key_var.set(self._key_cache.get(new, ""))
        # Swap model list, reset to first model, and update thinking dropdown
        models = self._MODELS[new]
        self.model_cb.config(values=models)
        self.model_var.set(models[0])
        self._on_model_change()
        # If batch mode is selected but new provider doesn't support it, revert
        if (self.mode_var.get() == "Batch (50% off)"
                and new not in self._BATCH_PROVIDERS):
            self.mode_var.set("Immediate")
            self._on_mode_change()

    def _on_model_change(self, *_):
        """Enable the thinking dropdown only for models that support it."""
        provider = self.provider_var.get()
        model    = self.model_var.get()
        supports = (provider == "Gemini" and model in self._GEMINI_THINKING_MODELS)
        self.thinking_cb.config(state="readonly" if supports else "disabled")
        if not supports:
            self.thinking_var.set(self._THINKING_BUDGETS[0][0])

    def _on_mode_change(self, *_):
        """Toggle between Immediate and Batch mode."""
        mode     = self.mode_var.get()
        provider = self.provider_var.get()
        if mode == "Batch (50% off)" and provider not in self._BATCH_PROVIDERS:
            self.mode_var.set("Immediate")
            messagebox.showinfo(
                "Batch not available",
                f"Batch mode is not available for {provider}.\n"
                f"Batch API is supported by: {', '.join(sorted(self._BATCH_PROVIDERS))}.",
            )
            return
        # Workers spinbox is irrelevant in batch mode
        if mode == "Batch (50% off)":
            self.workers_var.set(1)
            self._workers_spin.config(state="disabled")
        else:
            self.workers_var.set(4)
            self._workers_spin.config(state="readonly")

    # ---- File-list helpers ----------------------------------------------

    def _stage_file(self, src_path: str) -> str:
        """Copy *src_path* into the temp dir while file-dialog access is active.

        Returns the temp path.  On macOS, TCC hides protected-folder files
        from .app bundles; copying here preserves access for later processing.
        """
        name = os.path.basename(src_path)
        dest = os.path.join(
            self._temp_dir, f"{len(self._staged):04d}_{name}"
        )
        shutil.copy2(src_path, dest)
        self._staged[src_path] = dest
        return dest

    def _working_path(self, orig_path: str) -> str:
        """Return the staged temp copy if available, else the original path."""
        return self._staged.get(orig_path, orig_path)

    def _on_drop(self, event):
        import urllib.parse
        existing = set(self._image_paths)
        for path in self.tk.splitlist(event.data):
            path = path.strip()
            # macOS .app bundles sometimes deliver file:// URIs from drag-and-drop
            if path.startswith("file://"):
                path = urllib.parse.unquote(path[7:])
            path = os.path.realpath(path)
            ext = os.path.splitext(path.lower())[1]
            if os.path.isfile(path) and ext in _IMAGE_EXTS and path not in existing:
                try:
                    self._stage_file(path)
                except OSError:
                    pass  # will fall back to original at process time
                self._image_paths.append(path)
                self.file_list.insert(tk.END, path)
                existing.add(path)

    def _browse_images(self):
        paths = filedialog.askopenfilenames(title="Select images", filetypes=_IMAGE_FILETYPES)
        existing = set(self._image_paths)
        denied = []
        for path in paths:
            if path not in existing:
                try:
                    self._stage_file(path)
                except OSError:
                    denied.append(path)
                    continue  # skip files that can't be read
                self._image_paths.append(path)
                self.file_list.insert(tk.END, path)
                existing.add(path)
        if denied:
            messagebox.showwarning(
                "Cannot read files",
                f"{len(denied)} file(s) could not be read.\n\n"
                "If running as an app, grant access in:\n"
                "System Settings → Privacy & Security → Files and Folders",
            )

    def _browse_output_dir(self):
        folder = filedialog.askdirectory(title="Select output folder")
        if folder:
            self.out_dir_var.set(folder)

    def _remove_selected(self):
        for idx in reversed(self.file_list.curselection()):
            self.file_list.delete(idx)
            orig = self._image_paths.pop(idx)
            temp = self._staged.pop(orig, None)
            if temp and os.path.isfile(temp):
                os.remove(temp)

    def _clear_list(self):
        self.file_list.delete(0, tk.END)
        self._image_paths.clear()
        for temp in self._staged.values():
            if os.path.isfile(temp):
                os.remove(temp)
        self._staged.clear()

    # ---- Busy state -----------------------------------------------------

    def _set_busy(self, busy: bool):
        if busy:
            self.estimate_btn.config(state="disabled")
            self.gen_btn.config(state="disabled")
            self.cancel_btn.config(state="normal")
            self.progress["value"] = 0
        else:
            self.estimate_btn.config(state="normal")
            self.gen_btn.config(state="normal")
            self.cancel_btn.config(state="disabled")

    def _request_cancel(self):
        self._cancel_flag.set()
        self.cancel_btn.config(state="disabled")
        self.status_var.set("Cancelling after current file…")

    # ---- Cost estimation ------------------------------------------------

    def _estimate_cost(self):
        from PIL import Image as PILImage

        img_paths = list(self._image_paths)
        provider  = self.provider_var.get()
        model     = self.model_var.get()

        if not img_paths:
            messagebox.showinfo("Estimate Cost", "No images added yet.")
            return

        num_images = len(img_paths)

        # ── Per-page pricing (Mistral OCR) ──────────────────────────────────
        page_price = self._PAGE_PRICING.get(model)
        if page_price is not None:
            # Mistral OCR: each single-page image = 1 page
            total = num_images * page_price
            batch_total = total * 0.5
            batch_avail = provider in self._BATCH_PROVIDERS

            msg = (
                f"Provider :  {provider}\n"
                f"Model    :  {model}\n"
                f"Images   :  {num_images:,}\n"
                f"\n"
                f"Pricing  :  ${page_price:.4f} / page (immediate)\n"
                f"Est. pages:  {num_images:,}  (1 page per image)\n"
                f"{'─' * 40}\n"
                f"Est. total (immediate):  ${total:>10.4f}\n"
            )
            if batch_avail:
                msg += f"Est. total (batch 50% off):  ${batch_total:>10.4f}\n"
            messagebox.showinfo("Cost Estimate", msg)
            return

        # ── Per-token pricing (Claude / Gemini) ─────────────────────────────
        pricing = self._PRICING.get(model)
        if pricing is None:
            messagebox.showinfo("Estimate Cost",
                f"No pricing data available for:\n{model}")
            return

        input_per_1m, output_per_1m = pricing

        # Fixed per-image token estimates
        PROMPT_TOKENS  = 150    # OCR system prompt
        OUTPUT_TOKENS  = 1_500  # typical HTML output per image

        total_input_tokens = 0
        unreadable = 0

        for path in img_paths:
            try:
                with PILImage.open(self._working_path(path)) as img:
                    w, h = img.size
            except Exception:
                unreadable += 1
                w, h = 1_000, 1_400  # fall back to typical document dimensions

            if provider == "Anthropic":
                # Anthropic tiles images into 512×512 blocks (max source dim 1568 px)
                max_dim = 1_568
                if w > max_dim or h > max_dim:
                    scale = max_dim / max(w, h)
                    w, h = int(w * scale), int(h * scale)
                w, h = max(w, 200), max(h, 200)
                img_tokens = math.ceil(w / 512) * math.ceil(h / 512) * 1_600 + 560
            else:
                # Gemini counts ~258 tokens per image (simplified standard-res estimate)
                img_tokens = 258

            total_input_tokens += img_tokens + PROMPT_TOKENS

        total_output_tokens = num_images * OUTPUT_TOKENS
        cost_in  = (total_input_tokens  / 1_000_000) * input_per_1m
        cost_out = (total_output_tokens / 1_000_000) * output_per_1m
        total    = cost_in + cost_out

        is_preview = "preview" in model
        note = "\n* Preview model — price is an estimate." if is_preview else ""
        unreadable_note = (f"\n  ({unreadable} image(s) used fallback dimensions.)"
                           if unreadable else "")

        # Batch discount line (50 % off for supported providers)
        batch_avail = provider in self._BATCH_PROVIDERS
        batch_total = total * 0.5

        msg = (
            f"Provider :  {provider}\n"
            f"Model    :  {model}\n"
            f"Images   :  {num_images:,}\n"
            f"\n"
            f"Est. input tokens :  {total_input_tokens:>12,}{unreadable_note}\n"
            f"Est. output tokens:  {total_output_tokens:>12,}\n"
            f"\n"
            f"Est. input cost :  ${cost_in:>10.4f}\n"
            f"Est. output cost:  ${cost_out:>10.4f}\n"
            f"{'─' * 40}\n"
            f"Est. total (immediate):  ${total:>10.4f}\n"
        )
        if batch_avail:
            msg += f"Est. total (batch 50% off):  ${batch_total:>10.4f}\n"
        msg += note
        messagebox.showinfo("Cost Estimate", msg)

    # ---- Processing (background thread) ---------------------------------

    def _start_processing(self):
        api_key   = self.api_key_var.get().strip()
        img_paths = list(self._image_paths)
        provider  = self.provider_var.get()
        model     = self.model_var.get()
        out_dir   = self.out_dir_var.get().strip()

        # Resolve thinking budget label → token integer
        budget_map = {label: val for label, val in self._THINKING_BUDGETS}
        thinking_budget = budget_map.get(self.thinking_var.get(),
                                         self._THINKING_BUDGETS[0][1])

        if not api_key:
            messagebox.showerror("Missing API key", "Please enter your API key.")
            return
        if not img_paths:
            messagebox.showerror("No images", "Please add at least one image.")
            return
        if out_dir and not os.path.isdir(out_dir):
            messagebox.showerror("Invalid output folder",
                f"The folder does not exist:\n{out_dir}\n\nPlease choose a valid folder.")
            return

        # If saving alongside source images, verify write access (macOS TCC
        # can silently block writes to Desktop / Documents / Downloads).
        if not out_dir:
            test_dir = os.path.dirname(img_paths[0])
            probe = os.path.join(test_dir, ".ocr_write_test")
            try:
                with open(probe, "w") as f:
                    f.write("")
                os.remove(probe)
            except OSError:
                messagebox.showinfo(
                    "Output folder needed",
                    "Cannot save PDFs next to the source images "
                    "(the folder is not writable).\n\n"
                    "Please choose an output folder.",
                )
                out_dir = filedialog.askdirectory(title="Select output folder")
                if not out_dir:
                    return
                self.out_dir_var.set(out_dir)

        max_workers = self.workers_var.get()
        mode = self.mode_var.get()

        self._cancel_flag.clear()
        self._set_busy(True)

        if mode == "Batch (50% off)":
            if provider not in self._BATCH_PROVIDERS:
                messagebox.showerror("Batch not available",
                    f"Batch mode is not supported by {provider}.")
                self._set_busy(False)
                return
            self.status_var.set(
                f"Preparing batch — {len(img_paths)} image(s)…")
            threading.Thread(
                target=self._process_batch,
                args=(api_key, img_paths, provider, model,
                      thinking_budget, out_dir),
                daemon=True,
            ).start()
        else:
            self.status_var.set(
                f"Starting — {len(img_paths)} image(s) queued…")
            threading.Thread(
                target=self._process,
                args=(api_key, img_paths, provider, model,
                      thinking_budget, out_dir, max_workers),
                daemon=True,
            ).start()

    # HTML shown on page 2 when the model refuses due to copyright.
    _COPYRIGHT_NOTICE = (
        "<p><b>OCR text not available.</b></p>"
        "<p>The model refused to transcribe this image because it detected "
        "copyrighted material (recitation filter). You may retry these images "
        "with a different model or provider.</p>"
    )

    def _process(self, api_key: str, img_paths: list, provider: str,
                 model: str, thinking_budget: int, out_dir: str,
                 max_workers: int = 4):
        total       = len(img_paths)
        errors      = []
        warnings    = []
        recitations = []   # (name, img_path, work_path, out_path)
        lock        = threading.Lock()
        done_count  = [0]   # mutable counter for closure access

        def _do_one(img_path):
            """Process a single image.  Called from pool threads."""
            if self._cancel_flag.is_set():
                return

            name      = os.path.basename(img_path)
            stem      = os.path.splitext(name)[0]
            pdf_name  = stem + "_ocr.pdf"
            work_path = self._working_path(img_path)   # staged temp copy
            if out_dir:
                out_path = os.path.join(out_dir, pdf_name)
            else:
                out_path = os.path.splitext(img_path)[0] + "_ocr.pdf"

            # -- verify the working file is actually readable ----------------
            if not os.path.isfile(work_path):
                with lock:
                    errors.append((name,
                        f"File not accessible.\n"
                        f"  read path: {work_path}\n"
                        f"  original:  {img_path}\n"
                        f"  staged:    {img_path in self._staged}"))
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return

            # -- OCR ---------------------------------------------------------
            try:
                ocr_text = self._call_ocr(provider, work_path, api_key,
                                          model, thinking_budget)
            except RecitationError:
                with lock:
                    recitations.append((name, img_path, work_path, out_path))
                try:
                    build_pdf(work_path, self._COPYRIGHT_NOTICE, out_path,
                              provider, model)
                except Exception as exc:
                    with lock:
                        errors.append((name, f"PDF error ({out_path}): {exc}"))
                with lock:
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return
            except Exception as exc:
                with lock:
                    errors.append((name,
                        f"OCR error ({type(exc).__name__}): {exc}\n"
                        f"  file: {work_path}"))
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return

            if not ocr_text:
                with lock:
                    warnings.append((name,
                        "OCR returned no text (model may have refused or "
                        "filtered the image)"))

            # -- PDF ---------------------------------------------------------
            try:
                build_pdf(work_path, ocr_text or "", out_path, provider, model)
            except Exception as exc:
                with lock:
                    errors.append((name, f"PDF error ({out_path}): {exc}"))

            with lock:
                done_count[0] += 1
                d = done_count[0]
            self.after(0, self._set_progress, d, total)

        # -- Submit all images to the thread pool ----------------------------
        self.after(0, self.status_var.set,
                   f"Processing {total} image(s) with {max_workers} worker(s)…")

        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(_do_one, p) for p in img_paths]

            for f in as_completed(futures):
                if self._cancel_flag.is_set():
                    for pending in futures:
                        pending.cancel()
                    break
                try:
                    f.result()      # surfaces unexpected exceptions
                except Exception:
                    pass            # errors already captured inside _do_one

        final_done = done_count[0]
        self.after(0, self._on_batch_complete,
                   final_done, total, errors, warnings, recitations,
                   self._cancel_flag.is_set())

    @staticmethod
    def _call_ocr(provider, work_path, api_key, model, thinking_budget):
        """Dispatch OCR to the appropriate provider function."""
        if provider == "Anthropic":
            return ocr_with_claude(work_path, api_key, model)
        elif provider == "Gemini":
            return ocr_with_gemini(work_path, api_key, model, thinking_budget)
        elif provider == "Mistral":
            return ocr_with_mistral(work_path, api_key, model)
        else:
            raise ValueError(f"Unknown provider: {provider}")

    # ---- Async batch processing (50% discount) ----------------------------

    def _process_batch(self, api_key: str, img_paths: list, provider: str,
                       model: str, thinking_budget: int, out_dir: str):
        """Background thread: submit async batch, poll, build PDFs."""
        total       = len(img_paths)
        errors      = []
        warnings    = []
        recitations = []

        # Phase 1 — prepare images and mapping ----------------------------
        items   = []   # (custom_id, raw_bytes, media_type)
        id_map  = {}   # custom_id → (name, img_path, work_path, out_path)

        for i, img_path in enumerate(img_paths):
            if self._cancel_flag.is_set():
                self.after(0, self._on_batch_complete,
                           0, total, errors, warnings, recitations, True)
                return

            name      = os.path.basename(img_path)
            stem      = os.path.splitext(name)[0]
            pdf_name  = stem + "_ocr.pdf"
            work_path = self._working_path(img_path)
            if out_dir:
                out_path = os.path.join(out_dir, pdf_name)
            else:
                out_path = os.path.splitext(img_path)[0] + "_ocr.pdf"

            if not os.path.isfile(work_path):
                errors.append((name, "File not accessible"))
                continue

            try:
                raw, media_type = _compress_to_limit(work_path)
            except Exception as exc:
                errors.append((name, f"Image prep error: {exc}"))
                continue

            cid = str(i)
            items.append((cid, raw, media_type))
            id_map[cid] = (name, img_path, work_path, out_path)

            self.after(0, self._set_progress_pct, int(10 * (i + 1) / total))

        if not items:
            self.after(0, self._on_batch_complete,
                       0, total, errors, warnings, recitations, False)
            return

        # Phase 2 — submit the batch --------------------------------------
        self.after(0, self.status_var.set,
                   f"Submitting batch ({len(items)} images) to {provider}…")
        try:
            if provider == "Anthropic":
                batch_id = batch_submit_claude(items, api_key, model)
            elif provider == "Gemini":
                batch_id = batch_submit_gemini(
                    items, api_key, model, thinking_budget)
            elif provider == "Mistral":
                batch_id = batch_submit_mistral(items, api_key, model)
            else:
                raise ValueError(f"Batch not supported for {provider}")
        except Exception as exc:
            errors.append(("__batch__", f"Batch submission failed: {exc}"))
            self.after(0, self._on_batch_complete,
                       0, total, errors, warnings, recitations, False)
            return

        self.after(0, self.status_var.set,
                   f"Batch submitted ({batch_id}). Polling for results…")
        self.after(0, self._set_progress_pct, 15)

        # Phase 3 — poll for completion ------------------------------------
        def _status_cb(msg):
            self.after(0, self.status_var.set, msg)

        try:
            if provider == "Anthropic":
                results = batch_poll_claude(
                    batch_id, api_key, self._cancel_flag, _status_cb)
            elif provider == "Gemini":
                results = batch_poll_gemini(
                    batch_id, api_key, self._cancel_flag, _status_cb)
            elif provider == "Mistral":
                results = batch_poll_mistral(
                    batch_id, api_key, self._cancel_flag, _status_cb)
            else:
                results = []
        except Exception as exc:
            errors.append(("__batch__", f"Batch poll error: {exc}"))
            self.after(0, self._on_batch_complete,
                       0, total, errors, warnings, recitations, False)
            return

        if self._cancel_flag.is_set():
            self.after(0, self._on_batch_complete,
                       0, total, errors, warnings, recitations, True)
            return

        self.after(0, self._set_progress_pct, 90)
        self.after(0, self.status_var.set, "Building PDFs from batch results…")

        # Phase 4 — build PDFs from results --------------------------------
        done = 0
        for cid, ocr_text, err_msg in results:
            if cid not in id_map:
                if err_msg:
                    errors.append((cid, err_msg))
                continue

            name, img_path, work_path, out_path = id_map[cid]

            if err_msg == "RECITATION":
                recitations.append((name, img_path, work_path, out_path))
                try:
                    build_pdf(work_path, self._COPYRIGHT_NOTICE, out_path,
                              provider, model)
                except Exception as exc:
                    errors.append((name, f"PDF error: {exc}"))
                done += 1
                continue

            if err_msg:
                errors.append((name, f"OCR error: {err_msg}"))
                done += 1
                continue

            if not ocr_text:
                warnings.append((name,
                    "OCR returned no text (model may have refused or "
                    "filtered the image)"))

            try:
                build_pdf(work_path, ocr_text or "", out_path, provider, model)
            except Exception as exc:
                errors.append((name, f"PDF error: {exc}"))

            done += 1
            pct = 90 + int(10 * done / len(results))
            self.after(0, self._set_progress_pct, pct)

        final_done = done + (total - len(items))  # include skipped
        self.after(0, self._on_batch_complete,
                   final_done, total, errors, warnings, recitations,
                   self._cancel_flag.is_set())

    def _set_progress_pct(self, pct: int):
        """Set progress bar to an absolute percentage."""
        self.progress["value"] = min(pct, 100)

    # ---- Progress helpers -----------------------------------------------

    def _set_progress(self, done: int, total: int):
        self.progress["value"] = (done / total) * 100
        self.status_var.set(f"Processing… {done}/{total} complete")

    def _on_batch_complete(self, done: int, total: int, errors: list,
                           warnings: list, recitations: list, cancelled: bool):
        self._set_busy(False)
        ok = done - len(errors)
        extra = ""
        if warnings:
            warn_lines = "\n".join(f"• {n}: {m}" for n, m in warnings[:10])
            if len(warnings) > 10:
                warn_lines += f"\n…and {len(warnings) - 10} more"
            extra += (f"\n\nNo OCR text ({len(warnings)} image(s)) — "
                      f"PDFs created with notice:\n{warn_lines}")
        if recitations:
            extra += (f"\n\n{len(recitations)} image(s) blocked by copyright "
                      f"filter — PDFs created with notice.")

        if cancelled:
            self.status_var.set(f"Cancelled — {ok} of {done} file(s) processed.")
            messagebox.showwarning("Cancelled",
                f"Stopped after {done}/{total} files.\n"
                f"{ok} PDF(s) created successfully." + extra)
        elif not errors and not warnings and not recitations:
            self.status_var.set(f"Done — {total} PDF(s) created.")
            messagebox.showinfo("Complete",
                f"All {total} PDF(s) created successfully.")
        elif not errors:
            label = f"{total} PDF(s) created"
            if recitations:
                label += f" ({len(recitations)} copyright-blocked)"
            self.status_var.set(f"Done — {label}.")
            messagebox.showinfo("Complete",
                f"All {total} PDF(s) created successfully." + extra)
        else:
            self.status_var.set(f"Done with errors — {ok}/{total} succeeded.")
            err_lines = "\n".join(f"• {n}: {m}" for n, m in errors[:10])
            if len(errors) > 10:
                err_lines += f"\n…and {len(errors) - 10} more"
            messagebox.showwarning("Completed with errors",
                f"{ok}/{total} PDF(s) created.\n\nFailed:\n{err_lines}"
                + extra)

        # If any images were blocked by copyright, offer retry dialog
        if recitations:
            RecitationRetryDialog(self, recitations)


# ---------------------------------------------------------------------------
# Recitation Retry Dialog
# ---------------------------------------------------------------------------

class RecitationRetryDialog(tk.Toplevel):
    """Pop-up shown after a batch finishes if any images were blocked by the
    model's copyright/recitation filter.  The user can select a different
    provider, model, and API key, then retry OCR on only those images.
    """

    def __init__(self, master: "App", recitations: list):
        super().__init__(master)
        self.title("Copyright-Blocked Images — Retry OCR")
        self.resizable(True, True)
        self.transient(master)
        self._master_app = master
        # recitations: [(name, img_path, work_path, out_path), ...]
        self._recitations = recitations

        PAD = 12
        frame = ttk.Frame(self, padding=PAD)
        frame.grid(sticky="nsew")
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        frame.columnconfigure(1, weight=1)
        frame.rowconfigure(1, weight=1)

        # ── Info label ───────────────────────────────────────────────────────
        ttk.Label(
            frame,
            text=(f"{len(recitations)} image(s) were blocked by the model's "
                  f"copyright filter.\nSelect a different provider and model "
                  f"to retry OCR on these images."),
            wraplength=500, justify="left",
        ).grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))

        # ── File list ────────────────────────────────────────────────────────
        lb_frame = ttk.LabelFrame(frame, text="Blocked images")
        lb_frame.grid(row=1, column=0, columnspan=4, sticky="nsew", pady=(0, 8))
        lb_frame.columnconfigure(0, weight=1)
        lb_frame.rowconfigure(0, weight=1)
        self._file_list = tk.Listbox(lb_frame, height=8)
        self._file_list.grid(row=0, column=0, sticky="nsew")
        sb = ttk.Scrollbar(lb_frame, orient="vertical",
                           command=self._file_list.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self._file_list.configure(yscrollcommand=sb.set)
        for name, *_ in recitations:
            self._file_list.insert(tk.END, name)

        # ── Provider ─────────────────────────────────────────────────────────
        ttk.Label(frame, text="Provider:").grid(row=2, column=0, sticky="w",
                                                 pady=(0, 4))
        self._provider_var = tk.StringVar(value="Anthropic")
        provider_cb = ttk.Combobox(
            frame, textvariable=self._provider_var,
            values=list(App._PROVIDERS.keys()),
            state="readonly", width=14,
        )
        provider_cb.grid(row=2, column=1, sticky="w", pady=(0, 4))
        provider_cb.bind("<<ComboboxSelected>>", self._on_provider_change)

        # ── Model ────────────────────────────────────────────────────────────
        ttk.Label(frame, text="Model:").grid(row=3, column=0, sticky="w",
                                              pady=(0, 4))
        self._model_var = tk.StringVar(value=App._MODELS["Anthropic"][0])
        self._model_cb = ttk.Combobox(
            frame, textvariable=self._model_var,
            values=App._MODELS["Anthropic"],
            state="readonly", width=34,
        )
        self._model_cb.grid(row=3, column=1, columnspan=3, sticky="w",
                            pady=(0, 4))

        # ── API key ──────────────────────────────────────────────────────────
        self._key_label = ttk.Label(frame, text="Anthropic API key:")
        self._key_label.grid(row=4, column=0, sticky="w", pady=(0, 4))
        self._key_var = tk.StringVar()
        key_entry = ttk.Entry(frame, textvariable=self._key_var, width=52,
                              show="*")
        key_entry.grid(row=4, column=1, columnspan=2, sticky="ew",
                       pady=(0, 4))
        ttk.Checkbutton(
            frame, text="Show",
            command=lambda: key_entry.config(
                show="" if key_entry.cget("show") == "*" else "*"
            ),
        ).grid(row=4, column=3, padx=(4, 0), pady=(0, 4))

        # ── Status / progress ────────────────────────────────────────────────
        self._progress = ttk.Progressbar(frame, mode="determinate",
                                          maximum=100)
        self._progress.grid(row=5, column=0, columnspan=4, sticky="ew",
                            pady=(8, 4))
        self._status_var = tk.StringVar(value="Ready to retry.")
        ttk.Label(frame, textvariable=self._status_var,
                  foreground="gray").grid(row=6, column=0, columnspan=4,
                                          sticky="w")

        # ── Buttons ──────────────────────────────────────────────────────────
        btn_frame = ttk.Frame(frame)
        btn_frame.grid(row=7, column=0, columnspan=4, pady=(10, 0))
        self._retry_btn = ttk.Button(btn_frame, text="Retry OCR",
                                      command=self._start_retry)
        self._retry_btn.pack(side="left", padx=(0, 8))
        ttk.Button(btn_frame, text="Close",
                   command=self.destroy).pack(side="left")

        self.geometry("560x480")
        self.grab_set()

    def _on_provider_change(self, *_):
        provider = self._provider_var.get()
        models = App._MODELS.get(provider, [])
        self._model_cb.config(values=models)
        if models:
            self._model_var.set(models[0])
        self._key_label.config(
            text=App._API_KEY_LABELS.get(provider, "API key:"))

    def _start_retry(self):
        api_key  = self._key_var.get().strip()
        provider = self._provider_var.get()
        model    = self._model_var.get()
        if not api_key:
            messagebox.showerror("Missing API key",
                                 "Please enter your API key.", parent=self)
            return
        self._retry_btn.config(state="disabled")
        self._status_var.set("Retrying…")
        threading.Thread(
            target=self._retry_process,
            args=(api_key, provider, model),
            daemon=True,
        ).start()

    def _retry_process(self, api_key: str, provider: str, model: str):
        total      = len(self._recitations)
        errors     = []
        lock       = threading.Lock()
        done_count = [0]
        ok_count   = [0]
        max_workers = 4

        def _do_one(rec):
            name, img_path, work_path, out_path = rec

            try:
                ocr_text = App._call_ocr(provider, work_path, api_key,
                                         model, 1_024)
            except RecitationError:
                with lock:
                    errors.append((name, "Still blocked by copyright filter"))
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return
            except Exception as exc:
                with lock:
                    errors.append((name,
                        f"OCR error ({type(exc).__name__}): {exc}\n"
                        f"  file: {work_path}"))
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return

            if not ocr_text:
                with lock:
                    errors.append((name, "OCR returned no text"))
                    done_count[0] += 1
                    d = done_count[0]
                self.after(0, self._set_progress, d, total)
                return

            # Rebuild the PDF with real OCR text
            try:
                build_pdf(work_path, ocr_text, out_path, provider, model)
                with lock:
                    ok_count[0] += 1
            except Exception as exc:
                with lock:
                    errors.append((name, f"PDF error: {exc}"))

            with lock:
                done_count[0] += 1
                d = done_count[0]
            self.after(0, self._set_progress, d, total)

        self.after(0, self._status_var.set,
                   f"Retrying {total} image(s) with {max_workers} workers…")

        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(_do_one, rec) for rec in self._recitations]
            for f in as_completed(futures):
                try:
                    f.result()
                except Exception:
                    pass

        self.after(0, self._on_retry_complete, ok_count[0], total, errors)

    def _set_progress(self, done: int, total: int):
        self._progress["value"] = (done / total) * 100

    def _on_retry_complete(self, ok: int, total: int, errors: list):
        self._retry_btn.config(state="normal")
        if not errors:
            self._status_var.set(f"Done — {ok}/{total} PDFs updated.")
            messagebox.showinfo("Retry Complete",
                f"All {total} PDF(s) re-created with OCR text.",
                parent=self)
        else:
            self._status_var.set(
                f"Done — {ok}/{total} succeeded, {len(errors)} failed.")
            err_lines = "\n".join(f"• {n}: {m}" for n, m in errors[:10])
            if len(errors) > 10:
                err_lines += f"\n…and {len(errors) - 10} more"
            messagebox.showwarning("Retry Complete",
                f"{ok}/{total} PDF(s) updated.\n\nFailed:\n{err_lines}",
                parent=self)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = App()
    try:
        app.mainloop()
    finally:
        shutil.rmtree(app._temp_dir, ignore_errors=True)
