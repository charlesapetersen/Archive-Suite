"""Synthetic tests for enh_dewarp's lattice geometry: evaluation, inversion, frame, fold-overs, sagitta, curvature."""
import unittest
import hashlib
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

import numpy as np

import enh_dewarp as E

GH, GW = 45, 31


def lattice(f):
    u, v = np.meshgrid(np.linspace(0, 1, GW), np.linspace(0, 1, GH))
    return f(np.stack([u, v], -1))


def homography_grid():
    """A perspective map (straight lines stay straight) from the unit square into the source."""
    H = np.array([[0.8, 0.05, 0.1], [0.02, 0.85, 0.05], [0.1, 0.05, 1.0]])
    def f(uv):
        p = np.concatenate([uv, np.ones(uv.shape[:-1] + (1,))], -1) @ H.T
        return p[..., :2] / p[..., 2:3]
    return lattice(f)


def bent_grid(amp=0.02):
    """Rows bow downward in the middle, as a curled page's lines do once flattened."""
    return lattice(lambda uv: np.stack([0.1 + 0.8 * uv[..., 0],
                                        0.1 + 0.8 * uv[..., 1] + amp * np.sin(np.pi * uv[..., 0])], -1))


class Lattice(unittest.TestCase):
    def test_eval_hits_nodes_and_identity(self):
        g = lattice(lambda uv: uv)
        pts = np.array([[0, 0], [1, 1], [0.37, 0.81], [0.5, 0.5]])
        np.testing.assert_allclose(E.grid_eval(g, pts), pts, atol=1e-12)
        h = homography_grid()
        np.testing.assert_allclose(E.grid_eval(h, [1 / (GW - 1) * 7, 1 / (GH - 1) * 11]), h[11, 7], atol=1e-12)

    def test_frame_and_inside(self):
        g = lattice(lambda uv: 0.2 + 0.6 * uv)  # the frame shows the source's middle 60%
        poly = E.frame(g)
        self.assertEqual(len(poly), 2 * (GW + GH) - 4)
        got = E.inside(poly, [[0.5, 0.5], [0.21, 0.79], [0.1, 0.5], [0.5, 0.9], [0.95, 0.05]])
        self.assertEqual(got.tolist(), [True, True, False, False, False])
        self.assertEqual(E.covered(g, [[0.5, 0.5], [0.21, 0.79], [0.1, 0.5], [0.5, 0.9]]).tolist(), [True, True, False, False])

    def test_covered_survives_a_fold(self):
        # A lattice whose middle columns double back: the outer ring crosses itself, so the even-odd ring test
        # calls covered points outside; the cell test does not.
        def f(uv):
            x = uv[..., 0]
            fx = np.where(x < 0.5, x, 1 - x) * 1.6 + 0.1  # goes right, then folds back left
            return np.stack([fx, 0.1 + 0.8 * uv[..., 1]], -1)
        g = lattice(f)
        self.assertGreater(E.foldovers(g), 0)
        self.assertTrue(E.covered(g, [[0.5, 0.5]])[0])

    def test_foldovers(self):
        g = lattice(lambda uv: uv)
        self.assertEqual(E.foldovers(g), 0)
        g[10, 10], g[10, 11] = g[10, 11].copy(), g[10, 10].copy()  # swap two nodes: the cells around them flip
        self.assertGreater(E.foldovers(g), 0)

    def test_sagitta(self):
        scale = (1000, 1000)
        # a homography keeps lines straight; bilinear interpolation between the lattice's nodes bends them a hair
        self.assertLess(E.sagitta(homography_grid(), [0.1, 0.3], [0.9, 0.3], scale), 1e-3)
        s = E.sagitta(bent_grid(0.02), [0, 0.5], [1, 0.5], scale)
        self.assertAlmostEqual(s, 20, delta=0.5)  # 0.02 of 1000 px at the middle of the row

    def test_angle_residual(self):
        def line(y, deg, x0=0.1, x1=0.8):
            s = np.tan(np.radians(deg)) * (x1 - x0)
            return {'quad': [[x0, y - 0.02], [x1, y - 0.02 + s], [x1, y + s], [x0, y]]}
        scale = (1000, 1000)
        self.assertIsNone(E.angle_residual([line(0.5, 0)] * 4, scale))  # too few lines
        self.assertIsNone(E.angle_residual([line(y, 0, 0.1, 0.2) for y in np.linspace(.1, .9, 8)], scale))  # narrow
        smooth = [line(y, 0.5 + 2 * y) for y in np.linspace(.1, .9, 8)]  # perspective: angle grows down the page
        self.assertLess(E.angle_residual(smooth, scale), 1e-3)
        curled = [line(y, 3 * np.sin(np.pi * y)) for y in np.linspace(.1, .9, 8)]
        self.assertGreater(E.angle_residual(curled, scale), 0.3)

    def test_lattice_bend(self):
        scale = (1000, 1000)
        self.assertLess(E.lattice_bend(homography_grid(), scale), 1e-3)
        self.assertAlmostEqual(E.lattice_bend(bent_grid(0.02), scale), 20, delta=0.5)

    def test_truth_words_align(self):
        def w(t, x):
            return {'text': t, 'quad': [[x, 0.1], [x + 0.05, 0.1], [x + 0.05, 0.12], [x, 0.12]]}
        lines = [{'words': [w('the', 0.0), w('neighbour', 0.1)]},  # a neighbouring page's words first
                 {'words': [w('The', 0.3), w('cat', 0.4), w('sat', 0.5)]}]
        c = E.truth_words(lines, ['the', 'cat', 'sat'])
        np.testing.assert_allclose(c[:, 0], [0.325, 0.425, 0.525])  # the page's own 'The', not the neighbour's


class CollectedPack(unittest.TestCase):
    """Never publish a collection error as evidence that preprocessing hurt OCR."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.jobs = [('raw', 'p001'), ('docres', 'p001')]
        self.image = self.root / 'image.jpg'
        self.image.write_bytes(b'frozen test image')
        self.digest = hashlib.sha256(self.image.read_bytes()).hexdigest()
        self.manifest = [{'id': f'{a}/{p}', 'sha256': self.digest} for a, p in self.jobs]
        (self.root / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in self.manifest))
        (self.root / 'routes.json').write_text(json.dumps({r: {'model': m} for r, m in E.CLUSTER_MODELS.items()}))
        for route, mode in E.READERS.items():
            for arm, p in self.jobs:
                rec = {'id': f'{arm}/{p}', 'sha256': self.digest, 'route': route,
                       'model': E.CLUSTER_MODELS[route], 'status': 'ok', 'error': None,
                       'finish': None if mode == 'pipeline' else 'stop', 'max_tokens': 8192,
                       'prompt_sha256': hashlib.sha256((E.P.PROMPT if mode == 'panel' else '').encode()).hexdigest(),
                       'raw': 'KIND: typed\nTABLE: no\nTEXT:\nThe cat sat.' if mode == 'panel' else 'The cat sat.'}
                f = self.path(route, arm)
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(json.dumps(rec))
        self.addCleanup(patch.stopall)
        patch.object(E, 'arm_image', return_value=self.image).start()

    def path(self, route='qwen3.6-27b', arm='raw'):
        return self.root / 'out' / route / arm / 'p001.json'

    def update(self, **fields):
        f = self.path()
        rec = json.loads(f.read_text()); rec.update(fields)
        f.write_text(json.dumps(rec))

    def test_complete_pack_keeps_cap_and_blank_as_empty_scores(self):
        self.update(status='cap', finish='length')
        f = self.path('ppocrv6', 'docres')
        rec = json.loads(f.read_text()); rec.update(status='blank', raw='')
        f.write_text(json.dumps(rec))
        truth = self.root / 'truth'; truth.mkdir()
        (truth / 'p001.txt').write_text('The cat sat.')
        with patch.object(E, 'cluster_jobs', return_value=self.jobs), patch.object(E.P, 'TRUTH', self.root):
            rows = E.cluster_rows(self.root)
        for route, arm in [('qwen3.6-27b', 'raw'), ('ppocrv6', 'docres')]:
            row = rows[route][arm, 'p001']
            self.assertTrue(row['read'])  # terminal attempt, not an incomplete collection
            self.assertFalse(row['ok'])
            self.assertEqual(row['nes'], 0)
            self.assertEqual(row['missed'], row['words'])
        self.assertEqual(rows['lightonocr3-4b']['raw', 'p001']['nes'], 1)

    def test_missing_record_refuses_publication(self):
        self.path().unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete collection'):
            E.cluster_records(self.root, self.jobs)

    def test_manifest_requires_exact_unique_image_set(self):
        for rows in [self.manifest * 2, self.manifest[:1], self.manifest + [{'id': 'raw/p999'}]]:
            with self.subTest(rows=rows):
                (self.root / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
                with self.assertRaisesRegex(ValueError, 'manifest'):
                    E.cluster_records(self.root, self.jobs)

    def test_changed_local_image_refuses_publication(self):
        self.image.write_bytes(b'changed after inference')
        with self.assertRaisesRegex(ValueError, 'local frozen image'):
            E.cluster_records(self.root, self.jobs)

    def test_misidentified_record_or_decoder_refuses_publication(self):
        original = self.path().read_text()
        for fields in [{'id': 'raw/p999'}, {'sha256': '0' * 64}, {'route': 'ppocrv6'}, {'model': 'other'},
                       {'finish': 'length'}, {'max_tokens': 4000}, {'prompt_sha256': '0' * 64},
                       {'status': 'unknown'}, {'raw': None}, {'error': 'provider failed'}]:
            with self.subTest(fields=fields):
                self.path().write_text(original)
                self.update(**fields)
                with self.assertRaises(ValueError):
                    E.cluster_records(self.root, self.jobs)

    def test_duplicate_record_refuses_publication(self):
        self.path().with_name('p002.json').write_text(self.path().read_text())
        with self.assertRaises(ValueError):
            E.cluster_records(self.root, self.jobs)


if __name__ == '__main__':
    unittest.main()
