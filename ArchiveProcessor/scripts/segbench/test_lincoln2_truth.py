"""W46.seg-adapt-lora: the second Lincoln box's truth may only claim a continuation where Gemini said "same"."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import lincoln2_truth as T
import lincoln_box2 as B
import public_segmentation as PS


class Lincoln2Truth(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "public"
        manifests, store = Path(tmp.name) / "manifests", Path(tmp.name) / "store"
        manifests.mkdir()
        for patch in (mock.patch.object(PS, "MANIFESTS", manifests), mock.patch.object(T, "STORE", store)):
            patch.start()
            self.addCleanup(patch.stop)
        # Two catalogue items: a (4 pages) and b (2 pages): within-item gaps 1|2 2|3 3|4 and 5|6.
        pages, n = [], 0
        for item, count in (("mal1000000", 4), ("mal1000100", 2)):
            for j in range(1, count + 1):
                n += 1
                image = self.root / f"boxes/Lincoln2/{n:04}.jpg"
                image.parent.mkdir(parents=True, exist_ok=True)
                image.write_bytes(f"page {n}".encode())
                pages.append({"n": n, "id": item, "page": j, "image": str(image.relative_to(self.root)),
                              "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                              "label": "New" if j == 1 else "Cont", "reviewed": False})
        draft = {"box": "Lincoln2", "pages": pages, "audit": {},
                 "source_documents": [{"id": "mal1000000", "pages": 4, "title": "A to Lincoln"},
                                      {"id": "mal1000100", "pages": 2, "title": "B to Lincoln"}]}
        (manifests / "lincoln2-draft.json").write_text(json.dumps(draft))

    def reply(self, a, b, raw):
        p = T.reply_path(a, b)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"raw": raw}))

    def test_catalogue_starts_are_never_asked(self):
        self.assertEqual([(a, b) for a, b, _ in T.gaps(T.box(self.root))], [(1, 2), (2, 3), (3, 4), (5, 6)])

    def test_only_same_is_a_continuation(self):
        self.reply(1, 2, '{"decision": "same", "why": "letter continues"}')
        self.reply(2, 3, '```json\n{"decision": "new", "why": "enclosed clipping"}\n```')
        self.reply(3, 4, '{"decision": "unsure"}')
        self.reply(5, 6, 'not json')          # unparsable: never a continuation
        T.freeze(self.root)
        m = json.loads((PS.MANIFESTS / "lincoln2.json").read_text())
        self.assertEqual([(u["left"], u["right"]) for u in m["unsure"]], [(2, 3), (3, 4), (5, 6)])
        self.assertEqual([p["label"] for p in m["pages"]], ["New", "Cont", "Cont", "Cont", "New", "Cont"])
        self.assertTrue(all(p["reviewed"] for p in m["pages"]))
        PS.validate(m, self.root)

    def test_a_missing_reply_is_unsure(self):
        for a, b in ((1, 2), (2, 3), (3, 4)):
            self.reply(a, b, '{"decision": "same"}')
        T.freeze(self.root)
        m = json.loads((PS.MANIFESTS / "lincoln2.json").read_text())
        self.assertEqual([(u["left"], u["right"]) for u in m["unsure"]], [(5, 6)])

    def test_changed_image_refused(self):
        (self.root / "boxes/Lincoln2/0003.jpg").write_bytes(b"other")
        with self.assertRaisesRegex(ValueError, "image changed"):
            T.box(self.root)

    def test_unsettled_reservation_counts_and_stops(self):
        T.append({"gap": "1|2", "event": "reserve", "charge": T.RESERVE})
        self.assertAlmostEqual(T.spent(), T.RESERVE)
        with mock.patch.object(T.GW, "request", side_effect=AssertionError("no call may be sent")):
            with self.assertRaisesRegex(SystemExit, "without a settled reply"):
                T.collect(self.root)

    def test_cap_stops_before_sending(self):
        T.append({"gap": "9|10", "event": "settle", "charge": T.CAP})
        with mock.patch.object(T.GW, "request", side_effect=AssertionError("no call may be sent")):
            with self.assertRaisesRegex(SystemExit, "cap"):
                T.collect(self.root)


class Box2Service(unittest.TestCase):
    def test_service_url(self):
        self.assertEqual(B.service("mal2401700", 3),
                         "https://tile.loc.gov/image-services/iiif/service:mss:mal:240:2401700:003")

    def test_non_manuscript_id_refused(self):
        for bad in ("2020780882", "mal24017", "malxxxxxxx"):
            with self.assertRaises(ValueError):
                B.service(bad, 1)


if __name__ == "__main__":
    unittest.main()
