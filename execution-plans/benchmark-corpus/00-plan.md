# A broader OCR benchmark corpus — plan (W43.corpus-plan)

Owner request, 2026-10-16: more documents, more kinds, more periods and more scripts than his own boxes, because
the app is for other researchers. This plan answers the item's questions and ends in one owner decision
(`W43.corpus-plan-owner-ok`), which `W43.corpus-build` waits on. Written 2026-10-16 by an unattended session. It
made no paid calls and downloaded nothing. The research agents' `curl`, Chrome and WebFetch calls to loc.gov and
transcription.si.edu were denied or returned 403, so every format and convention below comes from a source's
README, dataset card or paper. **Corpus-build's first step is to open one page from each chosen source and confirm
it** (§7).

Part 1 is for the owner. Part 2 is the detail behind it.

---

## Part 1 — the proposal and the decision

**What the numbers say about size.** The 96-page panel cannot separate two routes that are 1 NES apart, and it
cannot separate most pairs that are 3 NES apart. A failed page scores 0, so per-page differences are heavy-tailed.
For most close pairs the median per-page difference is under 1 NES, but its SD is 14-20. Scoring the failure rate
as its own figure, with NES over the pages both routes answered, halves that SD to about 9.7 (median of 244 close
pairs) and cuts the pages needed by about four times. Even then, separating a typical pair 1 NES apart takes about
730 pages, and a harder stratum takes more (§4). So a single stratum can rank routes only coarsely: with 80 pages
it separates about 3 NES, and with 40 pages about 4.3. The pooled public set is what separates 1 NES.

**Proposed strata.** There are fifteen new strata on top of the frozen 96. Nine are Latin-script strata of 80 pages
each, the app's main audience. Six are other-script strata of 40 pages each, enough to say whether a script works,
but not to rank close routes within it.

| # | stratum | period | main source (licence) | images publishable? | contamination |
|---|---|---|---|---|---|
| S0 | **the owner's 96, frozen, unpublished** | 1930-2000 | owner | no | none |
| L1 | English letters and diaries, handwritten | 1850-1950 | LoC By the People (public domain) | yes | high |
| L2 | English manuscripts | 1700-1850 | By the People (founding-era campaigns) + Bentham R0 (CC BY) | yes | high |
| L3 | typescripts, carbons and telegrams | 1880-1980 | By the People typed campaigns + TAPUS/DAHN French typescripts (licence to check) | yes / check | high / low |
| L4 | ledgers, forms and tables | 1800-1950 | Smithsonian Transcription Center (licence per project; NARA public domain for Freedmen's Bureau) | per project | high |
| L5 | Dutch and Romance archival hands | 1600-1850 | VOC/WIC and notarial GT (CC BY) + HTR-United Castilian and iForal (CC BY/BY-SA) | yes | medium |
| L6 | German Kurrent and secretary hands | 1500-1900 | READ 2017, Konzilsprotokolle (CC BY) + 19th-c. Kurrent, Zenodo 17252677 (CC BY / NC-SA) | yes | low-medium |
| L7 | medieval and early-modern charters | before 1600 | HTR-United Königsfelden (CC BY) | yes | low |
| L8 | printed books and pamphlets, incl. Fraktur | 1500-1900 | OCR-D `gt_structure_text` (CC BY-SA) | yes | medium-high |
| L9 | newspapers, from microfilm | 1850-1920 | BLN600 (CC BY-NC-ND) + NewsBench's 19 LoC pages (public domain) + Europeana Newspapers PAGE GT | NewsBench only | low / high |
| N1 | Arabic manuscripts (Ruq'ah) | 1800-2000 | Muharaf public part (CC BY-NC-SA) | yes, NC-SA | low |
| N2 | Cyrillic | early 1700s | Digital Peter (MIT) | yes | medium |
| N3 | Greek minuscule | c.1500 | EPARCHOS (CC BY) | yes | low |
| N4 | Hebrew book hands | medieval | BiblIA (CC BY-NC-SA) | yes, NC-SA | low |
| N5 | Chinese print | modern + historical | OmniDocBench ZH (research only) + MTHv2 (research only) | **no** | high / medium |
| N6 | Devanagari print | 19th-20th c. | HTR-United's Devanagari print set (licence to check) | check | low |

Kinds the axes ask for that have no good page-level public source: phone photographs of archival pages (every
public set is a flatbed, overhead or microfilm scan), post-1950 archival material other than the owner's, and
historical CJK handwriting. Phone capture stays covered by S0 alone. Forms and receipt sets (FUNSD, XFUND, SROIE,
CORD) and olmOCR-Bench are left out because they have no page-level text.

**Which scripts the app should claim.** Claim Latin script, diacritics included, for print, typescript and
handwriting, on both the cloud and the on-device routes. Claim Cyrillic, Arabic, Chinese, Japanese and Korean
print on both, once N1, N2 and N5 have measured them. Apple Vision on macOS 26.6 reads those scripts, plus Thai,
Vietnamese and Turkish (§2.3). Claim Greek, Hebrew and Devanagari for the cloud routes only, because Apple Vision
does not read them, and only after N3, N4 and N6 show a usable score. Treat blackletter, Kurrent and pre-1600
hands as "cloud models, check the result" unless L6-L8 show otherwise.

**Contamination.** By the People, Bentham, NewsBench and OmniDocBench are on the open web and probably in the
models' training data. Every report gives three figures: S0 alone, the low-contamination public strata, and the
high-contamination public strata. A model that is much better on the high strata than on the low strata of the same
kind is reciting text it has seen, not reading the page. S0 stays the unpublished reference.

**The owner's question, 2026-10-16 (interactive session, after this plan was written).** The owner asked whether
any public source can be uncontaminated, since every proposed stratum already has a published transcription. This
plan's "low-contamination" strata are a guess, not a measurement. Its only clean stratum is S0, and §4 shows that
96 pages cannot separate close routes. A model can memorise a transcription, but it cannot memorise a page that has
never been transcribed. So public images with no published transcription are clean, even when the images have been
online for years. The Library of Congress, NARA and the Internet Archive hold many such pages. The cost is that we
make the truth ourselves, as the 96 were made: two models draft and a person adjudicates. That took the owner about
89 minutes per 100 pages (an estimate in `ocr-truth.md`, not measured). Several hundred clean pages would be needed
to rank close routes. Scripts the owner does not read would need another adjudicator, or would get weaker truth.
This changes the claim above that no adjudication is needed. The decision below should settle it before
corpus-build starts.

**Cost.** These are measured costs per page, not the brief's 2,500/500 tokens a page, which was never measured
(§5). Gemini 3.8 Flash costs about $0.0035 a page and Qwen3-VL 235B about $0.0012. Other-script pages get 50%
headroom for denser output. Only new pages are counted, because the 96 are already scored on both routes. Apple
Vision is free.

| option | new pages | separates, per stratum | separates, pooled | corpus-build's 3 reference routes | the sweep's 8 models | the sweep's 11 |
|---|---:|---|---|---:|---:|---:|
| **A — recommended** | 960 (9×80 + 6×40) | ~3 NES (Latin), ~4.3 (other scripts) | ~0.9 NES | **~$5.10** | ~$8.60 | ~$28 |
| B — lean | 510 (9×40 + 6×25) | ~4.3 / ~5.5 NES | ~1.2 NES | ~$2.75 | ~$4.90 | ~$17 |
| C — Latin only | 720 (9×80) | ~3 NES | ~1.0 NES | ~$3.40 | ~$6 | ~$20 |

Every option except B's corpus-build passes the $3 rule, so the owner's "yes" here is also the cap for
`W43.corpus-build`. The sweep is priced so that its own gate is no surprise. It asks again when it runs, with
measured figures.

**Owner time.** No adjudication is needed: every proposed source already has reviewed human transcriptions. The
build checks each source's convention on a few pages and keeps the pages where the truth does not match its image
(§3). The owner is asked one thing, below. No owner review session is timely now: there is nothing built to review,
and corpus-build will change the material. Corpus-build judges that again when it has a sample to show (§8).

**The decision (`W43.corpus-plan-owner-ok`).**
1. Strata and sources: the fifteen above, or a subset (for example C, Latin only).
2. Size: A (960 pages, about $5.10 for corpus-build), B (510, about $2.75) or C (720, about $3.40).
3. Publication: show page images on the published ArchiveOCRBench only from sources whose licence permits it
   (public domain, CC0, CC BY, BY-SA and MIT, plus NC-SA on a non-commercial page), and scores only for the rest.
   N5's research-only sources would publish scores only.
4. Optional: ask socOCRbench's author to share the set or run our candidates. The plan does not depend on it,
   and nothing has been sent.
5. Clean pages (added 2026-10-16, from the owner's question above): whether to add strata of public images with
   no published transcription, adjudicated as the 96 were, and rest the recommendations on them and S0, with the
   transcribed public strata as a contamination check. The figures to decide on are how many pages, which kinds
   and scripts, and the owner's adjudication time. If yes, corpus-build first prices that time on a small sample.

**Owner decision, 2026-10-16 walkthrough (`W43.corpus-plan-owner-ok` ticked).** (1) The strata and sources as
proposed: the frozen 96 plus the fifteen public strata. (2) Size A, 960 new pages, about $5.10 for corpus-build; the
owner's yes is corpus-build's cap. (3) Scores only: no third-party page images on the published ArchiveOCRBench,
whatever the licence. (4) Do not ask socOCRbench's author for now. (5) No clean strata. The owner can adjudicate
only English, so he declined untranscribed pages; for other languages the existing transcribed sets are relied on.
S0 stays the one unpublished reference, and the public strata are reported as possibly contaminated, as above.
Segmentation, asked after the decision: the owner suggested public digital collections already split into one file
per document (a letter, a memo) as segmentation truth. `W43.seg-corpus-plan` researches it; it is not part of this
decision.

---

## Part 2 — detail

### 1. Axes and how the strata cover them

| axis | covered by | gap |
|---|---|---|
| handwritten letters and diaries | L1, L2, L5, L6, N1, N4 | — |
| ledgers, forms, tables | L4 (+ S0's forms) | modern forms have field-level GT only |
| typescripts, carbons, telegrams | L3, S0 | telegrams are few; flagged in L3's sampling |
| printed books and pamphlets | L8, N2 (part), N3, N5, N6 | — |
| newspapers | L9 | BLN600 is excerpts, not whole pages; NewsBench has 19 whole pages |
| mixed pages | S0, L1/L3 (letterhead plus hand) | — |
| before 1700 | L5 (part), L6 (part), L7, L8 (part), N3, N4 | — |
| 1700-1850 | L2, L5, L6, L8, N2 | — |
| 1850-1950 | L1, L3, L4, L9, N1 | — |
| after 1950 | S0, N5 (OmniDocBench) | public post-1950 archival page GT not found |
| other Latin-script languages with diacritics | L5 (nl, es, pt), L6 (de), L3 (fr TAPUS/DAHN), L9 (Europeana) | — |
| blackletter/Fraktur | L8, L9 (Europeana/Impresso NZZ) | — |
| Kurrent and secretary hands | L6, L2 (secretary, if By the People's founding-era campaigns have it) | — |
| Cyrillic, Greek, Arabic, Hebrew, CJK, Devanagari | N1-N6 | historical CJK handwriting; modern Cyrillic |
| capture: phone photo | S0 only | no public source |
| capture: flatbed / overhead scan | L1-L8, N1-N6 | — |
| capture: microfilm | L9 (BLN600 and Chronicling America pages) | — |

Each stratum is sampled across its sources' sub-collections, with at most a quarter of its pages from one
collection, so that no one hand or printer dominates it.

### 2. Sources evaluated

"V" means verified on the cited page on 2026-10-16. "I" means inferred and not yet confirmed.

#### 2.1 Taken

| source | licence (benchmark use · publish scores · show images) | page images + page text | format and convention | size | URL |
|---|---|---|---|---|---|
| LoC By the People | public domain (V) · yes · yes | yes: a CSV row per page, image URL plus full text (V) | diplomatic; original spelling and line breaks kept, **words broken across lines joined**; `[?]` illegible, `[ ]` deleted, `[* *]` marginalia; two-person review (V) | 19+ datasets, 23,316 pages in the first 7 campaigns alone (V); almost all English (V) | crowd.loc.gov; johd.67 paper; github.com/LibraryOfCongress/concordia |
| Smithsonian Transcription Center | volunteers keep no IP (V); transcription CC0 **not verified**; images CC0 where Open Access flags them (I) | yes, per page on the site (V); no bulk dump found | "type what you see"; `[[??]]`, `[[strikethrough]]…`, `[[right margin]]…`, pipe tables, ditto marks expanded; three-stage QA (V) | large; export by project or EDAN | transcription.si.edu |
| VOC/WIC/notarial (Dutch) | CC BY 4.0 (V) | full JPG + PAGE + txt (V) | PAGE-XML; diplomatic (I) | ~6,000 GT scans (V) | HTR-United catalogue |
| HTR-United: Königsfelden, Late Medieval Castilian, iForal | CC BY / BY-SA (V) | pages with PAGE/ALTO line coordinates; page text rebuilt in line order (V/I) | CREMMA-style diplomatic, abbreviations **not** expanded (V) | 60k / 28k lines; iForal size not read | htr-united.github.io (catalogue YAML) |
| READ ICDAR 2017; Konzilsprotokolle | CC BY (V) | full pages, PAGE lines (V) | PAGE-XML | Test 65+57 pages; 8,770 lines (V) | zenodo.org/records/835489, /215383 |
| German Kurrent 19th c. | images CC0, DTA text CC BY 4.0, editorial CC BY-NC-SA (V) | full pages + PAGE (V) | OCR-D level 2 (V) | 9,317 lines, 1806-1894 (V) | zenodo.org/records/17252677 |
| Bentham R0 (HTRtS 2014) | CC BY 4.0 (V) | full pages + PAGE (V) | PAGE-XML | ~430 pages (I) | zenodo.org/records/44519 |
| OCR-D `gt_structure_text` | CC BY-SA 4.0 (V) | page images with region and line TextEquiv (V) | PAGE-XML; long s and ligatures depend on OCR-D GT level (level page not fetched) | 217 pages, 6,609 lines; de/la/fr/en/he (V) | github.com/OCR-D/gt_structure_text |
| BLN600 | CC BY-NC-ND 4.0, password-protected zip (V) · yes · **no** (ND, and the password is there to stop scraping) | image + human gold per excerpt (V); excerpts, not whole pages | — | 600 excerpts (V) | orda.shef.ac.uk (BLN600) |
| NewsBench (nealcaren) | MIT code; images and text are By the People public domain (V) | yes, full-page `.txt` (V) | gold from By the People | 19 pages, 15 scored (V) | github.com/nealcaren/newsbench |
| Europeana Newspapers / ENP | per record (not checked) | PAGE-XML (V) | — | 50 (SBB, Zenodo 2583866) / 500+ (V) | cneud.github.io/ocr-gt |
| TAPUS, DAHN (French typescripts) | not checked | page sets (from the ocr-gt list) | — | not checked | cneud.github.io/ocr-gt |
| Muharaf (public part) | CC BY-NC-SA 4.0 (from search results; confirm) | page images + polygons + page-level text (V) | PAGE-XML, JSON; expert transcribers | 1,216 public pages (V) | zenodo.org/records/11492215 |
| Digital Peter | MIT (V, HF card) | 662 full pages; lines named doc_page_line, so pages rebuild (V) | jpg + txt + COCO | 662 pages, 9,694 lines (V) | huggingface.co/datasets/ai-forever/Peter |
| EPARCHOS | CC BY 4.0 (V) | 120 pages, PageXML lines (V) | PAGE-XML | 120 pages (V) | zenodo.org/records/4095301 |
| BiblIA | CC BY-NC-SA 4.0 (V) | 202 page images (70 by IIIF link only) + ALTO lines (V) | ALTO 4.2 | 202 pages (V) | zenodo.org/records/5167263 |
| OmniDocBench | research only, not commercial (V, HF card) · yes · **no** | block-level text, tables and reading order; page text rebuilt (V) | its own headline metric is normalised edit distance | 1,651 pages, v1.6, EN/ZH (V) | github.com/opendatalab/OmniDocBench |
| MTHv2 | non-commercial research only (V) · yes · **no** | page images + line text in reading order (V) | txt + coordinates | 3,199 pages, Buddhist Tripitaka prints (V) | github.com/HCIILAB/MTHv2_Datasets_Release |

#### 2.2 Considered and not taken

- **GT4HistOCR** (CC BY): line crops only, and pages cannot be rebuilt from the set itself. It is also widely used
  for training.
- **IAM** (non-commercial research, registration): modern volunteer handwriting copying corpus text, heavily
  contaminated, and its images are doubtful to show.
- **KHATT**: modern volunteer Arabic handwriting, not historical.
- **Kuzushiji** (CC BY-SA): character boxes only. Rebuilding column order for page text is risky. It could be
  revisited as a CJK-handwriting stratum later.
- **HisDoc1B** (CC BY-NC-ND): character boxes on 3M pages; ND rules out showing images.
- **Zooniverse** projects: released data is classification data, not finished page text. Shakespeare's World
  (CC BY-SA, 14,330 pages) would need aggregation, for example with ALICE. Anti-Slavery Manuscripts' reviewed text is
  in Digital Commonwealth with its images, but the rights are unchecked. A later addition, not now.
- **Princeton Geniza Project** (CC BY-NC, IIIF images, scholarly transcriptions): Hebrew and Judaeo-Arabic. A good
  second source for N4 if corpus-build finds it page-aligned.
- **olmOCR-Bench** (ODC-BY): unit tests over PDFs, not page text, so NES cannot be computed.
- **American Stories**: its text is machine OCR, not human truth.
- **FUNSD, XFUND, SROIE, CORD**: field or box level, modern.
- **NorHand v3**: v1 is line-only, and v3's README was not read. Check it before ruling it out (Norwegian letters
  and diaries, CC BY).
- **The Vision OCR lab's truth sets** (`~/Claude/vision-ocr`, read only):
  - `TRUTH-PAGES-2026-09-29.tsv`: 215 pages of third-party published PDFs in the owner's library. Its own queue
    says "KEEP IT PRIVATE. The corpus is third-party." It could join S0 as a second unpublished stratum of modern
    print, but not the published bench.
  - `HW-PANEL-2026-10-15.tsv`: the 21 handwritten and mixed pages of our own 96, scored as a bag of words. Nothing
    new.
  - `OCR-NEWSBENCH-2026-10-07.tsv`: route summaries on NewsBench. NewsBench's own scorer is 1 − CER on lower-cased
    alphanumerics, so its numbers are not NES.
- **socOCRbench**: private (owner's decision 4).

#### 2.3 Apple Vision's languages (measured on this Mac, macOS 26.6, 25G72)

`VNRecognizeTextRequest.supportedRecognitionLanguages()` at revision 3 and the newer `RecognizeTextRequest` gave
the same list, from a throwaway script in `/tmp/corpus-plan-samples/applevision/`.
- **Accurate (30):** en-US, fr-FR, it-IT, de-DE, es-ES, pt-BR, zh-Hans, zh-Hant, yue-Hans, yue-Hant, ko-KR, ja-JP,
  ru-RU, uk-UA, th-TH, vi-VT, ar-SA, ars-SA, tr-TR, id-ID, cs-CZ, da-DK, nl-NL, no-NO, nn-NO, nb-NO, ms-MY, pl-PL,
  ro-RO, sv-SE.
- **Fast (6):** en, fr, it, de, es, pt.
- **Not supported:** Hebrew, Greek, Devanagari or any other Indic script. One web page lists hi-IN and mr-IN,
  perhaps for a later macOS. Unverified.

So N3, N4 and N6 have no on-device baseline, and the app's on-device route should say so when a user picks one of
those languages.

### 3. Transcription conventions and how each maps to the panel's rules

The panel prompt (`ocr_truth.PROMPT` via `ocr_panel.PROMPT`) asks for diplomatic text: original spelling,
capitalisation, punctuation, hyphenation and line breaks, nothing expanded or modernised, `[illegible]` for an
unreadable word, tables as ` | ` rows. The scorer collapses whitespace, so line breaks never count.

| source family | difference from the panel's rules | handled by |
|---|---|---|
| By the People | hyphenated line-end words joined; `[?]`, `[ ]`, `[* *]` markup | a per-source truth cleaner (strip markup, keep marginalia text in place); a stratum option that joins `-` + line break in **both** truth and answer before scoring |
| Smithsonian TC | `[[…]]` markup; ditto marks expanded | cleaner strips markup; ditto pages dropped at sampling, or ditto expansion accepted in both directions |
| HTR-United, READ, Kurrent, Bentham | abbreviations unexpanded (matches the prompt); special characters (ꝛ, ꝑ, macrons) | a per-stratum mapping table (§6), with strict and mapped scores both reported |
| OCR-D | long s and ligatures depend on the GT level | read each file's level and map ſ to s for level 1; NFKC already folds ſ today (§6) |
| BLN600, NewsBench | normalised gold (BLN600); whole-page reading order (NewsBench) | NES on BLN600 excerpts; NewsBench scored as NES and also with its own scorer, so the numbers can be compared with its table |
| Muharaf, BiblIA, EPARCHOS, Digital Peter | logical-order Unicode (I); BiblIA may keep vowel points | strip bidi controls; report pointed and unpointed scores for N4 |
| OmniDocBench, MTHv2 | block-level; tables in HTML/LaTeX | rebuild page text in its reading order; tables converted to ` \| ` rows |

**The prompt.** The current prompt begins "a photograph of one page from a US archive". The new strata need a
neutral line: "a photograph or scan of one page from an archive or library". Corpus-build runs the three reference
routes on the 96 with the neutral line once, at about $0.45, inside its cap. If S0's scores move by less than its
own run-to-run noise (0.28 NES between two FarmShare runs that differ only in KV cache), the neutral prompt becomes
the panel prompt everywhere. If they move more, S0 keeps its prompt and the report says so.

**Sampling check.** Before freezing, a cheap route (Apple Vision, free) reads every sampled page. A page that scores
far below its stratum's median is opened by the build session, which compares the truth with the image. The page is
dropped if the truth is wrong or belongs to a different page. Drops are recorded in the manifest with the reason, so
the sample is not quietly made easy.

### 4. Size

Measured from `segbench-results/ocr-pages.csv` (29 routes × 96 pages) and the FarmShare `pages.csv` files, with
failed pages scored 0 as the reports do.
- Per-page SD across routes: quartiles 14.2, 17.4 and 20.2.
- Paired-difference SD (σd) over the 244 route pairs within 3 NES: quartiles 14.1, 17.1 and 20.1 with failures
  as 0, and 8.2, 9.7 and 11.0 over the pages both routes answered.
- Near-twin routes (Qwen3-VL 235B, Qwen3.5 397B, Qwen3.6 27B) have σd of about 4.7. Sonnet 5.5 against Qwen3.6
  27B on FarmShare has 6.8 (Δ +1.22, permutation p = 0.064, bootstrap 95% CI [+0.01, +2.76]).
- Two FarmShare runs that differ only in KV cache have σd 2.95 and Δ 0.28: the noise floor.

Pages needed to detect Δ at α = 0.05 (two-sided) with 80% power, n = (2.8·σd/Δ)²:

| σd | Δ = 1 | Δ = 2 | Δ = 3 |
|---|---:|---:|---:|
| 4.7 (near twins) | 174 | 44 | 20 |
| 9.7 (typical pair, both answered) | 730 | 183 | 82 |
| ×1.5, a harder stratum (14.5) | 1,643 | 411 | 183 |
| 17.1 (typical pair, failures as 0) | 2,303 | 576 | 256 |

`difficulty.py`'s split-half check (200 random halves of the 96) shows that choosing the best route on one half
flatters it by 1.0-2.3 NES on the other half. A route picked from one stratum's 40-80 pages will look better than it
is by at least that much, so picks are made on the pooled set and checked on the strata.

**What follows.**
- Report two figures per route and stratum: the failure rate, and NES over answered pages. The headline strict
  mean stays, for history.
- Use a paired permutation test and a bootstrap interval, not a t-test, because the differences are heavy-tailed.
- Eighty pages per Latin stratum resolves about 3 NES on a typical pair. Forty per other-script stratum resolves
  about 4.3 NES: enough to tell "works" from "does not", not to rank close routes.
- The pooled public set of option A (960 pages) resolves about 0.9 NES on a typical pair, which meets the owner's
  "1 point apart" for the bench as a whole.
- S0 stays at 96 pages, frozen, so every earlier result stays comparable.

### 5. Cost per route

The brief's "2,500 input and 500 output tokens a page" was not measured anywhere: it appears only in
`SUITE_TODO.md`. The measured means (`segbench-results/ocr-panel-cloud.md`) are 1,337-4,099 input and 435-816 output
tokens a page, and 1,602 output for Gemini 3.1 Pro, whose reasoning is billed. Measured cost per page on the 96, at
`ocr-panel-cloud-prices.json` (OpenRouter list prices, 2026-10-14):

| route | $/page, measured | per 100 pages |
|---|---:|---:|
| Gemini 3.8 Flash | 0.0032 (0.0035 at the newer $0.825/$4.125) | $0.35 |
| Qwen3-VL 235B | 0.0012 | $0.12 |
| Qwen3.5 397B | 0.0020 | $0.20 |
| Mistral Large 4 | 0.0027 | $0.27 |
| Mistral OCR 4.1 | 0.0040 | $0.40 |
| GPT-5.4 Mini | 0.0056 | $0.56 |
| Gemini 3.5 Flash | 0.0062 | $0.62 |
| Claude Sonnet 5.5 | ~0.0115 (estimate) | $1.15 |
| Gemini 3.1 Pro | 0.0219 | $2.19 |
| Apple Vision, on the Mac | 0 | 0 |

The option totals in Part 1 use $0.0047 a page for the two paid reference routes together, 50% headroom on
other-script pages (Arabic, Hebrew and CJK output tokenise worse; not yet measured), and the $0.45 prompt check.
The sweep figures scale the 2026-10-16 estimate for eight models ($0.70 on 96 pages, so $0.0073 a page) and for
eleven ($2.35, so $0.0245 a page).
- Option A: 960 × 0.0047 = $4.51, plus 240 × 0.0047 × 0.5 = $0.56, comes to about **$5.10**.
- Option B: 510 × 0.0047 = $2.40, plus $0.35 headroom, comes to about **$2.75**. The prompt check would bring it
  to $3.20, so B leaves out the prompt check and keeps the current prompt.
- Option C: 720 × 0.0047 = $3.38, about **$3.40**, with the prompt check left out. C has no other-script pages, so
  no headroom.

Corpus-build measures tokens on its first 30 pages and stops at an owner gate if the projected total passes the
approved cap.

### 6. Scoring changes (`ocr_panel_score.py`)

Today:
- `normal()` (lines 35-44) applies NFKC, straightens quotes, maps dashes to `-` and `|` to a space, and collapses
  whitespace.
- `score()` (lines 51-65) computes NES as 1 − Levenshtein / max(len) on Python strings, so it counts **code
  points**. It also computes chrF2.
- `tokens()` (lines 47-48), which feeds the word rates, splits on spaces and keeps only `isalnum()` characters.

Hazards checked by test:
- NFKC already folds ſ to s, ﬁ to fi, and full-width characters to half-width, so long s is silently forgiven
  today.
- `isalnum()` drops combining marks (Hebrew points, Arabic harakat, Devanagari matras).
- Bidi control marks count as edits.

Changes, made in corpus-build:
1. **Graphemes.** Compute Levenshtein over grapheme clusters (`regex` `\X`; rapidfuzz accepts sequences), with the
   grapheme count as the denominator. NFC first, with the compatibility folds kept as an explicit, named table
   rather than NFKC's silent ones.
2. **CJK.** A character score with all whitespace removed (the CER convention), used for N5, and `tokens()` given a
   per-character segmenter for CJK.
3. **Right to left.** Strip U+200E/F, U+202A-E and U+2066-9 in `normal()`. Require logical-order truth. Never
   reorder visually.
4. **Diacritics.** Keep them. `tokens()` keeps categories Mn and Mc. Report a diacritic-insensitive second figure
   (NFD minus Mn) for N1, N4 and N6.
5. **Historical characters.** A per-stratum mapping table (ſ, ꝛ, æ, ligatures, u/v, i/j, the CREMMA abbreviation
   marks) applied before scoring, via `score(truth, hyp, stratum=…)`. Report strict and mapped scores.
6. **Hyphen joining.** A stratum option that joins a line-end `-` with the next line in both truth and answer (for
   By the People).
7. **Strata.** `aggregate()` (line 68) is already generic. Add `stratum` to `group_values()` (line 78).
8. **The tests decide.** S0's NES must not change under the new scorer, apart from explicit, listed folds. Every
   route uses this one `score()` (`ocr_cloud_report.py`, `ocr_cloud_full_report.py`, `ocr_mac_local.py`,
   `farmshare/fs_ocr.py:269`, `ocr_pages_export.py:106,128`), so a change rescores everything. Corpus-build rescores
   the 96 once with old and new scorers, and writes the differences into the commit.

**Reporting by stratum.**
- `ocr_pages_export.py`: add stratum, script and era to `FIELDS` (line 39), and allow several page sets (the page
  list at line 83 and the `FARMSHARE` path at line 32 assume one).
- `ArchiveOCRBench/build.py`: the hard-coded `"n": 96` (line 290), the `accuracy-96` rows in `mac_route()` (line
  111), and `summary["accuracy_96"]` in `farmshare_run()` and `farmshare()` (lines 122, 215) become per-stratum,
  with charts per stratum and overall.
- `difficulty.py`: the split-half runs within a stratum, and the six fixed bins of 16 (line 146) become per stratum.

### 7. Corpus-build, step by step (for `W43.corpus-build`)

1. **Confirm formats.** Open one page from each chosen source in scratch. Fetching needs network permission the
   unattended sessions did not have on 2026-10-16. If fetching is still denied, block on an owner gate naming
   the hosts (zenodo.org, huggingface.co, github.com, crowd.loc.gov and loc.gov, transcription.si.edu,
   orda.shef.ac.uk).
2. **Licences.** Confirm each licence that this plan marks unchecked (Smithsonian per project, TAPUS/DAHN, Europeana
   records, HTR-United's Devanagari set, Muharaf's exact text) before a source's pages enter the sample. A source
   whose licence cannot be confirmed is dropped from its stratum, and its slot is filled from another source.
3. **Fetch.** Fetch into `~/Library/Caches/ArchiveSuiteRehearsal/bench-corpus/`. Converters go in
   `ArchiveProcessor/scripts/segbench/corpus/`, one per source family, each with a unit test on a fixture page.
4. **Sample.** Sample with a fixed seed. Cap one collection at a quarter of its stratum. Run the Apple Vision sanity
   pass (§3), then drop bad truth with its reason recorded.
5. **Manifest and freeze.** Write a manifest with source, item URL, licence, checksum, stratum, convention,
   contamination class and whether the image may be published. Commit it, then freeze: no model call before the
   commit.
6. **Scorer.** Make the scorer changes (§6), then rescore the 96 with the old and new scorers.
7. **Reference routes.** Run Gemini 3.8 Flash, Qwen3-VL 235B and Apple Vision on the new pages. Measure tokens on
   the first 30 and stop at the approved cap.
8. **Report.** Update ArchiveOCRBench by stratum, with public-low, public-high and S0 shown apart.

### 8. Segmentation away from the owner's boxes (optional)

No public set is historical, archival or phone-photographed.
- **OpenPSS-LONG** (van Heusden et al.) is the nearest: 110 hand-labelled streams, 89,491 pages of Dutch FOIA
  releases (letters, reports, email threads, scans), with Tesseract OCR. Its licence and whether page images are
  included are unconfirmed, and the link found was an anonymous review mirror.
- **TABME++** (MIT on Hugging Face, the tobacco documents' own terms not checked) is clean, large and synthetic:
  1990s office scans concatenated into folders. It would show that the segmentation machinery runs, not that it
  works on archival boxes.
- **Tobacco800** is too small, and one-page documents dominate it, so predicting no boundaries scores well.
- Wiedemann and Heyer's German federal-archive streams are private.

Recommendation: no segmentation stratum in W43. If the owner wants one later, OpenPSS-LONG after its licence is
confirmed, as a file under the segmentation plan rather than this one.

### 9. Is an owner review timely?

No. There is nothing built to look at. Corpus-build will choose the pages, and the scorer changes will move the
figures, so a review now would be repeated. The owner's only input now is the decision in Part 1, which is a gate,
not a review session. Corpus-build judges again before offering a sample for the owner to look at, if it wants
one. It needs no owner adjudication as planned.
