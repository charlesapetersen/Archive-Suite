"""uv run --with rapidfuzz --with pillow --with regex --with sacrebleu python -m unittest test_mixed_route_bands"""
import unittest

import mixed_route_bands as B


def mark(cls, text="", status="owner_reviewed"):
    return dict(cls=cls, text=text, transcription_status=status)


class OwnerBand(unittest.TestCase):
    def test_no_marks_or_stamps_only(self):
        self.assertEqual(B.owner_band([]), ("none", 0))
        self.assertEqual(B.owner_band([mark("stamp", "SEP 3 1971"), mark("other", "W. D. Instructions")]), ("none", 0))

    def test_signature_only(self):
        self.assertEqual(B.owner_band([mark("signature_initials", status="label_only")]), ("signature", 0))

    def test_date_only_notes(self):
        self.assertEqual(B.owner_band([mark("annotation", "March 29, 1983")])[0], "signature")
        self.assertEqual(B.owner_band([mark("annotation", "7-22-79"), mark("marginal_note", "1974")])[0], "signature")
        self.assertEqual(B.owner_band([mark("annotation", "No 7-7-71 br")])[0], "few")

    def test_word_bands(self):
        self.assertEqual(B.owner_band([mark("annotation", "one two three")]), ("few", 3))
        self.assertEqual(B.owner_band([mark("annotation", " ".join(["w"] * 9))])[0], "few")
        self.assertEqual(B.owner_band([mark("annotation", " ".join(["w"] * 10))])[0], "passage")
        self.assertEqual(B.owner_band([mark("annotation", " ".join(["w"] * 20)),
                                       mark("marginal_note", " ".join(["w"] * 10))]), ("long", 30))

    def test_stamp_words_do_not_count(self):
        self.assertEqual(B.owner_band([mark("annotation", "two words"), mark("stamp", " ".join(["w"] * 50))]),
                         ("few", 2))

    def test_unread_handwriting_has_no_band(self):
        self.assertEqual(B.owner_band([mark("annotation", "a b c d e f g h i j k l"),
                                       mark("marginal_note", status="unread")]), ("unread", None))
        # an unread stamp or signature does not hide a known band
        self.assertEqual(B.owner_band([mark("annotation", "two words"), mark("stamp", status="unread")])[0], "few")


if __name__ == "__main__":
    unittest.main()
