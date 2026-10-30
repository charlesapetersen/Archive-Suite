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

    def test_untagged_gaps_beside_label_photos_are_not_asked(self):
        self.assertTrue(S.untagged_gap_needs_ruling(None, None))
        self.assertFalse(S.untagged_gap_needs_ruling("Folder", None))
        self.assertFalse(S.untagged_gap_needs_ruling(None, "Box"))

    def test_label_colours(self):
        self.assertEqual(S.label_of(["Unread", "Michael Young", "Red"]), "Box")
        self.assertEqual(S.label_of(["Purple"]), "Folder")
        self.assertIsNone(S.label_of(["Unread", "Michael Young"]))


class ArticleRule(unittest.TestCase):
    reading = [{"n": 1, "issue": "1921-01", "kind": "masthead_contents", "starts": True},
               {"n": 2, "issue": "1921-01", "kind": "article_start", "starts": True},
               {"n": 3, "issue": "1921-01", "kind": "article_cont", "starts": False},
               {"n": 4, "issue": "1926-02", "kind": "article_start", "starts": True},
               {"n": 5, "issue": "1926-01", "kind": "cover", "starts": True},
               {"n": 6, "issue": "1926-01", "kind": "article_start", "starts": True},
               {"n": 7, "issue": None, "kind": "ads", "starts": False}]

    def test_only_a_byte_identical_repeat_goes_unasked(self):
        self.assertFalse(S.article_gap_needs_ruling("ab", "ab"))
        self.assertTrue(S.article_gap_needs_ruling("ab", "cd"))

    def test_each_photo_gets_its_own_issues_front(self):
        self.assertEqual(S.issue_fronts(self.reading), {1: 1, 2: 1, 3: 1, 4: None, 5: 5, 6: 5, 7: None})

    def test_article_starts_from_the_reading(self):
        self.assertEqual(S.article_draft(self.reading, {}),
                         {1: "New", 2: "New", 3: "Cont", 4: "New", 5: "New", 6: "New", 7: "Cont"})

    def test_fallback_issue_is_one_document(self):
        d = S.article_draft(self.reading, {"1926-01": "interleaved"})
        self.assertEqual((d[4], d[5], d[6]), ("New", "New", "Cont"))   # its first photo still starts it


class Fold(unittest.TestCase):
    rows = [{"n": 1, "draft": "Folder"}, {"n": 2, "draft": "New"}, {"n": 3, "draft": "Cont"},
            {"n": 4, "draft": "Cont"}, {"n": 5, "draft": "Cont"}]
    key = [{"id": "ra001", "right": 3}, {"id": "ra002", "right": 4}, {"id": "ra003", "right": 5}]

    def test_answers_applied_and_open_ones_kept(self):
        labs, open_ids = S.fold(self.rows, self.key, {"ra001": "new", "ra002": "same", "ra003": "unsure"})
        self.assertEqual(labs, [(1, "Folder"), (2, "New"), (3, "New"), (4, "Cont"), (5, "Cont")])
        self.assertEqual(open_ids, ["ra003"])

    def test_fallback_answer_keeps_the_photo_with_its_issue(self):
        labs, open_ids = S.fold(self.rows, self.key, {"ra001": "fallback", "ra002": "new", "ra003": "same"})
        self.assertEqual(labs[2:], [(3, "Cont"), (4, "New"), (5, "Cont")])
        self.assertEqual(open_ids, [])

    def test_page_after_a_new_label_card_starts_a_document(self):
        labs, _ = S.fold(self.rows, self.key, {"ra001": "label", "ra002": "same", "ra003": "same"})
        self.assertEqual(labs[2:], [(3, "Folder"), (4, "New"), (5, "Cont")])


if __name__ == "__main__":
    unittest.main()
