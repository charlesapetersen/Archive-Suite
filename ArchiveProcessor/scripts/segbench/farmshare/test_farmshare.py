"""W41.farmshare-plan offline tests: Slurm-limit parsing, and fs_ocr.py against a fake vLLM server on localhost.
No cluster, GPU, corpus or paid API. Run: python3 -m unittest test_farmshare (from this directory)."""
import http.server
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import limits as L  # noqa: E402
import fs_ocr as F  # noqa: E402
import estimate as E  # noqa: E402

HERE = Path(__file__).resolve().parent
try:
    import ocr_panel_score  # noqa: F401
    SCORING = True
except ImportError:
    SCORING = False


class Limits(unittest.TestCase):
    def test_slurm_time_forms(self):
        for s, m in [('30', 30), ('30:15', 30), ('08:00:00', 480), ('1-00:00:00', 1440), ('7-00:00:00', 10080),
                     ('2-12', 3600), ('1-02:30', 1590), ('UNLIMITED', None), ('infinite', None), ('', None)]:
            self.assertEqual(L.minutes(s), m, s)

    # Shaped like the values docs.farmshare.stanford.edu/slurm published (2026-10-15), not cluster output.
    SINFO = 'normal*|(null)|2-00:00:00|20\nbigmem|(null)|2-00:00:00|2\ngpu|gpu:l40s:4(S:0-1)|2-00:00:00|6\n'
    QOS = ('normal||cpu=256,gres/gpu=3|128|1024\ninteractive|1-00:00:00|cpu=16,gres/gpu=1,mem=64G|3|3\n'
           'dev|08:00:00|cpu=8,gres/gpu=1,mem=32G|1|1\nlong|7-00:00:00|cpu=32|4|32\ngpu||gres/gpu=6|4|32\n')

    def test_parse_and_choose(self):
        parts = L.gpu_partitions(self.SINFO)
        self.assertEqual(parts, [('gpu', 4, 2880)])
        q = L.qos_table(self.QOS)
        self.assertEqual(q['gpu'], {'maxwall': None, 'gpus_pu': 6, 'jobs_pu': 4, 'submit_pu': 32})
        s = L.choose(parts, q, {'normal', 'gpu', 'interactive', 'dev'})
        self.assertEqual((s['FS_PARTITION'], s['FS_QOS'], s['FS_MAXGPU_PU'], s['FS_MAXJOBS_PU'], s['FS_MAXWALL_MIN']),
                         ('gpu', 'gpu', 6, 4, 2880))
        # A user not associated with the gpu QOS falls back to what they are allowed.
        s = L.choose(parts, q, {'normal'})
        self.assertEqual((s['FS_QOS'], s['FS_MAXGPU_PU']), ('normal', 3))
        # Slurm would not list the user's QOS: name none rather than guess one sbatch may refuse.
        self.assertEqual(L.choose(parts, q, set())['FS_QOS'], '')

    # What FarmShare itself reported on 2026-10-15: GPU nodes in BOTH `normal` and `gpu`, listed normal first, and
    # `normal` refusing the `gpu` QOS. The first run paired normal + gpu and sbatch said "Invalid qos specification".
    CLUSTER_SINFO = ('normal*|(null)|2-00:00:00|14\nnormal*|gpu:4(S:0-1)|2-00:00:00|6\n'
                     'bigmem|(null)|2-00:00:00|2\ngpu|gpu:4(S:0-1)|2-00:00:00|6\n')
    CLUSTER_QOS = ('normal||cpu=512,gres/gpu=1|128|1024\ninteractive||cpu=16,mem=64G|4|4\n'
                   'dev|08:00:00|cpu=8,mem=32G|1|1\nlong|7-00:00:00|cpu=128|4|32\ngpu||gres/gpu=4|4|32\n')
    CLUSTER_PARTS = ('PartitionName=normal AllowGroups=ALL AllowAccounts=ALL AllowQos=normal,long,interactive,dev '
                     'Default=YES QoS=normal\nPartitionName=bigmem AllowQos=ALL QoS=bigmem\n'
                     'PartitionName=gpu AllowGroups=ALL AllowAccounts=ALL AllowQos=ALL Default=NO QoS=gpu\n')
    CLUSTER_ALLOWED = {'bigmem', 'caddyshack', 'dev', 'gpu', 'interactive', 'long', 'normal'}

    def test_cluster_pairs_the_gpu_qos_with_a_partition_that_allows_it(self):
        parts = L.gpu_partitions(self.CLUSTER_SINFO)
        self.assertEqual(sorted(parts), [('gpu', 4, 2880), ('normal', 4, 2880)])
        allow = L.partition_qos(self.CLUSTER_PARTS)
        self.assertEqual(allow['normal'], {'normal', 'long', 'interactive', 'dev'})
        self.assertIsNone(allow['gpu'])
        s = L.choose(parts, L.qos_table(self.CLUSTER_QOS), self.CLUSTER_ALLOWED, allow)
        self.assertEqual((s['FS_PARTITION'], s['FS_QOS'], s['FS_MAXGPU_PU'], s['FS_MAXJOBS_PU'], s['FS_MAXWALL_MIN']),
                         ('gpu', 'gpu', 4, 4, 2880))
        # Without the gpu QOS the user gets normal's one GPU, on the normal partition that allows it.
        s = L.choose(parts, L.qos_table(self.CLUSTER_QOS), self.CLUSTER_ALLOWED - {'gpu'}, allow)
        self.assertEqual((s['FS_PARTITION'], s['FS_QOS'], s['FS_MAXGPU_PU']), ('normal', 'normal', 1))
        # If only `normal` had GPUs, its allow-list alone must keep the 4-GPU `gpu` QOS off it.
        s = L.choose([('normal', 4, 2880)], L.qos_table(self.CLUSTER_QOS), self.CLUSTER_ALLOWED, allow)
        self.assertEqual((s['FS_PARTITION'], s['FS_QOS']), ('normal', 'normal'))

    def test_no_gpu_partition_is_an_error(self):
        with self.assertRaises(SystemExit):
            L.choose(L.gpu_partitions('normal*|(null)|1:00:00|2\n'), {}, set())


class Fake(http.server.BaseHTTPRequestHandler):
    """Answers like vLLM's /v1/chat/completions. The reply text is chosen by the image bytes."""
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        Fake.seen.append(b)
        import base64
        img = base64.b64decode(b['messages'][0]['content'][0]['image_url']['url'].split(',', 1)[1])
        from PIL import Image
        colour = Image.open(io.BytesIO(img)).getpixel((0, 0))
        if colour[0] > 200:      # red: a reply cut off at max_tokens
            content, finish = 'KIND: printed\nTABLE: no\nTEXT:\nhalf a pa', 'length'
        else:
            content, finish = 'KIND: printed\nTABLE: no\nTEXT:\nThe quick brown fox', 'stop'
        out = json.dumps({'choices': [{'message': {'content': content}, 'finish_reason': finish}],
                          'usage': {'prompt_tokens': 4873, 'completion_tokens': 9}}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)


class Driver(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fake)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.url = f'http://127.0.0.1:{cls.httpd.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        Fake.seen.clear()
        self.tmp = Path(tempfile.mkdtemp(prefix='fs-ocr-test-'))

    def image(self, path, colour, size=(3000, 2000)):
        from PIL import Image
        path.parent.mkdir(parents=True, exist_ok=True)
        Image.new('RGB', size, colour).save(path)

    def bulk(self, *extra):
        cmd = [sys.executable, str(HERE / 'fs_ocr.py'), 'bulk', '--url', self.url, '--model', 'm',
               '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'out'), '--concurrency', '2', *extra]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120)

    def test_request_is_the_panel_request(self):
        F.Server(self.url, 'm', F.P.MAX_TOKENS, True).read(F.jpeg(self.mk('a.png', (0, 0, 0)), F.P.SIDE))
        b = Fake.seen[0]
        self.assertEqual(b['messages'][0]['content'][1]['text'], F.P.PROMPT)
        self.assertEqual((b['temperature'], b['max_tokens']), (0, 8192))
        self.assertEqual(b['chat_template_kwargs'], {'enable_thinking': False})

    def mk(self, name, colour, size=(3000, 2000)):
        p = self.tmp / 'in' / name; self.image(p, colour, size); return p

    def test_image_capped_like_the_panel(self):
        from PIL import Image
        im = Image.open(io.BytesIO(F.jpeg(self.mk('big.png', (0, 0, 0), (4800, 3000)), 2400)))
        self.assertEqual((im.format, im.size), ('JPEG', (2400, 1500)))
        im = Image.open(io.BytesIO(F.jpeg(self.mk('small.png', (0, 0, 0), (800, 600)), 2400)))
        self.assertEqual(im.size, (800, 600))  # never upscaled

    def test_bulk_writes_text_logs_failures_and_resumes(self):
        self.mk('box1/a.jpg', (0, 0, 0)); self.mk('box1/b.png', (0, 0, 0)); self.mk('c.jpg', (255, 0, 0))
        (self.tmp / 'in' / 'notes.txt').write_text('not an image')
        r = self.bulk()
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.tmp / 'out'
        self.assertEqual((out / 'box1/a.jpg.txt').read_text(), 'The quick brown fox')
        self.assertTrue((out / 'box1/b.png.txt').exists())
        self.assertFalse((out / 'c.jpg.txt').exists())      # cut off at max_tokens: a failure, not text
        fails = [json.loads(x) for x in (out / 'failed-0.jsonl').read_text().splitlines()]
        self.assertEqual([f['image'] for f in fails], ['c.jpg'])
        self.assertEqual(json.loads((out / '_meta/box1/a.jpg.json').read_text())['kind'], 'printed')
        self.assertEqual(list(out.rglob('*.tmp*')), [])
        n = len(Fake.seen)
        r = self.bulk()                                      # rerun: only the failed page is asked again
        self.assertEqual(len(Fake.seen) - n, 1, r.stdout)
        self.assertIn('2 already done, 1 to read', r.stdout)

    def test_bulk_shards_partition_the_input(self):
        for k in range(5):
            self.mk(f'p{k}.jpg', (0, 0, 0))
        for i in range(2):
            self.assertEqual(self.bulk('--shard', f'{i}/2').returncode, 0)
        self.assertEqual(len(list((self.tmp / 'out').glob('p*.txt'))), 5)
        self.assertEqual(len(Fake.seen), 5)                  # no page read twice across shards

    def test_same_stem_different_format_both_read(self):
        self.mk('a.jpg', (0, 0, 0)); self.mk('a.png', (0, 0, 0))
        self.assertEqual(self.bulk().returncode, 0)
        self.assertEqual(sorted(p.name for p in (self.tmp / 'out').glob('a.*.txt')), ['a.jpg.txt', 'a.png.txt'])

    def test_unreadable_image_is_that_page_failure_only(self):
        self.mk('good.jpg', (0, 0, 0))
        (self.tmp / 'in' / 'broken.jpg').write_bytes(b'not a jpeg')
        r = self.bulk()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.tmp / 'out' / 'good.jpg.txt').exists())
        fails = [json.loads(x) for x in (self.tmp / 'out' / 'failed-0.jsonl').read_text().splitlines()]
        self.assertEqual([(f['image'], f['status']) for f in fails], [('broken.jpg', 'unreadable')])

    def test_dead_server_stops_and_asks_for_a_resubmit(self):
        for k in range(20):
            self.mk(f'p{k:02}.jpg', (0, 0, 0))
        import socket
        with socket.socket() as sk:                          # a port nobody listens on: every read is 'error'
            sk.bind(('127.0.0.1', 0)); port = sk.getsockname()[1]
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'bulk', '--url', f'http://127.0.0.1:{port}',
                            '--model', 'm', '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'out'),
                            '--concurrency', '1'], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 75, r.stdout + r.stderr)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])['left'], 20)
        self.assertEqual(len((self.tmp / 'out' / 'failed-0.jsonl').read_text().splitlines()), F.DEAD_SERVER)
        self.assertEqual(self.bulk().returncode, 0)           # server back: the rerun reads all 20
        self.assertEqual(len(list((self.tmp / 'out').glob('p*.jpg.txt'))), 20)

    def test_bulk_deadline_stops_and_exits_75(self):
        self.mk('a.jpg', (0, 0, 0))
        r = self.bulk('--deadline', '1')
        self.assertEqual(r.returncode, 75)
        self.assertEqual(len(Fake.seen), 0)

    def test_bulk_refuses_output_inside_input(self):
        self.mk('a.jpg', (0, 0, 0))
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'bulk', '--url', self.url, '--model', 'm',
                            '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'in' / 'out')],
                           capture_output=True, text=True, timeout=60)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('outside --in', r.stderr)

    @unittest.skipUnless(SCORING, 'needs rapidfuzz + sacrebleu (ocr-panel-requirements.txt)')
    def test_truth_mode_scores_a_synthetic_pack(self):
        import hashlib
        pack = self.tmp / 'pack'
        jobs = []
        for page, colour in (('p001', (0, 0, 0)), ('p086', (0, 0, 0)), ('p002', (255, 0, 0))):
            b = F.jpeg(self.mk(page + '.png', colour, (900, 1200)), 2400)
            F.atomic_write(pack / 'images' / (page + '.jpg'), b)
            F.atomic_write(pack / 'truth' / (page + '.txt'), b'The quick brown fox')
            jobs.append({'page': page, 'scale': 'original', 'id': page + '-original',
                         'sha256': hashlib.sha256(b).hexdigest()})
        (pack / 'pages.tsv').write_text('\t'.join(F.STRATA) + '\n' + ''.join(
            f'{j["page"]}\tprinted\t\t\t{"yes" if j["page"] == "p001" else ""}\t\n' for j in jobs))
        (pack / 'pack.json').write_text(json.dumps({'prompt_sha256': hashlib.sha256(F.P.PROMPT.encode()).hexdigest(),
                                                    'jobs': jobs, 'agreement': ['p086']}))
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'truth', '--url', self.url, '--model', 'm',
                            '--pack', str(pack), '--out', str(self.tmp / 'runs'), '--label', 't'],
                           capture_output=True, text=True, timeout=120, env={**os.environ})
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads((self.tmp / 'runs/t/summary.json').read_text())
        self.assertEqual((s['accuracy_96']['n'], s['accuracy_96']['ok'], s['agreement_3']['n']), (2, 1, 1))
        self.assertAlmostEqual(s['clippings']['nes'], 1.0)
        self.assertAlmostEqual(s['accuracy_96']['nes'], 0.5)  # the cut-off page scores as empty, as on the panel
        self.assertEqual(s['throughput']['pages'], 3)

    def test_truth_mode_refuses_a_changed_image(self):
        import hashlib
        pack = self.tmp / 'pack'
        F.atomic_write(pack / 'images/p001.jpg', b'x')
        (pack / 'pages.tsv').write_text('\t'.join(F.STRATA) + '\n')
        (pack / 'pack.json').write_text(json.dumps({'prompt_sha256': hashlib.sha256(F.P.PROMPT.encode()).hexdigest(),
            'jobs': [{'page': 'p001', 'sha256': '0' * 64}], 'agreement': []}))
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'truth', '--url', self.url, '--model', 'm',
                            '--pack', str(pack), '--out', str(self.tmp / 'runs'), '--label', 't'],
                           capture_output=True, text=True, timeout=60)
        self.assertIn('differs from the frozen panel input', r.stderr)
        self.assertEqual(Fake.seen, [])


class Estimate(unittest.TestCase):
    def test_table_has_every_candidate_and_ranges_are_ordered(self):
        t = E.table()
        for name in E.CANDIDATES:
            self.assertIn(name, t)
        for c in E.CANDIDATES.values():
            fast = E.seconds_per_page(c, E.PHOTO, 0.40, 0.80, True)
            slow = E.seconds_per_page(c, E.PHOTO, 0.20, 0.60, False)
            self.assertLess(fast, slow)


class Shell(unittest.TestCase):
    def test_scripts_parse_and_presets_resolve(self):
        for f in ('setup.sh', 'download.sh', 'job.sbatch', 'submit.sh', 'models.sh'):
            self.assertEqual(subprocess.run(['bash', '-n', str(HERE / f)]).returncode, 0, f)
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; preset qwen3.6-27b-dyn; echo "$FS_VLLM_ARGS"; '
                              'preset qwen3.6-27b; echo "$FS_MODEL|$FS_VLLM_ARGS"; preset nope; '
                              'FS_MAX_LEN=12288 preset qwen3.6-35b-a3b'],
                             capture_output=True, text=True)
        first, second = out.stdout.splitlines()[:2]
        self.assertIn('--quantization fp8', first)
        self.assertTrue(second.startswith('Qwen/Qwen3.6-27B-FP8|'))
        self.assertNotIn('--quantization', second)          # the fallback's flag does not leak into the next preset
        self.assertIn('{"image":1}', second)
        self.assertIn('unknown preset', out.stderr)
        self.assertIn('below prompt + max_tokens', out.stderr)
        self.assertIn('--max-model-len 16384', second)


if __name__ == '__main__':
    unittest.main()
