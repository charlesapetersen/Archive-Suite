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
# set, the jobs after the first FAKE_SHORT read one line, as the 04:49 run read part of its pages. FAKE_FLIP names one
# image whose k-th reading has FAKE_SEQ[k] lines; from the FAKE_FAULT_CALL-th process on, every job reads one line.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
mode = args[0] if len(args) == 2 else None
n, short = int(os.environ['FAKE_LINES']), int(os.environ.get('FAKE_SHORT', '-1'))
state = os.environ['FAKE_STATE']
def bump(name):
    f = os.path.join(state, name)
    c = int(open(f).read()) if os.path.exists(f) else 0
    open(f, 'w').write(str(c + 1))
    return c
call = bump('calls')
fault = 0 < int(os.environ.get('FAKE_FAULT_CALL', '0')) <= call + 1
seq = [int(x) for x in os.environ.get('FAKE_SEQ', '').split(',') if x]
for i, row in enumerate(l for l in open(args[-1]).read().splitlines() if l.strip()):
    src, out = row.split('\t')[:2]
    if os.path.exists(out):
        continue
    k = 1 if fault or 0 <= short <= i else n
    if os.path.basename(src) == os.environ.get('FAKE_FLIP'):
        k = seq[min(bump('flip'), len(seq) - 1)]
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
        (self.t / 'state').mkdir()
        os.environ['FAKE_STATE'] = str(self.t / 'state')
        for k in ('FAKE_SHORT', 'FAKE_FLIP', 'FAKE_SEQ', 'FAKE_FAULT_CALL'):
            os.environ.pop(k, None)

    def calls(self):
        return int((self.t / 'state' / 'calls').read_text())

    def lines(self, out):
        return len(out.read_text().splitlines())

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

    def test_every_written_page_is_read_a_second_time(self):
        G.run(self.bin, self.jobs)
        self.assertEqual(self.calls(), 2)
        G.run(self.bin, self.jobs)                      # nothing new to write, nothing to read again
        self.assertEqual(self.calls(), 3)
        G.run(self.bin, self.jobs, twice=False)
        self.assertEqual(self.calls(), 4)

    def test_short_first_reading_is_replaced_by_the_agreeing_pair(self):
        os.environ.update(FAKE_FLIP='2.jpg', FAKE_SEQ='7,10,10')
        G.run(self.bin, self.jobs)
        self.assertEqual(self.lines(self.outs[2]), 10)
        self.assertEqual(self.calls(), 3)
        self.assertTrue(all(self.lines(o) == 10 for o in self.outs))

    def test_a_page_flipping_between_two_readings_keeps_the_first(self):
        os.environ.update(FAKE_FLIP='2.jpg', FAKE_SEQ='12,8,12')   # a handwritten page's two readings
        G.run(self.bin, self.jobs)
        self.assertEqual(self.lines(self.outs[2]), 12)
        self.assertFalse((self.t / 'q').exists())

    def test_a_page_that_never_settles_is_quarantined_and_refused(self):
        os.environ.update(FAKE_FLIP='2.jpg', FAKE_SEQ='10,13,16,19,22,25')
        with self.assertRaisesRegex(G.VisionRunFault, 'never read 1 page'):
            G.run(self.bin, self.jobs)
        self.assertFalse(self.outs[2].exists())
        self.assertTrue(all(o.exists() for o in self.outs if o != self.outs[2]))
        self.assertEqual(self.calls(), 1 + G.ROUNDS + 1)

    def test_a_fault_on_the_second_read_quarantines_the_first_reads_too(self):
        os.environ['FAKE_FAULT_CALL'] = '2'
        with self.assertRaisesRegex(G.VisionRunFault, 'outputs moved .* as well'):
            G.run(self.bin, self.jobs)
        self.assertFalse(any(o.exists() for o in self.outs))

    def test_nonzero_exit_still_raises_when_checked(self):
        bad = self.t / 'bad'
        bad.write_text(FAKE + 'sys.exit(1)\n')
        bad.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            G.run(bad, self.jobs)
        self.assertEqual(G.run(bad, self.jobs, check=False).returncode, 1)


if __name__ == '__main__':
    unittest.main()
