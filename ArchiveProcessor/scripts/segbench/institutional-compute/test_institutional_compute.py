"""W41.farmshare-plan offline tests: Slurm-limit parsing, and cluster_ocr.py and cluster_seg.py against a fake vLLM server on
localhost.
No cluster, GPU, corpus or paid API. Run: python3 -m unittest test_institutional_compute (from this directory)."""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import shlex
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profiles as C  # noqa: E402
import limits as L  # noqa: E402
import cluster_ocr as F  # noqa: E402
import estimate as E  # noqa: E402

HERE = Path(__file__).resolve().parent
try:
    import ocr_panel_score  # noqa: F401
    SCORING = True
except ImportError:
    SCORING = False
try:
    import numpy  # noqa: F401
    NUMPY = True
except ImportError:
    NUMPY = False


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
        self.assertEqual((s['IC_PARTITION'], s['IC_QOS'], s['IC_MAXGPU_PU'], s['IC_MAXJOBS_PU'], s['IC_MAXWALL_MIN']),
                         ('gpu', 'gpu', 6, 4, 2880))
        # A user not associated with the gpu QOS falls back to what they are allowed.
        s = L.choose(parts, q, {'normal'})
        self.assertEqual((s['IC_QOS'], s['IC_MAXGPU_PU']), ('normal', 3))
        # Slurm would not list the user's QOS: name none rather than guess one sbatch may refuse.
        self.assertEqual(L.choose(parts, q, set())['IC_QOS'], '')

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
        self.assertEqual((s['IC_PARTITION'], s['IC_QOS'], s['IC_MAXGPU_PU'], s['IC_MAXJOBS_PU'], s['IC_MAXWALL_MIN']),
                         ('gpu', 'gpu', 4, 4, 2880))
        # Without the gpu QOS the user gets normal's one GPU, on the normal partition that allows it.
        s = L.choose(parts, L.qos_table(self.CLUSTER_QOS), self.CLUSTER_ALLOWED - {'gpu'}, allow)
        self.assertEqual((s['IC_PARTITION'], s['IC_QOS'], s['IC_MAXGPU_PU']), ('normal', 'normal', 1))
        # If only `normal` had GPUs, its allow-list alone must keep the 4-GPU `gpu` QOS off it.
        s = L.choose([('normal', 4, 2880)], L.qos_table(self.CLUSTER_QOS), self.CLUSTER_ALLOWED, allow)
        self.assertEqual((s['IC_PARTITION'], s['IC_QOS']), ('normal', 'normal'))

    def test_no_gpu_partition_is_an_error(self):
        with self.assertRaises(SystemExit):
            L.choose(L.gpu_partitions('normal*|(null)|1:00:00|2\n'), {}, set())


LOOP_LINE = 'the same line again, and again\n'


class Fake(http.server.BaseHTTPRequestHandler):
    """Answers like vLLM's /v1/chat/completions, whole or streamed. The reply is chosen by the image's colour: black
    reads, red runs to the cap every time, yellow is a long page that fits only the panel's 8,192, blue loops until it
    is asked with a repetition penalty, green loops whatever it is asked."""
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        Fake.seen.append(b)
        import base64
        img = base64.b64decode(b['messages'][0]['content'][0]['image_url']['url'].split(',', 1)[1])
        from PIL import Image
        r, g, bl = Image.open(io.BytesIO(img)).getpixel((0, 0))[:3]
        head = 'KIND: printed\nTABLE: no\nTEXT:\n'
        if r > 200 and g > 200:  # yellow
            content, finish = (head + 'a long page', 'stop') if b['max_tokens'] >= 8192 else (head + 'a long pa', 'length')
        elif r > 200:            # red: a reply cut off at max_tokens
            content, finish = head + 'half a pa', 'length'
        elif g > 200 or (bl > 200 and 'repetition_penalty' not in b):
            content, finish = head + LOOP_LINE * 2000, 'length'
        else:
            content, finish = head + 'The quick brown fox', 'stop'
        if not b.get('stream'):
            out = json.dumps({'choices': [{'message': {'content': content}, 'finish_reason': finish}],
                              'usage': {'prompt_tokens': 4873, 'completion_tokens': 9}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        pieces = [content[k:k + 8] for k in range(0, len(content), 8)]
        try:
            for k, piece in enumerate(pieces):
                c = {'delta': {'content': piece}, 'finish_reason': finish if k == len(pieces) - 1 else None}
                self.wfile.write(b'data: ' + json.dumps({'choices': [c]}).encode() + b'\n\n')
            self.wfile.write(b'data: ' + json.dumps({'choices': [], 'usage': {'prompt_tokens': 4873,
                             'completion_tokens': len(pieces)}}).encode() + b'\n\ndata: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError):  # the client stopped reading: vLLM aborts the request here
            pass


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
        cmd = [sys.executable, str(HERE / 'cluster_ocr.py'), 'bulk', '--cluster', 'Test Cluster', '--url', self.url, '--model', 'm',
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
        self.assertEqual([(f['image'], f['attempts']) for f in fails], [('c.jpg', 2)])
        side = json.loads((out / '_meta/box1/a.jpg.json').read_text())
        self.assertEqual(side['kind'], 'printed')
        # W41.app-farmshare-import matches by the input's bytes and records the reader.
        self.assertEqual(side['sha256'], hashlib.sha256((self.tmp / 'in/box1/a.jpg').read_bytes()).hexdigest())
        self.assertEqual(side['model'], 'm')
        self.assertEqual(side['cluster'], 'Test Cluster')
        self.assertTrue({'preset', 'vllm_args', 'job'} <= side.keys())
        self.assertEqual(list(out.rglob('*.tmp*')), [])
        n = len(Fake.seen)
        r = self.bulk()                                      # rerun: the escalated page is not asked again
        self.assertEqual(len(Fake.seen) - n, 0, r.stdout)
        self.assertIn('3 already done or escalated, 0 to read', r.stdout)
        r = self.bulk('--retry-escalated')                   # unless asked: read, and retried, once more
        self.assertEqual(len(Fake.seen) - n, 2, r.stdout)

    def test_bulk_resume_refuses_other_cluster_and_missing_provenance(self):
        self.mk('a.jpg', (0, 0, 0))
        self.assertEqual(self.bulk().returncode, 0)
        n = len(Fake.seen)
        r = self.bulk('--cluster', 'Another University')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('incompatible cluster/input/model provenance', r.stderr)
        self.assertEqual(len(Fake.seen), n)
        side = self.tmp / 'out/_meta/a.jpg.json'
        metadata = json.loads(side.read_text()); del metadata['cluster']; side.write_text(json.dumps(metadata))
        r = self.bulk()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(Fake.seen), n)

    def test_bulk_request_streams_at_the_lower_cap(self):
        self.mk('a.jpg', (0, 0, 0))
        self.assertEqual(self.bulk().returncode, 0)
        b = Fake.seen[0]
        self.assertEqual((b['temperature'], b['max_tokens'], b['stream']), (0, F.BULK_MAX_TOKENS, True))
        self.assertNotIn('repetition_penalty', b)
        self.assertEqual((self.tmp / 'out/a.jpg.txt').read_text(), 'The quick brown fox')
        side = json.loads((self.tmp / 'out/_meta/a.jpg.json').read_text())
        self.assertEqual((side['status'], side['completion_tokens']), ('ok', 7))  # usage from the stream's last event
        self.bulk('--no-guard', '--retry-escalated')         # nothing left; --no-guard is the panel's request
        self.mk('b.jpg', (0, 0, 0)); self.bulk('--no-guard')
        self.assertEqual((Fake.seen[-1]['max_tokens'], Fake.seen[-1].get('stream')), (8192, None))

    def test_guard_stops_a_loop_retries_once_and_escalates_what_still_fails(self):
        self.mk('loop-then-reads.jpg', (0, 0, 255)); self.mk('loops.jpg', (0, 255, 0))
        self.mk('long.jpg', (255, 255, 0)); self.mk('capped.jpg', (255, 0, 0)); self.mk('fine.jpg', (0, 0, 0))
        r = self.bulk()
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.tmp / 'out'
        self.assertEqual((out / 'loop-then-reads.jpg.txt').read_text(), 'The quick brown fox')
        self.assertEqual((out / 'long.jpg.txt').read_text(), 'a long page')   # the retry's 8,192 fits it
        side = json.loads((out / '_meta/loop-then-reads.jpg.json').read_text())
        self.assertEqual((side['attempts'], side['first']['status'], side['retry']),
                         (2, 'loop', {'repetition_penalty': 1.05, 'max_tokens': 8192}))
        self.assertEqual(side['first']['loop_period'], len(LOOP_LINE))
        self.assertEqual(json.loads((out / '_meta/long.jpg.json').read_text())['first']['finish'], 'length')
        self.assertNotIn('attempts', json.loads((out / '_meta/fine.jpg.json').read_text()))
        esc = {e['image']: e for e in map(json.loads, (out / 'escalate-0.jsonl').read_text().splitlines())}
        self.assertEqual({k: (e['reason'], e['attempts']) for k, e in esc.items()},
                         {'loops.jpg': ('loop', 2), 'capped.jpg': ('cap', 2)})
        self.assertEqual(esc['loops.jpg']['model'], 'm')
        fails = {f['image']: f for f in map(json.loads, (out / 'failed-0.jsonl').read_text().splitlines())}
        self.assertLess(fails['loops.jpg']['chars'], 3000)   # stopped early, not at the reply's 62,000 characters
        retried = [b for b in Fake.seen if 'repetition_penalty' in b]
        self.assertEqual(len(retried), 4)                    # one retry each for the two loops, the long and the capped
        log = self.tmp / 'shard.out'; log.write_text(r.stdout)
        r = subprocess.run([sys.executable, str(HERE / 'bulk_summary.py'), str(out), '1', 'm', str(log)],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads((out / 'summary.json').read_text())
        self.assertEqual((s['pages'], s['ok'], s['retried'], s['recovered_by_retry'], s['escalated']),
                         (5, 3, 4, 2, {'loop': 1, 'cap': 1}))

    def test_loop_period_finds_loops_and_leaves_repetitive_pages(self):
        self.assertEqual(F.loop_period('KIND: printed\n' + 'abc def\n' * 300), len('abc def '))
        self.assertEqual(F.loop_period('x\n' + 'one line\n  wrapped  differently\n' * 100), len('one line wrapped differently '))
        self.assertIsNone(F.loop_period('abc def\n' * 100))        # 800 characters: under LOOP_MIN_CHARS
        self.assertIsNone(F.loop_period(' '.join(str(k) + '.' for k in range(1000, 1600))))  # counting: the cap's job
        self.assertIsNone(F.loop_period('The quick brown fox jumps. ' * 5 + 'over the lazy dog ' * 30))
        self.assertEqual([F.failure_reason(m) for m in ({'status': 'ok'}, {'status': 'error'}, {'status': 'loop'},
                          {'status': 'unparsed', 'finish': 'length'}, {'status': 'unparsed', 'finish': 'stop'},
                          {'status': 'rejected'}, {'status': 'unreadable'})],
                         [None, None, 'loop', 'cap', 'error', 'error', 'error'])

    def test_guard_check_replays_saved_replies(self):
        d = self.tmp / 'runs/replies'
        F.atomic_write(d / 'p1.json', json.dumps({'reply': {'raw': 'KIND: printed\nTEXT:\nfine'}, 'meta': {'finish': 'stop'}}).encode())
        F.atomic_write(d / 'p2.json', json.dumps({'reply': {'raw': LOOP_LINE * 500}, 'meta': {'finish': 'length'}}).encode())
        F.atomic_write(self.tmp / 'runs/x.raw.json', json.dumps({'choices': [{'message': {'content': 'x ' * 9},
                                                                              'finish_reason': 'length'}]}).encode())
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'guard-check', str(self.tmp / 'runs')],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        j = json.loads(r.stdout)
        self.assertEqual((j['answered'], j['answered_fired'], j['capped'], j['capped_caught']), (1, 0, 2, 1))
        self.assertNotIn('again', r.stdout)                  # names and counts only, never the text
        F.atomic_write(d / 'p3.json', json.dumps({'reply': {'raw': LOOP_LINE * 500}, 'meta': {'finish': 'stop'}}).encode())
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'guard-check', str(self.tmp / 'runs')],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 1)                    # a fire on an answered reply fails the check

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
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'bulk', '--cluster', 'Test Cluster', '--url', f'http://127.0.0.1:{port}',
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
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'bulk', '--cluster', 'Test Cluster', '--url', self.url, '--model', 'm',
                            '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'in' / 'out')],
                           capture_output=True, text=True, timeout=60)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('outside --in', r.stderr)

    @unittest.skipUnless(SCORING, 'needs rapidfuzz, regex + sacrebleu (ocr-panel-requirements.txt)')
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
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'truth', '--url', self.url, '--model', 'm',
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
        r = subprocess.run([sys.executable, str(HERE / 'cluster_ocr.py'), 'truth', '--url', self.url, '--model', 'm',
                            '--pack', str(pack), '--out', str(self.tmp / 'runs'), '--label', 't'],
                           capture_output=True, text=True, timeout=60)
        self.assertIn('differs from the frozen panel input', r.stderr)
        self.assertEqual(Fake.seen, [])


try:
    import newspaper_ocr  # noqa: F401
    import news_layout as NL
    LAYOUT = True
except ImportError:
    LAYOUT = False

# A crop's top-left colour picks GLM-OCR's reply: black and blue are text (green wrapped in a code fence, as GLM-OCR
# sometimes does), red is a request the server fails, so the library retries it and then gives up.
GLM = {(0, 0, 0): 'Column one', (0, 0, 255): 'Column two', (0, 255, 0): '```markdown\nColumn three\n```'}


class FakeGlm(http.server.BaseHTTPRequestHandler):
    seen, delay = [], 0.0

    def log_message(self, *a):
        pass

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        FakeGlm.seen.append(b)
        import base64
        from PIL import Image
        img = Image.open(io.BytesIO(base64.b64decode(b['messages'][0]['content'][0]['image_url']['url'].split(',', 1)[1])))
        text = GLM.get(tuple(255 if v > 127 else 0 for v in img.getpixel((0, 0))[:3]))  # JPEG shifts colours a little
        time.sleep(FakeGlm.delay)
        if text is None:
            self.send_response(500); self.send_header('Content-Length', '0'); self.end_headers(); return
        out = json.dumps({'choices': [{'message': {'content': text}, 'finish_reason': 'stop'}]}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)


class ColumnDetector:
    """Stands in for DocLayout-YOLO: one region per vertical third of the page (none on an all-white page)."""
    def __init__(self, fail=False):
        self.fail = fail

    def detect(self, image):
        from newspaper_ocr.models import BBox, PageLayout, Region
        if self.fail:
            raise RuntimeError('CUDA out of memory')
        w, h = image.size
        rs = []
        if image.getextrema() != ((255, 255),) * 3:
            for i in range(3):
                bb = BBox(i * w // 3 + 5, 5, (i + 1) * w // 3 - 5, h - 5)
                rs.append(Region(bbox=bb, image=image.crop((bb.x0, bb.y0, bb.x1, bb.y1)), label='plain_text',
                                 confidence=0.9))
        return PageLayout(image=image, regions=rs, width=w, height=h)


@unittest.skipUnless(LAYOUT, 'needs newspaper-ocr (setup.sh --layout; offline: pip install --no-deps newspaper-ocr==0.11.0 '
                     'plus pillow numpy httpx opencv-python-headless onnxruntime torch torchvision)')
class Layout(unittest.TestCase):
    """news_layout.py with the real newspaper-ocr Pipeline and GLM-OCR client; only the detector and server are fake."""
    @classmethod
    def setUpClass(cls):
        cls.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGlm)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.url = f'http://127.0.0.1:{cls.httpd.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        FakeGlm.seen.clear(); FakeGlm.delay = 0.0
        self.tmp = Path(tempfile.mkdtemp(prefix='fs-layout-test-'))

    def page(self, colours, path=None):
        from PIL import Image
        im = Image.new('RGB', (900, 1200), 'white')
        for i, c in enumerate(colours):
            im.paste(Image.new('RGB', (300, 1200), c), (i * 300, 0))
        if path:
            path.parent.mkdir(parents=True, exist_ok=True); im.save(path)
        return im

    def reader(self, url=None, **kw):
        return NL.LayoutReader(NL.build_pipeline(url or self.url, 'zai-org/GLM-OCR', detector=ColumnDetector(**kw)))

    def test_regions_read_at_once_in_reading_order_with_the_librarys_request(self):
        FakeGlm.delay = 0.6
        t0 = time.time()
        reply, meta = self.reader().read(self.page([(0, 0, 0), (0, 0, 255), (0, 255, 0)]))
        self.assertLess(time.time() - t0, 1.5)                # three 0.6 s regions together, not one after another
        self.assertEqual(reply['parsed']['text'], 'Column one\n\nColumn two\n\nColumn three')  # fence stripped
        self.assertEqual((meta['status'], meta['regions'], meta['region_status']), ('ok', 3, {'ok': 3}))
        b = FakeGlm.seen[0]
        self.assertEqual((b['model'], b['messages'][0]['content'][1]['text']), ('zai-org/GLM-OCR', 'Text Recognition:'))

    def test_page_status_tells_a_gone_server_from_a_bad_page(self):
        reply, meta = self.reader().read(self.page([(0, 0, 0), (255, 0, 0), (0, 0, 255)]))
        self.assertEqual((meta['status'], meta['region_status']), ('partial', {'ok': 2, 'error': 1}))
        self.assertIsNone(reply['parsed'])                     # not written as done: a rerun reads it again
        self.assertEqual(len(FakeGlm.seen), 2 + 3)             # the failing region was tried three times
        import socket
        with socket.socket() as sk:
            sk.bind(('127.0.0.1', 0)); port = sk.getsockname()[1]
        _, meta = self.reader(f'http://127.0.0.1:{port}').read(self.page([(0, 0, 0)] * 3))
        self.assertEqual(meta['status'], 'error')              # counts toward cluster_ocr's dead-server stop
        _, meta = self.reader().read(self.page([]))
        self.assertEqual((meta['status'], meta['regions']), ('empty', 0))
        reply, meta = self.reader(fail=True).read(self.page([(0, 0, 0)]))
        self.assertEqual((reply, meta['status']), (None, 'failed')); self.assertIn('out of memory', meta['error'])

    def test_bulk_layout_writes_done_pages_and_rereads_only_the_partial_one(self):
        self.page([(0, 0, 0), (0, 0, 255), (0, 255, 0)], self.tmp / 'in/1890/p1.jpg')
        self.page([(0, 0, 0), (255, 0, 0), (0, 0, 255)], self.tmp / 'in/1890/p2.png')
        real = NL.build_pipeline

        def bulk(*extra):
            argv = ['cluster_ocr.py', 'bulk', '--cluster', 'Test Cluster', '--layout', '--url', self.url, '--model', 'zai-org/GLM-OCR',
                    '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'out'), *extra]
            with unittest.mock.patch.object(sys, 'argv', argv), \
                    unittest.mock.patch.object(NL, 'build_pipeline', lambda u, m: real(u, m, detector=ColumnDetector())):
                with self.assertRaises(SystemExit) as e:
                    F.main()
            return e.exception.code

        self.assertEqual(bulk(), 0)
        out = self.tmp / 'out'
        self.assertEqual((out / '1890/p1.jpg.txt').read_text(), 'Column one\n\nColumn two\n\nColumn three')
        self.assertFalse((out / '1890/p2.png.txt').exists())
        fails = [json.loads(x) for x in (out / 'failed-0.jsonl').read_text().splitlines()]
        self.assertEqual([(f['image'], f['status']) for f in fails], [('1890/p2.png', 'partial')])
        side = json.loads((out / '_meta/1890/p1.jpg.json').read_text())
        self.assertEqual((side['kind'], side['regions']), ('newspaper', 3))
        self.assertEqual((side['cluster'], side['model']), ('Test Cluster', 'zai-org/GLM-OCR'))
        self.assertTrue(json.loads((out / 'throughput.jsonl').read_text().splitlines()[-1])['layout'])
        n = len(FakeGlm.seen)
        self.assertEqual(bulk(), 0)
        self.assertEqual(len(FakeGlm.seen), n)               # partial page is held for explicit escalation retry
        self.assertEqual(bulk('--retry-escalated'), 0)
        self.assertEqual(len(FakeGlm.seen) - n, 2 + 3)          # only p2's three regions (one tried three times)


class Estimate(unittest.TestCase):
    def test_table_has_every_candidate_and_ranges_are_ordered(self):
        t = E.table()
        for name in E.CANDIDATES:
            self.assertIn(name, t)
        for c in E.CANDIDATES.values():
            fast = E.seconds_per_page(c, E.PHOTO, 0.40, 0.80, True)
            slow = E.seconds_per_page(c, E.PHOTO, 0.20, 0.60, False)
            self.assertLess(fast, slow)


class Profiles(unittest.TestCase):
    def test_profiles_keep_identity_scheduler_runtime_and_paths_together(self):
        farm = C.load('farmshare'); other = C.load('example-university')
        self.assertEqual((farm['CLUSTER_NAME'], farm['IC_GPU_MEMORY_GB']), ('FarmShare', 48))
        self.assertEqual((other['IC_ACCOUNT'], other['IC_GPU_GRES_TYPE'], other['IC_MAXWALL_MIN']),
                         ('humanities', 'h100', 720))
        self.assertEqual((other['IC_GPU_MEMORY_GB'], other['IC_CUDA_MODE']), (80, 'modules'))
        self.assertIn('cuda/13.0', other['IC_MODULES'])
        self.assertTrue(Path(other['IC_SCRATCH']).is_absolute())
        self.assertTrue(Path(other['IC_STORAGE']).is_absolute())

    def test_rejects_other_schedulers_and_unsafe_scheduler_identifiers(self):
        original = json.loads((HERE / 'profiles/example-university.json').read_text())
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'profile.json'
            for field, value in [('scheduler', 'pbs'), ('name', ''), ('name', 'Cluster\nforged')]:
                data = dict(original); data[field] = value; path.write_text(json.dumps(data))
                with self.assertRaises(ValueError): C.load(path)
            for modules in ('cuda/13.0', ['--force'], ['cuda/13.0;echo']):
                data = json.loads(json.dumps(original)); data['runtime']['modules'] = modules
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError): C.load(path)
            original['slurm']['account'] = 'a; touch /tmp/should-not-exist'
            path.write_text(json.dumps(original))
            with self.assertRaises(ValueError): C.load(path)

    def test_live_caps_constrain_the_profile_without_switching_partition(self):
        profile = C.load('farmshare')
        result = L.constrain(profile, [('gpu', 2, 480)], L.qos_table(Limits.CLUSTER_QOS),
                             Limits.CLUSTER_ALLOWED, {'gpu': None})
        self.assertEqual(result['IC_GPUS_PER_NODE'], 2)
        self.assertEqual(result['IC_MAXWALL_MIN'], 480)
        self.assertEqual(result['IC_MAXGPU_PU'], 4)
        with self.assertRaises(ValueError):
            L.constrain(profile, [('normal', 4, 480)], {}, set(), {})
        with self.assertRaises(ValueError):
            L.constrain(profile, [('gpu', 4, 480)], L.qos_table(Limits.CLUSTER_QOS), {'normal'}, {})

    def test_dry_run_both_profiles_without_setup_or_external_commands(self):
        with tempfile.TemporaryDirectory(prefix='institutional compute ') as d:
            kit = Path(d) / 'kit with spaces'; shutil.copytree(HERE, kit)
            # Deliberately no setup files, GPU, modules or sbatch. A dry-run must remain purely local.
            for name in ('compute.env', 'limits.env'):
                path = kit / name
                if path.exists(): path.unlink()
            before = sorted(str(p.relative_to(kit)) for p in kit.rglob('*'))
            for profile in ('farmshare', 'example-university'):
                result = subprocess.run(['bash', str(kit / 'submit.sh'), '--profile', profile, 'news', 'auto',
                                         '--hours', '30', '--dry-run'], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('sbatch', result.stdout)
                self.assertIn('Qwen/Qwen3.6-27B-FP8', result.stdout)
                self.assertIn('48 GB/card' if profile == 'farmshare' else '80 GB/card', result.stdout)
                if profile == 'example-university':
                    self.assertIn('--account=humanities', result.stdout)
                    self.assertIn('--gres=gpu:h100:1', result.stdout)
                    self.assertIn('--time=720', result.stdout)
                    self.assertIn('--qos=research', result.stdout)
            after = sorted(str(p.relative_to(kit)) for p in kit.rglob('*') if '__pycache__' not in p.parts)
            self.assertEqual(after, [p for p in before if '__pycache__' not in Path(p).parts])
            # Fresh 24 GB profile selects the small default. Oversized explicit presets/shards refuse.
            data = json.loads((kit / 'profiles/example-university.json').read_text())
            data['gpu']['memory_gb'] = 24; data['gpu']['per_node'] = 1
            (kit / 'profiles/small.json').write_text(json.dumps(data))
            result = subprocess.run(['bash', str(kit / 'submit.sh'), '--profile', 'small', 'news', 'auto', '--dry-run'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Qwen/Qwen3-VL-8B-Instruct', result.stdout)
            result = subprocess.run(['bash', str(kit / 'submit.sh'), '--profile', 'small', 'news',
                                     'qwen3.6-27b', '--dry-run'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('needs 2 GPUs', result.stderr)

    def test_real_submission_matches_dry_run_and_requires_unchanged_setup_profile(self):
        with tempfile.TemporaryDirectory(prefix='cluster submit ') as d:
            kit = Path(d) / 'kit'; shutil.copytree(HERE, kit)
            profile = kit / 'profiles/example-university.json'
            data = json.loads(profile.read_text())
            data['paths'] = {'scratch': str(Path(d) / 'scratch with spaces'), 'storage': str(Path(d) / 'storage')}
            profile.write_text(json.dumps(data))
            config = C.load(profile)
            config.update({'IC_PY': sys.executable, 'IC_VLLM': '/not-used-in-submit'})
            (kit / 'compute.env').write_text(C.shell(config))
            caps = {k: config[k] for k in ('IC_GPUS_PER_NODE', 'IC_MAXGPU_PU', 'IC_MAXJOBS_PU',
                                         'IC_MAXSUBMIT_PU', 'IC_MAXWALL_MIN')}
            (kit / 'limits.env').write_text(C.shell(caps))
            fake_bin = Path(d) / 'bin'; fake_bin.mkdir()
            executable = fake_bin / 'sbatch'
            executable.write_text("#!/bin/bash\nprintf '%s\\0' \"$@\" > \"$IC_CAPTURE\"\n")
            executable.chmod(0o755)
            capture = Path(d) / 'capture'
            env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'], IC_CAPTURE=str(capture))
            inp = Path(d) / 'input'; inp.mkdir()
            out = Path(d) / 'new output'
            cmd = ['bash', str(kit / 'submit.sh'), '--profile', str(profile), 'bulk', 'auto',
                   '--in', str(inp), '--out', str(out), '--shards', '1']
            dry = subprocess.run(cmd + ['--dry-run'], env=env, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertFalse(out.exists()); self.assertFalse(capture.exists())
            real = subprocess.run(cmd, env=env, capture_output=True, text=True)
            self.assertEqual(real.returncode, 0, real.stderr)
            argv = capture.read_bytes().decode().split('\0')[:-1]
            self.assertEqual(argv, shlex.split(dry.stdout.splitlines()[-1])[1:])
            overlap_cmd = cmd.copy(); overlap_cmd[overlap_cmd.index('--out') + 1] = str(inp / 'forbidden output')
            overlap = subprocess.run(overlap_cmd, env=env, capture_output=True, text=True)
            self.assertNotEqual(overlap.returncode, 0)
            self.assertIn('outside --in', overlap.stderr)
            self.assertFalse((inp / 'forbidden output').exists())
            data['name'] = 'Renamed after submission'; profile.write_text(json.dumps(data))
            changed = subprocess.run(cmd, env=env, capture_output=True, text=True)
            self.assertNotEqual(changed.returncode, 0)
            self.assertIn('profile revision', changed.stderr)

    def test_layout_setup_loads_profile_modules_before_python(self):
        with tempfile.TemporaryDirectory(prefix='cluster layout setup ') as d:
            kit = Path(d) / 'kit'; shutil.copytree(HERE, kit)
            root = Path(d) / 'runtime'; root.mkdir()
            fake_bin = Path(d) / 'bin'; fake_bin.mkdir()
            module = fake_bin / 'module'
            module.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$IC_MODULE_LOG"\n')
            module.chmod(0o755)
            python = fake_bin / 'cluster-python'
            python.write_text('#!/bin/bash\n[ -s "$IC_MODULE_LOG" ] || exit 91\n'
                              'if [ "$*" = "-m pip freeze" ]; then echo "vllm==0.31.0"; fi\n')
            python.chmod(0o755)
            (kit / 'compute.env').write_text(C.shell({'IC_ROOT': root, 'IC_PY': python,
                                                     'IC_MODULES': 'python/3.12 cuda/13.0'}))
            env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'],
                       IC_MODULE_LOG=str(Path(d) / 'modules'))
            result = subprocess.run(['bash', str(kit / 'setup.sh'), '--layout'], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(env['IC_MODULE_LOG']).read_text().splitlines(),
                             ['load python/3.12', 'load cuda/13.0'])

    def test_memory_budgets_select_power_of_two_tensor_parallel_sizes(self):
        result = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; '
            'for m in 24 48 80; do IC_GPU_MEMORY_GB=$m; preset auto; echo "$m|$IC_MODEL|$IC_GPUS"; '
            'preset qwen3.5-122b-a10b; echo "$m|$IC_GPUS"; done'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            '24|Qwen/Qwen3-VL-8B-Instruct|1', '24|8',
            '48|Qwen/Qwen3.6-27B-FP8|1', '48|4',
            '80|Qwen/Qwen3.6-27B-FP8|1', '80|4'])


class Shell(unittest.TestCase):
    def test_scripts_parse_and_presets_resolve(self):
        for f in ('setup.sh', 'download.sh', 'job.sbatch', 'submit.sh', 'models.sh', 'runtime.sh', 'scheduler.sh',
                  'setup-layout.sh', 'setup-train.sh', 'train.sbatch', 'wave.sbatch'):
            self.assertEqual(subprocess.run(['bash', '-n', str(HERE / f)]).returncode, 0, f)
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; preset qwen3.6-27b-dyn; echo "$IC_VLLM_ARGS"; '
                              'preset qwen3.6-27b; echo "$IC_MODEL|$IC_VLLM_ARGS"; preset nope; '
                              'IC_MAX_LEN=12288 preset qwen3.6-35b-a3b'],
                             capture_output=True, text=True)
        first, second = out.stdout.splitlines()[:2]
        self.assertIn('--quantization fp8', first)
        self.assertTrue(second.startswith('Qwen/Qwen3.6-27B-FP8|'))
        self.assertNotIn('--quantization', second)          # the fallback's flag does not leak into the next preset
        self.assertIn('{"image":1}', second)
        self.assertIn('unknown preset', out.stderr)
        self.assertIn('below prompt + max_tokens', out.stderr)
        self.assertIn('--max-model-len 16384', second)
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; IC_MAX_LEN=32768 preset glm-ocr; '
                              'echo "$IC_LAYOUT|$IC_DET_FILE|$IC_VLLM_ARGS"; preset qwen3.6-27b; echo "$IC_LAYOUT|$IC_DET_REPO"'],
                             capture_output=True, text=True)
        glm, after = out.stdout.splitlines()
        self.assertTrue(glm.startswith('1|doclayout_yolo_docstructbench_imgsz1280_2501.pt|'), glm)
        for flag in ('--max-model-len 16384', '--kv-cache-dtype auto', '--gpu-memory-utilization 0.80',
                     '--speculative-config {"method":"mtp","num_speculative_tokens":1}'):
            self.assertIn(flag, glm)
        self.assertEqual(after, '0|')                          # the layout route does not leak into the next preset


def seg_answer(nums, conf=0.9):
    return json.dumps({'pages': [{'page': n, 'kind': 'document'} for n in nums],
                       'boundaries': [{'between': [n, n + 1], 'decision': 'continue', 'confidence': conf, 'cue': 'same'}
                                      for n in nums[:-1]]})


class FakeSeg(http.server.BaseHTTPRequestHandler):
    """vLLM's /v1/chat/completions for segmentation windows. Window 1-3's first answer is unparseable, window 4-6
    never parses, and a window starting at page 7 is refused (400), so the retry, failure and stop paths all run."""
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        FakeSeg.seen.append(b)
        prompt = b['messages'][0]['content'][-1]['text']
        nums = json.loads(prompt)
        if nums[0] == 7:
            self.send_response(400); self.send_header('Content-Length', '4'); self.end_headers(); self.wfile.write(b'nope')
            return
        bad = nums[0] == 4 or (nums[0] == 1 and b['max_tokens'] == 1500)
        out = json.dumps({'choices': [{'message': {'content': '<think>x</think>not json' if bad else seg_answer(nums)},
                                       'finish_reason': 'stop'}],
                          'usage': {'prompt_tokens': 5000, 'completion_tokens': 200}}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)


@unittest.skipUnless(NUMPY, 'cluster_seg imports the bench (numpy)')
class Seg(unittest.TestCase):
    """cluster_seg.py run on a synthetic pack (the prompt is the window's page list, so the fake can answer it)."""

    @classmethod
    def setUpClass(cls):
        cls.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeSeg)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.url = f'http://127.0.0.1:{cls.httpd.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        FakeSeg.seen.clear()
        self.tmp = Path(tempfile.mkdtemp(prefix='fs-seg-test-'))

    def pack(self, windows, model='Qwen/Qwen3.5-27B-FP8'):
        from PIL import Image
        pack = self.tmp / 'pack'
        pages = sorted({n for w in windows for n in w})
        for n in pages:
            (pack / 'images' / 'Deaver').mkdir(parents=True, exist_ok=True)
            Image.new('RGB', (64, 48), (n, 0, 0)).save(pack / 'images' / 'Deaver' / f'{n}.jpg', quality=90)
        (pack / 'windows.jsonl').write_text(''.join(json.dumps({'box': 'Deaver', 'window': w, 'cache_key': f'k{w[0]}',
                                                                'prompt': json.dumps(w)}) + '\n' for w in windows))
        (pack / 'pack.json').write_text(json.dumps({'key': 'fs-qwen3.5-27b', 'model': model, 'box': 'Deaver',
                                                    'pages': len(pages), 'windows': len(windows)}))
        return pack

    def run_seg(self, pack, model='Qwen/Qwen3.5-27B-FP8'):
        cmd = [sys.executable, str(HERE / 'cluster_seg.py'), 'run', '--pack', str(pack), '--out', str(self.tmp / 'out'),
               '--label', 'L', '--url', self.url, '--model', model, '--concurrency', '2']
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120)

    def answers(self):
        return {r['cache_key']: r for r in map(json.loads, (self.tmp / 'out/L/answers.jsonl').read_text().splitlines())}

    def test_request_is_the_seg_large_request_without_openrouter_fields(self):
        out = self.run_seg(self.pack([[10, 11, 12]]))
        self.assertEqual(out.returncode, 0, out.stderr)
        b = FakeSeg.seen[0]
        self.assertEqual(b['model'], 'Qwen/Qwen3.5-27B-FP8')
        self.assertEqual((b['temperature'], b['max_tokens']), (0, 1500))
        self.assertEqual(b['chat_template_kwargs'], {'enable_thinking': False})
        for k in ('provider', 'reasoning', 'usage'):
            self.assertNotIn(k, b)
        parts = b['messages'][0]['content']
        self.assertEqual([p['type'] for p in parts], ['image_url'] * 3 + ['text'])
        import base64
        sent = [base64.b64decode(p['image_url']['url'].split(',', 1)[1]) for p in parts[:3]]
        self.assertEqual(sent, [(self.tmp / f'pack/images/Deaver/{n}.jpg').read_bytes() for n in (10, 11, 12)])
        r = self.answers()['k10']
        self.assertEqual((r['status'], r['attempt'], r['prompt_tokens']), ('ok', 0, 5000))
        s = json.loads(next((self.tmp / 'out/L').glob('summary-*.json')).read_text())
        self.assertEqual((s['ok'], s['failed'], s['left'], s['rejected']), (1, 0, 0, []))
        self.assertGreater(s['pages_per_hour_per_gpu'], 0)

    def test_retry_at_twice_the_limit_then_failed_then_resume(self):
        pack = self.pack([[1, 2, 3], [4, 5, 6], [10, 11]])
        out = self.run_seg(pack)
        self.assertEqual(out.returncode, 0, out.stderr)
        a = self.answers()
        self.assertEqual((a['k1']['status'], a['k1']['attempt']), ('ok', 1))      # the retry at 3,000 tokens parsed
        self.assertEqual(a['k4']['status'], 'failed')                            # neither parsed: votes 0.5 later
        self.assertNotIn('<think>', a['k4']['result'])
        self.assertEqual(sorted(b['max_tokens'] for b in FakeSeg.seen if json.loads(b['messages'][0]['content'][-1]['text'])[0] == 4),
                         [1500, 3000])
        FakeSeg.seen.clear()
        out = self.run_seg(pack)                                                 # everything answered: nothing sent
        self.assertEqual((out.returncode, FakeSeg.seen), (0, []))

    def test_refused_request_stops_the_run_and_is_not_an_answer(self):
        out = self.run_seg(self.pack([[7, 8, 9]]))
        self.assertEqual(out.returncode, 1, out.stderr)
        self.assertFalse((self.tmp / 'out/L/answers.jsonl').exists())

    def test_test_boxes_need_the_committed_teacher_freeze(self):
        import cluster_seg as S
        R = S.R
        args = lambda **k: type('A', (), {'out': str(self.tmp / 'p'), 'box': None, 'final': False, **k})  # noqa: E731
        with self.assertRaisesRegex(SystemExit, 'not development'):
            S.cmd_pack(args(box=['Stanton']))
        saved, saved_students = R.TEACHER_FROZEN, R.STUDENTS_FROZEN
        try:
            R.STUDENTS_FROZEN = saved_students.with_name('seg-students-absent.json')
            R.TEACHER_FROZEN = saved.with_name('seg-teacher-absent.json')
            with self.assertRaisesRegex(SystemExit, 'no freeze'):
                S.cmd_pack(args(final=True))
            R.TEACHER_FROZEN = saved.with_name(f'seg-teacher-untracked-{os.getpid()}.json')
            R.TEACHER_FROZEN.write_text(json.dumps({'teacher': S.KEY}))
            with self.assertRaisesRegex(SystemExit, 'not committed'):
                S.cmd_pack(args(final=True))
        finally:
            if R.TEACHER_FROZEN != saved:
                R.TEACHER_FROZEN.unlink(missing_ok=True)
            R.TEACHER_FROZEN, R.STUDENTS_FROZEN = saved, saved_students
        self.assertFalse((self.tmp / 'p').exists())          # refused before a single image was written

    def test_pack_for_another_model_is_refused(self):
        out = self.run_seg(self.pack([[10, 11]], model='Qwen/Qwen3.6-27B-FP8'))
        self.assertNotEqual(out.returncode, 0)
        self.assertIn('the pack is for', out.stderr)
        self.assertEqual(FakeSeg.seen, [])

    def test_seg_preset_takes_seven_images(self):
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; IC_MM_IMAGES=7 preset qwen3.5-27b; '
                              'echo "$IC_VLLM_ARGS"; unset IC_MM_IMAGES; preset qwen3.5-27b; echo "$IC_VLLM_ARGS"'],
                             capture_output=True, text=True)
        seg, ocr = out.stdout.splitlines()
        self.assertIn('--limit-mm-per-prompt {"image":7}', seg)
        self.assertIn('--limit-mm-per-prompt {"image":1}', ocr)



class NewsLayout(unittest.TestCase):
    """cluster_news_layout.py with a stand-in pipeline: one file per page where NewsBench's score.py looks, failures kept."""

    def test_writes_each_page_and_records_failures(self):
        import cluster_news_layout as N

        class Pipe:
            def ocr(self, path):
                if 'bad' in path:
                    raise RuntimeError('detector fell over')
                if 'blank' in path:
                    return '  \n'
                return 'text of ' + Path(path).stem

        with tempfile.TemporaryDirectory() as d:
            nb = Path(d) / 'newsbench'
            (nb / 'images').mkdir(parents=True)
            for stem in ('a', 'b', 'bad', 'blank'):
                (nb / 'images' / f'{stem}.jpg').write_bytes(b'x')
            orig = N.build_pipeline
            N.build_pipeline = lambda *a: Pipe()
            try:
                args = type('A', (), {'newsbench': str(nb), 'out': str(Path(d) / 'runs'), 'label': 'L', 'reader': 'openai',
                                      'base_url': 'http://x/v1', 'model': 'M', 'workers': 2})()
                s = N.run_detector(args, 'paddlex', sorted((nb / 'images').glob('*.jpg')))
            finally:
                N.build_pipeline = orig
            self.assertEqual((s['pages'], s['ok'], s['empty']), (4, 2, 1))
            txt = nb / 'ocr-results' / 'L-paddlex'
            self.assertEqual((txt / 'a.txt').read_text(), 'text of a')
            self.assertEqual((txt / 'bad.txt').read_text(), '')          # scored as an empty reading
            timing = json.loads((Path(d) / 'runs' / 'L-paddlex' / 'timing.json').read_text())
            status = {p['page']: p['status'] for p in timing['per_page']}
            self.assertTrue(status['bad'].startswith('error: RuntimeError'))
            self.assertEqual(status['blank'], 'empty')
            self.assertNotIn('text of', json.dumps(timing))               # no transcript text in what comes back


FAKE_SLURM = r"""#!/bin/bash
# A pretend Slurm for the wave tests: sbatch records the job (argv, cwd, exported env) and queues it; the test runs it.
d="$FAKE_SLURM"; tool="$(basename "$0")"
case "$tool" in
  sbatch)
    script="${@: -1}"
    if [ -n "${FAKE_FAIL:-}" ] && [ "$(basename "$script")" = "$FAKE_FAIL" ]; then echo 'sbatch: error: invalid partition' >&2; exit 1; fi
    n=$(cat "$d/next"); echo $((n + 1)) > "$d/next"
    printf '%s\0' "$@" > "$d/$n.argv"; pwd > "$d/$n.cwd"; env -0 > "$d/$n.env"; echo "$n" >> "$d/queue"
    echo "$n" ;;
  squeue)
    ids=""; while [ $# -gt 0 ]; do [ "$1" = -j ] && ids="$2"; shift; done
    if [ -n "$ids" ]; then tr ',' '\n' <<<"$ids" | grep -Fx -f "$d/queue" || true; else cat "$d/queue"; fi ;;
  scontrol|scancel) echo "$*" >> "$d/$tool" ;;
  nvidia-smi) echo 'name, memory.total [MiB], driver_version'; echo 'Fake GPU, 81920 MiB, 0' ;;
  nvcc) echo 'Cuda compilation tools, release 13.0' ;;
esac
"""

FAKE_VLLM = r"""#!/usr/bin/env python3
# `vllm serve MODEL --host H --port P ...`: the tests' Fake reader, with vLLM's /health.
import http.server, sys
sys.path.insert(0, sys.argv[-1])
import test_institutional_compute as T
class H(T.Fake):
    def do_GET(self):
        self.send_response(200 if self.path == '/health' else 404); self.end_headers()
port = int(sys.argv[sys.argv.index('--port') + 1])
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
"""


class Wave(unittest.TestCase):
    """wave.py against a pretend Slurm: the chain's submission, and its jobs run for real against the fake reader."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='ic wave '))
        bench = self.tmp / 'segbench'; bench.mkdir()
        for f in HERE.parent.glob('*.py'):   # cluster_ocr imports the panel from the folder above
            (bench / f.name).symlink_to(f)
        self.kit = bench / 'institutional-compute'
        shutil.copytree(HERE, self.kit, ignore=shutil.ignore_patterns('__pycache__', '*.env'))
        self.profile = self.kit / 'profiles/test.json'
        data = json.loads((self.kit / 'profiles/example-university.json').read_text())
        data['paths'] = {'scratch': str(self.tmp / 'scratch'), 'storage': str(self.tmp / 'storage')}
        data['runtime'] = {'modules': [], 'cuda_mode': 'modules', 'cuda_home': ''}
        data['slurm'].update(max_submitted_jobs=12, max_running_jobs=4, max_gpus_per_user=4)
        self.profile.write_text(json.dumps(data))
        cfg = C.load(self.profile)
        self.root = Path(cfg['IC_ROOT'])
        self.slurm = self.tmp / 'slurm'; self.slurm.mkdir(); (self.slurm / 'next').write_text('7001')
        (self.slurm / 'queue').write_text('')
        fake_bin = self.tmp / 'bin'; fake_bin.mkdir()
        (fake_bin / 'fake-slurm').write_text(FAKE_SLURM)
        for tool in ('sbatch', 'squeue', 'scontrol', 'scancel', 'nvidia-smi', 'nvcc'):
            (fake_bin / tool).symlink_to(fake_bin / 'fake-slurm')
        (fake_bin / 'fake-slurm').chmod(0o755)
        vllm = fake_bin / 'vllm'; vllm.write_text(FAKE_VLLM.replace('sys.argv[-1]', repr(str(HERE)))); vllm.chmod(0o755)
        cfg.update({'IC_PY': sys.executable, 'IC_VLLM': str(vllm), 'HF_HOME': str(self.tmp / 'hf')})
        (self.kit / 'compute.env').write_text(C.shell(cfg))
        (self.kit / 'limits.env').write_text(C.shell({k: cfg[k] for k in (
            'IC_GPUS_PER_NODE', 'IC_MAXGPU_PU', 'IC_MAXJOBS_PU', 'IC_MAXSUBMIT_PU', 'IC_MAXWALL_MIN')}))
        self.env = dict(os.environ, PATH=f'{fake_bin}{os.pathsep}{os.environ["PATH"]}', FAKE_SLURM=str(self.slurm),
                        USER='tester')
        for k in [k for k in self.env if k.startswith(('IC_', 'SLURM_'))]:
            del self.env[k]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def images(self, folder, colours):
        from PIL import Image
        for name, colour in colours.items():
            (folder / name).parent.mkdir(parents=True, exist_ok=True)
            Image.new('RGB', (600, 800), colour).save(folder / name)

    def wave(self, jobs):
        path = self.tmp / 'wave.json'; path.write_text(json.dumps({'wave': 'w1', 'jobs': jobs})); return path

    def submit(self, wave, *extra, env=None):
        return subprocess.run([sys.executable, str(self.kit / 'wave.py'), 'submit', str(wave), '--profile',
                               str(self.profile), *extra], env=env or self.env, capture_output=True, text=True, timeout=60)

    def job(self, n):
        argv = (self.slurm / f'{n}.argv').read_bytes().decode().split('\0')[:-1]
        env = dict(x.split('=', 1) for x in (self.slurm / f'{n}.env').read_bytes().decode().split('\0') if '=' in x)
        return argv, env

    def run_job(self, n, task=None, **override):
        """What Slurm would do with job n: run its script with the environment sbatch exported."""
        argv, env = self.job(n)
        env.update(SLURM_JOB_ID=str(n), **override)
        if task is not None:
            env['SLURM_ARRAY_TASK_ID'] = str(task)
        queue = [x for x in (self.slurm / 'queue').read_text().split() if x != str(n)]
        (self.slurm / 'queue').write_text(''.join(x + '\n' for x in queue))
        cwd = (self.slurm / f'{n}.cwd').read_text().strip()
        return subprocess.run(['bash', str(Path(cwd) / argv[-1])], cwd=cwd, env=env, capture_output=True, text=True,
                              timeout=120)

    def test_example_wave_is_valid_and_dry_run_needs_nothing(self):
        import wave as W
        data = W.load_wave(HERE / 'waves/example.json', '/scratch/x/institutional-compute')
        self.assertEqual(data['jobs'][0]['pack'], '/scratch/x/ic-truthpack')
        for bad in ({'id': 'a', 'mode': 'news-layout', 'preset': 'auto'},
                    {'id': 'a', 'mode': 'bulk', 'preset': 'auto', 'in': '/x', 'env': {'IC_LIMIT': '9'}},
                    {'id': 'a', 'mode': 'bulk', 'preset': 'auto', 'in': 'relative'},
                    {'id': 'a', 'mode': 'truth', 'preset': 'auto'},
                    {'id': 'a b', 'mode': 'truth', 'preset': 'auto', 'pack': '/x'}):
            with self.assertRaises(ValueError, msg=bad):
                W.load_wave(self.wave([bad]), '/r')
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        for f in ('compute.env', 'limits.env'):
            (self.kit / f).unlink()
        wave = self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp), 'shards': 2},
                          {'id': 'later', 'mode': 'bulk', 'preset': 'auto', 'in': str(self.tmp / 'not yet')}])
        r = self.submit(wave, '--dry-run')
        self.assertEqual(r.returncode, 3, r.stderr)          # one job not ready
        self.assertIn('later: not ready', r.stdout)
        lines = {l.split(':')[0].strip(): l for l in r.stdout.splitlines() if l.startswith('  ')}
        self.assertIn('--hold', lines['pilot']); self.assertIn('--array=0-0', lines['pilot'])
        self.assertIn(r'--dependency=afterok:\<pilot\>', lines['full']); self.assertIn('--array=0-1', lines['full'])
        self.assertIn('--partition=general', lines['score']); self.assertNotIn('--gres', lines['score'])
        self.assertEqual(sorted(self.slurm.iterdir()), [self.slurm / 'next', self.slurm / 'queue'])
        self.assertFalse(self.root.exists())

    def test_chain_runs_pilot_then_full_with_a_requeued_shard_then_score(self):
        inp = self.tmp / 'pages'
        self.images(inp, {f'box/p{k}.png': (0, 0, 0) for k in range(6)})
        wave = self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp), 'shards': 2,
                           'score': ['python3', '-c', 'import json, pathlib, sys; full, res = map(pathlib.Path, sys.argv[1:]); '
                                     '(res / "count.json").write_text(json.dumps({"txt": len(list(full.rglob("*.txt"))), '
                                     '"dir": sys.argv[1]}))', '{full}', '{results}']}])
        r = self.submit(wave)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        pilot, full, score = 7001, 7002, 7003
        self.assertIn('--hold', self.job(pilot)[0])
        self.assertIn(f'--dependency=afterok:{pilot}', self.job(full)[0])
        self.assertIn(f'--dependency=afterany:{full}', self.job(score)[0])
        self.assertEqual((self.slurm / 'scontrol').read_text(), f'release {pilot}\n')
        self.assertEqual(self.job(pilot)[1]['IC_LIMIT'], '3'); self.assertEqual(self.job(full)[1]['IC_LIMIT'], '')
        again = self.submit(wave)                             # a second submit never doubles a chain
        self.assertIn('already submitted', again.stdout); self.assertFalse((self.slurm / f'{score + 1}.argv').exists())

        jd = self.root / 'waves/w1/b'
        r = self.run_job(pilot, 0)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('pilot gate: 3 of 3 items read', r.stdout)
        self.assertEqual(len(list((jd / 'bulk/pilot').rglob('*.txt'))), 3)
        self.assertTrue((jd / 'state/pilot-0').read_text().startswith('rc=0'))
        self.assertEqual(self.run_job(full, 0).returncode, 0)
        # Shard 1 runs out of time: it queues itself again, and the score job waits for the new job.
        r = self.run_job(full, 1, IC_BULK_ARGS='--deadline 1')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        requeued = score + 1
        self.assertIn(f'requeued {requeued}', (jd / 'state/full-1').read_text())
        r = self.run_job(score)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rescore = requeued + 1
        self.assertIn(f'--dependency=afterany:{requeued}', self.job(rescore)[0])
        self.assertIn('--partition=general', self.job(rescore)[0])
        self.assertFalse((self.root / 'waves/w1/results/b/status.json').exists())
        self.assertEqual(self.run_job(requeued, 1, IC_BULK_ARGS='').returncode, 0)
        r = self.run_job(rescore)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        res = self.root / 'waves/w1/results/b'
        status = json.loads((res / 'status.json').read_text())
        self.assertEqual(status['status'], 'ok', status)
        self.assertEqual(len(list((jd / 'bulk/full').rglob('*.txt'))), 6)
        count = json.loads((res / 'count.json').read_text())   # the job's own score command ran, on the full run
        self.assertEqual((count['txt'], count['dir']), (6, str(jd / 'bulk/full')))
        self.assertTrue((res / 'full/throughput.jsonl').exists())
        self.assertEqual([p for p in res.rglob('*') if p.suffix == '.txt' or '_meta' in p.parts], [])
        st = subprocess.run([sys.executable, str(self.kit / 'wave.py'), 'status', str(wave), '--profile', str(self.profile)],
                            env=self.env, capture_output=True, text=True)
        self.assertIn('b: ok', st.stdout)

    def test_failed_pilot_cancels_the_chain_and_reports(self):
        inp = self.tmp / 'pages'
        self.images(inp, {'a.png': (0, 0, 0), 'b.png': (255, 0, 0), 'c.png': (0, 0, 0), 'd.png': (0, 0, 0)})
        r = self.submit(self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp)}]))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        r = self.run_job(7001, 0)                             # b.png is cut off at max_tokens: not read
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.slurm / 'scancel').read_text(), '7002 7003\n')
        status = json.loads((self.root / 'waves/w1/results/b/status.json').read_text())
        self.assertEqual(status['status'], 'pilot-failed')
        self.assertEqual(status['reason'], 'pilot gate: 2 of 3 items read; pilot job exit 1')
        self.assertTrue((self.root / 'waves/w1/results/b/pilot/failed-0.jsonl').exists())

    def test_pilot_whose_server_dies_at_start_up_still_cancels_and_reports(self):
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        self.submit(self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp)}]))
        r = self.run_job(7001, 0, IC_VLLM='/usr/bin/false')   # vLLM gone before the trap's kill
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.slurm / 'scancel').read_text(), '7002 7003\n')
        status = json.loads((self.root / 'waves/w1/results/b/status.json').read_text())
        self.assertEqual(status['status'], 'pilot-failed')
        self.assertTrue((self.root / 'waves/w1/b/state/pilot-0').read_text().startswith('rc=1'))

    def test_leftover_job_folder_is_never_reused(self):
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        wave = self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp)}])
        (self.root / 'waves/w1/b/state').mkdir(parents=True)
        (self.root / 'waves/w1/b/state/full-0').write_text('rc=0 job=1 \n')
        r = self.submit(wave)
        self.assertEqual(r.returncode, 3)
        self.assertIn('left from an earlier chain', r.stdout)
        self.assertFalse((self.slurm / '7001.argv').exists())

    def test_score_rounds_follow_the_jobs_own_chain_limit(self):
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        self.submit(self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp),
                                'env': {'IC_CHAIN_MAX': '60'}}]))
        self.assertEqual(self.job(7003)[1]['IC_CHAIN_MAX'], '60')
        jd = self.root / 'waves/w1/b'
        (jd / 'state/full-0').write_text('rc=0 job=7002 requeued 7999\n')
        (self.slurm / 'queue').write_text('7999\n')
        r = self.run_job(7003, IC_SCORE_ROUND='40')          # beyond the default 31 rounds, inside 61
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('--dependency=afterany:7999', self.job(7004)[0])
        (self.slurm / 'queue').write_text('')                 # gone without reporting
        self.assertNotEqual(self.run_job(7004).returncode, 0)
        status = json.loads((self.root / 'waves/w1/results/b/status.json').read_text())
        self.assertIn('left the queue without reporting', status['reason'])

    def test_full_run_failure_is_reported_by_the_score_job(self):
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        self.submit(self.wave([{'id': 'b', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp)}]))
        jd = self.root / 'waves/w1/b'
        (jd / 'state/full-0').write_text('rc=1 job=7002 \n')    # the full run crashed
        self.assertNotEqual(self.run_job(7003).returncode, 0)
        status = json.loads((self.root / 'waves/w1/results/b/status.json').read_text())
        self.assertEqual((status['status'], status['reason']), ('failed', 'shard 0: exit 1'))

    def test_refused_score_job_leaves_nothing_queued_and_limits_hold_back_jobs(self):
        inp = self.tmp / 'pages'; self.images(inp, {'a.png': (0, 0, 0)})
        wave = self.wave([{'id': 'x', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp)}])
        r = self.submit(wave, env=dict(self.env, FAKE_FAIL='wave.sbatch'))
        self.assertEqual(r.returncode, 3)
        self.assertIn('invalid partition', r.stderr)
        self.assertEqual((self.slurm / 'scancel').read_text(), '7001 7002\n')
        self.assertFalse((self.slurm / 'scontrol').exists())  # the held pilot was never released
        self.assertFalse((self.root / 'waves/w1/x/chain.json').exists())
        (self.slurm / 'queue').write_text(''.join(f'{k}\n' for k in range(9)))   # 9 of 12 places taken
        wave = self.wave([{'id': 'y', 'mode': 'bulk', 'preset': 'auto', 'in': str(inp), 'shards': 2}])
        r = self.submit(wave)
        self.assertEqual(r.returncode, 3)
        self.assertIn('needs 4 queue places and 3 are free', r.stdout)


class Check(unittest.TestCase):
    """W46.kit-gate: train_seg.py check scores answers on the held-out gaps and the anchor and writes the manifest."""

    @staticmethod
    def answer(col, nums, new):
        bounds = [{"between": [a, b], "decision": "new" if (a in new) else "continue", "cue": "x",
                   "confidence": 0.95 if a % 2 else 0.6} for a, b in zip(nums, nums[1:])]
        res = {"pages": [{"page": n, "kind": "document"} for n in nums], "boundaries": bounds}
        return json.dumps({"collection": col, "window": nums, "status": "ok", "result": json.dumps(res)}) + "\n"

    def run_check(self, tmp, cand_new, anchor_new, *extra):
        truth = {"box": "Anchor", "pages": [{"n": n, "label": "New" if n in (1, 3, 5) else "Cont"} for n in range(1, 7)]}
        (tmp / "anchor.json").write_text(json.dumps(truth))
        labels = [{"folder_id": "f1", "n": n, "split": "holdout", "tag": "new" if n == 2 else "cont"} for n in (1, 2, 3)]
        labels.append({"folder_id": "f2", "n": 1, "split": "train", "tag": "new"})
        (tmp / "labels.jsonl").write_text("".join(json.dumps(g) + "\n" for g in labels))
        for name, held, anchor in (("shipped", {2}, {2, 4}), ("cand", cand_new, anchor_new)):
            d = tmp / name
            d.mkdir(exist_ok=True)
            (d / "answers.jsonl").write_text(self.answer("f1", [1, 2, 3, 4], held)
                                             + (self.answer("Anchor", list(range(1, 7)), anchor) if anchor is not None else ""))
        return subprocess.run([sys.executable, str(HERE / "train_seg.py"), "check", "--run", f"shipped={tmp / 'shipped'}",
                               "--run", f"cand={tmp / 'cand'}", "--candidate", "cand", "--anchor-truth",
                               str(tmp / "anchor.json"), "--labels", str(tmp / "labels.jsonl"),
                               "--out", str(tmp / "m.json"), *extra], capture_output=True, text=True)

    def test_manifest_scores_and_gate(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            r = self.run_check(tmp, {2}, {2, 4})
            self.assertEqual(r.returncode, 0, r.stderr)
            m = json.loads((tmp / "m.json").read_text())
            self.assertEqual(m["prompt_id"], "c1")
            self.assertEqual(m["heldout"]["tags"]["gaps"], 3)          # held-out gaps only, never the train split
            self.assertEqual(m["heldout"]["tags"]["accuracy"], 100.0)
            self.assertEqual(m["anchor"]["pages_exact"], 100.0)
            self.assertEqual(m["anchor"]["documents"], 3)
            self.assertTrue(m["gate"]["passed"])
            # Wrong on every held-out gap, and on the anchor's two boundaries: the gate fails, exit 1, with reasons.
            r = self.run_check(tmp, {1, 3}, set())
            self.assertEqual(r.returncode, 1)
            m = json.loads((tmp / "m.json").read_text())
            self.assertEqual(m["heldout"]["tags"]["accuracy"], 0.0)
            self.assertEqual(m["heldout"]["tags"]["difference"], -100.0)
            self.assertEqual(m["anchor"]["pages_exact"], 0.0)
            self.assertFalse(m["gate"]["passed"])
            self.assertIn("trail the shipped model", " ".join(m["gate"]["reasons"]))

    def test_no_anchor_answers_no_anchor_score(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            r = self.run_check(tmp, {2}, None)
            self.assertEqual(r.returncode, 1)
            m = json.loads((tmp / "m.json").read_text())
            self.assertIsNone(m["anchor"])
            self.assertIn("no anchor score", " ".join(m["gate"]["reasons"]))


if __name__ == '__main__':
    unittest.main()
