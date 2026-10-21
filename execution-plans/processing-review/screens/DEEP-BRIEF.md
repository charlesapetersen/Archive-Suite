# Deep-read brief (Phase 1, processing review)

You are doing the deep read for one strand of a processing review for Archive Suite, Mac apps that turn phone
photographs of archival boxes (mostly 20th-century US papers; a public 895-page set of older hands, print,
newspapers and non-Latin scripts) into segmented, dated, OCRed PDFs. User profiles: laptop only (Macs 16-64 GB+),
cheap APIs (OpenRouter), premium APIs and subscriptions, GPU clusters (Stanford Sherlock is the design target:
16 H100 and 32 L40S in its public gpu partition, 2-day jobs; FarmShare's L40S as fallback), and users with coding
agents who could train a model on their own photographs with a kit we provide. Owner rules: a reading copy may be
dewarped, deskewed or enhanced only without removing content (user option); content-removing enhancement may feed
OCR only; marks, annotations and stamps are evidence. Text placed on the page image is preferred to a separate
text page. Free cluster compute first; paid APIs only when needed, under a $3-per-item rule.

Inputs: the strand's screen (named in your task); our own measurements (paths in your task); the review plan
/Users/cp1/Claude/Archive Suite/execution-plans/processing-review/00-plan.md. The screen was done by a cheaper
model from abstracts and search snippets; treat its claims as leads to verify.

Do:
1. Read in full (arxiv.org/html/<id>, PDFs, model cards, READMEs, licences) the shortlisted items we would build on
   or test: at most about 8 full reads. Swap items in or out where reading shows the screen misjudged; say why.
2. Verify every figure you rely on in the source text, giving its location. Tag claims [M] measured in source,
   [I] your inference, [?] unverified.
3. Compare honestly with what we measured; say what transfers to photographed archival pages and what does not.

Write the strand note (path in your task) with sections: Question; What the field does now; Claims table (source,
claim, figure, conditions, tag, location); Code, weights, data and licences (Mac-runnable? cluster needs?);
Comparison with what we measured, including where a public benchmark makes our own less necessary and which
benchmark data, metrics or scorers we should borrow and run ourselves; strand-specific questions (named in your
task); Tests to run on our material, ranked, each with the profile it serves, its free route and any paid route
with a cost estimate; Open questions. Plain declarative prose. Do not write anywhere else, do not spend money, do
not log in. Report back a short summary of findings and the ranked tests.
