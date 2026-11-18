#!/usr/bin/env python3
"""W46.date-full-date: a headless proof of the month-and-day owner sheet on invented data only.

Builds the sheet for three invented documents (white images, invented boxes), drives it in Chrome's headless mode with
an isolated profile (never the owner's browser, never a window): gives one a month and day, one "no month written",
one "can't tell", writes a note on a document and one on the sheet, turns a page, reloads (answers kept), saves, then
folds the download against an invented key and checks the rulings and the controls' agreement. It also checks that
the page shows no route or reader reading and that the unasked fields are listed.

  uv run --with playwright --with pillow python prove_date_full_date_sheet.py --out /tmp/date-full-date-proof
"""
import argparse
import json
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

import date_full_date as F


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    out = Path(ap.parse_args().out)
    (out / "sheet/img").mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (600, 800), "white").save(out / "sheet/img/p.jpg")
    page = {"src": "img/p.jpg", "rotation": 0, "boxes": [[0.1, 0.05, 0.3, 0.03]]}
    data = [{"id": "D01", "pages": [page, page], "year": 1961, "du": False, "pages_total": 3},
            {"id": "D02", "pages": [page], "year": 1958, "du": True, "pages_total": 1},
            {"id": "D03", "pages": [page], "year": 1947, "du": False, "pages_total": 2}]
    page_html = F.render_sheet(data, [], [])
    (out / "sheet/index.html").write_text(page_html)
    checks = []

    def check(name, ok, detail=""):
        checks.append((name, bool(ok)))
        print(("PASS " if ok else "FAIL ") + name + (f" ({detail})" if detail and not ok else ""))

    check("unasked fields listed", "year 1961, no Date Uncertain" in page_html and "year 1958, Date Uncertain" in page_html)
    check("a box per date-like string", page_html.count('class="box"') == 4)
    check("no reading, route or group in the page",
          all(w not in page_html for w in ('"route"', '"second"', "disputed", "control", '"group"')))
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome", headless=True)
        ctx = browser.new_context(accept_downloads=True)
        pg = ctx.new_page()
        pg.goto((out / "sheet/index.html").as_uri())
        pg.select_option('select.month[data-id="D01"]', "3")
        pg.fill('input.day[data-id="D01"]', "30")
        pg.select_option('select.month[data-id="D02"]', "none")
        pg.select_option('select.month[data-id="D03"]', "unsure")
        pg.fill('input.note[data-id="D02"]', "the year is 1959 on page 1")
        pg.fill("#snote", "invented sheet note")
        pg.click("#D01 .turn >> nth=0")
        check("count shows 3 of 3", "3 of 3 answered" in pg.inner_text("#count"))
        pg.reload()
        check("answers survive a reload", pg.input_value('select.month[data-id="D01"]') == "3"
              and pg.input_value('input.day[data-id="D01"]') == "30"
              and pg.input_value('input.note[data-id="D02"]') == "the year is 1959 on page 1")
        check("a turn survives a reload, boxes with it",
              "rotate(90deg)" in (pg.get_attribute("#D01 .rot >> nth=0", "style") or ""))
        with pg.expect_download() as dl:
            pg.click("#save")
        path = out / "answers.json"
        dl.value.save_as(path)
        browser.close()
    ans = json.loads(path.read_text())
    check("export carries the ids", ans.get("_ids") == ["D01", "D02", "D03"])
    check("export carries the notes and the turn", ans["_notes"].get("D02") and ans["_notes"].get("_sheet")
          and ans["_turns"].get("img/p.jpg") == 90)
    key = {"D01": {"id": "o:a", "group": "control", "route": [1961, 3, 30]},
           "D02": {"id": "o:b", "group": "disputed", "route": [1958, 4, None]},
           "D03": {"id": "o:c", "group": "control", "route": [1947, 1, 2]}}
    f = F.fold(ans, key)
    docs = f["documents"]
    check("fold: month and day read", docs["o:a"]["month"] == 3 and docs["o:a"]["day"] == 30)
    check("fold: no month written is None, no day", docs["o:b"]["month"] is None and docs["o:b"]["day"] is None)
    check("fold: can't tell kept apart", docs["o:c"]["month"] == "unsure")
    check("fold: the note on its document", docs["o:b"]["note"].startswith("the year is 1959"))
    check("fold: controls counted, can't tell left out", f["controls"] == {"asked": 1, "same": 1, "differs": []})
    rs = [{"id": "o:b", "cls": "text", "route": [1958, 4, None], "tag": [1958, None, True], "second": [1958, 4, None],
           "owner_read": None},
          {"id": "o:c", "cls": "text", "route": [1947, 1, 2], "tag": [1947, None, False], "second": [1947, 1, 2],
           "owner_read": None}]
    check("truth: the owner's ruling wins over agreement", F.truth_of(rs[0], docs) == ("owner, this sheet", [1958, None, None]))
    check("truth: can't tell is not a truth", F.truth_of(rs[1], docs) == ("owner can't tell", None))
    bad = [n for n, ok in checks if not ok]
    print("ALL PASS" if not bad else f"FAILURES: {len(bad)}")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
