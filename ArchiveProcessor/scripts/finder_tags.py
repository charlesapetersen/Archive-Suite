#!/usr/bin/env python3
"""The one Spotlight-free Finder-tag reader for the Processor's test oracles.

Finder tags live in the `com.apple.metadata:_kMDItemUserTags` extended attribute: a binary plist of
strings, each either a bare name ("Unread") or "Name\\nLABELINDEX" ("Red\\n6"). Reading that xattr is a
plain filesystem read. Reading `kMDItemUserTags` via `mdls` instead goes through **Spotlight**, which
answers `(null)` for any file it has not indexed — and reports that as success (exit 0), so the caller
cannot tell "this file has no tags" from "I was never told about this file".

Measured 2026-08-06 on this machine, at the E2E harness's own output location
(`/tmp/ap-e2e-$$/out`, from `e2e-phone-mac.sh:34-35`): a file whose tags are provably on disk
(`xattr -px` returns the plist) reads back `kMDItemUserTags = (null)` from `mdls`, exit 0. `/tmp` and
`/var/folders` are not indexed, so an `mdls` oracle is not merely *fragile* there — it is **blind**,
in every run, always. That is the 2026-08-04 Reader incident reproduced inside the test lane.
(Wave 26 · `W26.oracle`; the plan is `execution-plans/despotlight.md` §"Site 6".)

Two entry points:

* `read_tags(path)` -> `(names, label, status)` — also reports **why** an empty answer is empty.
  "Confirmed no tags" and "could not read the tags" are different answers, and conflating them is the
  defect `W26.deny` fixed on the Swift side (`ArchiveCore.TagXattr.inspect`). Only the exact
  `No such xattr` signature confirms absence; everything unrecognised is `unreadable`, so a future
  macOS wording change degrades to "I could not look", never to a false "there is nothing here".
* `disk_tags(path)` -> `(names, label)` — the legacy compatibility shape, which reports `([], 0)` for both
  empty and unreadable. New callers should prefer `read_tags`; `tier2_assert.py` does, because its verdict
  depends on being able to distinguish those answers.
"""
import binascii
import plistlib
import subprocess

TAG_XATTR = 'com.apple.metadata:_kMDItemUserTags'

# Finder's label indices, for tags written as a bare colour name with no "\nINDEX" suffix.
COLOR_IDX = {'Red': 6, 'Purple': 3, 'Orange': 7, 'Yellow': 5, 'Blue': 4, 'Green': 2, 'Gray': 1, 'Grey': 1}

# `status` values from read_tags():
OK = 'ok'                  # the xattr was read and parsed; `names` is authoritative
ABSENT = 'absent'          # the file demonstrably carries no tag xattr (or a zero-length one)
UNREADABLE = 'unreadable'  # the answer is unknown: denied, vanished, malformed, or timed out


def read_tags(path, timeout=30):
    """(tag_names:[str], label_number:int, status:str) read straight from the tag xattr.

    `status` is one of OK / ABSENT / UNREADABLE. On anything but OK, `names` is `[]` and `label` is 0 —
    but ABSENT means "no tags, verified" while UNREADABLE means "do not trust this emptiness".

    A vanished file lands in UNREADABLE on purpose: the question a test oracle needs answered is "can I
    rely on this empty result?", and for a path that disappeared mid-run the answer is no.
    """
    try:
        r = subprocess.run(['xattr', '-px', TAG_XATTR, path],
                           capture_output=True, text=True, timeout=timeout)
    except Exception:
        return [], 0, UNREADABLE

    if r.returncode != 0:
        # Measured signatures (macOS 15, /usr/bin/xattr): "No such xattr: <name>" for a file with no
        # tags; "No such file: <path>" for a vanished one; "[Errno 13] Permission denied: <path>" for a
        # denied file OR a denied parent directory. Only the first confirms absence.
        return ([], 0, ABSENT) if 'No such xattr' in (r.stderr or '') else ([], 0, UNREADABLE)

    hexed = ''.join(r.stdout.split())
    if not hexed:
        # A zero-length attribute is a real, readable "no tags" — not a failure. (W26.deny measured that
        # treating size 0 as an error mis-flagged 51 files in the real corpus.)
        return [], 0, ABSENT
    try:
        items = plistlib.loads(binascii.unhexlify(hexed))
    except Exception:
        return [], 0, UNREADABLE   # the attribute exists but is not a tag plist

    names, label = [], 0
    for t in items:
        parts = str(t).split('\n')
        names.append(parts[0])
        if len(parts) > 1 and parts[1].strip().isdigit():
            label = max(label, int(parts[1].strip()))
        elif parts[0] in COLOR_IDX:
            label = max(label, COLOR_IDX[parts[0]])
    return names, label, OK


def disk_tags(path):
    """(tag_names:[str], label_number:int) from the file's Finder-tag xattr; ([],0) if none.

    Compatibility shape: collapses ABSENT and UNREADABLE into the same empty answer, which is why
    `read_tags` exists. Kept for legacy callers; any oracle whose verdict depends on tags must use
    `read_tags` and reject UNREADABLE.
    """
    names, label, _status = read_tags(path)
    return names, label


# ---------------------------------------------------------------------------------------------------
# Self-test: `python3 finder_tags.py --self-test`. Covers every status branch against a real scratch
# fixture, and re-measures the mdls differential this module exists to remove. Writes only to mktemp.
# ---------------------------------------------------------------------------------------------------

def _self_test():
    import os
    import shutil
    import sys
    import tempfile

    fails = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            fails.append(msg)

    d = tempfile.mkdtemp(prefix='finder-tags-selftest-')
    try:
        def mk(name, tags=None, raw=None):
            p = os.path.join(d, name)
            with open(p, 'wb') as f:
                f.write(b'%PDF-1.4 scratch\n')
            if tags is not None:
                raw = binascii.hexlify(plistlib.dumps(tags, fmt=plistlib.FMT_BINARY)).decode()
            if raw is not None:
                subprocess.run(['xattr', '-wx', TAG_XATTR, raw, p], check=True)
            return p

        print("[finder_tags] status branches")
        tagged = mk('tagged.pdf', tags=['1962', '03 March', 'Red\n6', 'Unread'])
        names, label, status = read_tags(tagged)
        check(status == OK, f"tagged file -> status {status!r} (want {OK!r})")
        check(names == ['1962', '03 March', 'Red', 'Unread'], f"tag names {names!r}")
        check(label == 6, f"label index {label} (want 6)")

        untagged = mk('untagged.pdf')
        names, label, status = read_tags(untagged)
        check((names, label, status) == ([], 0, ABSENT), f"no tag xattr at all -> {(names, label, status)!r}")

        # An attribute that is PRESENT but zero-length: a readable "no tags", NOT a failure. Distinct
        # from the case above (the attribute is in `xattr <file>`'s listing), and its own branch in
        # read_tags — W26.deny measured that calling this an error mis-flagged 51 real corpus files.
        # Without this fixture, mutating that branch to UNREADABLE survives the suite.
        zerolen = mk('zero-length-attr.pdf', raw='')
        names, label, status = read_tags(zerolen)
        check((names, label, status) == ([], 0, ABSENT), f"zero-length tag xattr -> {(names, label, status)!r}")

        names, label, status = read_tags(os.path.join(d, 'vanished.pdf'))
        check(status == UNREADABLE, f"missing file -> status {status!r} (want {UNREADABLE!r})")

        denied = mk('denied.pdf', tags=['1962'])
        os.chmod(denied, 0o000)
        try:
            names, label, status = read_tags(denied)
        finally:
            os.chmod(denied, 0o644)
        check(status == UNREADABLE, f"unreadable file -> status {status!r} (want {UNREADABLE!r})")
        check(names == [], "unreadable file reports no tag names")

        malformed = mk('malformed.pdf', raw='DEADBEEF')
        names, label, status = read_tags(malformed)
        check(status == UNREADABLE, f"non-plist xattr -> status {status!r} (want {UNREADABLE!r})")

        # A colour written WITHOUT the "\nINDEX" suffix must still yield its label index.
        bare = mk('bare-colour.pdf', tags=['Purple'])
        names, label, status = read_tags(bare)
        check((names, label, status) == (['Purple'], 3, OK), f"bare colour -> {(names, label, status)!r}")

        print("[finder_tags] disk_tags() compatibility shape")
        check(disk_tags(tagged) == (['1962', '03 March', 'Red', 'Unread'], 6), "disk_tags on tagged file")
        check(disk_tags(untagged) == ([], 0), "disk_tags on untagged file")
        check(disk_tags(os.path.join(d, 'vanished.pdf')) == ([], 0),
              "disk_tags collapses unreadable to ([],0) for legacy compatibility")

        print("[finder_tags] the mdls differential this module exists to remove")
        mdls = subprocess.run(['mdls', '-name', 'kMDItemUserTags', tagged],
                              capture_output=True, text=True)
        print(f"       mdls rc={mdls.returncode} out={mdls.stdout.strip()!r}")
        check('1962' in '\n'.join(read_tags(tagged)[0]),
              "xattr read finds the year tag on a never-indexed fixture")
        check('1962' not in mdls.stdout,
              "mdls does NOT find it on the same file (the blindness W26.oracle removes)")

        print("[finder_tags] the reader writes nothing")
        before = [(os.stat(p).st_mtime_ns, read_tags(p)[0]) for p in (tagged, untagged, bare)]
        for p in (tagged, untagged, bare, malformed):
            read_tags(p)
        after = [(os.stat(p).st_mtime_ns, read_tags(p)[0]) for p in (tagged, untagged, bare)]
        check(before == after, "mtimes + tags unchanged after repeated reads")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    if fails:
        print(f"\n[finder_tags] SELF-TEST FAIL ({len(fails)} failures)")
        return 1
    print("\n[finder_tags] SELF-TEST PASS")
    return 0


if __name__ == '__main__':
    import sys
    if '--self-test' in sys.argv:
        sys.exit(_self_test())
    print(__doc__)
    print("usage: finder_tags.py --self-test    (this module is a library; see read_tags/disk_tags)")
    sys.exit(2)
