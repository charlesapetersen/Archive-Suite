# The evidence checker's false refusals (W46.date-evidence-check)

`date_scorers.evidence_check` re-scored on the 27B's cached trace-neigh replies on Apple Vision text (296 replies with a year, the owner's 300), the context rebuilt from the prompts sent. Script: `scripts/segbench/date_evidence_check.py`. No model was called.

## Findings

- **The widened checker accepts 27 more citations; the right-year refusals fall from 49 to 28.** Valid / unsupported: 216 / 80 before, 243 / 53 after. Of the 27: 26 two digits, 1 ocr damage. Every one is listed below and was read: each quote is in the cited text and does carry the year given.
- **6 of the newly valid citations give a wrong year.** The check is for traceability, not truth: "3/25/68" in a neighbour does carry 1968, whether or not the document is from 1968. Before, the valid set held 49 wrong years; after, 55.
- **53 are still refused, 28 of them with the right year, and those refusals are meant.** Most quote text with no date in it ("Some people would bar President Truman, others Senator Taft."), or a different year as written ("APRIL 25, 1938" for 1988, "BUSINESS WEEK November 5, 1966" for 1968). A digit read as another digit is not accepted: the weekday does not separate the two, since April 25 was a Monday in 1938 and in 1988. A few are damage the checker does not read ("FALL 19/70", "9 0et 75", "June 20, 19 23"), each one case.
- **What this changes for the route.** W46.date-route's estimate step writes a year only when this check passes, and the owner's call 9 kept failed estimates hidden until it was fixed. A valid reason that is not four digits names how the year was read ("(two digits)", "(ocr damage)"), so the route can show the evidence class beside the quote.

## Measurement card

- **Truth:** the owner's date tags (date_truth, the 300), used only to say whether a year is right; the verdict itself needs no truth. The newly accepted quotes were read by this session against the rule.
- **Selection:** every trace-neigh reply with a year on the owner's 300; none chosen by a tested route or by ABBYY text. The checker is in-sample: its new forms and its exclusions were written from these same 296 replies (the forms are rows of the accepted table below, the tests are the quotes the 27B's refused right years cited), so "right-year refusals 49 → 28" is its fit to them, not a figure off them; W46.date-route-pipeline's fresh replies give the first out-of-sample counts.
- **Comparison:** the same replies, the same contexts, the checker before and after.
- **Noise:** none from sampling; it is a deterministic re-score of fixed replies. The change in counts is exact.
- **Scope:** one model (Qwen3.6 27B), one prompt (trace-neigh), Vision text. The corpus-text replies behind date-traceable.md's "49 of 101" and the Gemini arm's replies (45 of 131 failing) are in the owner's backup since 30 Oct and were not re-scored; W46.date-route-pipeline makes fresh Gemini and 27B replies and scores them with this checker. Whether a two-digit year's century is right is the year's question, not the quote's.

## The 27 citations now accepted

| year | right | how | cited quote |
|---|---|---|---|
| 1961 | yes | ocr damage | self: "June 29, 196L" |
| 1968 | no | two digits | N2: "3/25/68" |
| 1970 | yes | two digits | self: "Dec. 70" |
| 1968 | yes | two digits | self: "8/4/68" |
| 1969 | no | two digits | self: "J.B. 6/18/69" |
| 1982 | yes | two digits | N2: "27 Oct 82" |
| 1970 | yes | two digits | self: "10/6/70" |
| 1973 | yes | two digits | self: "25.1.73" |
| 1969 | yes | two digits | self: "1/22/69" |
| 1968 | no | two digits | self: "3/29/68" |
| 1968 | yes | two digits | P2: "9/25/68" |
| 1973 | yes | two digits | self: "8/31/73" |
| 1982 | yes | two digits | N3: "NA POST 1/31/82" |
| 1940 | no | two digits | self: "28 Jan. '40" |
| 1987 | yes | two digits | self: "8-3-87" |
| 1968 | yes | two digits | P3: "9-16-68,43" |
| 1953 | yes | two digits | self: "5/29/53" |
| 1977 | yes | two digits | self: "10-4-77" |
| 1984 | yes | two digits | self: "ANNUAL REPORT FOR 1983-84" |
| 1949 | yes | two digits | P1: "7/28/49" |
| 1940 | yes | two digits | N2: "20 Mar. '40" |
| 1976 | yes | two digits | self: "20.2.76" |
| 1999 | no | two digits | self: "11/14/99" |
| 1967 | yes | two digits | self: "SES - Interim Review and Report - 8/31/67" |
| 1958 | yes | two digits | self: "9/24/58" |
| 1999 | no | two digits | self: "Harry Sello 1/25/99" |
| 1981 | yes | two digits | self: "12.9-81" |

## Still refused (53)

| reason | n | of them right |
|---|---|---|
| quote does not carry the year given | 47 | 24 |
| quote is not in the cited document's text | 5 | 4 |
| cited document is not in the context given | 1 | 0 |

Right years still refused:

- 1969, self: "February 12, 1961"
- 1975, self: "FIVE YEARS OF HIGHLIGHTS-SUNNYVALE SOUTH BAY N.O.W. CHAPTER"
- 1937, self: "Jun 1, 19."
- 1982, self: "FY 20 miles"
- 1970, self: "FALL 19/70"
- 1958, self: "Stanford Book Notes No. 4. The Affluent Society, J.K. Galbra…"
- 1961, self: "1961"
- 1971, self: "Three landmark social documents of the past five years-by Da…"
- 1985, self: "10/25"
- 1973, self: "Notes for Ford Foundation Discussion, June 20, 19 23"
- 1984, self: "renamed it the USA Committee in 1984"
- 1980, self: "With Ronald Reagan's victory... Silicon Valley executives ar…"
- 1975, self: "9 0et 75"
- 1959, N1: "The advertisement on the adjoining page is the first of a se…"
- 1981, self: "(Ik-81)"
- 1978, self: "Mere. 2/4/28"
- 1987, self: "SATURDAY, FEBRUARY 28, 1937"
- 1959, self: "1859 Admissions"
- 1981, self: "A3221"
- 1950, self: "Some people would bar President Truman, others Senator Taft."
- 1956, N1: "Irving Kristol, who was co-editor of "En- counter" in London…"
- 1968, P2: "BUSINESS WEEK November 5, 1966"
- 1968, P2: "At a conference held in Boca Raton the weekend of November 2…"
- 1972, self: "CLEVELAND, May 13"
- 1926, self: "MO NEV/YORK NY SEPT 10-26"
- 1988, self: "MONDAY, APRIL 25, 1938"
- 1980, self: "The Dynamics of Process-Product Life Cycles™ (coauthor, Stev…"
- 1982, self: "Things are different in the 80's."
