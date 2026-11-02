#!/usr/bin/env python3
"""Headless sheet interaction/pixel proof on invented raster data only.

Requires Playwright in a temporary environment. Uses Chrome's headless mode with
an isolated profile; never connects to the owner's browser or opens a window.
  <venv>/bin/python prove_marks_sheet_browser.py --out /tmp/marks-sheet-proof
"""
import argparse
import copy
import json
from io import BytesIO
from pathlib import Path
import struct
import zlib

from PIL import Image
from playwright.sync_api import sync_playwright
import marks_sheet as S


def png(path):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    # White native 2600x700 page, blue and black synthetic ink regions.
    rows = []
    for y in range(700):
        row = bytearray(b'\xff\xff\xff' * 2600)
        if 70 <= y < 140:
            row[260*3:780*3] = b'\x00\x00\x00' * 520
        if 350 <= y < 490:
            row[1300*3:2080*3] = b'\x00\x00\xff' * 780
        rows.append(b'\0' + row)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2600, 700, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    png(out / 'synthetic.png')
    with Image.open(out/'synthetic.png') as image:
        exif=Image.Exif();exif[274]=6
        image.transpose(Image.Transpose.ROTATE_90).save(out/'synthetic.jpg', exif=exif, quality=95)
    a = dict(band='few', note='', added=[], candidates={
        '1':dict(keep=True, cls='annotation', overlaps=False, text='', note='',
                 feedback='NB: synthetic obscured reading', reviewed=False),
        '2':dict(keep=False, cls='other', overlaps=False, text='unchanged fixture')})
    data = [dict(page='synthetic', img='synthetic.jpg', pending=['1'], cands=[
        dict(box=[.1,.1,.3,.2], cls='annotation', overlaps=False, texts=[]),
        dict(box=[.5,.5,.8,.7], cls='other', overlaps=False, texts=[])])]
    S.write_sheet(out, data, {'answers_sha256':'synthetic-baseline'}, {'synthetic':copy.deepcopy(a)}, 'marks-feedback-synthetic-proof', recheck=True)
    errors = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel='chrome', headless=True)
        page = browser.new_page(viewport=dict(width=1440, height=1000), device_scale_factor=1)
        page.on('pageerror', lambda e: errors.append(str(e)))
        page.goto((out / 'index.html').as_uri())
        page.wait_for_function("document.querySelector('.frame img').naturalWidth === 2600")
        assert page.locator('#prog').inner_text().strip() == '0 / 1 pages done'
        c1 = page.locator('.mk[data-kind=c][data-n="1"]')
        c2 = page.locator('.mk[data-kind=c][data-n="2"]')
        assert c1.locator('input[type=radio]').evaluate_all('(xs)=>xs.every(x=>x.disabled)')
        assert c2.locator('[data-f=text]').is_disabled()
        assert not c1.locator('[data-f=text]').is_disabled()
        assert page.locator('.bx span').first.evaluate('(e)=>getComputedStyle(e).display') == 'none'
        page.locator('#numbers').check()
        assert page.locator('.bx span').first.evaluate('(e)=>getComputedStyle(e).display') == 'block'
        page.locator('#boxes').uncheck()
        assert page.locator('.bx').first.evaluate('(e)=>getComputedStyle(e).display') == 'none'
        page.locator('#boxes').check()
        page.locator('#numbers').uncheck()
        page.locator('.native').click()
        assert page.locator('.frame').evaluate('(e)=>e.getBoundingClientRect().width') == 2600
        page.locator('.native').click()
        page.screenshot(path=str(out / 'sheet.png'), full_page=True)
        c1.locator('[data-f=crop]').click()
        page.locator('#detail').wait_for(state='visible')
        dims = page.locator('#detail-canvas').evaluate('(c)=>[c.width,c.height]')
        assert dims == [650, 106], dims
        shot = page.locator('#detail-canvas').screenshot(path=str(out/'clean-crop.png'))
        assert Image.open(BytesIO(shot)).convert('RGB').getpixel((100,40)) == (0,0,0)
        page.get_by_role('button', name='rotate right', exact=True).click()
        assert page.locator('#detail-canvas').evaluate('(c)=>[c.width,c.height]') == dims[::-1]
        page.screenshot(path=str(out / 'crop-rotated.png'))
        page.get_by_role('button', name='close', exact=True).click()
        page.locator('.full').click()
        assert page.locator('#detail-canvas').evaluate('(c)=>[c.width,c.height]') == [2600,700]
        page.get_by_role('button', name='rotate left', exact=True).click()
        assert page.locator('#detail-canvas').evaluate('(c)=>[c.width,c.height]') == [700,2600]
        page.get_by_role('button', name='close', exact=True).click()
        c1.locator('[data-f=text]').fill('invented reading')
        c1.locator('[data-f=mark_note]').fill('separate synthetic note')
        c1.locator('[data-f=reviewed]').check()
        assert page.locator('#prog').inner_text().strip() == '1 / 1 pages done'
        c1.locator('[data-f=mark_note]').fill('revised separate note')
        assert not c1.locator('[data-f=reviewed]').is_checked()
        c1.locator('[data-f=reviewed]').check()
        # Add one separate subannotation; prior decisions must survive rerender.
        page.locator('.frame').scroll_into_view_if_needed()
        bounds = page.locator('.frame').bounding_box()
        page.keyboard.down('Shift')
        page.mouse.move(bounds['x']+bounds['width']*.35, bounds['y']+bounds['height']*.4)
        page.mouse.down()
        page.mouse.move(bounds['x']+bounds['width']*.45, bounds['y']+bounds['height']*.6)
        page.mouse.up(); page.keyboard.up('Shift')
        added = page.locator('.mk[data-kind=a]')
        added.wait_for()
        assert page.locator('#prog').inner_text().strip() == '0 / 1 pages done'
        added.locator('[data-f=cls][value=annotation]').check()
        added.locator('[data-f=overlaps][value=no]').check()
        added.locator('[data-f=text]').fill('invented subannotation')
        added.locator('[data-f=mark_note]').fill('invented separate note')
        assert page.locator('#prog').inner_text().strip() == '1 / 1 pages done'
        with page.expect_download() as download:
            page.get_by_role('button', name='Export answers', exact=True).click()
        export = download.value
        assert export.suggested_filename == 'marks-feedback-answers.json'
        export.save_as(str(out / export.suggested_filename))
        payload = json.loads((out/export.suggested_filename).read_text())
        assert payload['protocol'] == 'marks-feedback-answers-v1'
        assert payload['answers_sha256'] == 'synthetic-baseline'
        result = payload['pages']['synthetic']
        assert result['band'] == a['band']
        assert result['candidates']['2'] == a['candidates']['2']
        assert result['candidates']['1']['text'] == 'invented reading'
        assert result['candidates']['1']['note'] == 'revised separate note'
        assert result['candidates']['1']['feedback'] == a['candidates']['1']['feedback']
        assert result['added'][0]['note'] == 'invented separate note'
        page.reload()
        assert c1.locator('[data-f=text]').input_value() == 'invented reading'
        assert page.locator('.mk[data-kind=a]').count() == 1
        browser.close()
    assert not errors, errors
    print(json.dumps(dict(passed=True, artifact=str(out), checks='native pixels/crop pixel/rotation/overlays/locked labels/notes/added box/export/reload')))


if __name__ == '__main__':
    main()
