"""W46.place-geom-real5's pure parts: the line truth's matching and the quad-edge drags. Run with W46.enh-dewarp's
venv: $V test_place_geom_real5.py"""
import math

import numpy as np

import place_geom as G
import place_geom_real5 as R5


def test_norm_drops_case_and_punctuation():
    assert R5.norm('- "... a Modular, deployable') == 'a modular deployable'


def test_a_vision_line_matches_its_omnidocbench_line_despite_an_ocr_slip():
    olines = [R5.norm('OO view: a component contains a set of collaborating'), R5.norm('classes and more')]
    assert R5.match_lines([R5.norm('OO view: a comp0nent contains a set of collaborating')], olines) == {0: 0}


def test_a_vision_line_joining_two_lines_or_half_a_line_is_not_truth():
    a, b = 'logic, the internal data structures that are required to', 'implement the processing logic, and an'
    olines = [R5.norm(a), R5.norm(b)]
    assert R5.match_lines([R5.norm(a + ' ' + b)], olines) == {}
    assert R5.match_lines([R5.norm('logic, the internal data')], olines) == {}


def test_two_vision_lines_taking_one_omnidocbench_line_are_both_left_out():
    olines = [R5.norm('the same running header text')]
    v = [R5.norm('the same running header text')] * 2
    assert R5.match_lines(v, olines) == {}


def test_drag_runs_along_a_skewed_line_from_edge_midpoint_to_edge_midpoint():
    W, H, deg = 2000, 2400, 10.0
    t = math.radians(deg)

    def word(x, w, y=1000.0, h=40.0):
        # a word box turned deg degrees about its own top-left corner, normalised
        c = np.array([[0, 0], [w, 0], [w, h], [0, h]], float)
        R = np.array([[math.cos(t), -math.sin(t)], [math.sin(t), math.cos(t)]])
        q = c @ R.T + [x, y + (x - 200) * math.tan(t)]
        return {'quad': (q / [W, H]).tolist()}
    tr = {'width': W, 'height': H, 'words': [word(200, 150), word(380, 120)]}
    s, e = R5.drag_points(tr, G.identity_map(W, H), [0, 1])
    q0, q1 = np.array(tr['words'][0]['quad']), np.array(tr['words'][1]['quad'])
    assert np.allclose(s, (q0[0] + q0[3]) / 2) and np.allclose(e, (q1[1] + q1[2]) / 2)
    # an axis-aligned box's left edge at its mid-height would start off the line: the quad's does not
    R5.MARGIN = 0.35
    s2, e2 = R5.drag_points(tr, G.identity_map(W, H), [0, 1])
    R5.MARGIN = 0.0
    d = (e - s) * [W, H]
    out = (s - s2) * [W, H]
    assert abs(d[0] * out[1] - d[1] * out[0]) < 1e-6 * np.hypot(*d) * np.hypot(*out)   # moved out along the line
    assert abs(np.hypot(*out) - 0.35 * 40) < 1e-6


if __name__ == '__main__':
    for k, f in list(globals().items()):
        if k.startswith('test_'):
            f()
            print('ok', k)
