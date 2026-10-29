"""W46.fix-postcorrect-pack and W46.ocr-postcorrect: a pack's repeated ids, the reading a request carried and alignment
trimming, on hand-made requests.
Run: uv run --offline --with rapidfuzz python3 test_postcorrect.py   (no bench data, no cache, no network)."""
import unittest

from postcorrect import FAMILY, PROMPT_IMAGE, PROMPT_TEXT, reading_of, trim, unique_requests


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


class Trim(unittest.TestCase):
    reading = 'Tbe quick brown fox jumps over the lazy dog.'

    def test_drops_a_preamble_and_a_trailing_note(self):
        reply = 'Here is the corrected text:\nThe quick brown fox jumps over the lazy dog.\n\nNote: I fixed one word.'
        self.assertEqual(trim(self.reading, reply), 'The quick brown fox jumps over the lazy dog.')

    def test_keeps_a_corrected_first_word_whole(self):
        self.assertEqual(trim(self.reading, 'The quick brown fox jumps over the lazy dog.'),
                         'The quick brown fox jumps over the lazy dog.')

    def test_cuts_a_loop_that_runs_past_the_page(self):
        reply = self.reading + ' ' + ' '.join(['the end'] * 30)
        self.assertEqual(trim(self.reading, reply), self.reading)

    def test_leaves_an_unanchored_reply_alone(self):
        self.assertEqual(trim('abc', 'xyz'), 'xyz')


class Families(unittest.TestCase):
    def test_one_family_per_route_and_set(self):
        self.assertEqual(FAMILY[('owner96', 'qwen3-vl-8b')], 'FarmShare panel')
        self.assertEqual(len(FAMILY), 7)


if __name__ == '__main__':
    unittest.main()
