#!/bin/bash
# test-finder-tags.sh — the Spotlight-free Finder-tag read, and the E2E oracle that depends on it.
#
# Two lanes, no app build, no key, no cost, no network:
#   1. `finder_tags.py --self-test`  — every status branch of the reader against a scratch fixture.
#   2. `assert_mac.py` end-to-end    — a TESTOUT whose expected year exists ONLY as a Finder tag.
#
# Lane 2 is the point. It builds the incident (Wave 26 · W26.oracle) inside the test lane: a fixture
# under /tmp that Spotlight has never indexed, tagged on disk. Four assertions, and each one is there
# because without it lane 2 could pass for the wrong reason:
#   (a) `mdls` finds no year on that fixture     — the predecessor was blind, measured, not assumed;
#   (b) `assert_mac.py` PASSES on it             — the xattr read supplies what mdls could not;
#   (c) strip the tag and it FAILS               — so (b) passed BECAUSE of the tag, not despite it;
#   (d) make the tag unreadable and it FAILS     — but says the check went blind rather than blaming
#                                                  tagging (the "no tags" vs "couldn't read" split).
# Plus: the oracle writes nothing (mtimes + tags unchanged across a run).
#
# Usage: ./scripts/test-finder-tags.sh      Exit 0 = PASS. Writes only under mktemp.
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"

echo "=== lane 1: finder_tags.py --self-test ==="
python3 "$HERE/finder_tags.py" --self-test || { echo "RESULT: FAIL (reader self-test)"; exit 1; }

echo
echo "=== lane 2: assert_mac.py against a tag-only year, under /tmp ==="
python3 - "$HERE" <<'PY' || exit 1
import binascii, json, os, plistlib, shutil, subprocess, sys, tempfile

here = sys.argv[1]
ORACLE = os.path.join(here, 'assert_mac.py')
TAG_XATTR = 'com.apple.metadata:_kMDItemUserTags'
YEAR, TOKEN = '1962', 'MEMO-ALPHA-4471'
fails = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def write_tags(path, tags):
    blob = binascii.hexlify(plistlib.dumps(tags, fmt=plistlib.FMT_BINARY)).decode()
    subprocess.run(['xattr', '-wx', TAG_XATTR, blob, path], check=True)


# /tmp on purpose: this is where e2e-phone-mac.sh puts TESTOUT, and it is not Spotlight-indexed.
root = tempfile.mkdtemp(prefix='ap-e2e-oracletest-', dir='/tmp')
try:
    testout = os.path.join(root, 'out')
    os.makedirs(testout)
    pdf = os.path.join(testout, 'doc.pdf')          # NB: the YEAR must not appear in any filename
    with open(pdf, 'wb') as f:
        f.write(b'%PDF-1.4 scratch\n')
    write_tags(pdf, [YEAR, '03 March', 'Unread'])
    # The OCR token lands in a sidecar so lane 2 needs no real PDF text layer; the year must NOT.
    with open(os.path.join(testout, 'notes.txt'), 'w') as f:
        f.write(TOKEN + ' scratch fixture\n')
    # Ground truth lives OUTSIDE TESTOUT — inside it, the oracle would find the year in its own
    # ground-truth file and lane 2 would pass without ever reading a tag.
    gt = os.path.join(root, 'ground_truth.json')
    with open(gt, 'w') as f:
        json.dump([{'file': 'doc.pdf', 'token': TOKEN, 'year': YEAR}], f)
    nopdftext = os.path.join(root, 'no-pdftext-binary')   # sh() swallows the missing binary -> ''

    def oracle():
        return subprocess.run([sys.executable, ORACLE, testout, gt, nopdftext],
                              capture_output=True, text=True, cwd='/')   # foreign cwd on purpose

    # (a) the predecessor's read, on this exact fixture.
    mdls = subprocess.run(['mdls', '-name', 'kMDItemUserTags', pdf], capture_output=True, text=True)
    print(f"       mdls rc={mdls.returncode} out={mdls.stdout.strip()!r}")
    check(YEAR not in mdls.stdout,
          f"mdls cannot see the year tag here — the old oracle was blind, not merely fragile")

    # (b) the oracle passes, and says what it read.
    r = oracle()
    check(r.returncode == 0, f"oracle PASSES with the year only in a Finder tag (rc={r.returncode})")
    check(f"'{YEAR}'" in r.stdout and 'no Spotlight' in r.stdout,
          "oracle reports the tags it read from the xattr")
    if r.returncode != 0:
        print('\n'.join('       | ' + x for x in r.stdout.splitlines()))

    # no-write: the oracle is a reader.
    before = (os.stat(pdf).st_mtime_ns, subprocess.run(['xattr', '-px', TAG_XATTR, pdf],
                                                       capture_output=True, text=True).stdout)
    oracle()
    after = (os.stat(pdf).st_mtime_ns, subprocess.run(['xattr', '-px', TAG_XATTR, pdf],
                                                      capture_output=True, text=True).stdout)
    check(before == after, "oracle wrote nothing (mtime + tag xattr unchanged)")

    # (d) unreadable tags: must fail, but must not blame tagging.
    os.chmod(pdf, 0o000)
    try:
        r = oracle()
    finally:
        os.chmod(pdf, 0o644)
    check(r.returncode == 1, f"unreadable tags -> FAIL (rc={r.returncode})")
    check('could not READ Finder tags' in r.stdout, "unreadable tags are reported as a blind read")
    check('may be a blind check rather than a real failure' in r.stdout,
          "the year failure does not misattribute a blind read to broken tagging")

    # (c) the mutation that proves (b) was caused by the tag.
    subprocess.run(['xattr', '-d', TAG_XATTR, pdf], check=True)
    r = oracle()
    check(r.returncode == 1, f"tag stripped -> FAIL (rc={r.returncode}); (b) passed BECAUSE of the tag")
    check('(none)' in r.stdout, "oracle reports no tags on output when there are none")
finally:
    shutil.rmtree(root, ignore_errors=True)

if fails:
    print(f"\nRESULT: FAIL ({len(fails)} failures)")
    sys.exit(1)
print("\nRESULT: PASS")
PY

echo
echo "RESULT: PASS — reader self-test + oracle differential both green"
