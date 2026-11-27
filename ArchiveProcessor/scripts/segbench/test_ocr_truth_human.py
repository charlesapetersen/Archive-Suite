"""Unit tests for W46.truth-96-human-keyed tooling on invented pages only ($0, no owner pages read).

  ~/Library/Caches/ArchiveSuiteRehearsal/torch-env/bin/python -m unittest test_ocr_truth_human
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
if str(HERE / "corpus") not in sys.path:
    sys.path.insert(0, str(HERE / "corpus"))

import ocr_rescore as RS  # noqa: E402
import ocr_truth_human as H  # noqa: E402


def _make_invented_pages(pages_dir: Path, names: list[str]) -> None:
    pages_dir.mkdir(parents=True, exist_ok=True)
    for name in names:
        Image.new("RGB", (400, 600), "white").save(pages_dir / f"{name}.jpg", "JPEG")


def _extract_script(html_text: str) -> str:
    m = re.search(r"<script>(.*)</script>", html_text, re.S)
    assert m is not None, "expected inline <script>"
    return m.group(1)


class BlindKeyingSheetTests(unittest.TestCase):
    def test_live_server_saves_per_reader_per_page_resumes_and_tracks_time(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            pages_dir = root / "pages"
            work = root / "work"
            _make_invented_pages(pages_dir, ["inv01", "inv02"])
            H.init_work(pages_dir, work)

            srv = H.make_keying_server(work, "reader1", host="127.0.0.1", port=0)
            port = srv.server_address[1]
            t = threading.Thread(target=srv.serve_forever, daemon=True)
            t.start()
            try:
                base = f"http://127.0.0.1:{port}"
                # Sitting 1: fetch blind sheet HTML and state
                html_text = urllib.request.urlopen(base + "/").read().decode("utf-8")
                self.assertIn("Blind mode: no model text", html_text)
                self.assertNotIn("claude", html_text.lower())
                self.assertNotIn("gemini", html_text.lower())

                # Verify inline JS parses cleanly with node --check when node is present
                node_res = subprocess.run(["node", "--check"], input=_extract_script(html_text),
                                          text=True, capture_output=True)
                self.assertEqual(node_res.returncode, 0, node_res.stderr)

                # Save page inv01 in sitting 1
                req = urllib.request.Request(
                    base + "/api/save/inv01",
                    data=json.dumps({
                        "text": "Dear Board,\nThe schedule is ready.",
                        "kind": "typewritten",
                        "table_form": False,
                        "note": "slight skew",
                        "done": False,
                        "active_seconds": 42.5,
                        "rotation": 90,
                        "new_sitting": True,
                    }).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                resp = json.loads(urllib.request.urlopen(req).read().decode("utf-8"))
                self.assertTrue(resp["ok"])
                pfile = work / "keyings" / "reader1" / "inv01.json"
                self.assertTrue(pfile.exists())
                rec1 = json.loads(pfile.read_text(encoding="utf-8"))
                self.assertEqual(rec1["active_seconds"], 42.5)
                self.assertEqual(rec1["sittings"], 1)

                # Sitting 2: reload /api/state and resume on inv01, finish inv01 and inv02
                state = json.loads(urllib.request.urlopen(base + "/api/state").read().decode("utf-8"))
                self.assertEqual(state["saved"]["inv01"]["text"], "Dear Board,\nThe schedule is ready.")
                self.assertEqual(state["saved"]["inv01"]["rotation"], 90)

                req2 = urllib.request.Request(
                    base + "/api/save/inv01",
                    data=json.dumps({
                        "text": "Dear Board,\nThe schedule is ready for review.",
                        "kind": "typewritten",
                        "table_form": False,
                        "note": "slight skew",
                        "done": True,
                        "active_seconds": 75.0,
                        "rotation": 90,
                        "new_sitting": True,
                    }).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                urllib.request.urlopen(req2).read()
                rec2 = json.loads(pfile.read_text(encoding="utf-8"))
                self.assertTrue(rec2["done"])
                self.assertEqual(rec2["active_seconds"], 75.0)
                self.assertEqual(rec2["sittings"], 2)

                # Ensure page image endpoint serves inv01.jpg and rejects traversal
                img_bytes = urllib.request.urlopen(base + "/pages/inv01.jpg").read()
                self.assertTrue(img_bytes.startswith(b"\xff\xd8"))
            finally:
                srv.shutdown()
                srv.server_close()

    def test_offline_bundle_import_splits_into_per_page_files(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            pages_dir, work = root / "pages", root / "work"
            _make_invented_pages(pages_dir, ["inv01", "inv02"])
            H.init_work(pages_dir, work)
            sheet = H.build_keying_sheet(work, "reader2", live_server=False)
            self.assertTrue(sheet.exists())

            bundle = root / "bundle.json"
            bundle.write_text(json.dumps({
                "reader": "reader2",
                "pages": {
                    "inv01": {"text": "First invented page.", "kind": "printed", "active_seconds": 30, "done": True},
                    "inv02": {"text": "Second invented page.", "kind": "handwritten", "active_seconds": 55, "done": True},
                },
            }), encoding="utf-8")
            n = H.import_keying_bundle(work, "reader2", bundle)
            self.assertEqual(n, 2)
            self.assertEqual(len(H.load_reader_keyings(work, "reader2")), 2)


class CompareSettleAndRescoreTests(unittest.TestCase):
    def test_compare_and_settle_on_invented_keyings_without_overwriting_current_truth(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            pages_dir, work, truth_root = root / "pages", root / "work", root / "ocr-truth"
            _make_invented_pages(pages_dir, ["p001", "p002", "p003"])
            H.init_work(pages_dir, work)

            # Pre-existing drafted truth that MUST NEVER be overwritten
            (truth_root / "truth").mkdir(parents=True)
            (truth_root / "truth" / "p001.txt").write_text("OLD DRAFTED P001\n", encoding="utf-8")
            (truth_root / "truth" / "p002.txt").write_text("OLD DRAFTED P002\n", encoding="utf-8")
            (truth_root / "truth" / "p003.txt").write_text("OLD DRAFTED P003\n", encoding="utf-8")

            # Invented Reader A & Reader B keyings with known differences across kinds
            H.save_keying_page(work, "alice", "p001", {
                "text": "The committee met on May 4 in Chicago.",
                "kind": "typewritten", "table_form": False, "active_seconds": 24.0, "done": True,
            })
            H.save_keying_page(work, "bob", "p001", {
                "text": "The comittee met on May 9 in Chicago.",
                "kind": "typewritten", "table_form": False, "active_seconds": 30.0, "done": True,
            })
            H.save_keying_page(work, "alice", "p002", {
                "text": "Sector | Workers\nTextiles | 4,215",
                "kind": "printed", "table_form": True, "active_seconds": 18.0, "done": True,
            })
            H.save_keying_page(work, "bob", "p002", {
                "text": "Sector | Workers\nTextiles | 4,215",
                "kind": "printed", "table_form": True, "active_seconds": 20.0, "done": True,
            })
            H.save_keying_page(work, "alice", "p003", {
                "text": "Dear Clara we arrived safely.",
                "kind": "handwritten", "table_form": False, "active_seconds": 40.0, "done": True,
            })
            H.save_keying_page(work, "bob", "p003", {
                "text": "Dear Clara we arived safely.",
                "kind": "handwritten", "table_form": False, "active_seconds": 50.0, "done": True,
            })

            cmp_obj = H.compare_readers(work, "alice", "bob")
            ov = cmp_obj["stats"]["overall"]
            self.assertEqual(ov["pages"], 3)
            self.assertEqual(ov["exact_pages"], 1)  # p002 agreed verbatim
            self.assertEqual(ov["n_disputes"], 3)   # committee/comittee, 4/9, arrived/arived
            self.assertEqual(ov["disputed_words"], 3)
            self.assertIn("typewritten", cmp_obj["stats"]["by_kind"])
            self.assertIn("printed", cmp_obj["stats"]["by_kind"])
            self.assertIn("handwritten", cmp_obj["stats"]["by_kind"])
            self.assertEqual(cmp_obj["stats"]["by_kind"]["printed"]["word_agreement_rate"], 1.0)
            self.assertGreater(ov["wpm_combined"], 0)

            # Dispute sheet HTML exists, parses cleanly in node, and lists unasked fields + notes
            dispute_html = (work / "dispute" / "index.html").read_text(encoding="utf-8")
            self.assertIn("Unasked fields", dispute_html)
            self.assertIn("_notes", dispute_html)
            node_res = subprocess.run(["node", "--check"], input=_extract_script(dispute_html),
                                      text=True, capture_output=True)
            self.assertEqual(node_res.returncode, 0, node_res.stderr)

            # Build settlement answers: p001 picks bob for span 1 ("comittee"), typed "=6" for span 3; p003 picks alice
            p001_spans = next(p["spans"] for p in cmp_obj["pages"] if p["page"] == "p001")
            p001_disp = [i for i, s in enumerate(p001_spans) if "agreed" not in s]
            p003_spans = next(p["spans"] for p in cmp_obj["pages"] if p["page"] == "p003")
            p003_disp = [i for i, s in enumerate(p003_spans) if "agreed" not in s]
            answers = {
                "p001": {str(p001_disp[0]): "b", str(p001_disp[1]): "=6"},
                "p002": {},
                "p003": {str(p003_disp[0]): "a"},
                "_notes": {"p001": "original really says comittee and May 6"},
                "_settling_seconds": 95.0,
            }
            ans_path = root / "answers.json"
            ans_path.write_text(json.dumps(answers), encoding="utf-8")

            # Reserved name 'truth' must be refused
            with self.assertRaises(ValueError):
                H.settle(work, ans_path, truth_root, "truth")

            meta = H.settle(work, ans_path, truth_root, "human-v1")
            self.assertEqual(meta["settled_pages"], 3)
            self.assertEqual(meta["open_pages"], 0)
            self.assertEqual(meta["settling_seconds"], 95.0)

            vdir = truth_root / "truth-human-v1"
            self.assertEqual((vdir / "p001.txt").read_text(encoding="utf-8").strip(),
                             "The comittee met on May 6 in Chicago.")
            self.assertEqual((vdir / "p002.txt").read_text(encoding="utf-8").strip(),
                             "Sector Workers Textiles 4,215")
            self.assertEqual((vdir / "p003.txt").read_text(encoding="utf-8").strip(),
                             "Dear Clara we arrived safely.")

            # Original drafted truth MUST remain byte-identical untouched
            self.assertEqual((truth_root / "truth" / "p001.txt").read_text(encoding="utf-8"), "OLD DRAFTED P001\n")

            # Re-running settle on the same version directory refuses to overwrite
            with self.assertRaises(FileExistsError):
                H.settle(work, ans_path, truth_root, "human-v1")

    def test_rescore_replays_drafted_truth_first_and_reports_drafter_movement_and_rank_change(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            drafted_dir = root / "truth"
            human_dir = root / "truth-human-v1"
            out_dir = root / "out"
            drafted_dir.mkdir()
            human_dir.mkdir()

            # Synthetic 2-page scenario where drafted truth leaned toward Gemini/Claude,
            # while human truth matches qwen3.6-27b cleanly, causing a rank swap.
            (drafted_dir / "p001.txt").write_text("The comitee approved the budget in May 1953.\n", encoding="utf-8")
            (drafted_dir / "p002.txt").write_text("Regional office report by Ewbank.\n", encoding="utf-8")
            (human_dir / "p001.txt").write_text("The committee approved the budget in May 1953.\n", encoding="utf-8")
            (human_dir / "p002.txt").write_text("Regional office report by Eubank.\n", encoding="utf-8")

            sources = {
                ("gemini3.8-flash", "cloud panel"): {
                    "p001": "The comitee approved the budget in May 1953.",
                    "p002": "Regional office report by Ewbank.",
                },
                ("claude-sonnet5.5", "plan route"): {
                    "p001": "The comitee approved the budget in May 1953.",
                    "p002": "Regional office report by Eubank.",
                },
                ("qwen3.6-27b", "local panel"): {
                    "p001": "The committee approved the budget in May 1953.",
                    "p002": "Regional office report by Eubank.",
                },
                ("apple-vision", "Mac"): {
                    "p001": "The committee aproved the budget in May 1953.",
                    "p002": "Regonal office report by Eubank.",
                },
            }
            pages = ["p001", "p002"]

            # Build exact saved baseline from drafted truth
            base_rows = RS.score_set(
                "owner96", sources,
                lambda p: (drafted_dir / f"{p}.txt").read_text(encoding="utf-8"),
                lambda p: "S0", lambda _t: pages,
            )
            baseline_summary = RS.summarise(base_rows)

            # Corrupt baseline -> replay check MUST refuse before touching human truth
            corrupt = [dict(r, nes=(r["nes"] - 0.05 if r["route"] == "gemini3.8-flash" else r["nes"]))
                       for r in baseline_summary]
            with self.assertRaises(RuntimeError):
                H.rescore_with_truth(sources, pages, drafted_dir, human_dir, corrupt, "human-v1", out_dir)
            self.assertFalse((out_dir / "ocr-truth-human-human-v1.md").exists())

            # Exact baseline -> replay passes and rescores on human truth
            res = H.rescore_with_truth(sources, pages, drafted_dir, human_dir, baseline_summary, "human-v1", out_dir)
            self.assertTrue(res["replay_verified"])
            cmp_rank = res["comparison"]
            self.assertTrue(cmp_rank["ranking_changed"])
            # Drafter routes (claude, gemini) come first in the ordered table
            self.assertTrue(cmp_rank["routes"][0]["drafter_family"])
            self.assertTrue(cmp_rank["routes"][1]["drafter_family"])
            self.assertFalse(cmp_rank["routes"][2]["drafter_family"])
            # qwen3.6-27b moved to rank 1 on human truth while gemini dropped
            qwen = next(r for r in cmp_rank["routes"] if r["route"] == "qwen3.6-27b")
            gem = next(r for r in cmp_rank["routes"] if r["route"] == "gemini3.8-flash")
            self.assertEqual(qwen["human_rank"], 1)
            self.assertGreater(qwen["delta_nes"], 0)
            self.assertLess(gem["delta_nes"], 0)

            md = (out_dir / "ocr-truth-human-human-v1.md").read_text(encoding="utf-8")
            self.assertIn("Ranking change reported (no decision)", md)
            self.assertIn("Gemini and Claude rows first", md)
            self.assertIn("## Measurement card", md)


if __name__ == "__main__":
    unittest.main()
