# Google Colab GPU Runner (`ArchiveProcessor/scripts/segbench/colab/`)

Owner-authorized 2026-11-27 under the owner's **Google AI Ultra** plan (A100/H100 80 GB or L4 24 GB + High-RAM + background execution).

## One-time Google Drive setup

Upload the staged `ArchiveSuite-Colab/` folder from `~/Downloads/ArchiveSuite-Colab` into **`My Drive/ArchiveSuite-Colab`**:

```text
My Drive/ArchiveSuite-Colab/
├── run_pack.ipynb
├── README.md
├── datasets/
│   ├── public895/   # 895 frozen public images + public895.jsonl + pilot3.jsonl
│   └── truth99/     # 99 frozen owner truth images + truth99.jsonl + pilot3.jsonl
├── packs/           # Staged pack folders to run
└── results/         # Resume-safe per-page outputs written by Colab
```

Every image in `datasets/` is SHA-256-verified byte-for-byte against the frozen Sherlock/FarmShare manifests so Colab runs are 100% comparable with earlier measurements.

## Per-pack workflow

1. **Stage a pack on the Mac:**
   ```bash
   python3 ArchiveProcessor/scripts/segbench/colab/colab_pack.py pack ~/.local/state/archive-autonomous/artifacts/<PACK_DIR>
   ```
   Drag the staged folder from `~/Downloads/ArchiveSuite-Colab/packs/<PACK_NAME>` into `My Drive/ArchiveSuite-Colab/packs/`.
2. **Run on Colab:**
   Open `My Drive/ArchiveSuite-Colab/run_pack.ipynb` in Google Colab, pick **A100/H100** (for 27B FP8 or fast sweeps) or **L4** (for 1B–9B models) with **High-RAM** and **Background execution**, set `PACK_NAME`, and run all cells.
   - Hugging Face model weights download to fast local `/content/hf` (not Drive).
   - Per-page results write directly to `My Drive/ArchiveSuite-Colab/results/<PACK_NAME>/`, so a disconnect never loses completed pages.
3. **Collect back to the Mac and release for engine scoring:**
   Download `results/<PACK_NAME>/` to your Mac and run:
   ```bash
   python3 ArchiveProcessor/scripts/segbench/colab/colab_pack.py fetch ~/Downloads/<PACK_NAME> <ITEM_TAG>
   ```
   This copies results with `--ignore-existing` semantics (never overwriting frozen inputs) and releases `<ITEM_TAG>` in `.maintenance/AUTONOMOUS_PLAN.md` so the engine scores it automatically.
