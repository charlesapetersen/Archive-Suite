#!/usr/bin/env python3
"""Offline tests for vision_guard.run: a fake Vision binary, no model, no cache."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vision_guard as G  # noqa: E402

# Writes N lines of five words per job (N from FAKE_LINES), as text or as segbench-dewarp lines' JSON; with FAKE_SHORT
# set, the jobs after the first FAKE_SHORT read one line, as the 04:49 run read part of its pages.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
mode = args[0] if len(args) == 2 else None
n, short = int(os.environ['FAKE_LINES']), int(os.environ.get('FAKE_SHORT', '-1'))
for i, row in enumerate(l for l in open(args[-1]).read().splitlines() if l.strip()):
    src, out = row.split('\t')[:2]
    if os.path.exists(out):
        continue
    k = 1 if 0 <= short <= i else n
    lines = [f'w{j} a b c d' for j in range(k)]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w') as f:
        f.write(json.dumps({'lines': [{'text': l} for l in lines]}) if mode == 'lines' else '\n'.join(lines))
'''


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.bin = self.t / 'fake'
        self.bin.write_text(FAKE)
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IEXEC)
        images = self.t / 'images'
        images.mkdir()
        for p in G.REFERENCE:
            (images / f'{p}-original.jpg').write_bytes(p.encode())
        want = {p: {'lines': 10, 'words': 50} for p in G.REFERENCE}
        frozen = self.t / 'frozen.json'
        frozen.write_text(json.dumps({'os_build': 'TEST1', 'tools': {t: want for t in G.TOOLS},
                                      'images': {p: G.hashlib.sha256(p.encode()).hexdigest()[:16]
                                                 for p in G.REFERENCE}}))
        self.patch = mock.patch.multiple(G, IMAGES=images, FROZEN=frozen, QUARANTINE=self.t / 'q',
                                         os_build=lambda: 'TEST1')
        self.patch.start()
        self.jobs = self.t / 'jobs.tsv'
        self.outs = [self.t / 'out' / f'{k}.txt' for k in range(5)]
        self.jobs.write_text(''.join(f'/img/{k}.jpg\t{o}\n' for k, o in enumerate(self.outs)))
        os.environ['FAKE_LINES'] = '10'
        os.environ.pop('FAKE_SHORT', None)

    def tearDown(self):
        self.patch.stop()

    def test_good_run_passes_and_writes_only_its_jobs(self):
        G.run(self.bin, self.jobs)
        self.assertTrue(all(o.exists() for o in self.outs))
        self.assertEqual(sorted(p.name for p in (self.t / 'out').iterdir()), [o.name for o in self.outs])
        self.assertFalse((self.t / 'q').exists())

    def test_dewarp_lines_json_is_counted(self):
        outs = [o.with_suffix('.json') for o in self.outs]
        self.jobs.write_text(''.join(f'/img/{k}.jpg\t{o}\n' for k, o in enumerate(outs)))
        G.run(self.bin, self.jobs, 'lines')
        self.assertTrue(all(o.exists() for o in outs))

    def test_short_end_references_refuse_and_quarantine_new_outputs(self):
        self.outs[0].parent.mkdir()
        self.outs[0].write_text('kept from an earlier run')
        os.environ['FAKE_SHORT'] = str(len(G.REFERENCE) + 3)   # fails part-way through the run's own jobs
        with self.assertRaisesRegex(G.VisionRunFault, 'p004 at the end: 1 lines / 5 words against 10 / 50'):
            G.run(self.bin, self.jobs)
        self.assertEqual(self.outs[0].read_text(), 'kept from an earlier run')
        self.assertFalse(any(o.exists() for o in self.outs[1:]))
        moved = json.loads(next((self.t / 'q').glob('*/MOVED.json')).read_text())['moved']
        self.assertEqual(sorted(moved.values()), sorted(str(o) for o in self.outs[1:]))

    def test_slack_is_one_line_and_three_percent(self):
        want = {'lines': 10, 'words': 100}
        self.assertFalse(G.short({'lines': 9, 'words': 97}, want))
        self.assertTrue(G.short({'lines': 8, 'words': 100}, want))
        self.assertTrue(G.short({'lines': 10, 'words': 96}, want))
        self.assertTrue(G.short(None, want))

    def test_other_os_build_or_changed_image_refuses_before_reading(self):
        with mock.patch.object(G, 'os_build', lambda: 'TEST2'):
            with self.assertRaisesRegex(G.VisionRunFault, 'frozen on macOS build TEST1'):
                G.run(self.bin, self.jobs)
        (G.IMAGES / 'p014-original.jpg').write_bytes(b'other')
        with self.assertRaisesRegex(G.VisionRunFault, 'p014'):
            G.run(self.bin, self.jobs)
        self.assertFalse(any(o.exists() for o in self.outs))

    def test_quad_mode_is_not_guarded(self):
        with mock.patch.object(G.subprocess, 'run') as r:
            G.run(self.bin, self.jobs, 'quad')
        r.assert_called_once_with([str(self.bin), 'quad', str(self.jobs)], check=True)

    def test_nonzero_exit_still_raises_when_checked(self):
        bad = self.t / 'bad'
        bad.write_text(FAKE + 'sys.exit(1)\n')
        bad.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            G.run(bad, self.jobs)
        self.assertEqual(G.run(bad, self.jobs, check=False).returncode, 1)


if __name__ == '__main__':
    unittest.main()
