"""Synthetic pages and answers; no corpus page, model run or network call."""
import unittest

import rotation_routes as RR
import rotation_setapart_sheet as S


def answers(off, *, abstain=(), escalate=()):
    """A route that reads the page as stored turned by `off` at every turn."""
    return {t: {'found': None if t in abstain else (RR.want(t) + off) % 360, 'escalated': t in escalate}
            for t in RR.TURNS}


def route(pages):
    return {(p, t): v for p, by_turn in pages.items() for t, v in by_turn.items()}


class Score(unittest.TestCase):
    def setUp(self):
        self.pages = {'box:A:1': {'set': 'boxes'}, 'box:A:2': {'set': 'boxes'}, 'box:A:3': {'set': 'boxes'}}
        self.turned = {'box:A:1': {'offset': 180, 'routes': ['paddle', 'vision']}}
        self.a = {'vision': route({'box:A:1': answers(180), 'box:A:2': answers(0), 'box:A:3': answers(0, abstain=(90,))}),
                  'paddle': route({'box:A:1': answers(180), 'box:A:2': answers(90), 'box:A:3': answers(0)})}

    def test_owner_agrees_and_the_page_stops_counting_wrong(self):
        ans = {'box:A:1': 'up', 'box:A:2': 'up', '_turns': {'box:A:1': 180}}
        t = S.tally(self.pages, self.a, self.turned, ans)
        self.assertEqual(t['agree'], {'box:A:1': True})
        self.assertEqual(t['controls_turned'], [])
        v = t['rules']['vision']
        self.assertEqual((v['wrong_as_stored'], v['wrong_owner_truth'], v['flagged_owner_truth']), (1, 0, 1))
        self.assertEqual(t['rules']['paddle']['wrong_owner_truth'], 1)        # box:A:2's quarter turn stays wrong

    def test_owner_says_upright_as_stored_and_the_routes_are_wrong(self):
        ans = {'box:A:1': 'up', '_turns': {}}
        t = S.tally(self.pages, self.a, self.turned, ans)
        self.assertEqual(t['agree'], {'box:A:1': False})
        self.assertEqual(t['rules']['vision']['wrong_owner_truth'], 1)

    def test_cannot_tell_keeps_the_stored_truth_and_a_turned_control_is_reported(self):
        ans = {'box:A:1': 'x', 'box:A:2': 'up', '_turns': {'box:A:1': 180, 'box:A:2': 90}}
        t = S.tally(self.pages, self.a, self.turned, ans)
        self.assertEqual(t['agree'], {})
        self.assertEqual(t['controls_turned'], ['box:A:2'])
        self.assertEqual(t['rules']['vision']['wrong_owner_truth'], 2)        # A:1 as stored, A:2 under its new truth

    def test_the_report_scores_the_owner_truth_as_the_sheet_does(self):
        # rotation_report.rebase is what the published held-out figures use; it must count what tally counts
        for turns in ({'box:A:1': 180}, {}, {'box:A:2': 90}):
            ans = {p: 'up' for p in self.pages} | {'_turns': turns}
            t = S.tally(self.pages, self.a, self.turned, ans)
            owner = S.owner_offsets(ans, list(self.pages))
            for r in self.a:
                f = S.REP.page_figures(S.REP.rebase(self.a[r], owner), list(self.pages))
                self.assertEqual((f['wrong'], f['flagged']),
                                 (t['rules'][r]['wrong_owner_truth'], t['rules'][r]['flagged_owner_truth']))

    def test_escalated_turns_count_flagged_and_their_answer_still_scores(self):
        a = route({'box:A:1': answers(0, escalate=(0,))})
        self.assertEqual(S.page_outcome(a, 'box:A:1', 0), {'right': True, 'wrong': False, 'flagged': True})
        self.assertIsNone(S.page_outcome(a, 'box:A:9', 0))


if __name__ == '__main__':
    unittest.main()
