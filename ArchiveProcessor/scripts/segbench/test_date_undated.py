#!/usr/bin/env python3
"""date_undated.py: the spending cap refusing before any request, the app call's body, and the "own date on the
pages" reading.

    python3 -m unittest test_date_undated
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import date_undated as U


class Cap(unittest.TestCase):
    def test_refuses_before_a_request_when_the_worst_case_would_pass_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(U, "CACHE", Path(tmp)), \
                mock.patch.object(U.G, "request") as req:
            (Path(tmp) / "calls.jsonl").write_text(json.dumps({"id": "x", "cost": U.CAP - U.WORST_APP / 2}) + "\n")
            with self.assertRaises(SystemExit):
                U.call("k", U.app_body("p"), U.WORST_APP, Path(tmp) / "out.json")
            req.assert_not_called()

    def test_a_cached_reply_is_returned_without_a_request(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(U, "CACHE", Path(tmp)), \
                mock.patch.object(U.G, "request") as req:
            dest = Path(tmp) / "out.json"
            dest.write_text(json.dumps({"id": "k", "text": "{}"}))
            self.assertEqual(U.call("k", U.app_body("p"), U.WORST_APP, dest)["id"], "k")
            req.assert_not_called()


class AppCall(unittest.TestCase):
    def test_sends_no_temperature_or_reasoning_as_the_app(self):
        b = U.app_body("prompt")
        self.assertNotIn("temperature", b)
        self.assertNotIn("reasoning_effort", b)
        self.assertEqual(b["messages"], [{"role": "user", "content": "prompt"}])

    def test_parses_the_reply_as_the_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "r.json"
            dest.write_text(json.dumps({"text": '```json\n{"year": "1968", "month": null, "date_uncertain": true}\n```'}))
            self.assertEqual(U.app_reply(dest), {"y": 1968, "m": None, "du": True, "parsed": True})
            dest.write_text(json.dumps({"text": "no json"}))
            self.assertEqual(U.app_reply(dest), {"y": None, "m": None, "du": True, "parsed": False})
            self.assertIsNone(U.app_reply(Path(tmp) / "missing.json"))


class OwnDate(unittest.TestCase):
    def rec(self, dates, doc):
        return {"text": json.dumps({"dates": dates, "document_date": doc})}

    def test_own_date_needs_its_year_written_in_a_quote(self):
        ok, own, written = U.own_date(self.rec([{"quote": "March 3, 1968", "year": 1968}], {"year": 1968}))
        self.assertEqual((ok, own, written), (True, 1968, [1968]))

    def test_a_supplied_year_not_on_the_page_is_not_an_own_date(self):
        ok, own, written = U.own_date(self.rec([{"quote": "March 3", "year": 1968}], {"year": 1968}))
        self.assertEqual((ok, own, written), (True, None, []))

    def test_no_document_date_is_none_even_with_dates_quoted(self):
        self.assertIsNone(U.own_date(self.rec([{"quote": "1954", "year": 1954}], None))[1])

    def test_an_unparsed_reply(self):
        self.assertEqual(U.own_date({"text": "nothing"}), (False, None, []))


class Wilson(unittest.TestCase):
    def test_bounds(self):
        lo, hi = U.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.404, places=2)
        self.assertAlmostEqual(hi, 0.596, places=2)
        self.assertEqual(U.wilson(0, 0), (0.0, 0.0))


class Sheet(unittest.TestCase):
    def spans(self, s):
        return [s[a:b] for a, b in U.date_spans(s)]

    def test_date_like_strings(self):
        self.assertEqual(self.spans("Received May 12, 1967 at the office"), ["May 12, 1967"])
        self.assertEqual(self.spans("dated 5/12/67 and 12.5.1967"), ["5/12/67", "12.5.1967"])
        self.assertEqual(self.spans("Class of '67, 3 Dec 1954"), ["'67", "3 Dec 1954"])
        self.assertEqual(self.spans("Dec. 1967 report; September"), ["Dec. 1967", "September"])

    def test_not_date_like(self):
        self.assertEqual(self.spans("May we ask for 250 copies of item 3"), [])
        self.assertEqual(self.spans("phone 3210 or room 1234"), [])

    def test_box_is_the_union_of_the_words_the_date_overlaps(self):
        def w(t, x0, x1):
            return {"text": t, "quad": [[x0, .1], [x1, .1], [x1, .2], [x0, .2]]}
        ln = {"text": "Sent May 12, 1967 by hand", "quad": [[0, .1], [1, .1], [1, .2], [0, .2]],
              "words": [w("Sent", 0, .1), w("May", .15, .25), w("12", .3, .35), w("1967", .4, .5), w("by", .55, .6),
                        w("hand", .65, .8)]}
        got = U.date_boxes({"lines": [ln]})
        self.assertEqual([g["text"] for g in got], ["May 12, 1967"])
        self.assertEqual(got[0]["box"], [.15, .1, .35, .1])

    def test_falls_back_to_the_line_box_without_word_boxes(self):
        ln = {"text": "1967", "quad": [[.2, .3], [.6, .3], [.6, .4], [.2, .4]], "words": []}
        self.assertEqual(U.date_boxes({"lines": [ln]})[0]["box"], [.2, .3, .4, .1])

    def test_documents_are_the_false_years_and_seeded_controls(self):
        def r(i, du, y, own):
            return {"id": i, "set": "undated", "pages": [i], "app": {"y": y, "du": du}, "own": own}
        rs = ([r(f"f{i}", False, 1960, None) for i in range(3)] + [r("u", True, 1960, None)]
              + [r(f"c{i:02d}", False, 1970, 1970) for i in range(20)] + [r("x", False, 1971, 1970)])
        with mock.patch.object(U, "readable", return_value=True):
            a, n_false, n_same = U.sheet_documents(rs)
            b = U.sheet_documents(list(reversed(rs)))[0]
        self.assertEqual((n_false, n_same), (4, 20))   # "x" has a different own year: a false year
        self.assertEqual(sum(g == "control" for _, g in a), U.N_CONTROLS)
        self.assertEqual([d["id"] for d, _ in a], [d["id"] for d, _ in b])   # fixed by the seed, not the input order
        self.assertNotIn("u", [d["id"] for d, _ in a])


class Fold(unittest.TestCase):
    def test_rulings(self):
        self.assertEqual(U.owner_ruling({"date": "yes", "year": "1962"}), {"own": True, "lo": 1962, "hi": 1962})
        self.assertEqual(U.owner_ruling({"date": "yes", "year": "1965-1967"}), {"own": True, "lo": 1965, "hi": 1967})
        self.assertFalse(U.owner_ruling({"date": "yes", "note": "citations only"})["own"])   # yes with no year
        self.assertFalse(U.owner_ruling({"date": "no"})["own"])
        self.assertIsNone(U.owner_ruling({"date": "cannot tell", "year": "1970"})["own"])
        self.assertIsNone(U.owner_ruling(None)["own"])

    def doc(self, group, app, pass_own, ans):
        return {"group": group, "app_year": app, "app_date_uncertain": False, "pass_own_year": pass_own,
                "owner": U.owner_ruling(ans)}

    def test_counts_and_restated_rate(self):
        docs = {"a": self.doc("false year", 1962, None, {"date": "yes", "year": "1962"}),        # pass missed, app right
                "b": self.doc("false year", 1965, None, {"date": "yes", "year": "1965-1967"}),   # inside the range
                "c": self.doc("false year", 1967, None, {"date": "yes", "year": "1968"}),        # missed, app wrong
                "d": self.doc("false year", 1947, None, {"date": "yes"}),                        # citations only
                "e": self.doc("false year", 1963, None, {"date": "cannot tell"}),                # left out
                "f": self.doc("control", 1970, 1970, {"date": "yes", "year": "1970"}),
                "g": self.doc("control", 1971, 1971, {"date": "no"})}                            # pass invented
        f = U.owner_fold(docs, 90, 30, draws=2000)
        self.assertEqual(f["ruled"], 6)
        self.assertEqual(f["pass_missed"], [3, 4])
        self.assertEqual(f["app_matches_owner_missed"], [2, 3])
        self.assertEqual(f["confirmed_false"], [2, 4])
        self.assertEqual(f["pass_invented"], [1, 2])
        self.assertEqual(f["estimate"], 2 + 30 * 0.5)
        lo, hi = f["interval"]
        self.assertLess(lo, f["rate"])
        self.assertGreater(hi, f["rate"])
        self.assertEqual(f, U.owner_fold(docs, 90, 30, draws=2000))   # seeded


if __name__ == "__main__":
    unittest.main()
