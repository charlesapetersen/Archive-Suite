#!/usr/bin/env python3
"""W46.ent-robust: check a frozen pack before it is sent anywhere; stdlib only.

    python3 check_pack.py PACK [--as-root ROOT]

Every file freeze.json names must exist with its SHA-256, and every image a request names must be one of them. A
request's image path is the cluster path; with --as-root (the Mac dry run) it is mapped back from ROOT to PACK, and a
path outside ROOT fails. Exits 1 on the first kind of failure, after listing up to five.
"""
import hashlib, json, pathlib, sys

pack = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[sys.argv.index("--as-root") + 1]) if "--as-root" in sys.argv else pack
freeze = json.loads((pack / "freeze.json").read_text())
bad = [f for f, h in freeze["files"].items()
       if not (pack / f).is_file() or hashlib.sha256((pack / f).read_bytes()).hexdigest() != h]
if bad:
    sys.exit(f"{len(bad)} frozen files missing or changed: {bad[:5]}")
refs = 0
for arm in freeze["arms"]:
    for line in (pack / arm / "requests.jsonl").read_text().splitlines():
        r = json.loads(line)
        for img, digest in zip(r.get("images") or [], r.get("image_sha256s") or []):
            rel = pathlib.PurePosixPath(img).relative_to(root) if pathlib.PurePosixPath(img).is_relative_to(root) else None
            if rel is None or freeze["files"].get(str(rel)) != digest:
                sys.exit(f"request {r['id']}: image {img} is not a frozen file of this pack")
            refs += 1
print(f"pack ok: {len(freeze['files'])} files, {refs} image references, arms {freeze['arms']}")
