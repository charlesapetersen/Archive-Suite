#!/usr/bin/env python3
"""Colab-compatible preparation helper for family-coverage / boxes OCR packs.

Replaces Sherlock's container-specific `+cu129` check in `family_setup.py check` with a Colab-safe
check that downloads pinned Hugging Face snapshots onto local `/content/hf` via `boxes_setup.download`,
verifies architecture support in the installed vLLM + `mineru-vl-utils` when required, and writes
`prepared.json` (`state: 'ready'`) into both split directories (895 and 96).
"""
from __future__ import annotations

import importlib
import importlib.metadata as md
import json
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


def _pkg_version(name: str) -> str | None:
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return None


def prepare_all(candidates_path: Path, root895: Path, root96: Path) -> list[dict]:
    import boxes_setup as S  # noqa: E402
    import family_setup as FS  # noqa: E402

    cands = json.loads(candidates_path.read_text(encoding="utf-8"))
    # Refresh any prompt_from entries first (no-op when none are configured).
    if any(c.get("prompt_from") for c in cands):
        FS.prompts(candidates_path)
        cands = json.loads(candidates_path.read_text(encoding="utf-8"))

    roots = [root895, root96]
    for r in roots:
        r.mkdir(parents=True, exist_ok=True)
    S.download(candidates_path, roots)

    results = []
    for c in cands:
        key = c["key"]
        rec_path = root895 / key / "prepared.json"
        if not rec_path.is_file():
            rec_path = root96 / key / "prepared.json"
        rec = json.loads(rec_path.read_text(encoding="utf-8"))
        if rec.get("state") == "ready":
            results.append(rec)
            continue
        if rec.get("state") != "downloaded":
            print(key, rec.get("state"), rec.get("reason", ""), flush=True)
            results.append(rec)
            continue
        try:
            if not (rec.get("prompt") or "").strip():
                raise RuntimeError("no prompt in prepared.json")
            import torch
            import vllm
            from vllm import ModelRegistry

            versions = {
                "torch": torch.__version__,
                "vllm": vllm.__version__,
                "python": sys.version.split()[0],
                "cuda": getattr(torch.version, "cuda", None),
            }
            archs = json.loads(Path(rec["snapshot"], "config.json").read_text()).get("architectures") or []
            if not set(archs) & set(ModelRegistry.get_supported_archs()):
                raise RuntimeError(f"architecture {archs} unsupported by installed vLLM {vllm.__version__}")
            notes = {}
            for p in (rec.get("vllm") or {}).get("logits_processors", []):
                try:
                    mod, cls = p.split(":")
                    getattr(importlib.import_module(mod), cls)
                except Exception as exc:  # noqa: BLE001
                    notes["logits_processor_import"] = f"{type(exc).__name__}: {exc}"[:300]
            if rec.get("check_processor", True):
                from transformers import AutoProcessor
                AutoProcessor.from_pretrained(
                    rec["snapshot"],
                    local_files_only=True,
                    trust_remote_code=bool((rec.get("vllm") or {}).get("trust_remote_code")),
                )
            if rec.get("adapter") == "mineru":
                import mineru_vl_utils
                from mineru_vl_utils import MinerUClient, MinerULogitsProcessor  # noqa: F401
                versions["mineru_vl_utils"] = getattr(mineru_vl_utils, "__version__", None) or _pkg_version("mineru-vl-utils")
            rec.update(state="ready", python=sys.executable, check_versions=versions, check_notes=notes, platform="colab")
        except Exception:  # noqa: BLE001
            rec.update(state="skipped", reason="colab check failed: " + traceback.format_exc()[-1500:])
        S.write_both(roots, key, rec)
        print(key, rec["state"], rec.get("check_versions", ""), rec.get("reason", "")[-400:], flush=True)
        results.append(rec)
    return results


def main(argv=None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if len(argv) != 3:
        raise SystemExit("usage: colab_prepare.py CANDIDATES.json ROOT895 ROOT96")
    prepare_all(Path(argv[0]), Path(argv[1]), Path(argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
