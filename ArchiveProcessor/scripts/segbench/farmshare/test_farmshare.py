"""W41.farmshare-plan offline tests: Slurm-limit parsing, and fs_ocr.py and fs_seg.py against a fake vLLM server on
localhost.
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
import time
import unittest
import unittest.mock

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
        self.assertEqual([(f['image'], f['attempts']) for f in fails], [('c.jpg', 2)])
        self.assertEqual(json.loads((out / '_meta/box1/a.jpg.json').read_text())['kind'], 'printed')
        self.assertEqual(list(out.rglob('*.tmp*')), [])
        n = len(Fake.seen)
        r = self.bulk()                                      # rerun: the escalated page is not asked again
        self.assertEqual(len(Fake.seen) - n, 0, r.stdout)
        self.assertIn('3 already done or escalated, 0 to read', r.stdout)
        r = self.bulk('--retry-escalated')                   # unless asked: read, and retried, once more
        self.assertEqual(len(Fake.seen) - n, 2, r.stdout)

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
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'guard-check', str(self.tmp / 'runs')],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        j = json.loads(r.stdout)
        self.assertEqual((j['answered'], j['answered_fired'], j['capped'], j['capped_caught']), (1, 0, 2, 1))
        self.assertNotIn('again', r.stdout)                  # names and counts only, never the text
        F.atomic_write(d / 'p3.json', json.dumps({'reply': {'raw': LOOP_LINE * 500}, 'meta': {'finish': 'stop'}}).encode())
        r = subprocess.run([sys.executable, str(HERE / 'fs_ocr.py'), 'guard-check', str(self.tmp / 'runs')],
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
        self.assertEqual(meta['status'], 'error')              # counts toward fs_ocr's dead-server stop
        _, meta = self.reader().read(self.page([]))
        self.assertEqual((meta['status'], meta['regions']), ('empty', 0))
        reply, meta = self.reader(fail=True).read(self.page([(0, 0, 0)]))
        self.assertEqual((reply, meta['status']), (None, 'failed')); self.assertIn('out of memory', meta['error'])

    def test_bulk_layout_writes_done_pages_and_rereads_only_the_partial_one(self):
        self.page([(0, 0, 0), (0, 0, 255), (0, 255, 0)], self.tmp / 'in/1890/p1.jpg')
        self.page([(0, 0, 0), (255, 0, 0), (0, 0, 255)], self.tmp / 'in/1890/p2.png')
        real = NL.build_pipeline

        def bulk():
            argv = ['fs_ocr.py', 'bulk', '--layout', '--url', self.url, '--model', 'zai-org/GLM-OCR',
                    '--in', str(self.tmp / 'in'), '--out', str(self.tmp / 'out')]
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
        self.assertTrue(json.loads((out / 'throughput.jsonl').read_text().splitlines()[-1])['layout'])
        n = len(FakeGlm.seen)
        self.assertEqual(bulk(), 0)
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
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; FS_MAX_LEN=32768 preset glm-ocr; '
                              'echo "$FS_LAYOUT|$FS_DET_FILE|$FS_VLLM_ARGS"; preset qwen3.6-27b; echo "$FS_LAYOUT|$FS_DET_REPO"'],
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


@unittest.skipUnless(NUMPY, 'fs_seg imports the bench (numpy)')
class Seg(unittest.TestCase):
    """fs_seg.py run on a synthetic pack (the prompt is the window's page list, so the fake can answer it)."""

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
        cmd = [sys.executable, str(HERE / 'fs_seg.py'), 'run', '--pack', str(pack), '--out', str(self.tmp / 'out'),
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

    def test_pack_for_another_model_is_refused(self):
        out = self.run_seg(self.pack([[10, 11]], model='Qwen/Qwen3.6-27B-FP8'))
        self.assertNotEqual(out.returncode, 0)
        self.assertIn('the pack is for', out.stderr)
        self.assertEqual(FakeSeg.seen, [])

    def test_seg_preset_takes_seven_images(self):
        out = subprocess.run(['bash', '-c', f'source "{HERE}/models.sh"; FS_MM_IMAGES=7 preset qwen3.5-27b; '
                              'echo "$FS_VLLM_ARGS"; unset FS_MM_IMAGES; preset qwen3.5-27b; echo "$FS_VLLM_ARGS"'],
                             capture_output=True, text=True)
        seg, ocr = out.stdout.splitlines()
        self.assertIn('--limit-mm-per-prompt {"image":7}', seg)
        self.assertIn('--limit-mm-per-prompt {"image":1}', ocr)



class NewsLayout(unittest.TestCase):
    """fs_news_layout.py with a stand-in pipeline: one file per page where NewsBench's score.py looks, failures kept."""

    def test_writes_each_page_and_records_failures(self):
        import fs_news_layout as N

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


if __name__ == '__main__':
    unittest.main()
