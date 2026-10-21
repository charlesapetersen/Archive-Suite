"""W46.fix-ocr-scorers: chaos_probe.py's word choice, cell cut and verdicts on synthetic input. Run:
uv run --offline --with pillow --with numpy --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex \
    python -m unittest test_chaos_probe"""
import unittest

from PIL import Image, ImageDraw

import chaos_probe as C


class Words(unittest.TestCase):
    def test_candidates(self):
        truth = 'The committee, met to consider proposal again and the proposal was clear'
        boxes = [[w, 0, 0, .1, .01] for w in ('committee,', 'consider', 'proposal', 'clear')]
        # 'committee,' carries punctuation, 'proposal' occurs twice, 'clear' is short
        self.assertEqual([b[0] for b in C.candidates('p', boxes, truth)], ['consider'])

    def test_verdict(self):
        self.assertEqual(C.verdict(['the', 'commuttee'], 'committee', 'commuttee'), 'copied')
        self.assertEqual(C.verdict(['the', 'Committee'], 'committee', 'commuttee'), 'corrected')
        self.assertEqual(C.verdict(['the'], 'committee', 'commuttee'), 'other')
        # 'Committee' also printed elsewhere on the page: one occurrence is expected, so it is not a correction
        self.assertEqual(C.verdict(['Committee', 'comxittee'], 'committee', 'commuttee', expected=1), 'other')
        self.assertEqual(C.verdict(['Committee', 'committee'], 'committee', 'commuttee', expected=1), 'corrected')


def paper():
    """Light grey paper with a little grain, as a photograph has: cells() thresholds by Otsu, which needs it."""
    im = Image.new('RGB', (400, 40), (230, 230, 230))
    for x in range(0, 400, 3):
        for y in range(0, 40, 3):
            im.putpixel((x, y), (215, 215, 215))
    return im


def ink(im, box):
    """A block of type in two shades (Otsu's first maximum lands on the darker one's upper edge)."""
    d = ImageDraw.Draw(im)
    d.rectangle(box, fill=(45, 45, 45))
    for y in range(box[1], box[3] + 1, 2):
        d.line((box[0], y, box[2], y), fill=(30, 30, 30))


class Cells(unittest.TestCase):
    def test_fixed_pitch_accepted_and_trimmed(self):
        im = paper()
        for i in range(6):  # six glyph blocks on a 20 px pitch, gaps between
            ink(im, (50 + 20 * i + 3, 10, 50 + 20 * i + 16, 30))
        cs = C.cells(['abcdef', 40 / 400, 5 / 40, 150 / 400, 30 / 40], im)
        self.assertIsNotNone(cs)
        self.assertEqual(len(cs), 6)
        self.assertEqual(cs[0][0], 53)  # trimmed to the first ink column

    def test_solid_word_refused(self):
        im = paper()
        ink(im, (50, 10, 170, 30))  # no gaps: not fixed-pitch letters
        self.assertIsNone(C.cells(['abcdef', 40 / 400, 5 / 40, 150 / 400, 30 / 40], im))


if __name__ == '__main__':
    unittest.main()
