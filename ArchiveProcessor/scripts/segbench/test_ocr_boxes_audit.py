"""Box handoff checks, on synthetic data: no model, corpus or network."""
import unittest
import ocr_boxes_audit as A


class Geometry(unittest.TestCase):
    def box(self, coords, units='unlimited-999'):
        return {'box': coords, 'units': units}

    def test_range_depends_on_the_models_coordinate_system(self):
        self.assertEqual(A.geometry(self.box([0, 0, 999, 999])), set())
        self.assertEqual(A.geometry(self.box([0, 0, 2, 1], 'nemotron-canvas-1')), {'out_of_range'})
        self.assertEqual(A.geometry(self.box([0, 0, 500, 500], 'doctags-500')), set())

    def test_invalid_shapes_are_reported_without_fixing_them(self):
        self.assertEqual(A.geometry(self.box([3, 2, 1, 2])), {'reversed', 'zero_area'})
        self.assertEqual(A.geometry(self.box([0, 0, float('nan'), 1])), {'malformed'})
        self.assertEqual(A.geometry(self.box([0, 0, 1])), {'malformed'})
        self.assertEqual(A.geometry(self.box([0, 0, 1, 1], 'unknown')), {'malformed'})


class Identity(unittest.TestCase):
    def test_complete_run_requires_matching_job_and_image_identity(self):
        import json
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        contract = {'model': 'reader'}
        rec = {'id': 'p1', 'sha256': 'image', 'model': 'reader', 'job': '123',
               'status': 'ok', 'finish': 'stop', 'raw': 'synthetic', 'boxes': [], 'wall_s': 1}
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'cache-contract.json').write_text(json.dumps(contract))
            (root / 'status.json').write_text(json.dumps({'state': 'completed_raw', 'job': '123',
                'settings': contract, 'load_s': 1, 'wall_s': 1}))
            (root / 'pilot-summary.json').write_text(json.dumps({'wall_s': 0}))
            with patch.object(A.F, 'read_records', return_value={'p1': rec}):
                self.assertEqual(A.audit(root, {'p1': 'image'})['scored_outcomes'], {'ok': 1})
                for job in (None, '', 'wrong'):
                    rec['job'] = job
                    with self.assertRaises(ValueError): A.audit(root, {'p1': 'image'})
                rec['job'] = '123'
                with self.assertRaises(ValueError): A.audit(root, {'p1': 'changed'})
                with self.assertRaises(ValueError): A.audit(root, {'p1': 'image', 'p2': 'image'})
