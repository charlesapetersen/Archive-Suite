#!/usr/bin/env python3
"""W46.owner-set-grow: a headless proof of the owner sheet on invented data only.

Builds the sheet for one synthetic page (a white image, invented readings, invented Vision word boxes), drives it in
Chrome's headless mode with an isolated profile (never the owner's browser, never a window): picks a reading by
key, types one, can't-tell one, answers the control, writes a note (whose keys must not answer anything), turns the
page, checks that a place settled 2 to 1 is listed and takes no answer, exports, then folds the export and checks the truth text and that the box is drawn where the words are.

  uv run --with playwright --with pillow --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \\
      --with levenshtein python prove_owner_set_grow_sheet.py --out /tmp/osg-sheet-proof
"""
import argparse
import json
import random
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

import owner_set_grow as S


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    out = Path(ap.parse_args().out)
    (out / 'sheet').mkdir(parents=True, exist_ok=True)
    Image.new('RGB', (1000, 1400), 'white').save(out / 'page.jpg')
    a = 'Dear Mr Smith thank you for the letter of May 4 one two three four five six seven eight'
    b = 'Dear Mr Smyth thank you for the letter of May 9 one two three four five six sevin eight'
    sp = S.spans(a, b)
    S.tie_breaks(a, 'Dear Mr Smitt thank you for the letter of May 4th one two three four five six seven eight', sp)
    ctrl = S.control_spans(sp, random.Random(3))[:1]
    cmp = {'a': 'A', 'b': 'B', 'missing': [], 'pages': [
        {'id': 's001', 'spans': sp, 'controls': ctrl, 'kind': ['typewritten', 'typewritten'], 'table': [False, False],
         'language': ['English', 'French'], 'a_text': a, 'b_text': b}]}
    rows = [{'id': 's001', 'key': 'k1', 'set': 'topup', 'tags': ['1950', 'Unread'], 'source': 'original'}]
    # Vision words: one line of the same words, left to right at y 0.2
    toks = a.split()
    vision = {'k1': [[t, 0.05 + 0.05 * i, 0.2, 0.045, 0.02] for i, t in enumerate(toks)]}
    S.image = lambda r: out / 'page.jpg'
    S.OUT = out
    items, key = S.build(cmp, rows, {'k1': {'turn': 0, 'close': False, 'how': 'scores'}}, vision)
    html = (S.SHEET_HTML.replace('__ITEMS__', json.dumps(items)).replace('__BUILD__', key['build'])
            .replace('__N__', '1').replace('__MIN__', '1').replace('__TURNED__', '0').replace('__TOPUP__', '1'))
    (out / 'sheet' / 'index.html').write_text(html)
    places = items[0]['places']
    assert [p['kind'] for p in places].count('dispute') == 2 and all(p['box'] for p in places), places
    assert places[-1]['kind'] == 'listed' and places[-1]['texts'] == ['seven'], places[-1]
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel='chrome', headless=True)
        ctx = browser.new_context(accept_downloads=True, viewport={'width': 1500, 'height': 900})
        page = ctx.new_page()
        page.goto((out / 'sheet' / 'index.html').as_uri())
        page.click('[data-t="3"]')                     # has text
        page.fill('#note', 'y n t 1 2 e r')             # keys typed in a note answer nothing
        page.locator('body').click(position={'x': 1300, 'y': 50})
        order = [p['id'] for p in places if p['kind'] != 'listed']
        dialogs = iter(['6'])
        page.on('dialog', lambda d: d.accept(next(dialogs, '')))
        for pid in order:
            k = key['pages']['s001']['places'][pid]
            if k.get('control'):
                page.keyboard.press('y')
            elif sp[k['span']]['a'] == 'Smith':
                page.keyboard.press(str(k['options'].index('b') + 1))
            else:
                page.keyboard.press('t')
        assert page.locator('.pl.ls.cur').count() == 1   # the last answer moved on to the listed place
        for k in ('1', '2', 'e', 't', 'y'):
            page.keyboard.press(k)                     # nothing to answer there: no key records anything
        assert '✓' in page.text_content('#pos'), page.text_content('#pos')
        assert page.locator('.bx.ls').count() == 1
        page.keyboard.press('r')
        page.wait_for_timeout(400)                     # the turn's CSS transition
        page.screenshot(path=str(out / 'turned.png'))
        with page.expect_download() as dl:
            page.click('#exp')
        ans_path = out / 'answers.json'
        dl.value.save_as(ans_path)
        page.keyboard.press('r'); page.keyboard.press('r'); page.keyboard.press('r')
        page.wait_for_timeout(400)
        page.screenshot(path=str(out / 'upright.png'))
        browser.close()
    ans = json.loads(ans_path.read_text())
    assert ans['_turns'] == {'s001': 90}, ans['_turns']
    assert ans['_notes']['s001'] == 'y n t 1 2 e r', ans['_notes']
    got = S.fold(cmp, key, ans)['s001']
    assert got['status'] == 'settled' and got['drop'] is None, got
    assert 'Mr Smyth thank' in got['text'] and 'May 6 one' in got['text'], got['text']
    assert got['counts'] == {'dispute picked b': 1, 'dispute typed': 1, 'control right': 1, 'dispute 2 to 1 a': 1}, got['counts']
    assert places[-1]['id'] not in ans['s001'], ans['s001']
    assert got['text'].endswith('six seven eight') and len(got['two_to_one_words']) == 1, got
    # the box over "Smith" (token 2) is drawn magenta/blue where Vision put the word, on the upright screenshot
    im = Image.open(out / 'upright.png').convert('RGB')
    hits = sum(1 for x in range(im.width) for y in range(0, im.height, 3)
               if (lambda p: (p[0] > 200 and p[2] > 120 and p[1] < 80) or (p[2] > 200 and p[0] < 60 and p[1] > 120))(im.getpixel((x, y))))
    assert hits > 50, hits
    print('sheet proof ok:', got['counts'], 'box pixels', hits)


if __name__ == '__main__':
    main()
