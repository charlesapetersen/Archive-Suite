#!/usr/bin/env python3
"""The dating route's shared cases (fixtures/date-route-cases.json, which DateRouteTestDriver runs against the app's
Swift port) are what the bench's own code gives now, and the Swift literals are the bench's prompts.

    python3 -m unittest test_date_route_cases
"""
import json
import os
import re
import unittest

import date_image as DI
import date_route_cases as C
import date_traceable as T

SWIFT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "macOS", "Sources", "ArchiveProcessor",
                     "Tagging", "DateRoute.swift")


class Cases(unittest.TestCase):
    def test_fixture_is_current(self):
        want = json.dumps(C.synthetic(), ensure_ascii=False, indent=1) + "\n"
        with open(C.FIXTURE, encoding="utf-8") as f:
            self.assertEqual(f.read(), want, "run date_route_cases.py to rewrite the fixture")

    def test_every_step_is_covered(self):
        got = {(c["expect"]["route"]["cls"], c["expect"]["route"]["du"]) for c in C.synthetic()}
        for want in [("text", False), ("text", True), ("image", False), ("estimate", True), ("none", True)]:
            self.assertIn(want, got)

    def test_swift_literals(self):
        src = open(SWIFT, encoding="utf-8").read()
        m = re.search(r'static let traceTemplate = """\n(.*?)\n    """', src, re.S)
        self.assertIsNotNone(m)
        body = "\n".join(line[4:] if line.startswith("    ") else line for line in m.group(1).split("\n"))
        self.assertEqual(body, T.TRACE.replace("{{", "{").replace("}}", "}"))
        for part in ("These are the first pages of one archival document", "Use null for an unknown month or year"):
            self.assertIn(part, DI.PROMPT)
            self.assertIn(part, src)


if __name__ == "__main__":
    unittest.main()
