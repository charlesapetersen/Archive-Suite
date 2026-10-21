# Kind churn inside documents — W46.fix-seg-scorers (K-kinds test 5)

Made by `scripts/segbench/kind_churn.py` (method in its docstring): the shipped page-kind classifier (`kind-classifier-model.json`) on every document page of the five owner boxes, grouped by the truth's documents. No per-page kind truth exists here, so every change counted is the classifier's.

- 848 document pages in 463 documents; 193 documents have two or more pages (578 pages).
- Hands called: handwritten 14, printed 363, typewritten 471; form or table on 6 pages.
- **24 of 193 multi-page documents (12.4%) hold more than one hand**; 2 (1.0%) mix form and non-form pages.
- By box (documents with a hand change / multi-page documents): Dean 0/35, Deaver 1/39, Herrnstein 5/41, Stanton 11/63, RG165 7/15.
- The hands that meet: printed + typewritten 21, handwritten + printed 2, handwritten + typewritten 1.
- 28 pages differ from their document's majority hand: between 10, first page 5, last page 13.
- Their median confidence is 0.776 against 0.988 for all pages; **16 of the 28 are below the app's 0.8 floor**, against 78 of all 848 pages (9.2%).

A document prior used only below the floor could change at most the minority pages below it; those above it would need the prior to overrule a confident call, which the K note's design does not propose.
