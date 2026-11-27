# CHURRO-DS test overlap with the 895 public set (`W46.ocr-churro-overlap`)

Measured 2026-11-27 against `stanford-oval/churro-dataset` (`test` split, 1,170 pages across 3 Parquet shards) and all 895 frozen public bench pages (`manifest.jsonl`).

## Headline

- **Confirmed page-level overlap with CHURRO-DS test:** **24 of 895** public pages (16 of 440 in the original 440 reference set; 8 of 455 in the 455 added pages).
- **Match breakdown:** 20 exact byte SHA-256, 0 exact decoded-pixel SHA-256, 4 perceptual hash matches (`dhash64 <= 4 and dhash256_interior <= 24 and interior_r >= 0.985 (5% border crop)`).
- **Same-corpus filename audit (unmatched by hash):** 2 (checks that no cropped or rotated duplicate from a shared corpus was missed by pixel hashing).
- **Borderline candidates below threshold:** 44.
- **Why both CHURRO-3B and Gemini carry this note (OCR-15):** CHURRO-DS's truths were cleaned with Gemini 2.5 Pro and CHURRO-3B was trained on CHURRO-DS's train split drawn from the same source corpora (with random page splits, not corpus-disjoint splits). Page-level overlap with CHURRO-DS `test` measures direct image collisions with the published benchmark test split; corpus-level overlap with CHURRO-3B's training split remains broader (including READ 2017 in L6, Bentham/ICDAR2015 in L2, Devanagari in N6, BiblIA in N4, EPARCHOS in N3, Muharaf in N1 and Tapus in L3 alongside Königsfelden, iForal, Castilian, VOC and OCR-D).

## Overlap by stratum

| Stratum | Bench pages | CHURRO-DS test overlap | Exact bytes | Exact pixels | Perceptual |
|---|---:|---:|---:|---:|---:|
| L1 | 80 | 0 | 0 | 0 | 0 |
| L2 | 80 | 0 | 0 | 0 | 0 |
| L3 | 80 | 0 | 0 | 0 | 0 |
| L4 | 80 | 0 | 0 | 0 | 0 |
| L5 | 80 | 8 | 7 | 0 | 1 |
| L6 | 80 | 0 | 0 | 0 | 0 |
| L7 | 80 | 1 | 0 | 0 | 1 |
| L8 | 80 | 1 | 0 | 0 | 1 |
| L9 | 15 | 0 | 0 | 0 | 0 |
| N1 | 40 | 0 | 0 | 0 | 0 |
| N2 | 40 | 0 | 0 | 0 | 0 |
| N3 | 40 | 1 | 0 | 0 | 1 |
| N4 | 40 | 5 | 5 | 0 | 0 |
| N5 | 40 | 0 | 0 | 0 | 0 |
| N6 | 40 | 8 | 8 | 0 | 0 |

## Overlap by bench source

| Source | Strata | Bench pages | CHURRO-DS test overlap |
|---|---|---:|---:|
| bentham | L2 | 20 | 0 |
| biblia | N4 | 40 | 5 |
| btp | L1, L2, L3 | 218 | 0 |
| castilian | L5 | 51 | 1 |
| devanagari | N6 | 40 | 8 |
| eparchos | N3 | 40 | 1 |
| iforal | L5 | 26 | 7 |
| koenigsfelden | L7 | 80 | 1 |
| kurrent | L6 | 60 | 0 |
| muharaf | N1 | 40 | 0 |
| newsbench | L9 | 15 | 0 |
| ocrd | L8 | 80 | 1 |
| omnidoc | N5 | 40 | 0 |
| peter | N2 | 40 | 0 |
| read2017 | L6 | 20 | 0 |
| si | L4 | 80 | 0 |
| tapus | L3 | 2 | 0 |
| voc | L5 | 3 | 0 |

## Matched pages

| Stratum | Bench source | Bench page | In 440 | Match kind | dHash64 | dHash256 | Interior r | CHURRO dataset_id | CHURRO file_name |
|---|---|---|---|---|---:|---:|---:|---|---|
| L5 | castilian | `in_domain/Sal_L/unit_2/30` | yes | perceptual | 0 | 0 | 1.0000 | `castilian` | `30.jpeg` |
| L5 | iforal | `foral_de_condado_1255/1` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_condado_1255_1.jpeg` |
| L5 | iforal | `foral_de_evora_1218/1` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_evora_1218_1.jpeg` |
| L5 | iforal | `foral_de_guardao_1380/1` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_guardao_1380_1.jpeg` |
| L5 | iforal | `foral_de_sortelha_1395/2` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_sortelha_1395_2.jpeg` |
| L5 | iforal | `foral_de_teloes_de_aguiar_1491/1` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_teloes_de_aguiar_1491_1.jpeg` |
| L5 | iforal | `foral_de_teloes_de_aguiar_2_1255/1` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_teloes_de_aguiar_2_1255_1.jpeg` |
| L5 | iforal | `foral_de_torres_novas_1251/3` | yes | exact_bytes | 0 | 0 | 1.0000 | `iforal` | `foral_de_torres_novas_1251_3.jpeg` |
| L7 | koenigsfelden | `U-17_0059_v` | yes | perceptual | 1 | 10 | 0.9997 | `charters` | `U-17_0059_v.jpeg` |
| L8 | ocrd | `arnimb_goethe03_1835/arnimb_goethe03_1835_0029` | yes | perceptual | 0 | 1 | 1.0000 | `ocrd` | `arnimb_goethe03_1835_0029.jpeg` |
| N3 | eparchos | `6971_(118)` | yes | perceptual | 1 | 0 | 0.9999 | `eparchos` | `6971 (118).jpeg` |
| N4 | biblia | `Ashkenazy/btv1b10539996w` | yes | exact_bytes | 0 | 0 | 1.0000 | `biblia` | `btv1b10539996w.jpeg` |
| N4 | biblia | `Ashkenazy/btv1b10549397c` | yes | exact_bytes | 0 | 0 | 1.0000 | `biblia` | `btv1b10549397c.jpeg` |
| N4 | biblia | `Ashkenazy/btv1b9003019b` | yes | exact_bytes | 0 | 0 | 1.0000 | `biblia` | `btv1b9003019b.jpeg` |
| N4 | biblia | `Sephardi/btv1b9002892x` | yes | exact_bytes | 0 | 0 | 1.0000 | `biblia` | `btv1b9002892x.jpeg` |
| N4 | biblia | `Sephardi/btv1b9064414m` | yes | exact_bytes | 0 | 0 | 1.0000 | `biblia` | `btv1b9064414m.jpeg` |
| N6 | devanagari | `giridharadasa1902/08` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `giridharadasa1902_08.jpeg` |
| N6 | devanagari | `hajarilala1919/12` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `hajarilala1919_12.jpeg` |
| N6 | devanagari | `paramananda1924/000c` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `paramananda1924_000c.jpeg` |
| N6 | devanagari | `pyarelala1914/01` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `pyarelala1914_01.jpeg` |
| N6 | devanagari | `sankaracarya1925/000c` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `sankaracarya1925_000c.jpeg` |
| N6 | devanagari | `sivaramasukla1900/04` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `sivaramasukla1900_04.jpeg` |
| N6 | devanagari | `sriramastavarajah1898/05` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `sriramastavarajah1898_05.jpeg` |
| N6 | devanagari | `vyasa1906/04` | no | exact_bytes | 0 | 0 | 1.0000 | `devanagari` | `vyasa1906_04.jpeg` |

## Closest borderline candidates (not counted as matches)

| Stratum | Bench source | Bench page | dHash64 | dHash256 | Interior r | CHURRO dataset_id | CHURRO file_name |
|---|---|---|---:|---:|---:|---|---|
| L5 | castilian | `in_domain/Val_S/Hand_D/pg_27` | 5 | 39 | 0.8797 | `castilian` | `pg_31.jpeg` |
| L5 | castilian | `in_domain/Sal_L/unit_2/30` | 4 | 41 | 0.8741 | `castilian` | `8.jpeg` |
| N4 | biblia | `Sephardi/btv1b10539466r` | 4 | 57 | 0.7286 | `liber` | `7_bc51d_default.jpeg` |
| L5 | castilian | `in_domain/Mad_B/a000618` | 6 | 71 | 0.5346 | `klostern` | `CCl-48_014v.jpeg` |
| L7 | koenigsfelden | `U-17_0901_02_r` | 4 | 75 | 0.8705 | `charters` | `U-17_0956_s01.jpeg` |
| L8 | ocrd | `blumenbach_anatomie_1805/blumenbach_anatomie_1805_0047` | 6 | 75 | 0.3808 | `sleuk` | `452_pp_ttp_02_009.jpeg` |
| L5 | castilian | `in_domain/Sal_J/pg_0006.pdf_page_1` | 5 | 76 | -0.0143 | `lidi` | `PirroLigorio_Ja_III_3_048b.jpeg` |
| N4 | biblia | `Sephardi/btv1b10539466r` | 6 | 78 | 0.4234 | `biblia` | `btv1b10544753q.jpeg` |
| L5 | castilian | `in_domain/Val_S/Hand_C/pg_48` | 6 | 81 | 0.5872 | `liber` | `020-Trevet Lisboa 2 482.jpeg` |
| N1 | muharaf | `QBat3D_0005r` | 6 | 82 | 0.5779 | `impact` | `00541489.jpeg` |

## Measurement card

- **Truth:** Deterministic image hashing (byte SHA-256, decoded RGB pixel SHA-256, 64-bit full dHash, 256-bit interior dHash and 64x64 interior grayscale Pearson correlation with a 5% border crop), plus an independent same-corpus filename audit. No model calls, no human adjudication required.
- **Selection:** Exhaustive comparison of all 1,170 rows of `stanford-oval/churro-dataset` (`test` split) against all 895 frozen pages of `bench-corpus/manifest.jsonl` (matched 895/895 by `image_sha256`).
- **Comparison:** Every page compared directly in pixel space regardless of file format or resize.
- **Noise:** Deterministic (zero sampling variance). Perceptual threshold (`dhash64 <= 4, dhash256 <= 24, interior_r >= 0.985`) is audited by logging the closest borderline candidates and checking same-corpus filenames.
- **Scope:** Measures overlap with CHURRO-DS `test` only (not CHURRO-DS `train` or `dev`, which has 101 shards). Zero overlap with `test` does not rule out source-corpus training overlap with CHURRO-DS `train`, which is reported separately in `specialists.md`.
