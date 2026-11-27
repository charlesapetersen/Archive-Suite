#!/usr/bin/env python3
"""Google Colab staging and collection helper for Archive Suite OCR / metadata packs.

Owner-authorized 2026-11-27 (Google AI Ultra plan, Drive root `My Drive/ArchiveSuite-Colab`).

Commands:
  colab_pack.py stage-datasets [--dest DIR] [--public-images DIR] [--truth-images DIR]
      Verify SHA-256 of every image in public895.jsonl (895) and truth99.jsonl (99),
      write Colab-ready manifests pointing at `/content/drive/MyDrive/ArchiveSuite-Colab/datasets/...`,
      and copy `run_pack.ipynb` into DEST.

  colab_pack.py pack ARTIFACT_DIR [--dest DIR] [--name NAME]
      Stage a prepared Sherlock/cluster pack into DEST/packs/<NAME>/ with Drive-compatible paths,
      ready to drag into Google Drive and run in `run_pack.ipynb`.

  colab_pack.py fetch RESULTS_DIR TAG [--artifact DIR]
      Copy finished results downloaded from Google Drive (`results/<NAME>/`) into the Mac artifact
      folder without overwriting inputs (`--ignore-existing` semantics), then mark TAG finished and
      release it in `.maintenance/AUTONOMOUS_PLAN.md` for engine scoring.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
DEFAULT_DEST = Path.home() / "Downloads" / "ArchiveSuite-Colab"
DEFAULT_DRIVE_ROOT = "/content/drive/MyDrive/ArchiveSuite-Colab"
DEFAULT_ARTIFACTS = Path.home() / ".local" / "state" / "archive-autonomous" / "artifacts"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rewrite_manifest(src: Path, dst: Path, images_dir: Path, drive_images_prefix: str) -> tuple[int, int]:
    """Rewrite a JSONL manifest's `image` paths to Drive paths and verify every file's SHA-256."""
    rows = [json.loads(line) for line in src.read_text().splitlines() if line.strip()]
    out_lines = []
    missing = []
    mismatched = []
    for row in rows:
        orig = Path(row["image"])
        local = images_dir / orig.name
        if not local.is_file():
            # Fall back to <id>.<ext> if renamed
            cand = images_dir / f"{row['id']}{orig.suffix or '.jpg'}"
            if cand.is_file():
                local = cand
            else:
                missing.append(row["id"])
                continue
        expected = row.get("sha256")
        if expected:
            actual = sha256_file(local)
            if actual != expected:
                mismatched.append((row["id"], expected[:12], actual[:12]))
                continue
        new_row = dict(row)
        new_row["image"] = f"{drive_images_prefix.rstrip('/')}/{local.name}"
        out_lines.append(json.dumps(new_row, ensure_ascii=False))
    if missing or mismatched:
        parts = []
        if missing:
            parts.append(f"missing {len(missing)} images (first 5: {missing[:5]})")
        if mismatched:
            parts.append(f"sha256 mismatch on {len(mismatched)} images (first 3: {mismatched[:3]})")
        raise SystemExit(f"ERROR verifying {src.name}: " + "; ".join(parts))
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(out_lines) + "\n")
    return len(rows), len(out_lines)


def default_manifest_pair() -> tuple[Path, Path]:
    """Locate the canonical public895 and truth99 manifest folders on the Mac."""
    for candidate in (
        DEFAULT_ARTIFACTS / "ocr-family-coverage-20261117" / "scratch",
        DEFAULT_ARTIFACTS / "new-open-boxes-20261031" / "scratch",
    ):
        p895 = candidate / "family-895" if (candidate / "family-895").is_dir() else candidate / "new-open-boxes-895"
        p96 = candidate / "family-96" if (candidate / "family-96").is_dir() else candidate / "new-open-boxes-96"
        if (p895 / "public895.jsonl").is_file() and (p96 / "truth99.jsonl").is_file():
            return p895, p96
    raise SystemExit("Could not find public895.jsonl / truth99.jsonl in ~/.local/state/archive-autonomous/artifacts/")


def cmd_stage_datasets(args: argparse.Namespace) -> int:
    dest = Path(args.dest).expanduser()
    pub_dir = dest / "datasets" / "public895"
    t99_dir = dest / "datasets" / "truth99"
    pub_images = Path(args.public_images).expanduser() if args.public_images else pub_dir / "images"
    t99_images = Path(args.truth_images).expanduser() if args.truth_images else t99_dir / "images"
    src_895, src_96 = (Path(args.manifests_895), Path(args.manifests_96)) if args.manifests_895 else default_manifest_pair()

    drive_root = args.drive_root.rstrip("/")
    for label, mf_dir, names, img_dir, out_dir, drive_sub in [
        ("public895", src_895, ["public895.jsonl", "pilot3.jsonl"], pub_images, pub_dir, f"{drive_root}/datasets/public895/images"),
        ("truth99", src_96, ["truth99.jsonl", "pilot3.jsonl"], t99_images, t99_dir, f"{drive_root}/datasets/truth99/images"),
    ]:
        for name in names:
            src = mf_dir / name
            if not src.is_file():
                continue
            total, written = rewrite_manifest(src, out_dir / name, img_dir, drive_sub)
            print(f"OK {label}/{name}: {written}/{total} SHA-256 verified -> {out_dir / name}")

    (dest / "packs").mkdir(parents=True, exist_ok=True)
    (dest / "results").mkdir(parents=True, exist_ok=True)
    nb_src = HERE / "run_pack.ipynb"
    if nb_src.is_file():
        shutil.copy2(nb_src, dest / "run_pack.ipynb")
        print(f"OK notebook -> {dest / 'run_pack.ipynb'}")
    readme_src = HERE / "README.md"
    if readme_src.is_file():
        shutil.copy2(readme_src, dest / "README.md")
        print(f"OK guide -> {dest / 'README.md'}")
    return 0


def cmd_pack(args: argparse.Namespace) -> int:
    src = Path(args.artifact_dir).expanduser().resolve()
    if not src.is_dir():
        raise SystemExit(f"Artifact directory not found: {src}")
    dest = Path(args.dest).expanduser()
    name = args.name or src.name
    out = dest / "packs" / name
    if out.exists() and not args.force:
        raise SystemExit(f"Pack already staged at {out} (pass --force to overwrite)")
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out)

    # Include family-coverage + new-open-boxes runners if not already bundled inside support/
    runners_dst = out / "colab_support"
    runners_dst.mkdir(parents=True, exist_ok=True)
    for rel in (
        "ArchiveProcessor/scripts/segbench/sherlock/family-coverage/family_run.py",
        "ArchiveProcessor/scripts/segbench/sherlock/family-coverage/family_parse.py",
        "ArchiveProcessor/scripts/segbench/sherlock/family-coverage/family_setup.py",
        "ArchiveProcessor/scripts/segbench/sherlock/new-open-boxes/boxes_run.py",
        "ArchiveProcessor/scripts/segbench/sherlock/new-open-boxes/boxes_parse.py",
    ):
        p = REPO / rel
        if p.is_file():
            shutil.copy2(p, runners_dst / p.name)

    meta = {
        "pack_name": name,
        "source_artifact": str(src),
        "drive_root": args.drive_root.rstrip("/"),
    }
    (out / "colab-pack.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"OK staged pack -> {out}")
    print(f"Next: drag {out.name} into My Drive/ArchiveSuite-Colab/packs/ and run run_pack.ipynb with PACK_NAME = '{name}'")
    return 0


def copy_no_clobber(src: Path, dst: Path) -> tuple[int, list[str]]:
    """Copy files from src into dst without overwriting existing files; flag differing collisions."""
    copied = 0
    conflicts: list[str] = []
    for p in src.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(src)
        target = dst / rel
        if target.exists():
            if sha256_file(p) != sha256_file(target):
                conflicts.append(str(rel))
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
        copied += 1
    return copied, conflicts


def cmd_fetch(args: argparse.Namespace) -> int:
    if os.environ.get("ARCHIVE_UNATTENDED") == "1":
        raise SystemExit("Refused under ARCHIVE_UNATTENDED=1")
    src = Path(args.results_dir).expanduser().resolve()
    if not src.is_dir():
        raise SystemExit(f"Results directory not found: {src}")
    artifact = Path(args.artifact).expanduser().resolve() if args.artifact else (DEFAULT_ARTIFACTS / src.name)
    artifact.mkdir(parents=True, exist_ok=True)
    copied, conflicts = copy_no_clobber(src, artifact)
    print(f"Copied {copied} new files into {artifact}")
    if conflicts:
        raise SystemExit(f"Blocked release: {len(conflicts)} differing files already exist (first 5: {conflicts[:5]})")

    if not args.no_release:
        plan = REPO / ".maintenance" / "AUTONOMOUS_PLAN.md"
        plan_edit = REPO / "ops" / "autonomous" / "plan-edit.sh"
        cluster_reach = REPO / "ops" / "autonomous" / "cluster-reach.py"
        if cluster_reach.is_file():
            subprocess.run([sys.executable, str(cluster_reach), "mark", args.tag, "finished"], check=False)
        if plan_edit.is_file() and plan.is_file():
            subprocess.run(["bash", str(plan_edit), str(plan), "release", args.tag, f"Colab results in {artifact}"], check=True)
            print(f"Released {args.tag} for engine scoring")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Archive Suite Google Colab pack staging & collection helper.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_ds = sub.add_parser("stage-datasets", help="Verify and write Colab-ready public895 and truth99 manifests.")
    p_ds.add_argument("--dest", default=str(DEFAULT_DEST))
    p_ds.add_argument("--drive-root", default=DEFAULT_DRIVE_ROOT)
    p_ds.add_argument("--public-images", default="")
    p_ds.add_argument("--truth-images", default="")
    p_ds.add_argument("--manifests-895", default="")
    p_ds.add_argument("--manifests-96", default="")
    p_ds.set_defaults(func=cmd_stage_datasets)

    p_pk = sub.add_parser("pack", help="Stage an artifact pack for Google Drive / Colab.")
    p_pk.add_argument("artifact_dir")
    p_pk.add_argument("--dest", default=str(DEFAULT_DEST))
    p_pk.add_argument("--drive-root", default=DEFAULT_DRIVE_ROOT)
    p_pk.add_argument("--name", default="")
    p_pk.add_argument("--force", action="store_true")
    p_pk.set_defaults(func=cmd_pack)

    p_ft = sub.add_parser("fetch", help="Import downloaded Colab results into Mac artifacts and release item.")
    p_ft.add_argument("results_dir")
    p_ft.add_argument("tag")
    p_ft.add_argument("--artifact", default="")
    p_ft.add_argument("--no-release", action="store_true")
    p_ft.set_defaults(func=cmd_fetch)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
