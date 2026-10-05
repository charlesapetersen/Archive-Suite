
## W36.seg-features checkpoint 1 — on-device feature model (development set, leave-one-collection-out)

Logistic regression on rule cues, TF-IDF similarity, length, blank, paper colour, ink, aspect and capture-time features; each development collection predicted by a model fitted on the other two (Stanton and RG 165 untouched; photo labels from the truth). 551 pages is little data. Embedding features (image and text) are checkpoint 2. Detail: features-lr-report.md.

| variant | collection | pages in exact doc | false splits | false merges | boundary F1 | error rate at the best >=50% coverage | Brier |
|---|---|---:|---:|---:|---:|---:|---:|
| with the time gap | Dean | 73.0% | 6 | 10 | 0.930 | 3.6% (4/112, coverage 58.6%) | 0.078 |
| with the time gap | Deaver | 9.9% | 2 | 67 | 0.303 | 45.5% (40/88, coverage 64.7%) | 0.380 |
| with the time gap | Herrnstein | 82.9% | 10 | 2 | 0.938 | 2.5% (3/120, coverage 71.9%) | 0.059 |
| with the time gap | pooled | 59.3% | 18 | 79 | 0.814 | 13.5% (51/378, coverage 76.5%) | 0.155 |
| without the time gap | Dean | 72.4% | 23 | 8 | 0.876 | 1.0% (1/101, coverage 52.9%) | 0.099 |
| without the time gap | Deaver | 0.0% | 3 | 79 | 0.068 | 50.6% (41/81, coverage 59.6%) | 0.429 |
| without the time gap | Herrnstein | 71.8% | 10 | 5 | 0.921 | 2.0% (2/101, coverage 60.5%) | 0.067 |
| without the time gap | pooled | 52.5% | 36 | 92 | 0.757 | 14.3% (45/314, coverage 63.6%) | 0.179 |

With the time gap, it ranks 2 of 26 features by permutation importance; the strongest is next_salutation. Top features without the time gap: next_salutation, next_pn_top_ge2, tfidf_cosine, paper_diff, prev_closing.

Reading (as of the 2026-10-05 run): the pooled figures are pulled down by Deaver, mostly newspaper clippings. Its boundaries carry none of the letter cues the other two collections teach (salutation, closing), and the features that do separate them there (TF-IDF similarity, a lower-case first line, orientation change) are flat in Dean and Herrnstein, so the model fitted on those two calls nearly every Deaver gap a continuation. Two collections per fit cannot teach a third document type. The 'best >=50% coverage' column picks its cut on the same held-out predictions, so it is optimistic; the threshold rows in the report are the fixed-cut view.
