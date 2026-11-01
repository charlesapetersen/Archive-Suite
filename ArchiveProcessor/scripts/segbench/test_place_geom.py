"""W46.place-geom's pure parts: the arm maps and the fold of the owner's line rulings. Run with W46.enh-dewarp's venv:
$V test_place_geom.py"""
import math

import numpy as np

import place_geom as G


def test_deskew_map_levels_a_sloped_line_and_keeps_the_page():
    W, H, deg = 3000, 4000, 2.0
    m = G.deskew_map(W, H, deg)
    # a line falling 2 degrees to the right (image y down) comes out level
    x0, y0 = 0.2, 0.5
    x1 = 0.8
    y1 = y0 + (x1 - x0) * W * math.tan(math.radians(deg)) / H
    a, b = m([(x0, y0), (x1, y1)])
    assert abs((b[1] - a[1]) * m.out_h) < 1e-6
    # every corner of the page is still shown: deskew removes nothing
    assert np.all(np.isfinite(m([(0, 0), (1, 0), (1, 1), (0, 1)])))
    assert m.out_w > W and m.out_h > H


def test_quad_inverse_of_a_homography_lattice_is_exact():
    W, H, ow, oh = 2000, 3000, 1800, 2600
    src = np.array([[0.1, 0.05], [0.92, 0.08], [0.95, 0.9], [0.05, 0.93]])
    import cv2
    out = np.array([[0, 0], [ow, 0], [ow, oh], [0, oh]], float)
    Hm = cv2.getPerspectiveTransform(out.astype(np.float32), (src * [W, H]).astype(np.float32))
    gh, gw = 9, 7
    u, v = np.meshgrid(np.linspace(0, 1, gw), np.linspace(0, 1, gh))
    pts = np.c_[u.ravel() * ow, v.ravel() * oh, np.ones(gw * gh)] @ Hm.T
    grid = (pts[:, :2] / pts[:, 2:3] / [W, H]).reshape(gh, gw, 2)
    m = G.lattice_inverse(grid, ow, oh, W, H, 'quad')
    got = m(grid.reshape(-1, 2))
    assert np.allclose(got, np.c_[u.ravel(), v.ravel()], atol=1e-6)
    assert np.all(np.isnan(m([(0.01, 0.01)])))   # outside the quad: not shown


def test_uvdoc_inverse_round_trips_inside_and_is_nan_outside():
    W, H = 1000, 1400
    gh, gw = 11, 9
    u, v = np.meshgrid(np.linspace(0, 1, gw), np.linspace(0, 1, gh))
    # a gentle curl: rows bow down in the middle
    grid = np.stack([0.1 + 0.8 * u, 0.1 + 0.8 * v + 0.02 * np.sin(np.pi * u)], -1)
    m = G.lattice_inverse(grid, 900, 1200, W, H, 'uvdoc')
    uv = np.array([[0.5, 0.5], [0.25, 0.7], [0.8, 0.3]])
    from enh_dewarp import grid_eval
    back = m(grid_eval(grid, uv))
    assert np.allclose(back, uv, atol=2e-3)
    assert np.all(np.isnan(m([(0.02, 0.5)])))


def page(words):
    return {'page': 'p999', 'width': 1000, 'height': 1000,
            'words': [{'text': t, 'box': [x, y, 0.05, 0.02], 'line': L, 'status': 'drawn'} for t, x, y, L in words]}


def test_fold_merges_a_join_the_owner_read_as_one_line_in_x_order():
    t = page([('right', 0.6, 0.1, 0), ('words', 0.7, 0.1, 0), ('left', 0.1, 0.1, 1), ('side', 0.2, 0.1, 1)])
    rul = {'p999': {'t000': {'ruling': 'truth wrong', 'places': [{'kind': 'join', 'lines': [0, 1]}]}}}
    lines, n = G.fold_lines(t, rul)
    assert n['merged'] == 1
    assert [t['words'][i]['text'] for i in lines['0+1']] == ['left', 'side', 'right', 'words']


def test_fold_splits_at_the_marked_breaks_and_leaves_a_standing_truth_alone():
    t = page([('a', 0.1, 0.1, 0), ('b', 0.2, 0.1, 0), ('c', 0.5, 0.1, 0), ('d', 0.6, 0.1, 0), ('e', 0.1, 0.3, 1)])
    rul = {'p999': {'t000': {'ruling': 'truth wrong', 'places': [{'kind': 'split', 'lines': [0], 'breaks': [1]}]},
                    't001': {'ruling': 'truth stands', 'places': [{'kind': 'split', 'lines': [1], 'breaks': [0]}]}}}
    lines, n = G.fold_lines(t, rul)
    assert n['split'] == 1
    assert [[t['words'][i]['text'] for i in lines[k]] for k in ('0.0', '0.1', '1')] == [['a', 'b'], ['c', 'd'], ['e']]


def test_fold_leaves_out_the_table_rows_the_owner_said_break_more():
    t = page([('a', 0.1, 0.1, 0), ('b', 0.5, 0.1, 0), ('c', 0.1, 0.3, 1), ('d', 0.5, 0.3, 1)])
    t['page'] = 'p057'
    rul = {'p057': {'t007': {'ruling': 'truth wrong', 'places': [{'kind': 'split', 'lines': [0], 'breaks': [0]}]}}}
    lines, n = G.fold_lines(t, rul)
    assert '0' not in lines and '0.0' not in lines and n['left_out'] == 1 and '1' in lines


def test_expected_lines_skip_a_word_vision_did_not_read():
    t = page([('one', 0.1, 0.1, 0), ('two', 0.2, 0.1, 0), ('three', 0.1, 0.3, 1), ('four', 0.2, 0.3, 1)])
    vwords = [{'text': 'one', 'box': [0.09, 0.09, 0.07, 0.04], 'line': 0},
              {'text': 'two', 'box': [0.19, 0.09, 0.07, 0.04], 'line': 0},
              {'text': 'three', 'box': [0.09, 0.29, 0.07, 0.04], 'line': 1}]
    folded, _ = G.fold_lines(t, {})
    a = G.assign(t, vwords)
    exp, skipped = G.expected_lines(t, folded, vwords, a)
    assert list(exp) == ['0'] and exp['0'][1] == [0, 1] and skipped['unread'] == 1


if __name__ == '__main__':
    for name, fn in sorted(globals().items()):
        if name.startswith('test_'):
            fn()
            print('ok', name)
