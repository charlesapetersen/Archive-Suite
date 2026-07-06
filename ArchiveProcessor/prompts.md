# Archive Processor — Model Prompts

## 1. OCR Prompt (Primary)

**Source:** `OCRPrompt.swift` — `build(previousText:previousImageIncluded:customPrompt:)`

Used for all providers except Mistral OCR (which uses a dedicated OCR endpoint with no custom prompt).

```
You are classifying and transcribing photographs from a historical archive collection.

TASK 1 — CLASSIFY this image. On the VERY FIRST LINE write exactly one tag:

[box_label] — A photograph of an archival STORAGE BOX or its label. Physical cues: cardboard box, printed or handwritten label affixed to the box, record group numbers, date ranges, collection identifiers. These are NOT documents — they are containers.

[folder_label] — A photograph of a FILE FOLDER divider, tab, or separator label. Physical cues: folder tab or edge, handwritten or typed label identifying folder contents, often brief text like a name, topic, or date range. These are NOT documents — they are organizers within a box.

[document_start] — The FIRST PAGE of a document. Signals include:
  • A letter salutation ("Dear ___")
  • A new date and/or new recipient/sender at the top
  • A memo header ("MEMORANDUM", "TO:", "FROM:", "SUBJECT:")
  • A title, headline, or report heading
  • Letterhead or institutional header from a different organization than the previous page
  • A printed form, table, or list that is clearly a new item
  • The previous page ended mid-page with blank space below (its document ended)
  Even if the topic is the same as the previous page, a new letter or memo is a NEW DOCUMENT.

[document_continuation] — A later page of the SAME document as the previous page. Signals:
  • Text continues mid-sentence from where the previous page ended
  • Sequential page numbers from the same document (e.g., previous page was "- 3 -", this is "- 4 -")
  • Same formatting, letterhead, and layout as the previous page with text flowing continuously
  A page is ONLY a continuation if it is clearly part of the same single document. When uncertain, prefer [document_start].

IMPORTANT: These photographs often show multiple papers stacked on top of each other. Other pages may be partially visible in the background. For classification and transcription, focus ONLY on the foreground page — ignore any background pages or partially visible documents.

TASK 2 — ORIENTATION (CRITICAL). Many of these photographs are rotated sideways or upside down as displayed in the raw pixels. You MUST examine the actual pixel orientation of text in the image — do NOT assume the image is upright just because you can read the text. Look at whether text baselines are horizontal, vertical, or inverted relative to the image frame.
On line 2, write the clockwise rotation needed to make the image upright:
[rotate_0] — Text baselines are horizontal and text reads left-to-right normally. Image is already correctly oriented.
[rotate_90] — Text baselines are vertical, reading bottom-to-top on the left side of the image. Needs 90° clockwise rotation.
[rotate_180] — Text is upside down (baselines horizontal but text is inverted). Needs 180° rotation.
[rotate_270] — Text baselines are vertical, reading top-to-bottom on the right side of the image. Needs 270° clockwise rotation.
IMPORTANT: Examine the raw visual orientation of text carefully. If text appears sideways or upside down in the image, it IS rotated — even if you can still read it.
When the image shows a folder with a tab, orient based on the folder tab and label, not fragments of documents visible inside the folder.

TASK 3 — TRANSCRIBE all visible text exactly as it appears, preserving formatting and layout. No commentary.

FORMAT — Your response MUST begin with the classification tag on line 1, rotation tag on line 2, then the transcribed text:
[classification_tag]
[rotate_N]
(transcribed text)
```

### When a custom prompt is provided:

```
ADDITIONAL CONTEXT from the user:
{custom prompt text}
```

### When previous page context is available (with image):

```
The FIRST image is the previous page. The SECOND image is the page you must classify and transcribe.

Previous page's text ended with:
"""
{previous page text}
"""
Use this to decide: does the current page continue the SAME document, or is it a NEW document? Look for changes in sender, recipient, date, format, or letterhead. A new date + new recipient = new document, even if the topic is similar.
```

### When previous page context is available (text only):

```
Previous page's text ended with:
"""
{previous page text}
"""
Use this to decide: does the current page continue the SAME document, or is it a NEW document? Look for changes in sender, recipient, date, format, or letterhead. A new date + new recipient = new document, even if the topic is similar.
```

---

## 2. Classification-Only Prompt (Pre-OCRed Files)

**Source:** `OCRPrompt.swift` — `buildClassificationOnly(text:previousText:customPrompt:)`

Used when PDFs already contain OCR text and only classification is needed (no image sent).

```
You are classifying a page from a historical archive collection based on its OCR text.

Classify this text as exactly one of these categories. Respond with ONLY the tag on a single line:

[box_label] — Text from a storage box label. Indicators: collection names, record group numbers, box numbers, date ranges, library/archive names, accession numbers. Typically short text with identifiers.

[folder_label] — Text from a folder tab or divider. Indicators: brief label text like a name, topic, or date range, folder identifiers. Very short text.

[document_start] — First page of a document. Indicators: letter salutation, date header, memo header, title, letterhead, new correspondence.

[document_continuation] — A later page of the same document as the previous page. Indicators: text continuing mid-sentence, sequential page numbers, same formatting.

OCR text of this page:
"""
{text, first 2000 chars}
"""
```

### When previous page context is available:

```
Previous page's text ended with:
"""
{previous text, last 500 chars}
"""
Use this to decide: does the current page continue the same document, or is it new?
```

### When a custom prompt is provided:

```
ADDITIONAL CONTEXT from the user:
{custom prompt text}
```

Ends with:

```
Respond with ONLY the classification tag (e.g., [document_start]). Nothing else.
```

---

## 3. Collection Name Extraction Prompt

**Source:** `CollectionSegmenter.swift` — `extractCollectionName(...)`

Used to extract the collection name from a box label's OCR text.

```
You are analyzing the OCR text from a photograph of an archival storage box label.
Extract ONLY the collection or archive name (the name of the person or organization whose papers are in this box).

Do NOT include:
- Library names (e.g. "Baker Library", "Hoover Institution")
- Box numbers (e.g. "Box 104", "Box 5 of 12")
- Accession numbers
- Date ranges
- Call numbers or MSS numbers
- Words like "Special Collections" or "Archives"

OCR text from box label:
---
{box text, first 2000 chars}
---

FORMATTING RULES:
- Use Title Case (capitalize each major word): "Joel Dean Papers" not "joel dean papers" or "JOEL DEAN PAPERS"
- Replace ampersands with "and": "Deaver and Hannaford" not "Deaver & Hannaford"
- Replace all special characters with words (e.g. "/" with "and", "#" with "Number")
- Keep it clean and readable

Respond with ONLY the collection name, nothing else. For example: "Joel Dean Papers" or "Deaver and Hannaford" or "Papers of Richard Herrnstein"
```

---

## 4. Collection Name Clustering Prompt

**Source:** `CollectionSegmenter.swift` — `clusterCollectionNames(...)`

Used to deduplicate and normalize collection names that may have slight variations.

```
You have the following collection names extracted from archival box labels. Some may refer to the same collection but with slight variations (different casing, extra whitespace, abbreviations, etc.).

1. "{name 1}"
2. "{name 2}"
...

Group these into unique collections. For each group, pick the best canonical name.

FORMATTING RULES for canonical names:
- Use Title Case (capitalize each major word)
- Replace ampersands with "and"
- Replace all special characters with words
- Keep names clean and readable

Respond with ONLY a valid JSON object mapping each input name to its canonical name. Example:
{
  "Joel Dean Papers": "Joel Dean Papers",
  "joel dean papers": "Joel Dean Papers",
  "DEAVER & HANNAFORD": "Deaver and Hannaford",
  "Deaver & Hannaford": "Deaver and Hannaford"
}

If all names are already unique and distinct collections, map each to itself (with corrected formatting).
Respond with ONLY the JSON object.
```

---

## 5. Tagging Prompt

**Source:** `TagGenerator.swift` — `generateTags(for:...)`

Used to generate metadata tags (date, subject, format, author, etc.) for a document segment.

```
You are a metadata tagging assistant for a historical archive.

Here is the OCR text of a document:
---
{document text, first 3000 chars}
---

Nearby documents for date estimation context (use only if this document's date is unclear):
---
{context text from up to 3 nearby segments, first 300 chars each, or "(none)"}
---

Please respond with ONLY a valid JSON object in this exact format:
{
  "year": "1987",
  "month": "03 March",
  "day": "Day 15",
  "date_uncertain": false,
  "subject_tags": ["Democratic Party", "elections", "legislation"],
  "format": "letter",
  "author_name": "John Smith",
  "recipient_name": "Jane Doe",
  "author_location": "Washington, D.C.",
  "recipient_location": "New York, NY",
  "publication_name": null
}

Rules:
- "year": 4-digit year string. ALWAYS provide a year — if not stated in the document, estimate from nearby documents or contextual clues. Never return null for year.
- "month": format "MM MonthName" (e.g. "03 March"). Provide ONLY if the month is explicitly stated in THIS document. NEVER infer or estimate the month from context or nearby documents. Return null otherwise.
- "day": format "Day D" (e.g. "Day 15", "Day 3"), or null if not determinable
- "date_uncertain": true if year cannot be determined from the document itself (even if estimated from context)
- "subject_tags": 2–6 general-but-specific subject tags (e.g. "Democratic Party", "taxes", "education", "transportation", "business", "literature", "economics", "foreign policy", "civil rights", "military", "journalism", "science", "health care", "labor unions"). Do NOT use overly broad terms like "politics" or "history".
  - **When a custom vocabulary is supplied**, this line is replaced with: `2–6 tags chosen ONLY from this controlled vocabulary: ["…", "…"]. Use only tags from this list that are relevant to the document. Do not invent new tags.`
- "format": document type, e.g. "letter", "memo", "newspaper article", "magazine article", "report", "draft", "speech", "press release", "telegram", "photograph", or null if unclear
- "author_name": author, sender, or writer name if identifiable, or null
- "recipient_name": recipient or addressee name if identifiable, or null
- "author_location": author's or sender's location if identifiable, or null
- "recipient_location": recipient's location if identifiable, or null
- "publication_name": newspaper, magazine, or publication name if applicable, or null
- Respond with ONLY the JSON object. No commentary.
```

---

## 6. Comparative Rotation Detection Prompt

**Source:** `LLMRotationDetector.swift` — `detectCorrection(...)`

A cheap vision-LLM (default `gemini-2.5-flash-lite`) is shown the SAME image in four candidate rotations (labeled A–D, at ~800px) and picks the upright one; optionally votes across several label orderings. Anthropic/Gemini only — the gateway and Mistral have no supported multi-image path (caller falls back to local Vision).

```
You are shown the SAME scanned document in four different rotations, labeled A, B, C, D. Exactly one of them is correctly upright: text horizontal, reading left-to-right, not upside down or sideways. Reply with EXACTLY one letter — A, B, C, or D — for the upright one. Nothing else.
```

---

## 7. Date-Only Tagging Prompt

**Source:** `TagGenerator.swift` — `generateDateOnly(for:...)`

Used by the auto-date manual tagging mode — cheaper than the full tagging prompt (no subject/format/author fields).

```
You are a date-extraction assistant for a historical archive.

OCR text of a document:
---
{document text, first 3000 chars}
---

Nearby documents for date-estimation context (use only if this document's date is unclear):
---
{context text from up to 3 nearby segments, first 300 chars each, or "(none)"}
---

Respond with ONLY a valid JSON object in this exact format:
{ "year": "1987", "month": "03 March", "day": "Day 15", "date_uncertain": false }

Rules:
- "year": 4-digit year string. ALWAYS provide a year — if not stated, estimate from nearby documents or contextual clues. Never null.
- "month": format "MM MonthName" (e.g. "03 March"). Provide ONLY if the month is explicitly stated in THIS document. NEVER infer or estimate the month from context or nearby documents. Return null otherwise.
- "day": format "Day D" (e.g. "Day 15"), or null if not determinable
- "date_uncertain": true if the year cannot be determined from the document itself (even if estimated from context)
- Respond with ONLY the JSON object. No commentary.
```

---

## Notes

- **Mistral OCR** uses Mistral's dedicated OCR endpoint (`/v1/ocr`) and does not receive a custom prompt. It returns markdown-formatted text.
- The OCR prompt (1) is sent with the image to Anthropic and Gemini providers, and also through the **OpenAI-compatible gateway** (`OpenAICompatibleClient` reuses `OCRPrompt.build`). For Anthropic, the previous page image can also be included alongside the current page image.
- All prompts truncate input text to prevent excessive token usage (2000–3000 chars for document text, 500 chars for previous page context).
