"""Unit tests for W46.ocr-churro-overlap (churro_overlap.py) on synthetic images, no network."""
import io
import unittest

from PIL import Image, ImageDraw

import churro_overlap as co


def make_image_bytes(seed_shift=0, size=(200, 260), fmt="JPEG", quality=92):
    im = Image.new("RGB", size, (245, 240, 228))
    dr = ImageDraw.Draw(im)
    # Dark scan frame around the page (must NOT cause unrelated pages to match after 5% interior crop)
    dr.rectangle([0, 0, size[0] - 1, size[1] - 1], outline=(20, 20, 20), width=6)
    for i in range(7):
        y = 24 + i * 28 + seed_shift
        dr.rectangle([22 + ((i + seed_shift) % 4) * 14, y, size[0] - 24 - (i % 3) * 18, y + 9], fill=(30 + i * 12, 25, 20))
    dr.ellipse([size[0] // 2 - 18 + seed_shift * 2, 55, size[0] // 2 + 18 + seed_shift * 2, 91], fill=(80, 40, 40))
    buf = io.BytesIO()
    if fmt == "JPEG":
        im.save(buf, format="JPEG", quality=quality)
    else:
        im.save(buf, format=fmt)
    return buf.getvalue()


class ChurroOverlapTests(unittest.TestCase):
    def test_exact_bytes_and_recompressed_perceptual_matches_reject_unrelated_framed_pages(self):
        raw_png = make_image_bytes(seed_shift=0, size=(240, 320), fmt="PNG")
        recompressed_jpg = make_image_bytes(seed_shift=0, size=(240, 320), fmt="JPEG", quality=75)
        different = make_image_bytes(seed_shift=13, size=(240, 320), fmt="PNG")

        fp_png = co.image_fingerprints(raw_png)
        fp_jpg = co.image_fingerprints(recompressed_jpg)
        fp_diff = co.image_fingerprints(different)

        bench = [
            {"stratum": "L7", "source": "koenigsfelden", "page_id": "U-17_0059_v", "norm_id": "u_17_0059_v", "norm_full": "u_17_0059_v", "in_440": True, "fp": fp_png},
            {"stratum": "L1", "source": "btp", "page_id": "b-1", "norm_id": "b_1", "norm_full": "b_1", "in_440": False, "fp": fp_diff},
        ]
        churro_rows = [
            ({"index": 0, "dataset_id": "charters", "file_name": "U-17_0059_v.png"}, fp_png),
            ({"index": 1, "dataset_id": "charters", "file_name": "U-17_0059_v.jpeg"}, fp_jpg),
            ({"index": 2, "dataset_id": "norhand", "file_name": "unrelated.jpeg"}, fp_diff),
        ]
        # Only compare against bench[0] to confirm unrelated framed page does NOT false-match bench[0].
        total, ds_counts, confirmed, borderline, unmatched_fn = co.match_records(churro_rows, [bench[0]])
        self.assertEqual(total, 3)
        self.assertEqual(ds_counts["charters"], 2)
        self.assertEqual(len(confirmed), 2)
        self.assertEqual(confirmed[0]["match_kind"], "exact_bytes")
        self.assertEqual(confirmed[1]["match_kind"], "perceptual")
        self.assertEqual(unmatched_fn, [])

        # Deduplication keeps exact_bytes over perceptual for the same bench page.
        report = co.summarise(total, ds_counts, confirmed, borderline, unmatched_fn, bench, ["shard0"])
        self.assertEqual(report["overlap_unique_bench_pages"], 1)
        self.assertEqual(report["overlap_by_match_kind"]["exact_bytes"], 1)
        self.assertEqual(report["overlap_by_match_kind"]["perceptual"], 0)
        self.assertEqual(report["overlap_in_440"], 1)
        self.assertEqual(report["overlap_in_455"], 0)
        md = co.render_markdown(report)
        self.assertIn("## Measurement card", md)
        self.assertIn("1 of 2", md)


if __name__ == "__main__":
    unittest.main()
