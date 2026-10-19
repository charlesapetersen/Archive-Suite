"""Cache correctness across growth: no network or inference needed."""
from pathlib import Path
import json
import tempfile
import unittest

from farmshare_incremental import bind, cached


class IncrementalCache(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory()
        self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        self.row = {'id': 'source__page1', 'sha256': 'image-one'}
        self.record = {**self.row, 'model': 'pinned-model', 'mode': 'panel',
                       'status': 'ok', 'raw': 'Saved reading'}
        self.path = self.root / 'source__page1.json'
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.record))

    def test_expanding_manifest_reuses_old_page_without_rewriting(self):
        before = self.path.read_bytes()
        found = cached([self.row, {'id': 'source__page2', 'sha256': 'image-two'}], self.root, 'pinned-model')
        self.assertEqual(list(found), ['source__page1'])
        self.assertEqual(self.path.read_bytes(), before)

    def test_truth_revision_does_not_invalidate_the_reading(self):
        row = {**self.row, 'truth_sha256': 'corrected-truth'}
        self.assertIn(row['id'], cached([row], self.root, 'pinned-model'))

    def test_changed_image_or_model_is_refused(self):
        for row, model in [({**self.row, 'sha256': 'other-image'}, 'pinned-model'),
                           (self.row, 'other-model')]:
            with self.assertRaisesRegex(ValueError, 'differs'):
                cached([row], self.root, model)

    def test_capped_reply_is_terminal_but_transport_error_is_not(self):
        self.record['status'] = 'cap'
        self.write()
        self.assertIn(self.row['id'], cached([self.row], self.root, 'pinned-model'))
        self.path.rename(self.root / 'source__page1.error.json')
        self.assertEqual(cached([self.row], self.root, 'pinned-model'), {})

    def test_settings_change_never_silently_adopts_cached_answers(self):
        path = self.root / 'contract.json'
        config = {'prompt_sha256': 'one', 'revision': 'pinned', 'max_tokens': 8192}
        bind(path, config)
        before = path.read_bytes()
        bind(path, config)
        self.assertEqual(path.read_bytes(), before)
        for change in [{'prompt_sha256': 'two'}, {'revision': 'changed'}, {'max_tokens': 16384}]:
            with self.assertRaisesRegex(ValueError, 'settings changed'):
                bind(path, {**config, **change})
            self.assertEqual(path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
