"""Synthetic tests for enh_dewarp's lattice geometry: evaluation, inversion, frame, fold-overs, sagitta, curvature."""
import unittest

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


if __name__ == '__main__':
    unittest.main()
