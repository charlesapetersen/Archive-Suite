import unittest
from pathlib import Path

from farmshare_expanded_report import parse_route
from farmshare_results import reading


class Routes(unittest.TestCase):
    def test_route_spec_keeps_colons_and_spaces_in_the_path(self):
        self.assertEqual(parse_route('glm-ocr=/Long term storage/a:b/glm:native'),
                         ('glm-ocr', Path('/Long term storage/a:b/glm'), 'native'))
        self.assertEqual(parse_route('q=/x/y:panel'), ('q', Path('/x/y'), 'panel'))
        self.assertEqual(parse_route('q=/x/y'), ('q', Path('/x/y'), 'panel'))

    def test_bad_spec_is_refused(self):
        with self.assertRaises(SystemExit):
            parse_route('no-equals-sign')

    def test_native_reads_raw_and_panel_parses_and_caps_fail(self):
        ok = {'status': 'ok', 'finish': 'stop', 'raw': '# Title\nbody'}
        self.assertEqual(reading(ok, 'native'), '# Title\nbody')
        self.assertEqual(reading(ok, 'panel'), '')  # not a KIND/TABLE/TEXT reply
        panel = {'status': 'ok', 'finish': 'stop', 'raw': 'KIND: printed\nTABLE: no\nTEXT:\nbody'}
        self.assertEqual(reading(panel, 'panel'), 'body')
        self.assertEqual(reading({'status': 'cap', 'finish': 'length', 'raw': 'loop loop'}, 'native'), '')
        self.assertEqual(reading(None, 'native'), '')


if __name__ == '__main__':
    unittest.main()
