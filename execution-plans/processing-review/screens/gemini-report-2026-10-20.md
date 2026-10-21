# The owner's Gemini research report (2026-10-20) — assessment

The owner supplied a Gemini-written report, "A Holistic Review of Document Packet Recognition and Splitting for
Archival Research" (about 4,400 words; the original stays in the owner's Downloads). Read 2026-10-20.

- HR-DocStream does not exist. The report names it twice as a historical page-stream benchmark; asked for a link,
  the same session said it could not find one. Strand A's screen and deep read searched for it five times and
  found nothing. The plan treats it as invented.
- "PoliTax Split" is real (corrected 2026-10-20 after the owner pointed to https://www.extend.ai/benchmarks): Extend's
  splitting benchmark of the 30 largest compound filings in the public PoliTax tax corpus, hundreds of pages each,
  dataset on Hugging Face, boundary F1, published 2026-03-30. Extend's splitting harness beat direct calls to the
  same frontier models by 17-44 points of recall (best F1 72.48%, Claude Opus 4.6). Tax filings, not archival,
  but its harness-versus-direct finding bears on how we window and prompt. Strand A's screen missed it.
  "The ICDAR 2021 and 2023 document stream segmentation competitions" remain unverified.
- The report recommends a fixed modular order: image enhancement first, then a specialist splitter, then OCR and
  dating. Its evidence for enhancement is the Rényi DIE blog's single damaged page. It does not consider that
  content-removing enhancement destroys marks (the owner's rule), and it does not compare with one-shot
  vision-language models, which our measurements and strand D's screen (TeleOCR: dewarping helps staged pipelines
  more than end-to-end VLMs) suggest are less helped by enhancement. Its vendor accuracy figures are invoice
  benchmarks.
- Useful additions not in the screens: Google Document AI's Custom Splitter and Azure AI Document Intelligence's
  custom classification and composed models, both trainable from a few labelled documents. They belong in the
  paid profile as candidates to price and, if cheap enough, to test on the locked boxes. Label Studio and
  Prodigy are noted as annotation tools for the small labelled sets the gap audit needs.

## Other benchmarks the owner pointed to

- https://www.extend.ai/benchmarks (read 2026-10-20): RealDoc-Bench (parsing layout and reading order plus Q&A, 1,500
  layout samples, code on GitHub and data on Hugging Face, 2026-05-26), LongArray-Extract (array extraction, 45
  PDFs), PoliTax Split (above). All regulated-industry or business documents; none historical or photographed; no
  OCR benchmark. RealDoc-Bench's layout set is a candidate anchor for strand E.
