#!/usr/bin/env python3
"""W40.c2: a read-only sample of the real corpus, copied out for the Reader rehearsals (W40.d7, W40.d8).

Owner decision 3, 2026-10-04 (`execution-plans/verification-phase/00-owner-plan.md` §Decisions): the daemon may
copy about 5,000 PDFs with their tags out of the collection into a scratch folder, reading only.

READ ONLY on the corpus. The only calls that touch a corpus file are `os.walk`/`lstat` (listing), `getxattr(2)` /
`listxattr(2)` (reading the tags and the other xattrs), `open(..., "rb")` (hashing the content), and `cp -c -p SRC
DST` (or `ditto SRC DST` on another volume) reading it to make the copy. Nothing in the corpus is written, renamed or deleted. The destination is refused if
it, or any folder above it, is the same folder (device + inode, so no spelling of the path gets past it) as the
corpus parent or either corpus tree, or if a corpus tree lies inside it.

The corpus is two sibling trees under one parent, as Reader sees it (`ReaderArchiveLayout`):
    Archival Photos/        the PDFs (the main tree)
    Archival Photos JPEGS/  the JPEG partners
The copy keeps that shape, so Reader is granted the copy's parent folder exactly as it is granted the real one.

The evidence that the corpus was not touched: every sampled file's size, mtime, ctime, inode, tag xattr and full
xattr set is listed BEFORE the copy and again AFTER it, and the two listings must be byte-identical; the same is
done for the two tree roots and every folder directly inside them (mtime, ctime, link count). ctime moves on any
write to a file's data or metadata, so an unchanged ctime covers changes the other fields would miss; a folder's
mtime moves when an entry is added to or removed from it. atime is left out on purpose: reading a file may move
it, and reading is all this does. Files that were not sampled, and folders deeper than the first level, are not
listed: the claim is about what this script read. The copy is then checked against the source: same bytes
(SHA-256), size, mtime and Finder-tag xattr.

    python3 rehearsal-sample.py make            # select, list, copy, list again, check  (~5,000 PDFs)
    python3 rehearsal-sample.py make --count 50 --dest /tmp/x   # a small trial
    python3 rehearsal-sample.py make --resume   # finish or extend an earlier copy (see below)
    python3 rehearsal-sample.py verify          # re-list the sampled corpus files against the BEFORE listing

Sampling is spread across the tree, not the first N: PDFs are grouped by their first two folder levels and each
group gets its proportional share (largest remainder, at least one each when the count allows; below one per
group, a seeded choice of groups gets one each), drawn with a fixed seed.

What comes with a sampled PDF:
  * its JPEG partner(s) in the JPEGS tree, by Reader's own rule (`ArchiveCore` `JPEGPartnerIndex.resolve`): the
    image whose path mirrors the PDF's; else every image in the JPEGS tree with the PDF's stem (one = Reader's
    unique-stem match; several = an ambiguity Reader refuses to guess, and copying them all keeps it ambiguous);
  * main-tree images (.jpg/.jpeg/.heic) sharing its stem in its own folder, or the only main-tree image with that
    stem. These are not partners; they are real main-tree content a Reader walk meets next to the PDF.
On the corpus's own APFS volume the copy is made with `cp -c -p` (clonefile(2), copy-on-write, keeping xattrs and
mtime): it takes next to no space, and writing to it never reaches the source. `ditto` does not clone there; it was
measured writing the full size, so it is used only on another volume. Elsewhere the run is refused up front if it would leave less than --min-free-gib
free; either way it stops if free space falls under that floor mid-copy.

--resume reuses files an earlier run already copied: a destination file whose bytes match the source is kept,
any other existing destination file stops the run. This is how a sample is extended once disk space frees up.

Output (outside git, regenerable): ~/Library/Caches/ArchiveSuiteRehearsal/reader-sample/
    Archival Photos/ + Archival Photos JPEGS/   the copied trees; grant Reader this folder (their parent)
    selection.tsv      the sampled paths (relative to the parent), kind, and the PDF each belongs to
    before.tsv / after.tsv              sampled-file listings (must be equal)
    roots-before.tsv / roots-after.tsv  tree-root and first-level folder listings (must be equal)
    copy-check.tsv     per-file copy comparison
    MANIFEST.txt       what this is, how it was made, the counts and hashes
The listings name corpus files, so they stay in the cache; only counts and hashes are committed
(`verification/evidence/reader/W40.c2-sample.md`).
"""

import argparse
import collections
import ctypes
import ctypes.util
import hashlib
import os
import random
import shutil
import subprocess
import sys
import time

PARENT = os.path.expanduser("~/Desktop/Google Drive")
MAIN = "Archival Photos"
JPEGS = "Archival Photos JPEGS"
DEST = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/reader-sample")
TAG_XATTR = b"com.apple.metadata:_kMDItemUserTags"
IMAGE_EXTS = {".jpg", ".jpeg", ".heic"}  # JPEGPartnerIndex.isSupportedImageExtension
SEED = 402  # W40.c2
GiB = 1 << 30

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                           ctypes.c_uint32, ctypes.c_int]
_libc.getxattr.restype = ctypes.c_ssize_t
_libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
_libc.listxattr.restype = ctypes.c_ssize_t
XATTR_NOFOLLOW = 0x0001


def xattr_names(path):
    p = os.fsencode(path)
    size = _libc.listxattr(p, None, 0, XATTR_NOFOLLOW)
    if size <= 0:
        return []
    buf = ctypes.create_string_buffer(size)
    got = _libc.listxattr(p, buf, size, XATTR_NOFOLLOW)
    if got < 0:
        raise OSError(ctypes.get_errno(), "listxattr", path)
    return sorted(n for n in buf.raw[:got].split(b"\0") if n)


def xattr_value(path, name):
    p = os.fsencode(path)
    size = _libc.getxattr(p, name, None, 0, 0, XATTR_NOFOLLOW)
    if size < 0:
        return None
    buf = ctypes.create_string_buffer(max(size, 1))
    got = _libc.getxattr(p, name, buf, size, 0, XATTR_NOFOLLOW)
    if got < 0:
        raise OSError(ctypes.get_errno(), "getxattr", path)
    return buf.raw[:got]


def xattr_map(path):
    return {name: xattr_value(path, name) for name in xattr_names(path)}


def xattr_digest(path):
    """Tag xattr as hex, and a SHA-256 over every xattr name and value."""
    h = hashlib.sha256()
    for name, value in sorted(xattr_map(path).items()):
        value = value or b""
        h.update(name + b"\0" + len(value).to_bytes(8, "big") + value)
    tag = xattr_value(path, TAG_XATTR)
    return (tag.hex() if tag is not None else "-"), h.hexdigest()


def content_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def list_row(root, rel):
    """One listing line for `root/rel`. Every call here only reads."""
    path = os.path.join(root, rel)
    st = os.lstat(path)
    tag, xall = xattr_digest(path)
    return "\t".join([rel, str(st.st_size), str(st.st_mtime_ns), str(st.st_ctime_ns), str(st.st_ino),
                      tag, xall])


def roots_listing(parent):
    """The two tree roots and every folder directly inside them: mtime, ctime, link count."""
    rows = []
    for tree in (MAIN, JPEGS):
        top = os.path.join(parent, tree)
        entries = [""] + sorted(e.name for e in os.scandir(top) if e.is_dir(follow_symlinks=False))
        for name in entries:
            st = os.lstat(os.path.join(top, name))
            rows.append("\t".join([os.path.join(tree, name), str(st.st_mtime_ns), str(st.st_ctime_ns),
                                   str(st.st_nlink)]))
    return rows


def file_id(path):
    st = os.stat(path)
    return st.st_dev, st.st_ino


def ancestor_ids(path):
    """(dev, inode) of the nearest existing folder at or above `path`, and of every folder above it."""
    path = os.path.abspath(path)
    while not os.path.exists(path):
        path = os.path.dirname(path)
    ids = []
    while True:
        ids.append(file_id(path))
        up = os.path.dirname(path)
        if up == path:
            return ids
        path = up


def protected_ids(parent):
    return {file_id(parent), file_id(os.path.join(parent, MAIN)), file_id(os.path.join(parent, JPEGS))}


def check_dest(dest, parent):
    protected = protected_ids(parent)
    if protected & set(ancestor_ids(dest)):
        sys.exit(f"refused: destination {dest} is, or is inside, the corpus parent or a corpus tree")
    if os.path.exists(dest):
        dest_id = file_id(dest)
        for tree in (MAIN, JPEGS):
            if dest_id in ancestor_ids(os.path.join(parent, tree)):
                sys.exit(f"refused: the corpus tree {tree} lies inside the destination {dest}")
        # A symlink anywhere inside an existing destination (only --resume gets this far with one) could steer
        # ditto, or the "already copied" check, into the corpus. There is no reason for one to be there.
        for d, dirs, files in os.walk(dest, followlinks=False):
            for name in dirs + files:
                if os.path.islink(os.path.join(d, name)):
                    sys.exit(f"refused: {os.path.join(d, name)} is a symlink inside the destination")


def walk_tree(root):
    """Relative paths of PDFs and supported images under `root`; hidden entries and symlinks skipped."""
    pdfs, images = [], []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for f in sorted(files):
            rel = os.path.relpath(os.path.join(d, f), root)
            if f.startswith(".") or os.path.islink(os.path.join(root, rel)):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext == ".pdf":
                pdfs.append(rel)
            elif ext in IMAGE_EXTS:
                images.append(rel)
    return pdfs, images


def stratum(rel):
    return os.sep.join(os.path.dirname(rel).split(os.sep)[:2])


def select(pdfs, count, seed):
    groups = collections.defaultdict(list)
    for rel in pdfs:
        groups[stratum(rel)].append(rel)
    keys = sorted(groups)
    count = min(count, len(pdfs))
    if count < len(keys):  # too small for one per group: spread the groups themselves
        keys = sorted(random.Random(seed).sample(keys, count))
        quota = {k: 1 for k in keys}
    else:
        total = len(pdfs)
        exact = {k: len(groups[k]) * count / total for k in keys}
        quota = {k: max(1, int(exact[k])) for k in keys}
        spare = count - sum(quota.values())
        by_remainder = sorted(keys, key=lambda k: (-(exact[k] - int(exact[k])), k))
        i = 0
        while spare > 0:
            k = by_remainder[i % len(keys)]
            if quota[k] < len(groups[k]):
                quota[k] += 1
                spare -= 1
            i += 1
        while spare < 0:  # the at-least-one floor overshot: take back from the largest groups
            k = max((k for k in keys if quota[k] > 1), key=lambda k: quota[k])
            quota[k] -= 1
            spare += 1
    rng = random.Random(seed)
    chosen = []
    for k in keys:
        chosen.extend(rng.sample(groups[k], min(quota[k], len(groups[k]))))
    return sorted(chosen), len(groups)


def stem_of(rel):
    return os.path.splitext(os.path.basename(rel))[0]


def main_images(chosen, images):
    """Main-tree images sharing a sampled PDF's stem: same folder first, else the only one with that stem."""
    by_dir_stem, by_stem = collections.defaultdict(list), collections.defaultdict(list)
    for rel in images:
        by_dir_stem[(os.path.dirname(rel), stem_of(rel))].append(rel)
        by_stem[stem_of(rel)].append(rel)
    out = {}
    for pdf in chosen:
        here = by_dir_stem.get((os.path.dirname(pdf), stem_of(pdf)))
        if here:
            out[pdf] = here
        elif len(by_stem.get(stem_of(pdf), [])) == 1:
            out[pdf] = by_stem[stem_of(pdf)]
    return out


def partners(chosen, jpegs):
    """JPEGS-tree partners per JPEGPartnerIndex.resolve: mirrored path, else every candidate with the stem."""
    by_path, by_stem = collections.defaultdict(list), collections.defaultdict(list)
    for rel in jpegs:
        by_path[os.path.splitext(rel)[0]].append(rel)
        by_stem[stem_of(rel)].append(rel)
    out, kinds = {}, collections.Counter()
    for pdf in chosen:
        mirrored = by_path.get(os.path.splitext(pdf)[0])
        if mirrored:
            out[pdf] = mirrored
            kinds["mirrored" if len(mirrored) == 1 else "mirrored-ambiguous"] += 1
        elif by_stem.get(stem_of(pdf)):
            out[pdf] = by_stem[stem_of(pdf)]
            kinds["unique-stem" if len(out[pdf]) == 1 else "ambiguous-stem"] += 1
        else:
            kinds["none"] += 1
    return out, kinds


def write_tsv(path, header, rows):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + "\n")
        for r in rows:
            f.write(r + "\n")


LISTING_HEADER = "rel\tsize\tmtime_ns\tctime_ns\tino\ttag_xattr_hex\tall_xattrs_sha256"
ROOTS_HEADER = "folder\tmtime_ns\tctime_ns\tnlink"


def sha_file(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def cmd_make(a):
    parent, dest = os.path.realpath(a.parent), os.path.abspath(a.dest)
    main_root, jpeg_root = os.path.join(parent, MAIN), os.path.join(parent, JPEGS)
    for root in (main_root, jpeg_root):
        if not os.path.isdir(root):
            sys.exit(f"corpus tree not found: {root}")
    check_dest(dest, parent)
    if os.path.exists(dest) and os.listdir(dest) and not a.resume:
        sys.exit(f"refused: {dest} already exists and is not empty. It is regenerable: remove it first, "
                 f"or pass --resume to keep the files an earlier run copied.")

    t0 = time.time()
    pdfs, main_imgs = walk_tree(main_root)
    _, jpeg_imgs = walk_tree(jpeg_root)
    chosen, n_groups = select(pdfs, a.count, a.seed)
    extra = main_images(chosen, main_imgs)
    partner_sets, partner_kinds = partners(chosen, jpeg_imgs)

    def size(rel):
        return os.lstat(os.path.join(parent, rel)).st_size

    def to_copy(rel):  # bytes this run still has to write for `rel` (0 when an earlier run copied it)
        return 0 if a.resume and os.path.exists(os.path.join(dest, rel)) else size(rel)

    # selection rows: (rel under the parent, kind, the sampled PDF it came with)
    core = [(os.path.join(MAIN, p), "pdf", p) for p in chosen]
    core += [(os.path.join(MAIN, r), "main-image", p) for p, rs in extra.items() for r in rs]
    core = list(dict.fromkeys(core))
    for pdf, rs in partner_sets.items():
        core += [(os.path.join(JPEGS, r), "partner", pdf) for r in rs]
    seen = set()
    core = [row for row in core if not (row[0] in seen or seen.add(row[0]))]  # a file once, with its first PDF
    probe = dest
    while not os.path.exists(probe):
        probe = os.path.dirname(probe)
    free = shutil.disk_usage(probe).free
    # On the corpus's own APFS volume ditto clones (copy-on-write), so the copy takes next to no space and a
    # later write to it never reaches the source. Elsewhere it is a full copy; refuse up front if it cannot fit.
    clones = os.stat(probe).st_dev == os.stat(parent).st_dev
    need = 0 if clones else sum(to_copy(r) for r, _, _ in core)
    if free - need < a.min_free_gib * GiB:
        sys.exit(f"refused: the copy would leave {(free - need) / GiB:.1f} GiB free, under the "
                 f"--min-free-gib floor of {a.min_free_gib}. Nothing was copied.")
    sample = sorted(core)
    nbytes = sum(size(r) for r, _, _ in sample)
    print(f"walked {len(pdfs)} PDFs in {n_groups} folder groups and {len(jpeg_imgs)} JPEGS-tree images; sampled "
          f"{len(chosen)} PDFs, {len(partner_sets)} with partners; {len(sample)} files, {nbytes / GiB:.2f} GiB; "
          f"{free / GiB:.1f} GiB free; {'APFS clones' if clones else 'full copies'}", flush=True)

    os.makedirs(dest, exist_ok=True)
    write_tsv(os.path.join(dest, "selection.tsv"), "rel\tkind\tpdf", ["\t".join(s) for s in sample])

    print("listing sources (before) and hashing their content ...", flush=True)
    roots_before = roots_listing(parent)
    before = [list_row(parent, r) for r, _, _ in sample]
    src_sha = {r: content_sha256(os.path.join(parent, r)) for r, _, _ in sample}
    write_tsv(os.path.join(dest, "roots-before.tsv"), ROOTS_HEADER, roots_before)
    write_tsv(os.path.join(dest, "before.tsv"), LISTING_HEADER, before)

    print(f"copying {len(sample)} files with ditto ...", flush=True)
    protected = protected_ids(parent)
    reused = 0
    for i, (r, _, _) in enumerate(sample, 1):
        target = os.path.join(dest, r)
        if protected & set(ancestor_ids(os.path.dirname(target))):  # belt and braces over check_dest
            sys.exit(f"refused: {target} resolves into the corpus")
        if os.path.lexists(target):
            if (os.path.isfile(target) and not os.path.islink(target)
                    and content_sha256(target) == src_sha[r]):
                reused += 1
                continue
            sys.exit(f"refused: {target} exists and is not a copy of its source; nothing was overwritten")
        if clones:  # clonefile(2); ditto makes full copies even on the same volume (measured, 2026-10-14)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            subprocess.run(["/bin/cp", "-c", "-p", os.path.join(parent, r), target], check=True)
        else:
            subprocess.run(["/usr/bin/ditto", os.path.join(parent, r), target], check=True)
        if i % 100 == 0 and shutil.disk_usage(dest).free < a.min_free_gib * GiB:
            sys.exit(f"stopped after {i} files: under {a.min_free_gib} GiB free. Free space, then --resume.")
        if i % 500 == 0:
            print(f"  {i}/{len(sample)}", flush=True)

    print("listing sources (after) ...", flush=True)
    roots_after = roots_listing(parent)
    after = [list_row(parent, r) for r, _, _ in sample]
    write_tsv(os.path.join(dest, "roots-after.tsv"), ROOTS_HEADER, roots_after)
    write_tsv(os.path.join(dest, "after.tsv"), LISTING_HEADER, after)
    untouched = before == after and roots_before == roots_after

    print("checking the copy against the source ...", flush=True)
    bad, other = [], collections.Counter()
    check_rows = []
    for r, _, _ in sample:
        src, cpy = os.path.join(parent, r), os.path.join(dest, r)
        s_st, c_st = os.lstat(src), os.lstat(cpy)
        checks = [(c_st.st_dev, c_st.st_ino) != (s_st.st_dev, s_st.st_ino),  # a copy, not the source itself
                  content_sha256(cpy) == src_sha[r], c_st.st_size == s_st.st_size,
                  c_st.st_mtime_ns == s_st.st_mtime_ns,
                  xattr_value(cpy, TAG_XATTR) == xattr_value(src, TAG_XATTR)]
        s_x, c_x = xattr_map(src), xattr_map(cpy)
        differ = sorted(n for n in set(s_x) | set(c_x) if s_x.get(n) != c_x.get(n))
        other.update(differ)
        check_rows.append(r + "\t" + "\t".join("yes" if x else "NO" for x in checks) + "\t"
                          + (",".join(n.decode(errors="replace") for n in differ) or "-"))
        if not all(checks):
            bad.append(r)
    write_tsv(os.path.join(dest, "copy-check.tsv"),
              "rel\tdistinct_file\tsame_bytes\tsame_size\tsame_mtime\tsame_tags\tother_xattrs_differing", check_rows)
    used = free - shutil.disk_usage(dest).free
    other_note = ("none" if not other else
                  "; ".join(f"{n.decode(errors='replace')} on {c}" for n, c in sorted(other.items())))
    selected = {r for r, _, _ in sample}
    strays = sum(1 for tree in (MAIN, JPEGS) for d, _, fs in os.walk(os.path.join(dest, tree)) for f in fs
                 if os.path.relpath(os.path.join(d, f), dest) not in selected)

    kinds = collections.Counter(k for _, k, _ in sample)
    tagged = sum(1 for row in before if row.split("\t")[5] != "-")
    pk = ", ".join(f"{v} {k}" for k, v in sorted(partner_kinds.items()))
    manifest = f"""Archive Suite rehearsal set: Reader sample of the real corpus (W40.c2)

What: a read-only copy of {len(chosen)} PDFs from the real corpus with JPEG partners, every xattr (Finder tags
included) and mtime preserved by the copy, for the Reader rehearsals W40.d7 (at size) and W40.d8 (triage writes).
Grant Reader the folder "{dest}" (the parent of the two trees, as with the real corpus).
It is a COPY: writing to it is the point of W40.d8, and it never reaches the corpus.

Made: {time.strftime('%Y-%m-%d %H:%M:%S %Z')} by ArchiveReader/scripts/rehearsal-sample.py make
      --count {a.count} --seed {a.seed} --min-free-gib {a.min_free_gib}{' --resume' if a.resume else ''}
      (owner decision 3, 2026-10-04)
Source: {parent}/{{{MAIN}, {JPEGS}}}
        {len(pdfs)} PDFs walked in {n_groups} folder groups (first two levels); {len(jpeg_imgs)} JPEGS-tree images
Sample: {len(sample)} files, {nbytes / GiB:.2f} GiB: {kinds['pdf']} PDFs (proportional per group),
        {kinds['main-image']} main-tree images beside them, {kinds['partner']} JPEGS-tree partner files.
        {tagged} of {len(sample)} files carry a Finder-tag xattr.
Partners (Reader's rule, per sampled PDF): {pk}. Every one is copied.
Disk: {'APFS clones of the source (copy-on-write)' if clones else 'full copies'}; free space fell by
        {used / GiB:.2f} GiB during the run (other processes included).
Reused from an earlier run: {reused} files. Files in the copy's trees that are not in this selection: {strays}.

Sampled corpus files untouched: {'YES' if before == after else 'NO -- before.tsv and after.tsv differ'}
  before.tsv sha256 {sha_file(os.path.join(dest, 'before.tsv'))}
  after.tsv  sha256 {sha_file(os.path.join(dest, 'after.tsv'))}
  (size, mtime, ctime, inode, tag xattr and a hash of all xattrs, per sampled file; atime excluded, reads move it)
Corpus roots and first-level folders unchanged: {'YES' if roots_before == roots_after else 'NO -- roots-*.tsv differ'}
  roots-before.tsv sha256 {sha_file(os.path.join(dest, 'roots-before.tsv'))}
  roots-after.tsv  sha256 {sha_file(os.path.join(dest, 'roots-after.tsv'))}
Copy faithful: {'YES' if not bad else f'NO -- {len(bad)} files differ, see copy-check.tsv'}
  (per file: a distinct file from its source (device + inode), with the same SHA-256 content, size, mtime and
  Finder-tag xattr)
  Other xattrs that differ between copy and source (macOS bookkeeping it sets or rewrites on a new file; name on
  N files): {other_note}
selection.tsv sha256 {sha_file(os.path.join(dest, 'selection.tsv'))}

Extend once disk frees up: python3 ArchiveReader/scripts/rehearsal-sample.py make --resume
Regenerate: delete "{dest}", then python3 ArchiveReader/scripts/rehearsal-sample.py make
Re-check the corpus at any time: python3 ArchiveReader/scripts/rehearsal-sample.py verify
Took {time.time() - t0:.0f} s.
"""
    with open(os.path.join(dest, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write(manifest)
    print(manifest)
    if not untouched or bad:
        sys.exit(1)


def cmd_verify(a):
    parent, dest = os.path.realpath(a.parent), os.path.abspath(a.dest)
    with open(os.path.join(dest, "before.tsv"), encoding="utf-8") as f:
        rows = f.read().splitlines()[1:]
    changed = [r for r in rows if list_row(parent, r.split("\t")[0]) != r]
    print(f"{len(rows) - len(changed)} of {len(rows)} sampled corpus files unchanged since the copy")
    for r in changed[:20]:
        print("  changed:", r.split("\t")[0])
    sys.exit(1 if changed else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["make", "verify"])
    ap.add_argument("--parent", default=PARENT, help=f"folder holding '{MAIN}' and '{JPEGS}'")
    ap.add_argument("--dest", default=DEST)
    ap.add_argument("--count", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--min-free-gib", type=float, default=8.0,
                    help="never let the copy leave less than this free on the destination volume")
    ap.add_argument("--resume", action="store_true", help="keep files an earlier run already copied")
    a = ap.parse_args()
    {"make": cmd_make, "verify": cmd_verify}[a.command](a)


if __name__ == "__main__":
    main()
