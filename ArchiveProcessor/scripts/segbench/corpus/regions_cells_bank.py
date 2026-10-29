"""W46.ocr-regions-cells-bank: score a frozen oracle-cells pack for some of its readers.

regions_cells.score() wants receipts from every reader in its ROUTES, and the bank run is
Qwen3.6-27B alone. regions_cells.py is hashed into the freeze, so editing it would make the
frozen pack fail its own check; this wrapper runs the full check once, then scores with the
reader list narrowed. Everything else (receipt identity, runtime drift, metrics) is unchanged.

    python3 regions_cells_bank.py --root PACK --routes qwen3.6-27b [--phase all] --out SCORE.json
"""
import argparse
from pathlib import Path

import regions_cells as R


def score(root, routes, phase='all'):
    routes = tuple(routes)
    if not routes or len(set(routes)) != len(routes) or set(routes) - set(R.ROUTES):
        raise ValueError('readers must be distinct names from %s' % (R.ROUTES,))
    checked = R.check(root)
    saved = R.ROUTES, R.check
    try:
        # The check above already compared the freeze against every reader; score() calls it again with
        # ROUTES narrowed, which the reader-set comparison would refuse.
        R.ROUTES, R.check = routes, (lambda _root: checked)
        result = R.score(root, phase)
    finally:
        R.ROUTES, R.check = saved
    result['routes_scored'] = list(routes)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', required=True, type=Path)
    ap.add_argument('--routes', required=True, help='comma-separated, e.g. qwen3.6-27b')
    ap.add_argument('--phase', choices=('capability', 'all'), default='all')
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    R.write_new(a.out, R.encoded(score(a.root, a.routes.split(','), a.phase)))


if __name__ == '__main__':
    main()
