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

    def test_invert_round_trip(self):
        for g in (homography_grid(), bent_grid()):
            uv = np.array([[0.1, 0.2], [0.9, 0.95], [0.5, 0.5], [0, 1]])
            back, res = E.invert(g, E.grid_eval(g, uv))
            np.testing.assert_allclose(back, uv, atol=1e-6)
            self.assertLess(res.max(), 1e-9)

    def test_frame_and_inside(self):
        g = lattice(lambda uv: 0.2 + 0.6 * uv)  # the frame shows the source's middle 60%
        poly = E.frame(g)
        self.assertEqual(len(poly), 2 * (GW + GH) - 4)
        got = E.inside(poly, [[0.5, 0.5], [0.21, 0.79], [0.1, 0.5], [0.5, 0.9], [0.95, 0.05]])
        self.assertEqual(got.tolist(), [True, True, False, False, False])

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

    def test_line_curvature(self):
        def words(ys):
            return [{'quad': [[x, y - 0.02], [x + 0.05, y - 0.02], [x + 0.05, y], [x, y]]}
                    for x, y in zip(np.linspace(0.1, 0.8, len(ys)), ys)]
        scale = (1000, 1000)
        self.assertIsNone(E.line_curvature(words([0.5] * 3), scale))
        self.assertLess(E.line_curvature(words(np.linspace(0.4, 0.6, 6)), scale), 1e-9)  # straight, though slanted
        bowed = E.line_curvature(words([0.5, 0.51, 0.515, 0.515, 0.51, 0.5]), scale)
        self.assertGreater(bowed, 0.1)


if __name__ == '__main__':
    unittest.main()
