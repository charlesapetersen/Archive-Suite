"""W46.seg-magazine-rule-redo: g2 differs from g1 only in rule 10, and the scorer's prompt arms nest and restore.

    ~/.local/share/visionocr-ocrlab/venv/bin/python -m unittest test_seg_magazine_rule
"""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import method_gemini as G  # noqa: E402
import method_whole as H  # noqa: E402
import seg_magazine_rule as R  # noqa: E402


class PromptTest(unittest.TestCase):
    def test_g2_is_g1_with_rule_10_rewritten(self):
        self.assertEqual(G.PROMPTS["g1"], G.PROMPT)
        self.assertEqual(G.PROMPT.count(G.RULE10_G1), 1)
        self.assertNotIn(G.RULE10_G1, G.PROMPT_G2)
        self.assertEqual(G.PROMPT_G2.count(G.RULE10_G2), 1)
        self.assertEqual(G.PROMPT_G2.replace(G.RULE10_G2, G.RULE10_G1), G.PROMPT)

    def test_g2_states_the_article_rule_and_its_fallback(self):
        for words in ("split by article", "advertisement", "cover to end", "interleaved"):
            self.assertIn(words, " ".join(G.RULE10_G2.split()))

    def test_wh2_is_wh1_with_the_same_rule(self):
        self.assertEqual(H.PROMPT_WH2.replace(G.RULE10_G2, G.RULE10_G1), H.PROMPT)
        self.assertNotIn(G.RULE10_G1, H.PROMPT_WH2)

    def test_g2_formats_like_g1(self):
        kw = dict(k=2, texts="t", gaps="[1, 2]", max_text=10, pages="1, 2")
        self.assertEqual(G.PROMPT_G2.format(**kw).replace(G.RULE10_G2, G.RULE10_G1), G.PROMPT.format(**kw))


class ArmTest(unittest.TestCase):
    def test_arms_nest_and_restore(self):
        with R.arm("g1") as (_, _, S, _):
            self.assertIs(G.PROMPT, G.PROMPTS["g1"])
            self.assertEqual(S.STORE, R.SB.STORE)
            with R.arm("g2"):
                self.assertIs(G.PROMPT, G.PROMPTS["g2"])
                self.assertEqual((S.STORE, S.CAP), (R.STORE, R.CAP))
            self.assertIs(G.PROMPT, G.PROMPTS["g1"])
            self.assertEqual((S.STORE, S.CAP), (R.SB.STORE, R.SB.CAP))
        with R.arm("g2") as (_, _, S, _):
            with R.arm("g1"):
                pass
            self.assertIs(G.PROMPT, G.PROMPTS["g2"])
            self.assertEqual(S.STORE, R.STORE)
        self.assertIs(G.PROMPT, G.PROMPTS["g1"])


if __name__ == "__main__":
    unittest.main()
