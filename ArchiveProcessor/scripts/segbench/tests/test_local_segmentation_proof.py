"""Scratch-only lifecycle regressions for the local proof supervisor; no app/model/API calls.

Run outside the sandbox (ps/footprint inspection): python3 -B -m unittest discover -s scripts/segbench/tests -p test_local_segmentation_proof.py
"""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('local_proof', Path(__file__).resolve().parents[1] / 'local_segmentation_proof.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class LifecycleTests(unittest.TestCase):
    def wait_finished(self, child):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            if proof.finished(child):
                return
            time.sleep(.02)
        self.fail('scratch child did not finish')

    def test_exited_leader_is_not_reaped_before_orphan_cleanup(self):
        child = subprocess.Popen([sys.executable, '-c',
            'import subprocess,sys; subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"])'],
            start_new_session=True)
        try:
            self.wait_finished(child)
            self.assertIsNone(child.returncode, 'finished must not reap the group leader')
            self.assertTrue(proof.group_live(child.pid), 'the scratch orphan must actually exist')
            self.assertEqual(proof.stop(child), 0)
            self.assertFalse(proof.group_live(child.pid))
        finally:
            if child.returncode is None:
                proof.stop(child)

    def test_live_group_ignoring_term_is_killed_and_reaped(self):
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(60)'],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            self.assertEqual(proof.stop(child), -signal.SIGKILL)
            self.assertFalse(proof.group_live(child.pid))
        finally:
            child.stdout.close()
            if child.returncode is None:
                proof.stop(child)

    def test_already_finished_group_needs_no_live_member(self):
        child = subprocess.Popen([sys.executable, '-c', 'raise SystemExit(7)'], start_new_session=True)
        try:
            self.wait_finished(child)
            self.assertEqual(proof.stop(child), 7)
        finally:
            if child.returncode is None:
                proof.stop(child)


class AppOwnershipTests(unittest.TestCase):
    def test_report_stops_and_reaps_the_app(self):
        with tempfile.TemporaryDirectory(prefix='proof-app-test-') as directory:
            base = Path(directory)
            binary, report, pidfile = base / 'app', base / 'report', base / 'pid'
            binary.write_text('#!' + sys.executable + '\nimport os,time\nfrom pathlib import Path\n'
                              + f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
                              + f'Path({str(report)!r}).write_text("ALL PASS")\ntime.sleep(60)\n')
            binary.chmod(0o755)
            self.assertEqual(proof.run_app(binary, report, base / 'app.log'), 0)
            self.assertFalse(proof.group_live(int(pidfile.read_text())))

    def test_crash_before_report_fails_promptly(self):
        with tempfile.TemporaryDirectory(prefix='proof-app-test-') as directory:
            base = Path(directory)
            binary = base / 'app'
            binary.write_text('#!' + sys.executable + '\nraise SystemExit(7)\n')
            binary.chmod(0o755)
            start = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, 'app exited before writing'):
                proof.run_app(binary, base / 'report', base / 'app.log')
            self.assertLess(time.monotonic() - start, 5)


    def test_outer_stop_also_cleans_a_term_ignoring_app_group(self):
        with tempfile.TemporaryDirectory(prefix='proof-app-nested-test-') as directory:
            base = Path(directory)
            binary, pidfile = base / 'app', base / 'pid'
            binary.write_text('#!' + sys.executable + '\nimport os,signal,time\nfrom pathlib import Path\n'
                              + 'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                              + f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(60)\n')
            binary.chmod(0o755)
            supervisor = subprocess.Popen([sys.executable, str(Path(proof.__file__)), '--app', str(binary),
                '--report', str(base / 'report'), '--app-log', str(base / 'log')],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            app_pid = None
            try:
                until = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < until:
                    time.sleep(.02)
                self.assertTrue(pidfile.exists(), 'the separate app group must actually start')
                app_pid = int(pidfile.read_text())
                proof.stop(supervisor, grace=15)
                self.assertFalse(proof.group_live(app_pid), 'outer teardown must leave no escaped app group')
            finally:
                if supervisor.returncode is None:
                    proof.stop(supervisor, grace=15)
                if app_pid is not None and proof.group_live(app_pid):
                    os.killpg(app_pid, signal.SIGKILL)
