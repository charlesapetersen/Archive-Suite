"""W46.fix-seg-scorers: the letter and layout cue columns on hand-made pages.
Run: <lab venv>/bin/python test_features_cues.py   (no bench data, no detector, no network)."""
import unittest

from features_cues import LAYOUT_FEATURES, LETTER_FEATURES, layout_features, letter_features

LETTER_END = "We hope to hear from you soon.\nSincerely yours,\nJohn Dean"
MEMO_P1 = "To: M. M. May\nFrom: J. Smith\nRe: the budget\nThe figures for March are attached."
MEMO_P2 = "To: M. M. May\nPage 2\nand the April figures follow below."


def lf(a, b):
    return dict(zip(LETTER_FEATURES, letter_features(a, b)))


def reg(label, y0=500.0):
    return {"label": label, "bbox": [y0, 100.0, y0 + 50, 900.0], "score": 0.9, "reading_order": 1}


class Letter(unittest.TestCase):
    def test_salutation_and_closing(self):
        f = lf(LETTER_END, "March 3, 1973\nDear Mr. Haldeman:\nThank you for your note.")
        self.assertEqual((f["g_salutation"], f["g_closing"], f["g_both"], f["g_running_header"]), (1, 1, 1, 0))

    def test_running_header_is_not_a_salutation(self):
        f = lf(MEMO_P1, MEMO_P2)
        self.assertEqual((f["g_salutation"], f["g_running_header"]), (0, 1))
        # The memo's first page after a letter: "To:" opens it, nothing repeats.
        f = lf(LETTER_END, MEMO_P1)
        self.assertEqual((f["g_salutation"], f["g_running_header"], f["g_both"]), (1, 0, 1))

    def test_short_repeats_are_not_headers(self):
        self.assertEqual(lf("2\nsome text here", "2\nmore text")["g_running_header"], 0)

    def test_blank_pages(self):
        self.assertEqual(letter_features(None, ""), [0.0, 0.0, 0.0, 0.0])


class Layout(unittest.TestCase):
    def test_title_top_and_text_only(self):
        f = dict(zip(LAYOUT_FEATURES, layout_features([reg("text")], [reg("doc_title", 80), reg("text")])))
        self.assertEqual((f["lay_next_title_top"], f["lay_next_doc_title"], f["lay_next_text_only"]), (1, 1, 0))
        f = dict(zip(LAYOUT_FEATURES, layout_features([reg("text")], [reg("text"), reg("number", 950)])))
        self.assertEqual((f["lay_next_title_top"], f["lay_next_text_only"], f["lay_hist_l1"]), (0, 1, 1.0))

    def test_a_low_header_is_not_top(self):
        f = dict(zip(LAYOUT_FEATURES, layout_features([], [reg("header", 600)])))
        self.assertEqual(f["lay_next_title_top"], 0)
        self.assertEqual(f["lay_next_text_only"], 0)

    def test_empty_page(self):
        f = layout_features([], [])
        self.assertEqual(len(f), len(LAYOUT_FEATURES))
        self.assertEqual(f[2], 0.0)   # an empty page is not "text only"


if __name__ == "__main__":
    unittest.main()
