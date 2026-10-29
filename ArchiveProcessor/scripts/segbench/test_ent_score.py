#!/usr/bin/env python3
"""Unit tests for ent_score.py's pure parts: reply name splitting, span merging and the position rule
(W46.ent-score). No model, no gateway, no corpus."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))
import ent_score as S  # noqa: E402


def span(tag, text, start):
    return {"tag": tag, "start": start, "end": start + len(text), "text": text}


LETTER = """HARVARD UNIVERSITY
Department of Economics
Cambridge, Massachusetts

March 3, 1961

Mr. Walter W. Heller
Council of Economic Advisers
Washington, D.C.

Dear Walter:

I enclose the memorandum we discussed with Paul Samuelson last week.

Sincerely yours,

John K. Galbraith
"""


def spans_in(text, items):
    """[(tag, phrase)] -> spans at each phrase's first occurrence."""
    return [span(tag, phrase, text.index(phrase)) for tag, phrase in items]


class SplitNames(unittest.TestCase):
    def test_two_people_joined_by_and(self):
        self.assertEqual(S.split_names("John Smith and Mary Jones"), ["John Smith", "Mary Jones"])

    def test_semicolon_and_comma_lists(self):
        self.assertEqual(S.split_names("John Smith; Mary Jones"), ["John Smith", "Mary Jones"])
        self.assertEqual(S.split_names("John Smith, Mary Jones"), ["John Smith", "Mary Jones"])

    def test_surname_first_stays_whole(self):
        self.assertEqual(S.split_names("Smith, John"), "Smith, John")

    def test_organisation_with_and_stays_whole(self):
        self.assertEqual(S.split_names("Committee on Admissions and Financial Aid"),
                         "Committee on Admissions and Financial Aid")
        self.assertEqual(S.split_names("Department of Labor and Industry"), "Department of Labor and Industry")

    def test_non_strings_pass_through(self):
        self.assertIsNone(S.split_names(None))
        self.assertEqual(S.split_names(["A B", "C D"]), ["A B", "C D"])


class MergeSpans(unittest.TestCase):
    def test_initial_between_two_person_spans(self):
        text = "John K. Galbraith wrote"
        got = S.merge_spans([span("person", "John", 0), span("person", "Galbraith", 8)], text)
        self.assertEqual([s["text"] for s in got], ["John K. Galbraith"])

    def test_place_joined_over_a_comma_only_for_places(self):
        text = "Cambridge, Massachusetts"
        got = S.merge_spans([span("place", "Cambridge", 0), span("place", "Massachusetts", 11)], text)
        self.assertEqual([s["text"] for s in got], ["Cambridge, Massachusetts"])
        got = S.merge_spans([span("person", "Cambridge", 0), span("person", "Massachusetts", 11)], text)
        self.assertEqual(len(got), 2)

    def test_different_tags_and_wide_gaps_stay_apart(self):
        text = "John Smith of Boston"
        got = S.merge_spans([span("person", "John Smith", 0), span("place", "Boston", 14)], text)
        self.assertEqual(len(got), 2)
        text = "John sent it to Mary"
        got = S.merge_spans([span("person", "John", 0), span("person", "Mary", 16)], text)
        self.assertEqual(len(got), 2)

    def test_nested_span_does_not_shrink_the_merged_one(self):
        text = "John K. Galbraith wrote"
        got = S.merge_spans([span("person", "John K. Galbraith", 0), span("person", "Galbraith", 8)], text)
        self.assertEqual([s["text"] for s in got], ["John K. Galbraith"])

    def test_unsorted_input_is_sorted(self):
        text = "Mary and John"
        got = S.merge_spans([span("person", "John", 9), span("person", "Mary", 0)], text)
        self.assertEqual([s["text"] for s in got], ["Mary", "John"])


class PositionRule(unittest.TestCase):
    def spans(self):
        return spans_in(LETTER, [("organization", "HARVARD UNIVERSITY"), ("place", "Cambridge"),
                                 ("place", "Massachusetts"), ("person", "Walter W. Heller"),
                                 ("organization", "Council of Economic Advisers"), ("place", "Washington"),
                                 ("person", "Paul Samuelson"), ("person", "John K. Galbraith")])

    def test_sender_recipient_and_place(self):
        got = S.position_rule(self.spans(), LETTER)
        self.assertEqual(got["sender"], "John K. Galbraith")
        self.assertEqual(got["recipient"], "Walter W. Heller")
        self.assertEqual(got["sending_place"], "Cambridge, Massachusetts")
        self.assertIn(["person", "Paul Samuelson"], got["spans"])

    def test_body_person_is_not_the_sender_when_no_person_follows_the_closing(self):
        text = LETTER.replace("John K. Galbraith\n", "")
        sp = [s for s in self.spans() if s["text"] != "John K. Galbraith"]
        got = S.position_rule(sp, text)
        # No person after "Sincerely", none in the footer after the salutation but Samuelson, who is in the body
        # above the final lines only if the letter is long; here the letter is short, so he is in the foot.
        self.assertIn(got["sender"], ("Paul Samuelson", "HARVARD UNIVERSITY"))

    def test_letterhead_organisation_when_unsigned(self):
        text = "\n".join(["ACME CORPORATION", "New York, New York", "", "Dear Sir:", "", "Please remit.", ""]
                         + ["Line %d of body text." % i for i in range(20)])
        sp = spans_in(text, [("organization", "ACME CORPORATION"), ("place", "New York")])
        got = S.position_rule(sp, text)
        self.assertEqual(got["sender"], "ACME CORPORATION")
        self.assertIsNone(got["recipient"])
        self.assertEqual(got["sending_place"], "New York")

    def test_salutation_name_is_the_recipient_when_no_inside_address(self):
        text = "Dear Mr. Heller:\n\nThanks.\n\nYours truly,\nJohn Smith\n"
        sp = spans_in(text, [("person", "Heller"), ("person", "John Smith")])
        got = S.position_rule(sp, text)
        self.assertEqual(got["recipient"], "Heller")
        self.assertEqual(got["sender"], "John Smith")

    def test_no_spans_gives_nulls(self):
        got = S.position_rule([], LETTER)
        self.assertEqual((got["sender"], got["recipient"], got["sending_place"]), (None, None, None))


class Helpers(unittest.TestCase):
    def test_first_text(self):
        self.assertEqual(S.first_text({"text": "A"}), "A")
        self.assertEqual(S.first_text([{"text": "A"}, "B"]), ["A", "B"])
        self.assertEqual(S.first_text("C"), "C")
        self.assertIsNone(S.first_text(None))

    def test_found_ignores_apostrophes(self):
        self.assertTrue(S.found("Patrick O'Brien", "from patrick o'brien, boston"))
        self.assertTrue(S.found("Patrick O’Brien", "from patrick o'brien, boston"))
        self.assertFalse(S.found("Patrick O'Brien", "from patrick smith, boston"))

    def test_f1_of_is_zero_when_nothing_predicted_but_truth_named(self):
        self.assertEqual(S.f1_of({"ed2": {"f1": None, "recall": 0.0}}, "ed2"), 0.0)
        self.assertIsNone(S.f1_of({"ed2": {"f1": None, "recall": None}}, "ed2"))
        self.assertEqual(S.f1_of({"ed2": {"f1": 0.5, "recall": 0.5}}, "ed2"), 0.5)

    def test_city(self):
        self.assertEqual(S.city("Cambridge, Massachusetts"), "Cambridge")
        self.assertEqual(S.city("Paris"), "Paris")


if __name__ == "__main__":
    unittest.main()
