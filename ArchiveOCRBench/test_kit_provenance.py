"""The published kit panel must carry the source-validated owner support and truth limits."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build


class KitProvenance(unittest.TestCase):
    def test_panel_keeps_owner_support_and_draft_qualification(self):
        panel = build.seg_kit_gate_sherlock()
        sc = panel['sc0122_owner']
        self.assertEqual((sc['asked_known'], sc['controls'], sc['agreed_doc_gaps']), (30, 60, 158))
        self.assertEqual(len(sc['models']), 3)
        self.assertTrue(all('teacher-drafted' in r['truth'] and 'conditional' in r['interpretation']
                            for r in panel['boxes'] if r['box'] == 'SC0122'))
        self.assertAlmostEqual(sc['models']['fs-seg-2b']['owner_weighted_accuracy'], .9813829787234043)

    def test_build_refuses_missing_or_stale_provenance(self):
        record = json.loads((build.RESULTS / 'seg-kit-gate-sherlock.json').read_text())
        source = (build.RESULTS / 'seg-boxes-score-local.json').read_bytes()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'seg-boxes-score-local.json').write_bytes(source)
            for change in ('missing', 'stale'):
                bad = deepcopy(record)
                if change == 'missing':
                    bad['boxes'].pop('sc0122_owner')
                else:
                    bad['boxes']['sc0122_owner']['source_sha256'] = 'old'
                (root / 'seg-kit-gate-sherlock.json').write_text(json.dumps(bad))
                with self.subTest(change=change), patch.object(build, 'RESULTS', root):
                    with self.assertRaisesRegex(SystemExit, 'stale provenance'):
                        build.seg_kit_gate_sherlock()


if __name__ == '__main__':
    unittest.main()
