"""W46.fix-seg-boxes offline tests: which gaps go to the owner, and how the rulings fold into the draft.
No corpus. Run: python3 -m unittest test_seg_boxes (from this directory)."""
import unittest

import seg_boxes as S


class Ruling(unittest.TestCase):
    def test_tagged_gap_asked_only_when_teacher_disagrees(self):
        self.assertFalse(S.gap_needs_ruling("new", 0.9))
        self.assertFalse(S.gap_needs_ruling("cont", 0.1))
        self.assertTrue(S.gap_needs_ruling("new", 0.2))
        self.assertTrue(S.gap_needs_ruling("cont", 0.5))   # 0.5 counts as new, as the agree rule reads it
        self.assertFalse(S.gap_needs_ruling("new", 0.5))
        self.assertTrue(S.gap_needs_ruling("cont", None))  # never judged: the owner rules it

    def test_rawls_gaps_beside_label_photos_are_not_asked(self):
        self.assertTrue(S.rawls_gap_needs_ruling(None, None))
        self.assertFalse(S.rawls_gap_needs_ruling("Folder", None))
        self.assertFalse(S.rawls_gap_needs_ruling(None, "Box"))

    def test_label_colours(self):
        self.assertEqual(S.label_of(["Unread", "John Rawls", "Red"]), "Box")
        self.assertEqual(S.label_of(["Purple"]), "Folder")
        self.assertIsNone(S.label_of(["Unread", "John Rawls"]))


class Fold(unittest.TestCase):
    rows = [{"n": 1, "draft": "Folder"}, {"n": 2, "draft": "New"}, {"n": 3, "draft": "Cont"},
            {"n": 4, "draft": "Cont"}, {"n": 5, "draft": "Cont"}]
    key = [{"id": "ra001", "right": 3}, {"id": "ra002", "right": 4}, {"id": "ra003", "right": 5}]

    def test_answers_applied_and_open_ones_kept(self):
        labs, open_ids = S.fold(self.rows, self.key, {"ra001": "new", "ra002": "same", "ra003": "unsure"})
        self.assertEqual(labs, [(1, "Folder"), (2, "New"), (3, "New"), (4, "Cont"), (5, "Cont")])
        self.assertEqual(open_ids, ["ra003"])

    def test_page_after_a_new_label_card_starts_a_document(self):
        labs, _ = S.fold(self.rows, self.key, {"ra001": "label", "ra002": "same", "ra003": "same"})
        self.assertEqual(labs[2:], [(3, "Folder"), (4, "New"), (5, "Cont")])


if __name__ == "__main__":
    unittest.main()
