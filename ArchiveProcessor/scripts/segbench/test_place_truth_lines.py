"""Tests for place_truth_lines.py's grouping, marks, PP-OCRv6 row joining and fold, on synthetic pages."""
import unittest

import place_truth_lines as ptl


def page(rows):
    """rows: per truth line, its words' x positions (all on one row per line, a row 0.1 apart)."""
    ws, ls = [], []
    for i, xs in enumerate(rows):
        y = 0.1 + 0.1 * i
        for x in xs:
            ws.append({'text': 'w', 'box': [x, y, 0.08, 0.03], 'line': i, 'status': 'vision'})
        ls.append({'id': i, 'box': [xs[0], y, xs[-1] + 0.08 - xs[0], 0.03], 'status': 'drafted',
                   'baseline': [[xs[0], y + 0.025], [xs[-1] + 0.08, y + 0.025]]})
    return {'page': 'pX', 'width': 1000, 'height': 1000, 'words': ws, 'lines': ls}


def det_line(x0, x1, y):
    return {'baseline': [[x0, y + 0.025], [x1, y + 0.025]],
            'boundary': [[x0, y - 0.005], [x1, y - 0.005], [x1, y + 0.035], [x0, y + 0.035]]}


class Grouping(unittest.TestCase):
    def test_same_grouping_no_disagreement(self):
        t = page([[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
        det = {'lines': [det_line(0.09, 0.4, 0.1), det_line(0.09, 0.4, 0.2)]}
        self.assertEqual(ptl.disagreements(t, ptl.assign(t, det)), ({}, set()))

    def test_split_at_gutter(self):
        t = page([[0.1, 0.2, 0.6, 0.7]])          # one truth line across a gutter
        det = {'lines': [det_line(0.09, 0.3, 0.1), det_line(0.59, 0.8, 0.1)]}
        splits, joins = ptl.disagreements(t, ptl.assign(t, det))
        self.assertEqual(splits, {0: [1]})
        self.assertEqual(joins, set())

    def test_join_of_two_truth_lines_on_a_row(self):
        t = page([[0.1, 0.2], [0.6, 0.7]])
        t['words'][2]['box'][1] = t['words'][3]['box'][1] = 0.1   # line 1 on line 0's row
        det = {'lines': [det_line(0.09, 0.8, 0.1)]}
        splits, joins = ptl.disagreements(t, ptl.assign(t, det))
        self.assertEqual(joins, {frozenset({0, 1})})
        self.assertEqual(splits, {})

    def test_one_stray_word_is_not_a_split(self):
        t = page([[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
        t['words'][1]['box'][1] = 0.19     # a tall word whose centre falls in the next line's polygon
        det = {'lines': [det_line(0.09, 0.4, 0.1), det_line(0.09, 0.4, 0.2)]}
        self.assertEqual(ptl.disagreements(t, ptl.assign(t, det))[0], {})

    def test_unscored_words_are_ignored(self):
        t = page([[0.1, 0.6]])
        t['words'][1]['status'] = 'missing'
        det = {'lines': [det_line(0.09, 0.3, 0.1), det_line(0.59, 0.8, 0.1)]}
        self.assertEqual(ptl.disagreements(t, ptl.assign(t, det)), ({}, set()))


class Marks(unittest.TestCase):
    def test_upright_between_words_on_a_row(self):
        m = ptl.mark([0.1, 0.1, 0.1, 0.03], [0.5, 0.1, 0.1, 0.03])
        self.assertEqual((m[0], m[2]), (0.35, 0.35))
        self.assertAlmostEqual(m[1], 0.1)

    def test_level_between_rows(self):
        m = ptl.mark([0.1, 0.1, 0.5, 0.03], [0.1, 0.2, 0.5, 0.03])
        self.assertEqual(m[1], m[3])
        self.assertAlmostEqual(m[1], 0.165)


class RowJoin(unittest.TestCase):
    def quad(self, x0, x1, y0=100, y1=130):
        return ptl.PH.quad_line([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])

    def test_small_gap_joins_wide_gap_breaks(self):
        lines = ptl.join_gap([self.quad(0, 100), self.quad(110, 200), self.quad(400, 500)])
        self.assertEqual(len(lines), 2)
        self.assertEqual(min(p[0] for p in lines[0]['boundary']), 0)
        self.assertEqual(max(p[0] for p in lines[0]['boundary']), 200)
        self.assertEqual(min(p[0] for p in lines[1]['boundary']), 400)


class Fold(unittest.TestCase):
    def test_rulings(self):
        q = lambda kind, n=1: {'kind': kind, 'truth': 'one' if kind == 'split' else 'breaks', 'places': [{}] * n}
        key = {'pages': {'p1': {'t000': q('split', 2), 't001': q('join'), 't002': q('join'), 't003': q('split'),
                                't004': q('split')},
                         'p9': {'hand': True, 'lines': [0, 1, 2]}}}
        ans = {'p1': {'t000': {'pick': '1'}, 't001': {'pick': '1'}, 't002': {'pick': '3'}, 't003': {'pick': 'e'}},
               'p9': {'lines': {'bad': [2], 'checked': True}}}
        r = ptl.fold(key, ans)
        self.assertEqual(r['counts']['typed'], {'truth stands': 2, 'truth wrong': 1, 'truth partly wrong': 1,
                                                'either': 1, 'open': 1})
        self.assertEqual((r['counts']['hand_lines'], r['counts']['hand_lines_wrong']), (3, 1))
        self.assertEqual(r['rulings']['p9']['wrong'], [2])


if __name__ == '__main__':
    unittest.main()
