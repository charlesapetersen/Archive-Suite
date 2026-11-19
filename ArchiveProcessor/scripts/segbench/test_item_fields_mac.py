#!/usr/bin/env python3
"""W47.wh-item-fields-mac: the Mac prompts are the image prompt word for word, and the Mac readers' text swaps in
LightOnOCR on the hand pages only.

    python3 -m unittest test_item_fields_mac
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_fields_mac as M  # noqa: E402
import item_fields_retruth as IR  # noqa: E402


class Prompt(unittest.TestCase):
    def test_text_prompt_differs_only_in_its_opening(self):
        self.assertEqual(M.TEXT_PROMPT.replace(M.TEXT_OPENING, M.IMAGE_OPENING), IR.PROMPT)
        self.assertNotIn("Read the images", M.TEXT_PROMPT)

    def test_image_input_keeps_the_image_prompt(self):
        d = {"id": "x", "part": "base", "pages": ["a.pdf"]}
        with mock.patch.object(IR, "doc_text", return_value="TEXT"):
            self.assertEqual(M.prompt_of(d, "image"), IR.PROMPT.replace("{text}", "TEXT"))
            self.assertEqual(M.prompt_of(d, "vision"), M.TEXT_PROMPT.replace("{text}", "TEXT"))


class MacText(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = mock.patch.object(M, "CACHE", self.tmp.name)
        self.p.start()

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def put(self, page, text):
        M.save(M.lighton_path(page), {"text": text})

    def test_hand_pages_read_by_lighton(self):
        self.put("h1.pdf", "Dear Sam")
        d = {"id": "h", "part": "handwritten", "pages": ["h1.pdf"]}
        with mock.patch.object(IR, "doc_text", return_value="VISION"):
            self.assertEqual(M.doc_text(d, "mac"), "[page 1 of 1]\nDear Sam")
            self.assertEqual(M.doc_text(d, "vision"), "VISION")
            self.assertEqual(M.doc_text({**d, "part": "base"}, "mac"), "VISION")

    def test_mac_reading_falls_back_to_vision_outside_the_hand_part(self):
        rec = {"raw": json.dumps({"kind": "letter", "recipient_place": ["Boston, MA"]})}
        M.save(M.reading_path("qwen3.5-4b", "vision", "b"), rec)
        with mock.patch.object(M, "hand_ids", return_value={"h"}):
            self.assertEqual(M.reading("qwen3.5-4b", "mac", "b")["kind"], "letter")
            self.assertIsNone(M.reading("qwen3.5-4b", "mac", "h"))

    def test_unparsed_reply_fills_nothing(self):
        M.save(M.reading_path("qwen3.5-4b", "image", "u"), {"raw": "no json here"})
        r = M.reading("qwen3.5-4b", "image", "u")
        self.assertTrue(all(v is None for v in r.values()))


if __name__ == "__main__":
    unittest.main()
