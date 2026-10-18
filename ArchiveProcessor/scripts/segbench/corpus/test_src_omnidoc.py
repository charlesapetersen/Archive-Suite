import unittest

import src_omnidoc as O


def page(*blocks):
    return {'layout_dets': [dict(zip(('category_type', 'order', 'text'), b)) for b in blocks]}


class Truth(unittest.TestCase):
    def test_blocks_in_order_figures_allowed(self):
        p = page(('text_block', '2', '第二'), ('title', '0', '題'), ('figure', None, ''), ('abandon', '1', ''),
                 ('text_block', '1', '第一'))
        self.assertEqual(O.truth(p), '題\n\n第一\n\n第二')

    def test_pages_left_out(self):
        for bad in (('table', '1', '<table>'), ('equation_isolated', '1', 'x^2'), ('text_mask', None, ''),
                    ('text_block', '1', '面积 $S$')):
            self.assertIsNone(O.truth(page(('text_block', '0', '正文'), bad)), bad)
        self.assertIsNone(O.truth(page(('figure', None, ''))))

    def test_unordered_peripheral_text_is_not_lost(self):
        p = page(('text_block', 1, '正文'), ('page_number', None, '54'),
                 ('header', None, '題頭'), ('footer', None, '刊名'))
        p['layout_dets'][1]['poly'] = [0, 900, 20, 900, 20, 920, 0, 920]
        p['layout_dets'][3]['poly'] = [0, 850, 20, 850, 20, 870, 0, 870]
        self.assertEqual(O.truth(p), '題頭\n\n正文\n\n刊名\n\n54')
        self.assertIsNone(O.truth(page(('text_block', 1, '正文'), ('footer', None, '$x$'))))


if __name__ == '__main__':
    unittest.main()
