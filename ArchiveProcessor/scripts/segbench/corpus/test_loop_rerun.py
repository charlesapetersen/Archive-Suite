"""Offline tests for W46.ocr-loops' cluster collector: the two arms' requests and the half-size image."""
import io
import unittest

from PIL import Image

import loop_rerun_cluster as L


class Arms(unittest.TestCase):
    def test_ngram_asks_for_the_processor_and_half_does_not(self):
        b = L.body('ngram', 'OCR:', b'x', 'm')
        self.assertEqual(b['vllm_xargs'], {'ngram_size': 4, 'window_size': 8192})
        self.assertEqual(b['temperature'], 0)
        self.assertEqual(b['max_tokens'], 8192)
        self.assertNotIn('vllm_xargs', L.body('half', 'OCR:', b'x', 'm'))

    def test_empty_prompt_sends_the_image_alone(self):
        content = L.body('half', '', b'x', 'm')['messages'][0]['content']
        self.assertEqual([c['type'] for c in content], ['image_url'])
        content = L.body('half', 'Text Recognition:', b'x', 'm')['messages'][0]['content']
        self.assertEqual(content[1], {'type': 'text', 'text': 'Text Recognition:'})

    def test_half_halves_the_long_edge(self):
        buf = io.BytesIO(); Image.new('RGB', (2400, 1601), 'white').save(buf, 'JPEG', quality=90)
        data, size = L.half(buf.getvalue())
        self.assertEqual(size, (1200, 800))
        self.assertEqual(Image.open(io.BytesIO(data)).size, (1200, 800))


if __name__ == '__main__':
    unittest.main()
