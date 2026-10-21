# Screening brief (Phase 1, processing review)

Project: Archive Suite, Mac apps that turn phone photographs of archival boxes (US 20th-century papers mostly:
typed letters, memos, forms, clippings, handwriting; plus a public 895-page set of older hands, print, newspapers,
non-Latin scripts) into PDFs that are segmented into documents, dated, and OCRed. Users range from a laptop only,
to cheap API access (OpenRouter), to premium APIs and subscriptions, to university GPU clusters (Stanford Sherlock,
FarmShare). The review asks whether a staged pipeline of specialist models beats one-shot frontier vision-language
models, per user profile, and what to test. Today is 2026-10-20: prefer 2024-2026 work, but include the
foundational papers a field builds on.

Your job is to SCREEN, not to read deeply. Search widely: arXiv, Semantic Scholar (api.semanticscholar.org,
including its citations endpoint for forward citations), ACL Anthology, ICDAR / ICFHR / HIP / DAS / JCDL / DH
proceedings, Hugging Face (models, datasets, papers), GitHub, Papers with Code. Follow citations forward from the
seed papers. Do not rely on memory for what exists: every entry must have a URL you actually fetched or saw in a
search result. Say which.

Output: write ONE markdown file at the path given in your task, with:
1. Search log: the queries and sources you used (short).
2. Candidate table, one row per paper / model / dataset / benchmark: id, title, year, venue, URL, kind (method,
   benchmark, dataset, model, survey, thesis), one-line claim with its headline figure if the abstract gives one,
   code/weights available (yes/no/unknown, with link), licence if visible, verdict READ (worth a full read: we
   would build on it or test it), SKIM, or DROP, and a one-line reason for the verdict.
3. A READ shortlist of at most 8, ranked, each with why it matters to us specifically and what test on our
   material it suggests.
4. Benchmarks and datasets we could reuse or borrow (run ourselves), with licence, size, and how close they are
   to archival photographs.
5. Open questions the deep read should settle.
Aim for 30-60 candidates. Keep dropped items in the table: the shortlist must be auditable. Plain declarative
prose. Do not write anywhere else. Do not spend money (no paid APIs). Do not log in anywhere.
