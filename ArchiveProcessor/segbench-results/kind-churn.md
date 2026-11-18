# Kind churn inside documents — W46.fix-seg-scorers (K-kinds test 5)

Made by `scripts/segbench/kind_churn.py` (method in its docstring): the shipped page-kind classifier (`kind-classifier-model.json`) on every document page of the five owner boxes, grouped by the truth's documents. No per-page kind truth exists here, so every change counted is the classifier's.

- 848 document pages in 463 documents; 194 documents have two or more pages (579 pages).
- Hands called: handwritten 14, printed 363, typewritten 471; form or table on 6 pages.
- **24 of 194 multi-page documents (12.4%) hold more than one hand**; 2 (1.0%) mix form and non-form pages.
- By box (documents with a hand change / multi-page documents): Dean 0/35, Deaver 1/39, Herrnstein 5/41, Stanton 11/64, RG165 7/15.
- The hands that meet: printed + typewritten 21, handwritten + printed 2, handwritten + typewritten 1.
- 29 pages differ from their document's majority hand: between 11, first page 5, last page 13.
- Their median confidence is 0.765 against 0.988 for all pages; **17 of the 29 are below the app's 0.8 floor**, against 78 of all 848 pages (9.2%).

A document prior used only below the floor could change at most the minority pages below it; those above it would need the prior to overrule a confident call, which the K note's design does not propose.

## Measurement card

- **Truth.** None for the page kind: these boxes have no per-page hand or form truth, so this is the classifier's consistency with itself inside a document, not its accuracy, and a change counted may be a real change of hand (a typed letter with a printed enclosure) or a classifier error. The documents are the owner's segmentation truth for Dean, Deaver, Herrnstein, Stanton and RG165; at the gaps the owner left unsure the document split follows the label the truth file carries, which nobody has confirmed. The classifier's own held-out accuracy is reported separately (`kind-classifier.md`).
- **Selection.** Every document page of the five owner boxes, label photos excluded; nothing chosen by the classifier.
- **Comparison.** None between routes: one classifier, the one the app ships, against the floor the app uses (0.8).
- **Noise.** One deterministic run, no interval and no rerun floor; the per-box counts are small (RG165 has 15 multi-page documents), so the box-to-box differences are not a finding.
- **Scope.** How much a document prior applied below the floor could change, which decides whether building one is worth it. It does not measure how often the classifier is right, whether a churned document is wrong, or what any change would do to OCR or segmentation.
