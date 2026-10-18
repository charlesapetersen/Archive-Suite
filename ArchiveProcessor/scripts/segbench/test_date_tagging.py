#!/usr/bin/env python3
"""date_tagging.py's prompt is TagGenerator.generateTags' prompt, and its reply parsing keeps what the app keeps.

    python3 -m unittest test_date_tagging
"""
import re
import unittest

import date_tagging as D


def swift_prompt():
    """generateTags' multi-line literal with Swift's indentation rule applied and its three interpolations replaced
    by date_tagging's placeholders (the subject rule by the literal of its empty-vocabulary branch)."""
    with open(D.SWIFT, encoding="utf-8") as fh:
        src = fh.read()
    body = src[src.index("func generateTags("):src.index("func generateDateOnly(")]
    starts = [m.end() for m in re.finditer(r'let prompt = """\n', body)]
    assert len(starts) == 1, "generateTags must hold exactly one prompt literal"
    end = body.index('\n        """', starts[0])
    lines = body[starts[0]:end].split("\n")
    assert all(not l or l.startswith("        ") for l in lines)
    text = "\n".join(l[8:] for l in lines)
    text = text.replace(r"\(text.prefix(3000))", "{text}", 1)
    text = text.replace(r'\(contextText.isEmpty ? "(none)" : contextText)', "{context}", 1)
    m = re.search(r'\\\(vocabulary\.isEmpty \? "((?:[^"\\]|\\.)*)" : .*\)$', text, re.M)
    assert m, "the subject-rule interpolation changed shape"
    rule = m.group(1).replace('\\"', '"')
    text = text[:m.start()] + "{subject_rule}" + text[m.end():]
    assert "\\(" not in text, "an interpolation this test does not know about"
    return text, rule


class PromptIsTheApps(unittest.TestCase):
    def test_template_matches_swift(self):
        text, rule = swift_prompt()
        self.assertEqual(D.PROMPT.replace("{{", "{").replace("}}", "}"), text)
        self.assertEqual(D.SUBJECT_RULE, rule)

    def test_rendering(self):
        p = D.build_prompt("x" * 4000, "")
        self.assertIn("\n" + "x" * 3000 + "\n---", p)
        self.assertNotIn("x" * 3001, p)
        self.assertIn("---\n(none)\n---", p)
        self.assertIn('"year": "1987"', p)
        self.assertIn('{\n  "year"', p)


class ParseIsTheApps(unittest.TestCase):
    def resp(self, text):
        return {"candidates": [{"content": {"parts": [{"text": text}]}}]}

    def test_fenced_numeric_year_and_named_month(self):
        y, m, du, ok = D.app_parse(self.resp('```json\n{"year": 1968, "month": "March", "date_uncertain": false}\n```'))
        self.assertEqual((y, m, du, ok), ("1968", 3, False, True))

    def test_unparsable_is_uncertain_with_no_year(self):
        self.assertEqual(D.app_parse(self.resp("no json here")), (None, None, True, False))
        self.assertEqual(D.app_parse({}), (None, None, True, False))

    def test_null_month_and_spec_month(self):
        self.assertEqual(D.app_parse(self.resp('{"year": "1970", "month": null}'))[1], None)
        self.assertEqual(D.app_parse(self.resp('{"year": "1970", "month": "11 November"}'))[1], 11)


class Truth(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(D.truth_of(["1968", "03 March", "Unread"]), ("year+month", {"year": 1968, "month": 3, "du": False}))
        self.assertEqual(D.truth_of(["1968"])[0], "year")
        self.assertEqual(D.truth_of(["1968", "Date Uncertain"])[0], "year+DU")
        self.assertEqual(D.truth_of(["1970s"]), ("decade", {"decade": 1970, "du": False}))
        self.assertEqual(D.truth_of(["1968", "1969"])[0], "ambiguous")
        self.assertEqual(D.truth_of(["taxes"])[0], "undated")


class TrainingTarget(unittest.TestCase):
    """W41.date-model's target is a reply the app's parser reads back as the owner's date."""
    def resp(self, text):
        return {"candidates": [{"content": {"parts": [{"text": text}]}}]}

    def test_round_trips_through_app_parse(self):
        for tags in (["1968", "03 March"], ["1968"], ["1968", "Date Uncertain"], ["1968", "11 November", "Date Uncertain"]):
            _, truth = D.truth_of(tags)
            y, m, du, ok = D.app_parse(self.resp(D.target_of(truth)))
            self.assertEqual((y, m, du, ok), (str(truth["year"]), truth["month"], truth["du"], True))

    def test_month_is_the_apps_spelling(self):
        self.assertIn('"month": "03 March"', D.target_of({"year": 1968, "month": 3, "du": False}))
        self.assertIn('"month": null', D.target_of({"year": 1968, "month": None, "du": False}))


if __name__ == "__main__":
    unittest.main()


class OpenModels(unittest.TestCase):
    def test_reasoning_is_stripped_as_the_local_route_strips_it(self):
        import date_tagging as D
        self.assertEqual(D.strip_reasoning('<think>the year is 1968</think>\n{"year": "1968"}'), '{"year": "1968"}')
        self.assertEqual(D.strip_reasoning('a</think>{"year": "1970"}'), '{"year": "1970"}')   # opening tag cut off
        self.assertEqual(D.strip_reasoning('<think>never closed, all 512 tokens'), '<think>never closed, all 512 tokens')
        self.assertEqual(D.strip_reasoning('{"year": "1971"}'), '{"year": "1971"}')

    def test_an_unfinished_thought_is_an_unusable_reply(self):
        import date_tagging as D
        resp = {"candidates": [{"content": {"parts": [{"text": D.strip_reasoning("<think>the letter is dated")}]}}]}
        self.assertEqual(D.app_parse(resp), (None, None, True, False))   # no year, Date Uncertain, as the app writes
