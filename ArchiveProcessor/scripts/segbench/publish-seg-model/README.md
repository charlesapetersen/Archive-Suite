---
license: apache-2.0
base_model: Qwen/Qwen3.5-2B
library_name: mlx
pipeline_tag: image-text-to-text
tags:
  - mlx
  - document-segmentation
  - archives
---

# Archive Suite segmenter: Qwen3.5 2B, fine-tuned, 8-bit MLX

This model is the "on this Mac" segmentation approach of Archive Processor (Archive Suite). It reads a window of seven
photographed archival pages with their OCR text and answers, for each gap between two pages, whether a new document
starts there. The answer comes back as JSON with a decision and a confidence for each gap. Serve it with mlx-vlm
(`pip install mlx-vlm`, then `mlx_vlm.server --port 8080`). The app sends the repository name as the model, and mlx-vlm
downloads it on the first request.

## How it was trained

The base model is Qwen3.5 2B, with a LoRA fine-tune (rank 16, one epoch) merged into it. The training set was 5,885
page windows from one owner's archival photographs. A window was used only where every gap had the same label from
two sources: a larger teacher model (Qwen3.5 27B) and the owner's own folder tags. The target was the teacher's reply.
In 29% of the windows the page text was left out. The model was then converted to 8 bits with mlx-vlm 0.7.4 (about
9.6 bits a weight, 2.5 GB). No page images and no page text are included in the weights.

## How well it segments

"Pages in the exact document" means the page ends up in a document with exactly the right pages. All figures are with
no checking by a person.

| boxes | pages | this model | Gemini 3.8 Flash |
|---|---:|---:|---:|
| development boxes (Dean, Deaver, Herrnstein), this 8-bit build on an M3 Pro | 551 | 90.3% | 90.7% |
| locked test boxes (Stanton, RG 165), full precision, scored once | 363 | 78.8% | 88.8% |

- **Speed and memory:** on an 18 GB M3 Pro it takes about 18 s for a seven-page window (about 6 s a page) and peaks at
  4.4 GB of memory. An 8 GB Mac has not been measured.
- **Confidences:** they do not help find its mistakes. To reach 98% of pages right after checking, a person has to
  check about 80 gaps per 100 pages, so skim every boundary it proposes.
- **Limits:** it was trained on one owner's collections, mostly twentieth-century American government and political
  papers. On boxes it never saw, it is about ten points behind the best cloud models. Expect it to do worse on material
  unlike that.

The full measurements are in Archive Suite's `ArchiveProcessor/segbench-results/seg-students.md` and `options.json`.

## Licence

Apache 2.0, the licence of the Qwen3.5 base model.
