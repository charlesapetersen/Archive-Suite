# Dating: the typeface probe (W46.date-image-paid, B test 9)

Written by `scripts/segbench/date_image_gateway.py typeface`. Gemini 3.7 Flash through the Stanford AI API gateway (temperature 0, reasoning low) on 12 crops of the first page of documents from W46.date-image's pack that Qwen3.6-27B found no written date on (20 of the 122; the first 12 by class, D first): the top 22% of the page for the even ones (letterhead), the band from 35% to 60% for the odd ones (typewriting), cut by position. Each was asked for the typeface or machine, the features it rests on and the years it fits, judging the letterforms only. **Checkable**: a named typeface or machine, with features and an earliest year. **Consistent**: the owner's year lies within the years it gave. Spend about $0.027 for 12 replies (3.8's list price as a ceiling).

- Parsed 12/12. What the crops show, by the reply: typewritten 6, printed 5, handwritten 1.
- Named a typeface or machine: 11/12; checkable: 11/12; consistent with the owner's year: 11/11. Width of the range given: median 50 years (from 25 to 90).

| doc | class | crop | shows | typeface | machine | years | owner's year | consistent | confidence |
|---|---|---|---|---|---|---|---|---|---|
| eea32dd7 | D | letterhead | printed | Bodoni / Modern display serif | - | 1930-1980 | 1948 | yes | high |
| 8497e0c5 | D | body | typewritten | Pica | - | 1920-1980 | 1957 | yes | medium |
| d0d7a60c | C | letterhead | handwritten | - | - | - | 1976 | - | high |
| 69d338c4 | C | body | typewritten | Pica | - | 1930-1985 | 1978 | yes | medium |
| e005e129 | C | letterhead | typewritten | Pica | - | 1920-1980 | 1949 | yes | medium |
| 406e716d | C | body | printed | Times New Roman / Futura | - | 1950-1975 | 1975 | yes | high |
| 8012cef5 | C | letterhead | printed | Alternate Gothic / Condensed Sans-Serif | - | 1950-1985 | 1970 | yes | medium |
| e05d89ab | C | body | printed | Century Expanded / Modern Serif | - | 1900-1990 | 1974 | yes | medium |
| 38ba0414 | B | letterhead | typewritten | Standard Pica | Manual Typewriter (Underwood/Royal/Smith-Corona) | 1920-1965 | 1959 | yes | medium |
| 27dfa6ca | B | body | typewritten | Courier | IBM Selectric | 1961-1990 | 1982 | yes | high |
| cd5e7620 | B | letterhead | printed | Helvetica | - | 1957-1985 | 1967 | yes | high |
| 3a60a7e4 | A | body | typewritten | Pica | Standard Manual Typewriter | 1920-1980 | 1968 | yes | medium |

## Reading it

(written by hand; a rerun keeps everything below this heading)

**Yes, something checkable comes back; no, it does not date a document.** Eleven of the twelve replies name a typeface
or machine, list the features they rest on and give a range of years, and the owner's year lies inside all eleven. The
ranges are what make that easy: a median 50 years, "Pica, 1920-1980" four times. Two answers carry a lower bound sharp
enough to check against a type history (the IBM Selectric with its Courier element, from 1961; Helvetica, from 1957);
that is the forensic use (B44), a bound on a forgery, not a year for an archive. The one handwritten letterhead crop
was answered as handwriting, so a position-cut crop that misses is visible. A date on the page gives the year, a neighbour a candidate year
with its evidence; this gives decades. Not filed for a larger test.
