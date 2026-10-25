"""Scratch JPEGs and a loopback fake server; no corpus, model or paid call."""
import contextlib
import csv
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

from PIL import Image
import marks_pilot as M


def good():
    return dict(page_kind='typed_printed', marks={k: k == 'signature_initials' for k in M.CLASSES},
                overlap_with_print=False, uncertain=False)


@contextlib.contextmanager
def server(mode='ok'):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            calls.append(body)
            if mode == 'redirect':
                self.send_response(302); self.send_header('Location', 'https://example.invalid/'); self.end_headers()
                return
            if mode == 'http':
                self.send_error(503); return
            pred = good()
            if mode == 'bad':
                pred['marks']['stamp'] = 'false'
            response = dict(choices=[dict(finish_reason='length' if mode == 'cap' else 'stop',
                                         message=dict(content=json.dumps(pred)))],
                            usage=dict(prompt_tokens=100, completion_tokens=30))
            raw = M.encoded(response)
            self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers()
            self.wfile.write(raw)

    httpd = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True); thread.start()
    try:
        yield 'http://127.0.0.1:' + str(httpd.server_port), calls
    finally:
        httpd.shutdown(); httpd.server_close(); thread.join()


class Scratch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='marks pilot ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.originals = self.base / 'originals'; self.originals.mkdir()
        self.roots = {c: c + ' exact root' for c in M.COLLECTIONS}
        self.pairs = self.base / 'pairs.tsv'
        self.rows = []
        for ci, c in enumerate(M.COLLECTIONS):
            folder = self.originals / self.roots[c]; folder.mkdir()
            for n in range(4):
                path = folder / f'{n:05}.jpg'
                Image.new('RGB', (80, 100), (ci * 40 + n * 3, 30 + n * 20, 140)).save(path)
                self.rows.append(dict(pdf=c + str(n) + '.pdf', jpeg=str(path.relative_to(self.originals)),
                                      method='stem', tied='[]'))
        self.save_pairs()
        self.root = self.base / 'prepared'
        M.prepare(self.root, self.pairs, self.originals, self.roots)
        self.runtime = dict(model=M.MODEL, vllm_args=M.VLLM_ARGS, revision='a' * 40, job='123',
                            served=M.SERVED + '-123',
                            vllm_version='test', transformers_version='test')

    def save_pairs(self):
        with self.pairs.open('w', newline='') as f:
            w = csv.DictWriter(f, ['pdf', 'jpeg', 'method', 'tied'], delimiter='\t')
            w.writeheader(); w.writerows(self.rows)

    def test_original_selection_reproducible_and_no_source_mutation(self):
        original_hashes = {p: M.file_hash(p) for p in self.originals.rglob('*.jpg')}
        other = self.base / 'prepared second'
        M.prepare(other, self.pairs, self.originals, self.roots)
        self.assertEqual(M.file_hash(self.root / 'freeze.json'), M.file_hash(other / 'freeze.json'))
        self.assertEqual(original_hashes, {p: M.file_hash(p) for p in original_hashes})
        self.assertEqual(len(M.load(other / 'pilot.json')['pages']), 15)

    def test_existing_draft_never_overwritten(self):
        with self.assertRaises(FileExistsError):
            M.prepare(self.root, self.pairs, self.originals, self.roots)

    def test_frozen_image_tamper_refused(self):
        path = self.root / M.load(self.root / 'pilot.json')['pages'][0]['image']
        path.write_bytes(path.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'changed frozen file'):
            M.check(self.root)

    def test_frozen_code_tamper_refused(self):
        (self.root / 'support/marks_pilot.py').write_text('# stale')
        with self.assertRaisesRegex(ValueError, 'changed frozen file'):
            M.check(self.root)

    def test_wrong_model_refused(self):
        f = M.load(self.root / 'freeze.json'); f['model'] = 'substitute'
        (self.root / 'freeze.json').write_bytes(M.encoded(f))
        with self.assertRaisesRegex(ValueError, 'protocol/model'):
            M.check(self.root)

    def test_ambiguous_pair_refused(self):
        self.rows[0]['tied'] = '["other.jpg"]'; self.save_pairs()
        with self.assertRaisesRegex(ValueError, 'unresolved'):
            M.inventory(self.pairs, self.originals, self.roots)

    def test_exact_collection_prefix_not_substring(self):
        unrelated = self.originals / 'Dean unrelated'; unrelated.mkdir()
        Image.new('RGB', (80, 100)).save(unrelated / 'one.jpg')
        self.rows.append(dict(pdf='unrelated.pdf', jpeg='Dean unrelated/one.jpg', method='stem', tied='[]'))
        self.save_pairs()
        self.assertEqual(len(M.inventory(self.pairs, self.originals, self.roots)), 20)

    def test_backup_variant_refused(self):
        self.rows[0]['jpeg'] = self.roots['Dean'] + '/original1.00000.jpg'; self.save_pairs()
        with self.assertRaisesRegex(ValueError, 'noncanonical'):
            M.inventory(self.pairs, self.originals, self.roots)

    def test_source_path_escape_refused(self):
        self.rows[0]['jpeg'] = '../outside.jpg'; self.save_pairs()
        with self.assertRaisesRegex(ValueError, 'relative'):
            M.inventory(self.pairs, self.originals, self.roots)

    def test_request_includes_only_image_and_instruction(self):
        p = M.load(self.root / 'pilot.json')['pages'][0]
        b = M.request(self.root, p)
        self.assertEqual(b['model'], M.SERVED)
        self.assertFalse(b['chat_template_kwargs']['enable_thinking'])
        text = json.dumps(b)
        for sensitive in ('source_rel', 'source_sha256', 'collection', 'truth', str(self.originals)):
            self.assertNotIn(sensitive, text)

    def test_real_loopback_transport_receipts_resume_and_summary(self):
        with server() as (url, calls):
            M.read(self.root, url, self.runtime)
            M.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 15)
        self.assertTrue(all(b['model'] == self.runtime['served'] for b in calls))
        s = M.summary(self.root)
        self.assertEqual(s['status'], {'ok': 15}); self.assertEqual(s['preflagged'], 15)

    def test_failed_outcomes_are_kept_and_not_retried(self):
        with server('bad') as (url, calls):
            M.read(self.root, url, self.runtime); M.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 15)
        self.assertEqual(M.summary(self.root)['status'], {'parse': 15})

    def test_cap_is_not_a_positive_prediction(self):
        with server('cap') as (url, _):
            M.read(self.root, url, self.runtime)
        self.assertEqual(M.summary(self.root)['status'], {'cap': 15})
        self.assertEqual(M.summary(self.root)['preflagged'], 0)

    def test_redirect_stops_at_loopback(self):
        with server('redirect') as (url, calls):
            M.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 15)
        self.assertEqual(M.summary(self.root)['status'], {'error': 15})

    def test_http_error_recorded_without_retry(self):
        with server('http') as (url, calls):
            M.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 15)
        self.assertEqual(M.summary(self.root)['status'], {'error': 15})

    def test_interrupted_call_intent_blocks_ambiguous_replay(self):
        p = M.load(self.root / 'pilot.json')['pages'][0]
        M.write_new(self.root / 'intents' / (p['id'] + '.json'), M.encoded(M.identity(self.root, p, self.runtime)))
        with mock.patch.object(M.urllib.request.OpenerDirector, 'open', side_effect=AssertionError('network called')):
            with self.assertRaises(FileExistsError):
                M.read(self.root, 'http://127.0.0.1:8000', self.runtime)

    def test_missing_receipt_refuses_complete_summary(self):
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            M.summary(self.root)

    def test_wrong_revision_and_stale_request_refused(self):
        with server() as (url, _):
            M.read(self.root, url, self.runtime)
        p = M.load(self.root / 'pilot.json')['pages'][0]
        dest = self.root / 'out' / (p['id'] + '.json')
        rec = M.load(dest); rec['request_sha256'] = '0' * 64; dest.write_bytes(M.encoded(rec))
        with self.assertRaisesRegex(ValueError, 'mismatched'):
            M.summary(self.root)

    def test_submit_dry_run_spaced_paths_two_jobs_no_scratch_writes(self):
        scratch = self.base / 'scratch tree'
        env = dict(M.os.environ, SCRATCH=str(scratch), GROUP_HOME=str(self.base / 'group home'), ARCHIVE_UNATTENDED='1')
        r = subprocess.run(['bash', str(M.HERE / 'marks-pilot-submit.sh'), str(self.root), '--dry-run'],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr.count('sbatch '), 2)
        self.assertIn('/support/marks-pilot-job.sh', r.stderr)
        self.assertFalse(scratch.exists())
        denied = subprocess.run(['bash', str(M.HERE / 'marks-pilot-submit.sh'), str(self.root)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(denied.returncode, 2)
        self.assertIn('owner-attended', denied.stdout)
        self.assertFalse(scratch.exists())

    def test_real_submit_refuses_stale_shell_before_scheduling(self):
        (self.root / 'support/marks-pilot-job.sh').write_text('# stale execution path')
        scratch = self.base / 'scratch tree'
        env = dict(M.os.environ, SCRATCH=str(scratch), GROUP_HOME=str(self.base / 'group home'), ARCHIVE_UNATTENDED='0')
        r = subprocess.run(['bash', str(M.HERE / 'marks-pilot-submit.sh'), str(self.root)],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn('differs from frozen support', r.stdout)
        self.assertFalse(scratch.exists())


class Parsing(unittest.TestCase):
    def test_good_and_empty_are_distinct(self):
        self.assertTrue(any(M.prediction(json.dumps(good()))['marks'].values()))
        p = good(); p['marks'] = dict.fromkeys(M.CLASSES, False)
        self.assertFalse(any(M.prediction(json.dumps(p))['marks'].values()))

    def test_nonboolean_missing_extra_duplicate_and_nonfinite_rejected(self):
        variants = []
        for value in (0, 'false', None):
            p = good(); p['marks']['stamp'] = value; variants.append(json.dumps(p))
        p = good(); p['marks'].pop('other'); variants.append(json.dumps(p))
        p = good(); p['marks']['extra'] = False; variants.append(json.dumps(p))
        variants += ['{"marks":{},"marks":{}}', '{"a":NaN}', '```json\n' + json.dumps(good()) + '\n```']
        for raw in variants:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError): M.prediction(raw)

    def test_external_url_credentials_and_path_rejected(self):
        for url in ('https://example.com', 'http://localhost.evil:80', 'http://localhost',
                    'http://user@localhost:80', 'http://localhost:80/else', 'http://127.0.0.1:80?x=1'):
            with self.subTest(url=url):
                with self.assertRaises(ValueError): M.server_url(url)

    def test_real_corpus_output_refused(self):
        with self.assertRaisesRegex(ValueError, 'scratch/cache'):
            M.safe_output(Path.home() / 'Desktop/Google Drive/Archival Photos/test-output')

    def test_job_specific_server_name_required(self):
        r = dict(model=M.MODEL, vllm_args=M.VLLM_ARGS, revision='a' * 40, job='123',
                 served=M.SERVED, vllm_version='test', transformers_version='test')
        with self.assertRaisesRegex(ValueError, 'runtime provenance'):
            M.runtime_check(r)


if __name__ == '__main__':
    unittest.main()
