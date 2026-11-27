# Google Colab GPU access (owner-authorized 2026-11-27)

Owner, 2026-11-27: future GPU benchmark packs may run on **Google Colab** under the owner's **Google AI Ultra** plan
(A100 80 GB / H100 80 GB / L4 24 GB + High-RAM + background execution), as an alternative to Sherlock's Slurm queue.
Both frozen benchmark image sets (`public895` 895 public pages and `truth99` 99 owner truth pages) are authorized for
staging in the owner's Google Drive (`My Drive/ArchiveSuite-Colab/`).

## Rules (same discipline as Sherlock)

- **No unattended engine session drives Colab.** The engine prepares a pack on the Mac (with the same size-and-necessity
  review in `execution-plans/items/<TAG>.md`, `plan-edit.sh hold TAG ...`, and `$0` dry-run checks). The owner's session
  stages the pack into `~/Downloads/ArchiveSuite-Colab/packs/` (`colab_pack.py pack`), runs `run_pack.ipynb` on Colab,
  downloads `results/<PACK_NAME>/`, and runs `colab_pack.py fetch` to release the item for engine scoring.
- **Exact comparability.** `datasets/public895/` and `datasets/truth99/` on Google Drive hold the exact SHA-256-verified
  JPEG bytes from `open-sweep-20261019` and `truth96-20261020`, and `run_pack.ipynb` invokes the same `family_run.py` /
  `boxes_run.py` runner with the same 3-page pilot gate, greedy decoding, context limits, and per-page resume-safe JSONL
  writes.
- **Keep weights off Drive.** `HF_HOME` and `XDG_CACHE_HOME` live on Colab's fast local NVMe (`/content/hf`), never on
  Google Drive. Only manifests, pack configs, and results live on Drive.
- **GPU selection (Google AI Ultra):**
  - 1B–9B OCR models: **L4 24 GB** (fast, cheap compute units) or **A100 80 GB**.
  - 27B FP8 models (e.g., Qwen3.6 27B): **A100 80 GB** or **H100 80 GB** + High-RAM.

## Tooling & tests

- `ArchiveProcessor/scripts/segbench/colab/colab_pack.py` — `stage-datasets`, `pack`, `fetch`.
- `ArchiveProcessor/scripts/segbench/colab/run_pack.ipynb` — ready-to-run notebook.
- `ArchiveProcessor/scripts/segbench/colab/test_colab_pack.py` — `$0` unit tests (manifest rewrite, SHA-256 guard,
  no-clobber fetch).
