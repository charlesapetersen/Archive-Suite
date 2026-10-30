"""Scratch JPEGs and a loopback fake server; no corpus, model or paid call."""
import contextlib
import csv
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

from PIL import Image
import marks_pilot as P
import marks_scan as S


def good(amount='signature_initials_date'):
    return dict(page_kind='typed_printed', marks={k: k == 'signature_initials' for k in S.CLASSES},
                handwriting_amount=amount, overlap_with_print=False, uncertain=False)


@contextlib.contextmanager
def server(mode='ok'):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            calls.append(body)
            if mode == 'http':
                self.send_error(503); return
            content = json.dumps(good())
            if mode == 'fenced':
                content = '```json\n' + content + '\n```'
            if mode == 'pilot-schema':
                pred = good(); pred.pop('handwriting_amount'); content = json.dumps(pred)
            response = dict(choices=[dict(finish_reason='length' if mode == 'cap' else 'stop',
                                         message=dict(content=content))],
                            usage=dict(prompt_tokens=100, completion_tokens=30))
            raw = P.encoded(response)
            self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers()
            self.wfile.write(raw)

    httpd = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True); thread.start()
    try:
        yield 'http://127.0.0.1:' + str(httpd.server_port), calls
    finally:
        httpd.shutdown(); httpd.server_close(); thread.join()


class Scratch(unittest.TestCase):
    PER = 4

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='marks scan ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.originals = self.base / 'originals'; self.originals.mkdir()
        self.roots = {c: c + ' exact root' for c in S.COLLECTIONS}
        self.pairs = self.base / 'pairs.tsv'
        self.rows = []
        for ci, c in enumerate(S.COLLECTIONS):
            folder = self.originals / self.roots[c]; folder.mkdir()
            for n in range(self.PER):
                path = folder / f'{n:05}.jpg'
                Image.new('RGB', (80, 100), (ci * 40 + n * 3, 30 + n * 20, 140)).save(path)
                self.rows.append(dict(pdf=c + str(n) + '.pdf', jpeg=str(path.relative_to(self.originals)),
                                      method='stem', tied='[]'))
        self.save_pairs()
        self.root = self.base / 'prepared'
        self.runtime = dict(model=S.MODEL, vllm_args=S.VLLM_ARGS, revision='a' * 40, job='123',
                            served=S.SERVED + '-123', vllm_version='test', transformers_version='test')

    def save_pairs(self):
        with self.pairs.open('w', newline='') as f:
            w = csv.DictWriter(f, ['pdf', 'jpeg', 'method', 'tied'], delimiter='\t')
            w.writeheader(); w.writerows(self.rows)

    def prepare(self, root=None):
        return S.prepare(root or self.root, self.pairs, self.originals, self.roots)

    def pages(self):
        return P.load(self.root / 'scan.json')['pages']

    def test_reproducible_whole_small_collections_and_no_source_mutation(self):
        hashes = {p: P.file_hash(p) for p in self.originals.rglob('*.jpg')}
        out = self.prepare()
        self.assertEqual(out['scan'], 20)
        self.prepare(self.base / 'second')
        self.assertEqual(P.file_hash(self.root / 'freeze.json'), P.file_hash(self.base / 'second/freeze.json'))
        self.assertEqual(hashes, {p: P.file_hash(p) for p in hashes})

    def test_cap_per_collection(self):
        with mock.patch.object(S, 'PER_COLLECTION', 2):
            out = self.prepare()
            self.assertEqual(out['collections'], dict.fromkeys(S.COLLECTIONS, 2))
            S.check(self.root)
        with self.assertRaisesRegex(ValueError, 'selection'):
            S.check(self.root)  # the frozen cap is part of the selection

    def test_duplicate_photograph_read_once_and_skip_explained(self):
        folder = self.originals / self.roots['Dean']
        shutil.copy2(folder / '00000.jpg', folder / 'copy.jpg')
        self.rows.append(dict(pdf='copy.pdf', jpeg=self.roots['Dean'] + '/copy.jpg', method='stem', tied='[]'))
        self.save_pairs()
        out = self.prepare()
        self.assertEqual((out['scan'], out['skipped_duplicates']), (20, 1))
        scan = P.load(self.root / 'scan.json')
        scan['skipped'][0]['source_sha256'] = '0' * 64
        (self.root / 'scan.json').write_bytes(P.encoded(scan))
        with self.assertRaisesRegex(ValueError, 'unexplained'):
            S.check(self.root)

    def test_existing_draft_never_overwritten(self):
        self.prepare()
        with self.assertRaises(FileExistsError):
            self.prepare()

    def test_tampered_image_prompt_or_code_refused(self):
        self.prepare()
        path = self.root / self.pages()[0]['image']
        original = path.read_bytes()
        path.write_bytes(original + b'changed')
        with self.assertRaisesRegex(ValueError, 'changed frozen file'):
            S.check(self.root)
        path.write_bytes(original)
        (self.root / 'support/marks_pilot.py').write_text('# stale')
        with self.assertRaisesRegex(ValueError, 'changed frozen file'):
            S.check(self.root)

    def test_request_carries_v2_prompt_and_nothing_private(self):
        self.prepare()
        b = S.request(self.root, self.pages()[0])
        self.assertEqual(b['messages'][0]['content'][1]['text'], S.PROMPT)
        self.assertEqual(b['model'], S.SERVED)
        text = json.dumps(b)
        for sensitive in ('source_rel', 'source_sha256', 'collection', str(self.originals)):
            self.assertNotIn(sensitive, text)

    def test_loopback_read_resume_and_summary(self):
        self.prepare()
        with server() as (url, calls):
            S.read(self.root, url, self.runtime); S.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 20)
        s = S.summary(self.root)
        self.assertTrue(s['complete'])
        self.assertEqual((s['status'], s['fenced'], s['inconsistent']), ({'ok': 20}, 0, 0))
        self.assertEqual(s['by_collection']['Dean']['amount'], {'signature_initials_date': 4})

    def test_fence_is_parsed_and_recorded(self):
        self.prepare()
        with server('fenced') as (url, _):
            S.read(self.root, url, self.runtime)
        s = S.summary(self.root)
        self.assertEqual((s['status'], s['fenced']), ({'ok': 20}, 20))

    def test_pilot_schema_reply_is_a_kept_parse_failure(self):
        self.prepare()
        with server('pilot-schema') as (url, calls):
            S.read(self.root, url, self.runtime); S.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 20)
        self.assertEqual(S.summary(self.root)['status'], {'parse': 20})

    def test_http_error_and_cap_kept_without_retry(self):
        self.prepare()
        with server('http') as (url, calls):
            S.read(self.root, url, self.runtime); S.read(self.root, url, self.runtime)
        self.assertEqual(len(calls), 20)
        self.assertEqual(S.summary(self.root)['status'], {'error': 20})

    def test_interrupted_request_recorded_never_replayed(self):
        self.prepare()
        p = self.pages()[0]
        P.write_new(self.root / 'intents' / (p['id'] + '.json'), P.encoded(S.identity(self.root, p, self.runtime)))
        second = dict(self.runtime, job='456', served=S.SERVED + '-456')
        with server() as (url, calls):
            S.read(self.root, url, second)
        self.assertEqual(len(calls), 19)
        self.assertEqual(S.summary(self.root)['status'], {'ok': 19, 'interrupted': 1})

    def test_deadline_leaves_pages_unread_and_summary_says_so(self):
        self.prepare()
        with server() as (url, calls):
            S.read(self.root, url, self.runtime, deadline=-1)
        self.assertEqual(len(calls), 0)
        s = S.summary(self.root)
        self.assertEqual((s['read'], s['complete']), (0, False))

    def test_other_model_runtime_refused_on_resume(self):
        self.prepare()
        with server() as (url, _):
            S.read(self.root, url, self.runtime)
        other = dict(self.runtime, revision='b' * 40)
        with self.assertRaisesRegex(ValueError, 'mix model runtimes'):
            S.read(self.root, 'http://127.0.0.1:9', other)

    def test_stale_receipt_refused(self):
        self.prepare()
        with server() as (url, _):
            S.read(self.root, url, self.runtime)
        dest = self.root / 'out' / (self.pages()[0]['id'] + '.json')
        rec = P.load(dest); rec['prediction']['uncertain'] = True; dest.write_bytes(P.encoded(rec))
        with self.assertRaisesRegex(ValueError, 'disagrees'):
            S.summary(self.root)

    def test_submit_dry_run_two_jobs_and_unattended_refusal(self):
        self.prepare()
        scratch = self.base / 'scratch tree'
        env = dict(S.os.environ, SCRATCH=str(scratch), GROUP_HOME=str(self.base / 'group home'),
                   ARCHIVE_UNATTENDED='1')
        r = subprocess.run(['bash', str(S.HERE / 'marks-scan-submit.sh'), str(self.root), '--dry-run'],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr.count('sbatch '), 2)
        self.assertIn('/support/marks-scan-job.sh', r.stderr)
        self.assertIn('--time=03:00:00', r.stderr)
        self.assertFalse(scratch.exists())
        denied = subprocess.run(['bash', str(S.HERE / 'marks-scan-submit.sh'), str(self.root)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(denied.returncode, 2)
        self.assertIn('owner-attended', denied.stdout)

    def test_real_submit_refuses_stale_shell_before_scheduling(self):
        self.prepare()
        (self.root / 'support/marks-scan-job.sh').write_text('# stale')
        scratch = self.base / 'scratch tree'
        env = dict(S.os.environ, SCRATCH=str(scratch), GROUP_HOME=str(self.base / 'group home'),
                   ARCHIVE_UNATTENDED='0')
        r = subprocess.run(['bash', str(S.HERE / 'marks-scan-submit.sh'), str(self.root)],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn('differs from frozen support', r.stdout)
        self.assertFalse(scratch.exists())


class Parsing(unittest.TestCase):
    def test_bands_and_consistency(self):
        obj, fenced, consistent = S.prediction(json.dumps(good()))
        self.assertEqual((obj['handwriting_amount'], fenced, consistent), ('signature_initials_date', False, True))
        none = good('none'); none['marks'] = dict.fromkeys(S.CLASSES, False)
        self.assertTrue(S.prediction(json.dumps(none))[2])
        self.assertFalse(S.prediction(json.dumps(good('none')))[2])  # a signature but no handwriting
        stamp_only = good('30_plus_words'); stamp_only['marks'] = dict(dict.fromkeys(S.CLASSES, False), stamp=True)
        self.assertFalse(S.prediction(json.dumps(stamp_only))[2])  # words of handwriting but no hand class
        page = good('handwritten_page'); page['page_kind'] = 'handwritten'
        page['marks'] = dict.fromkeys(S.CLASSES, False)
        self.assertTrue(S.prediction(json.dumps(page))[2])
        self.assertFalse(S.prediction(json.dumps(good('handwritten_page')))[2])  # typed page kind

    def test_invalid_replies_rejected(self):
        variants = []
        p = good(); p['handwriting_amount'] = 'some'; variants.append(json.dumps(p))
        p = good(); p.pop('handwriting_amount'); variants.append(json.dumps(p))
        p = good(); p['marks']['stamp'] = 'false'; variants.append(json.dumps(p))
        p = good('none'); p['marks'] = dict.fromkeys(S.CLASSES, False); p['overlap_with_print'] = True
        variants.append(json.dumps(p))
        variants += ['{"marks":{},"marks":{}}', 'Here it is: ' + json.dumps(good()),
                     '```json\n' + json.dumps(good()) + '\n```\nand more', '```json\n{}\n```']
        for raw in variants:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError): S.prediction(raw)

    def test_the_pilots_fenced_reply_parses(self):
        raw = '```json\n' + json.dumps(good(), indent=2) + '\n```'
        self.assertTrue(S.prediction(raw)[1])

    def test_job_specific_server_name_required(self):
        r = dict(model=S.MODEL, vllm_args=S.VLLM_ARGS, revision='a' * 40, job='123',
                 served=S.SERVED, vllm_version='test', transformers_version='test')
        with self.assertRaisesRegex(ValueError, 'runtime provenance'):
            S.runtime_check(r)


if __name__ == '__main__':
    unittest.main()
