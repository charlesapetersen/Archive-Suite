#!/usr/bin/env python3
"""W46.ocr-input-colour-dropout: the colour cue, the channel, the dropout input and the mark layer on synthetic pages.

  ~/.local/share/visionocr-ocrlab/venv/bin/python -m unittest test_colour_dropout
"""
import unittest

import numpy as np

import colour_dropout as D

PAPER = (235, 228, 215)
BLACK, RED, BLUE = (30, 30, 35), (205, 40, 45), (40, 60, 190)


def page(h=600, w=450):
    return np.tile(np.array(PAPER, np.uint8), (h, w, 1))


def text(img, colour, top, bottom, left=40, right=410, pitch=18, stroke=4):
    """Rows of short strokes, like lines of type."""
    for y in range(top, bottom, pitch):
        for x in range(left, right, 9):
            img[y:y + stroke * 2, x:x + stroke] = colour
    return img


def stamp(img, colour, y0, y1, x0, x1, width=6):
    """A hollow rectangle with a bar across: a stamp's border and a letter stroke, over whatever is there."""
    img[y0:y0 + width, x0:x1] = colour
    img[y1 - width:y1, x0:x1] = colour
    img[y0:y1, x0:x0 + width] = colour
    img[y0:y1, x1 - width:x1] = colour
    img[(y0 + y1) // 2:(y0 + y1) // 2 + width, x0:x1] = colour
    return img


class Cue(unittest.TestCase):
    def test_red_stamp_over_black_text_is_a_stamp_page(self):
        img = stamp(text(page(), BLACK, 40, 560), RED, 200, 330, 100, 350)
        c = D.cue(img)
        self.assertEqual(c['class'], 'stamp', c)
        self.assertLess(abs(((c['hue'] - 0) + 180) % 360 - 180), 30)

    def test_red_text_alone_is_a_control(self):
        c = D.cue(text(page(), RED, 40, 560))
        self.assertEqual(c['class'], 'control', c)

    def test_black_text_alone_is_neither(self):
        self.assertIsNone(D.cue(text(page(), BLACK, 40, 560))['class'])

    def test_coloured_background_at_the_edge_is_not_a_mark(self):
        img = text(page(), BLACK, 40, 560)
        img[:, :30] = (40, 120, 60)   # a green table showing at the edge of the photo
        c = D.cue(img)
        self.assertEqual(c['mark_frac'], 0.)
        self.assertIsNone(c['class'])

    def test_stamp_in_a_margin_is_not_over_text(self):
        img = stamp(text(page(), BLACK, 300, 560), RED, 30, 150, 100, 350)
        self.assertLess(D.cue(img)['over'], D.STAMP_OVER)


class Arms(unittest.TestCase):
    def test_channel_is_where_the_mark_is_lightest(self):
        red = stamp(text(page(), BLACK, 40, 560), RED, 200, 330, 100, 350)
        blue = stamp(text(page(), BLACK, 40, 560), BLUE, 200, 330, 100, 350)
        self.assertEqual(D.channel(red)[0], 0)
        self.assertEqual(D.channel(blue)[0], 2)
        self.assertIsNone(D.channel(text(page(), BLACK, 40, 560))[0])

    def test_dropout_keeps_size_whitens_the_mark_and_keeps_black_text(self):
        img = stamp(text(page(), BLACK, 40, 560), RED, 200, 330, 100, 350)
        out = D.dropout(img, 0)
        self.assertEqual(out.shape, img.shape)
        self.assertGreater(out[202, 200, 0], 180)       # the stamp's border, in red ink
        self.assertLess(out[40, 41, 0], 60)              # a black stroke outside the stamp

    def test_mark_layer_holds_the_mark_and_not_the_text(self):
        img = stamp(text(page(), BLACK, 40, 560), RED, 200, 330, 100, 350)
        out = D.mark_layer(img, 0)
        self.assertEqual(out.shape, img.shape)
        self.assertLess(out[202, 200, 0], 60)            # the stamp is dark
        self.assertGreater(out[40, 41, 0], 220)          # black text is gone
        self.assertGreater(out[5, 5, 0], 220)            # paper is white


if __name__ == '__main__':
    unittest.main()
