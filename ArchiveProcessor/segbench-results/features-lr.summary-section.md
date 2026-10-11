
## W36.seg-features — on-device feature model (development set, leave-one-collection-out)

Logistic regression on rule cues, TF-IDF similarity, length, blank, paper colour, ink, aspect and capture-time features; the -emb variants add on-device embedding similarities of adjacent pages (Apple Vision image feature print; NaturalLanguage sentence embedding of the whole page and of the seam, page n's last 400 characters against page n+1's first 400). Each development collection is predicted by a model fitted on the other two (Stanton and RG 165 untouched; photo labels from the truth). 551 pages is little data. Detail: features-lr-report.md.

| variant | collection | pages in exact doc | false splits | false merges | boundary F1 | error rate at the best >=50% coverage | Brier | ECE |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| base, with the time gap | Dean | 74.0% | 6 | 10 | 0.930 | 1.0% (1/104, coverage 54.5%) | 0.061 | 0.040 |
| base, with the time gap | Deaver | 17.0% | 1 | 51 | 0.559 | 37.9% (47/124, coverage 91.2%) | 0.344 | 0.350 |
| base, with the time gap | Herrnstein | 91.7% | 4 | 1 | 0.974 | 0.0% (0/84, coverage 50.3%) | 0.029 | 0.051 |
| base, with the time gap | pooled | 64.7% | 11 | 62 | 0.864 | 10.9% (41/375, coverage 75.9%) | 0.128 | 0.106 |
| base, without the time gap | Dean | 77.6% | 23 | 3 | 0.897 | 0.0% (0/96, coverage 50.3%) | 0.083 | 0.070 |
| base, without the time gap | Deaver | 0.0% | 2 | 81 | 0.067 | 54.7% (47/86, coverage 63.2%) | 0.448 | 0.443 |
| base, without the time gap | Herrnstein | 76.2% | 8 | 4 | 0.938 | 0.0% (0/84, coverage 50.3%) | 0.047 | 0.053 |
| base, without the time gap | pooled | 56.0% | 33 | 88 | 0.773 | 13.0% (40/308, coverage 62.3%) | 0.172 | 0.137 |
| embeddings, with the time gap | Dean | 69.4% | 4 | 13 | 0.924 | 0.8% (1/128, coverage 67.0%) | 0.068 | 0.062 |
| embeddings, with the time gap | Deaver | 23.4% | 11 | 39 | 0.643 | 36.0% (41/114, coverage 83.8%) | 0.319 | 0.310 |
| embeddings, with the time gap | Herrnstein | 89.0% | 3 | 4 | 0.963 | 0.0% (0/84, coverage 50.3%) | 0.029 | 0.040 |
| embeddings, with the time gap | pooled | 63.7% | 18 | 56 | 0.865 | 6.0% (15/251, coverage 50.8%) | 0.124 | 0.084 |
| embeddings, without the time gap | Dean | 81.1% | 3 | 11 | 0.938 | 0.0% (0/96, coverage 50.3%) | 0.065 | 0.051 |
| embeddings, without the time gap | Deaver | 17.7% | 14 | 42 | 0.600 | 40.2% (49/122, coverage 89.7%) | 0.362 | 0.331 |
| embeddings, without the time gap | Herrnstein | 87.8% | 4 | 4 | 0.957 | 0.0% (0/84, coverage 50.3%) | 0.036 | 0.027 |
| embeddings, without the time gap | pooled | 66.2% | 21 | 57 | 0.859 | 9.7% (24/248, coverage 50.2%) | 0.137 | 0.095 |

- base, with the time gap: the time gap ranks 2 of 26 by permutation importance; the strongest is next_salutation.
- base, without the time gap: top five next_salutation, next_pn_top_ge2, paper_diff, prev_closing, tfidf_cosine.
- embeddings, with the time gap: the time gap ranks 2 of 31 by permutation importance; the strongest is next_salutation.
- embeddings, with the time gap: embedding ranks img_embed_cos 5, text_embed_cos 13, seam_embed_cos 8.
- embeddings, without the time gap: top five next_salutation, paper_diff, img_embed_cos, next_pn_top_ge2, next_memo.
- embeddings, without the time gap: embedding ranks img_embed_cos 3, text_embed_cos 10, seam_embed_cos 7.

Reading (as of the 2026-10-11 run, on the owner-corrected truth of 8308b64, which is why the base rows moved from checkpoint 1's 59.3% / 52.5%): the embeddings stand in for the timestamps. Without the time gap they lift the pooled score from 56.0% to 66.2% of pages in an exact document and cut false merges from 88 to 57, level with the base model that has the time gap (64.7%); with the time gap they add nothing to the pooled score (63.7%) but improve its calibration (ECE 0.106 to 0.084) and its best >=50% coverage error (10.9% to 6.0%). The image feature print is the useful one (importance rank 3 of 30 without the time gap); the sentence embedding of the whole page ranks 10 and of the seam 7. Deaver (clippings) still fails, 17.7%-23.4%: two letter collections per fit cannot teach a third document type, and no feature here changes that. An on-device feature model is therefore far below the cloud windows (90%+) and useful, if at all, as a cheap extra voter for the ensemble, not alone.
