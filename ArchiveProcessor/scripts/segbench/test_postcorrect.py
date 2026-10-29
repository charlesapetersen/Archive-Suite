"""W46.fix-postcorrect-pack: a pack's repeated ids and the reading a request carried, on hand-made requests.
Run: python3 test_postcorrect.py   (no bench data, no cache, no network)."""
import unittest

from postcorrect import FAMILY, PROMPT_IMAGE, PROMPT_TEXT, reading_of, unique_requests


def req(rid, reading, arm='image', **kw):
    prompt = (PROMPT_IMAGE if arm == 'image' else PROMPT_TEXT) + reading
    return {'id': rid, 'arm': arm, 'image': 'a.jpg' if arm == 'image' else None, 'image_sha256': 'h',
            'prompt': prompt, **kw}


class UniqueRequests(unittest.TestCase):
    def test_identical_repeat_is_kept_once_whatever_its_stored_score(self):
        rows = [req('a', 'x', nes=0.8), req('b', 'y'), req('a', 'x', nes=0.9)]
        uniq, repeats = unique_requests(rows)
        self.assertEqual([r['id'] for r in uniq], ['a', 'b'])
        self.assertEqual(repeats, 1)

    def test_repeat_with_a_different_reading_is_refused(self):
        with self.assertRaises(SystemExit):
            unique_requests([req('a', 'x'), req('a', 'z')])

    def test_repeat_with_a_different_image_is_refused(self):
        other = req('a', 'x'); other['image_sha256'] = 'g'
        with self.assertRaises(SystemExit):
            unique_requests([req('a', 'x'), other])


class ReadingOf(unittest.TestCase):
    def test_strips_the_arms_instruction(self):
        self.assertEqual(reading_of(req('a', 'line one\nline two', arm='text')), 'line one\nline two')

    def test_refuses_another_arms_prompt(self):
        r = req('a', 'x', arm='text'); r['arm'] = 'image'
        with self.assertRaises(SystemExit):
            reading_of(r)


class Families(unittest.TestCase):
    def test_one_family_per_route_and_set(self):
        self.assertEqual(FAMILY[('owner96', 'qwen3-vl-8b')], 'FarmShare panel')
        self.assertEqual(len(FAMILY), 7)


if __name__ == '__main__':
    unittest.main()
