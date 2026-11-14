"""place_hands_kit_parity.py — the app's hand placer against the route W46.place-hands measured (W42.int-s5-hands).

    python3 place_hands_kit_parity.py <python> [--reading qwen3.6-27b] [--pages a,b,c] [--model PATH]

Runs VisionOCRKit's `place-hands.py` (the script the app ships) with <python> (the lab's kraken venv, or the hand
runtime's own `bin/python3`) on the owner hand pages the bench scored, and compares each page's confidence, matcher
and placed lines with the saved `blla.ctc-mccatmus-conf` hypothesis of the same reading (place_hands.py's cache).
Prints one row a page and a JSON summary; writes nothing outside a temporary directory. Run it under the heavy lock.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_hands as P  # noqa: E402

SCRIPT = HERE.parents[2] / 'packages/VisionOCRKit/Sources/VisionOCRKit/Resources/place-hands.py'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('python')
    ap.add_argument('--reading', default='qwen3.6-27b')
    ap.add_argument('--pages')
    ap.add_argument('--model', default=str(P.MODELS['mccatmus']))
    a = ap.parse_args()
    saved_dir = P.CACHE / 'hyp' / f'blla.ctc-mccatmus-conf.{a.reading}'
    todo = [t for t in P.pages(a.pages.split(',') if a.pages else None)
            if t['group'] == 'owner-hand' and (saved_dir / f'{P.key(t)}.json').exists()
            and (P.CACHE / 'readings' / a.reading / f'{P.key(t)}.txt').exists()]
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for t in todo:
            k = P.key(t)
            out = Path(tmp) / f'{k}.json'
            t0 = time.time()
            subprocess.run([a.python, '-I', str(SCRIPT), t['image'], str(P.CACHE / 'readings' / a.reading / f'{k}.txt'),
                            str(out), '--model', a.model], check=True)
            wall = time.time() - t0
            got, saved = json.loads(out.read_text()), json.loads((saved_dir / f'{k}.json').read_text())
            want = [ln['text'] for ln in saved['lines'] if ln.get('text')]
            have = [ln['text'] for ln in got['lines']]
            row = {'page': t['page'], 'conf': round(got['confidence'], 4), 'saved_conf': round(saved['meta']['ctc_conf'], 4),
                   'span': got['span'], 'saved_span': saved['meta']['span'], 'lines': len(have), 'saved_lines': len(want),
                   'same_lines': have == want, 'wall_s': round(wall, 2), 'peak_gb': round(got['peak_rss'] / 2**30, 2),
                   'seconds': {k_: round(v, 2) for k_, v in got['seconds'].items()}}
            rows.append(row)
            print(json.dumps(row), flush=True)
    same = sum(r['same_lines'] for r in rows)
    gate_same = sum((r['conf'] >= 0.67) == (r['saved_conf'] >= 0.67) for r in rows)
    print(json.dumps({'pages': len(rows), 'same_lines': same, 'same_gate': gate_same,
                      'max_conf_diff': max((abs(r['conf'] - r['saved_conf']) for r in rows), default=None)}))


if __name__ == '__main__':
    main()
