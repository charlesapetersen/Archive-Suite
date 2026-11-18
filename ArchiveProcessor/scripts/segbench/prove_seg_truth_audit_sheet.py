#!/usr/bin/env python3
"""W46.seg-truth-audit: a headless proof of the agreed-gap owner sheet on invented data only.

Builds the sheet for three invented gaps (white images, invented page numbers), drives it in Chrome's headless mode with
an isolated profile (never the owner's browser, never a window): answers one gap new and one continues, leaves one
can't tell, writes a note on a gap and one on the sheet, turns a page, reloads (answers kept), saves, then folds the
download against an invented key and checks the rulings, the per-stratum counts and the weighted error. It also checks
that the page shows no truth for an asked gap and that the unasked marks are listed.

  uv run --with playwright --with pillow python prove_seg_truth_audit_sheet.py --out /tmp/seg-truth-audit-proof
"""
import argparse
import json
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

import seg_truth_audit as A


def items(out: Path):
    Image.new("RGB", (600, 800), "white").save(out / "sheet/img/p.jpg")
    def strip(left, ask_at, seps):
        return [{"n": left - ask_at + k, "path": "", "src": "img/p.jpg", "rotation": 0, "label_photo": False,
                 "sep": s} for k, s in enumerate(seps)]
    return [
        {"id": "a01", "key": "Box1 10|11", "box": "Box1", "left": 10, "right": 11,
         "strip": strip(10, 2, ["same", "new", "ask", "same", "same", None])},
        {"id": "a02", "key": "Box1 20|21", "box": "Box1", "left": 20, "right": 21,
         "strip": strip(20, 0, ["ask", "card", None])},
        {"id": "a03", "key": "Box2 5|6", "box": "Box2", "left": 5, "right": 6,
         "strip": strip(5, 1, ["new", "ask", "same", None])},
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    out = Path(ap.parse_args().out)
    (out / "sheet/img").mkdir(parents=True, exist_ok=True)
    its = items(out)
    page_html = A.render_sheet(its, [], [])
    (out / "sheet/index.html").write_text(page_html)
    checks = []

    def check(name, ok, detail=""):
        checks.append((name, bool(ok)))
        print(("PASS " if ok else "FAIL ") + name + (f" ({detail})" if detail and not ok else ""))

    # The asked gap shows only "?"; the unasked ones are listed with their marks.
    check("each asked gap is marked ? and nothing else", page_html.count('class="sep ask"') == 3)
    check("unasked marks listed", "p. 8|9: same; p. 9|10: new; p. 11|12: same; p. 12|13: same" in page_html)
    check("label card listed", "p. 21|22: card" in page_html)
    check("no truth or consensus in the page", '"truth"' not in page_html and "consensus" not in page_html)
    # The one-page trap (owner, 2026-11-18): the asked pair is one box, marks name their pair, the question asks
    # whether the right page belongs with the left one, and a page the next gap separates is called a one-page document.
    check("each asked pair is one box", page_html.count('class="asked"') == 3)
    check("the question asks whether the right page belongs with the left",
          "Does p. 11 belong to the same document as p. 10?" in page_html and "start of a new document" not in page_html)
    check("an unasked mark names its own pair", "9|10 │ new" in page_html and "21|22 · card" in page_html)
    check("the one-page note only where the next gap separates", page_html.count('class="alone"') == 1
          and "if p. 21 does not belong with p. 20 it is a document of one page" in page_html)
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome", headless=True)
        ctx = browser.new_context(accept_downloads=True)
        pg = ctx.new_page()
        pg.goto((out / "sheet/index.html").as_uri())
        check("the box holds the two asked pages and the ?",
              pg.locator("#a01 .asked figure").count() == 2 and pg.locator("#a01 .asked .sep.ask").count() == 1)
        pg.check('input[name="a01"][value="new"]')
        pg.check('input[name="a02"][value="continue"]')
        pg.check('input[name="a03"][value="unsure"]')
        pg.fill('input.note[data-id="a02"]', "p. 21 is the back of p. 20")
        pg.fill("#snote", "invented sheet note")
        pg.click("#a01 .turn >> nth=0")
        check("count shows 3 of 3", "3 of 3 answered" in pg.inner_text("#count"))
        pg.reload()
        check("answers survive a reload", pg.is_checked('input[name="a02"][value="continue"]')
              and pg.input_value('input.note[data-id="a02"]') == "p. 21 is the back of p. 20")
        check("a turn survives a reload", "rotate(90deg)" in (pg.get_attribute("#a01 img >> nth=0", "style") or ""))
        with pg.expect_download() as dl:
            pg.click("#save")
        path = out / "answers.json"
        dl.value.save_as(path)
        browser.close()
    ans = json.loads(path.read_text())
    check("export carries the ids' keys", ans.get("_keys") == {it["id"]: it["key"] for it in its})
    check("export carries the notes and the turn", ans["_notes"].get("a02") and ans["_notes"].get("_sheet")
          and ans["_turns"].get("img/p.jpg") == 90)
    key = [{"key": "Box1 10|11", "truth": "continue", "consensus": "continue", "stratum": "Box1 continue", "weight": 4.0},
           {"key": "Box1 20|21", "truth": "continue", "consensus": "continue", "stratum": "Box1 continue", "weight": 4.0},
           {"key": "Box2 5|6", "truth": "new", "consensus": "new", "stratum": "Box2 new", "weight": 2.0}]
    f = A.fold(ans, key, ans["_keys"])
    check("fold: one ruling differs from the truth", f["differs"] == 1 and f["ruled"] == 2, f"{f['differs']} {f['ruled']}")
    check("fold: can't tell is not a ruling", f["strata"]["Box2 new"] == {"asked": 1, "ruled": 0, "differs": 0,
                                                                       "unsure": 1, "blank": 0})
    check("fold: weighted error over the ruled", abs(f["weighted_truth_error"] - 0.5) < 1e-9, f["weighted_truth_error"])
    check("fold: the note is on its row", next(r for r in f["rows"] if r["id"] == "a02")["note"].startswith("p. 21"))
    bad = [n for n, ok in checks if not ok]
    print("ALL PASS" if not bad else f"FAILURES: {len(bad)}")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
