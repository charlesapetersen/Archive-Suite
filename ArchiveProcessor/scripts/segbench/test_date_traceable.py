#!/usr/bin/env python3
"""date_traceable.py: the rule stage, the reply parsers and the pipeline's routing, on hand-built documents.

    python3 -m unittest test_date_traceable
"""
import unittest

import date_traceable as T


def doc(text, near=(), cls="in text", truth=None):
    ns = []
    for label, t in near:
        dist = int(label[1:]) * (1 if label[0] == "P" else -1)
        ns.append({"label": label, "dist": dist, "text": t, "pick": T.rule_pick(T.candidates(t))})
    return {"id": "o:x", "set": "owner", "cls": cls, "truth": truth or {"year": 1947, "du": False}, "text": text,
            "near": ns, "prompt": "", "collection": "c", "folder": "f", "position": 5}


class Candidates(unittest.TestCase):
    def test_forms_and_lines(self):
        cs = T.candidates("Stanford University\nMarch 3, 1947\nre: the 1946 act\n12/5/52 memo\n3rd of June 1950")
        got = [(c["year"], c["kind"], c["line_no"], c["month"]) for c in cs]
        self.assertEqual(got, [(1947, "full", 1, 3), (1946, "year", 2, None), (1952, "numeric", 3, 12),
                               (1950, "full", 4, 6)])

    def test_a_full_date_is_not_read_again_as_a_bare_year(self):
        cs = T.candidates("January 1960 and June 12, 1961")
        self.assertEqual([(c["year"], c["kind"]) for c in cs], [(1960, "month"), (1961, "full")])

    def test_out_of_range_and_number_runs_are_dropped(self):
        self.assertEqual(T.candidates("room 1750, phone 21960, $1,950, year 2099"), [])

    def test_limit_is_the_apps_3000_characters(self):
        self.assertEqual(T.candidates("x" * 3000 + "\nMay 1, 1950"), [])


class RulePick(unittest.TestCase):
    def test_head_date_wins_and_is_sure_when_all_dated_forms_agree(self):
        y, m, conf, c = T.rule_pick(T.candidates("April 2, 1951\nthe 1949 budget"))
        self.assertEqual((y, m, conf, c["line_no"]), (1951, 4, "sure", 0))

    def test_disagreeing_dated_forms_are_ambiguous(self):
        y, _, conf, _ = T.rule_pick(T.candidates("April 2, 1951\nreplying to yours of May 1, 1950"))
        self.assertEqual((y, conf), (1951, "ambiguous"))

    def test_one_bare_year_is_single(self):
        self.assertEqual(T.rule_pick(T.candidates("Annual report 1962\nfor 1962"))[2], "single")

    def test_latest_mode_changes_only_the_fallback(self):
        cs = T.candidates("in 1957 we began\n" + "\n" * 20 + "by 1960 we had")
        self.assertEqual(T.rule_pick(cs)[0], 1957)
        self.assertEqual(T.rule_pick(cs, mode="latest")[0], 1960)
        head = T.candidates("May 1, 1950\nin 1957")
        self.assertEqual(T.rule_pick(head, mode="latest")[0], 1950)

    def test_no_candidates(self):
        self.assertEqual(T.rule_pick([]), (None, None, "none", None))

    def test_distinct_keeps_the_strongest_form_per_year(self):
        cs = T.distinct(T.candidates("1950 report\nJune 1, 1950\n1949"))
        self.assertEqual([(c["year"], c["kind"]) for c in cs], [(1950, "full"), (1949, "year")])


class Parsers(unittest.TestCase):
    def test_trace_reply(self):
        t = T.parse_trace('<think>x</think>```json\n{"year": "1947", "lo": 1946, "hi": 1949, "date_uncertain": true, '
                          '"evidence": {"neighbour": "P1", "quote": "May 2, 1947"}}\n```')
        self.assertEqual((t["y"], t["lo"], t["hi"], t["du"], t["bad_interval"]), (1947, 1946, 1949, True, False))
        self.assertEqual(t["evidence"]["neighbour"], "P1")

    def test_interval_not_holding_the_year_becomes_the_point(self):
        t = T.parse_trace('{"year": 1947, "lo": 1950, "hi": 1955, "date_uncertain": false}')
        self.assertEqual((t["lo"], t["hi"], t["bad_interval"], t["du"]), (1947, 1947, True, False))

    def test_null_year_and_garbage(self):
        self.assertIsNone(T.parse_trace('{"year": null}')["y"])
        self.assertFalse(T.parse_trace("no json here")["parsed"])
        self.assertIsNone(T.parse_trace('{"year": 1492}')["y"])

    def test_choice(self):
        cs = [{"year": 1950}, {"year": 1951}]
        self.assertEqual(T.parse_choice('{"choice": 2}', cs), ({"year": 1951}, True))
        self.assertEqual(T.parse_choice('{"choice": null}', cs), (None, True))
        self.assertEqual(T.parse_choice('{"choice": 7}', cs), (None, True))
        self.assertEqual(T.parse_choice('nope', cs), (None, False))


class Pipeline(unittest.TestCase):
    def test_printed_date_stays_with_the_rule_and_cites_itself(self):
        r = T.pipeline(doc("June 1, 1947\nDear Sir"), None, None, 3)
        self.assertEqual((r["stage"], r["y"], r["verdict"], r["du_pred"]), ("rule", 1947, "valid", False))

    def test_undated_document_propagates_from_the_nearest_earlier_dated_one(self):
        d = doc("Dear Sir, enclosed", near=[("P1", "no date"), ("P2", "May 5, 1946\nmemo"), ("N1", "July 1, 1950")],
                cls="A")
        r = T.pipeline(d, None, None, 3)
        self.assertEqual((r["stage"], r["y"], r["du_pred"], r["evidence"]["neighbour"], r["verdict"]),
                         ("propagated", 1946, True, "P2", "valid"))
        self.assertEqual(T.pipeline(d, None, None, 1)["stage"], "none")

    def test_residue_reply_is_scored_with_its_evidence(self):
        d = doc("Dear Sir", near=[("N1", "Palo Alto, July 1, 1950")], cls="D")
        res = {"o:x": {"raw": '{"year": 1950, "lo": 1949, "hi": 1951, "date_uncertain": true, '
                              '"evidence": {"neighbour": "N1", "quote": "July 1, 1950"}}'}}
        r = T.pipeline(d, None, res, 3)
        self.assertEqual((r["stage"], r["y"], r["lo"], r["hi"], r["verdict"]), ("residue", 1950, 1949, 1951, "valid"))
        bad = {"o:x": {"raw": '{"year": 1950, "evidence": {"neighbour": "N1", "quote": "July 2, 1950"}}'}}
        self.assertEqual(T.pipeline(d, None, bad, 3)["verdict"], "unsupported")
        self.assertEqual(T.pipeline(d, None, {}, 3)["stage"], "residue-missing")

    def test_27b_chooser_overrides_an_ambiguous_pick(self):
        d = doc("April 2, 1951\nreplying to yours of May 1, 1950")
        ch = {"choose|o:x": {"raw": '{"choice": 2}'}}
        r = T.pipeline(d, ch, None, 3)
        self.assertEqual((r["stage"], r["y"]), ("chooser", 1950))
        self.assertEqual(T.pipeline(d, {}, None, 3)["y"], 1951)


class Prompts(unittest.TestCase):
    def test_trace_prompt_variants(self):
        d = doc("Dear Sir", near=[("P1", "May 5, 1946\nmemo"), ("N1", "no date")])
        plain = T.trace_prompt(d, "plain")
        self.assertIn("[P1]\nMay 5, 1946", plain)
        self.assertNotIn("Dates a rule found", plain)
        self.assertIn('[P1] 1946 ("May 5, 1946")', T.trace_prompt(d, "neigh"))
        shots = T.trace_prompt(d, "shots", [{"year": 1944, "text": "an example"}])
        self.assertIn("Example 1 (1944):\nan example", shots)
        self.assertIn("(none tagged yet)", T.trace_prompt(d, "shots", []))

    def test_shots_skip_the_neighbours_and_prefer_other_folders(self):
        d = doc("x")
        pool = {"c": [{"folder": "f", "position": 6, "year": 1, "text": ""},
                      {"folder": "f", "position": 9, "year": 2, "text": ""},
                      {"folder": "g", "position": 1, "year": 3, "text": ""}]}
        self.assertEqual([s["year"] for s in T.shots_for(d, pool)], [3, 2])


if __name__ == "__main__":
    unittest.main()
