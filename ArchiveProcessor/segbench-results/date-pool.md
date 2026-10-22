# Dating: the agreed pool classed A to D, the stratified 200 and the masked-date set (W46.fix-date-truth-score)

Written by `scripts/segbench/date_pool.py` (B-dating.md test 7). The pool is the W41 date-tagging pool (documents whose gaps the owner's labels agree on, with a year tag and text), less the 300 already sampled. Classes as in `date-truth.md`. The sets themselves stay private in the bench cache (`date-tagging/pool/`). No model call, $0.

Year-tagged pool documents with text: 4690; the year is printed in the first 3,000 characters of 2679 and not printed in 2011.

| class | unprinted-year documents | of them Date Uncertain | in the stratified 200 |
|---|---|---|---|
| A | 410 | 14 | 40 |
| A' | 171 | 6 | 40 |
| B | 528 | 22 | 40 |
| C | 736 | 31 | 40 |
| D | 166 | 2 | 40 |

The stratified 200 takes an equal share per class, seed 46, so the rare classes are not drowned by the common one; per-class figures from it are unweighted, and a pool-wide figure needs the class weights above. Per the owner's Phase 2 decision 2 (labelling: judgement sets to the owner, the rest drafted by models and audited), the 200 are drafted by models, then audited; the owner's 54 answers (`date-truth-sets.md`) are the calibration for that draft. The 54 showed that most unprinted years sit on the page itself, so the draft asks first for a date on the document's own pages.

The masked-date set: 200 printed-year documents, stratified by tag class year 97, year+DU 5, year+month 98, with the owner's year removed from the document's text in every written form. The year survives in the text on 8 (a form the masker does not catch) and in the neighbours' context on 83; scorers split on both flags. Truth is exact: the year was printed.
