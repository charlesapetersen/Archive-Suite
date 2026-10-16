#!/usr/bin/env python3
"""Tests for common.py on hand-made fixtures (no network). python3 test_common.py"""
import io
import subprocess
import unittest
import zipfile

import common as C

PAGE = b'''<?xml version="1.0" encoding="UTF-8"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">
 <Page imageFilename="p.jpg">
  <ReadingOrder><OrderedGroup id="g"><RegionRefIndexed index="1" regionRef="r1"/>
   <RegionRefIndexed index="0" regionRef="r2"/></OrderedGroup></ReadingOrder>
  <TextRegion id="r1">
   <TextLine id="l1"><TextEquiv><Unicode>second region, line one</Unicode></TextEquiv></TextLine>
   <TextLine id="l2"><TextEquiv><Unicode>line two \xc5\xbf</Unicode></TextEquiv></TextLine>
   <TextEquiv><Unicode>region text, not used when lines have text</Unicode></TextEquiv>
  </TextRegion>
  <TextRegion id="r2"><TextEquiv><Unicode>first region (region-level only)</Unicode></TextEquiv></TextRegion>
  <TextRegion id="r3"><TextLine id="l3"><TextEquiv><Unicode></Unicode></TextEquiv></TextLine></TextRegion>
 </Page>
</PcGts>'''

ALTO = b'''<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"><Layout><Page><PrintSpace>
 <TextBlock><TextLine><String CONTENT="Hello"/><SP/><String CONTENT="wor"/><HYP CONTENT="-"/></TextLine>
  <TextLine><String CONTENT="ld"/></TextLine></TextBlock>
 <TextBlock><TextLine><String CONTENT="\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d"/></TextLine></TextBlock>
</PrintSpace></Page></Layout></alto>'''


class Formats(unittest.TestCase):
    def test_page_xml_reading_order_lines_and_region_fallback(self):
        self.assertEqual(C.page_xml_text(PAGE),
                         'first region (region-level only)\n\nsecond region, line one\nline two ſ')

    def test_alto_lines_blocks_and_hyphen(self):
        self.assertEqual(C.alto_text(ALTO), 'Hello wor-\nld\n\nשלום')


class Zip(unittest.TestCase):
    def _zip(self, **kw):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w', **kw) as z:
            z.writestr('a/stored.txt', b'plain bytes', compress_type=zipfile.ZIP_STORED)
            z.writestr('a/deflated.xml', PAGE * 20, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr('a/', b'')
        data = buf.getvalue()
        reads = []

        def reader(a, b):
            reads.append(b - a + 1)
            return data[a:b + 1]
        return C.RemoteZip(size=len(data), reader=reader), reads

    def test_members_round_trip(self):
        z, _ = self._zip()
        self.assertEqual(sorted(z.names()), ['a/deflated.xml', 'a/stored.txt'])
        self.assertEqual(z.member('a/stored.txt'), b'plain bytes')
        self.assertEqual(z.member('a/deflated.xml'), PAGE * 20)

    def test_zip64_directory(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w', allowZip64=True) as z:
            with z.open('big.bin', 'w', force_zip64=True) as f:
                f.write(b'x' * 1000)
        data = buf.getvalue()
        z = C.RemoteZip(size=len(data), reader=lambda a, b: data[a:b + 1])
        self.assertEqual(z.member('big.bin'), b'x' * 1000)


class Fetch(unittest.TestCase):
    def run_fetch(self, *args):
        return subprocess.run([str(C.FETCH), *args], capture_output=True, text=True)

    def test_refuses_other_hosts_and_bad_urls(self):
        for url in ('https://example.com/x', 'http://zenodo.org/x', 'https://zenodo.org:8443/x',
                    'https://u@zenodo.org/x', 'https://zenodo.org.evil.com/x', 'ftp://zenodo.org/x'):
            r = self.run_fetch('--head', url)
            self.assertEqual(r.returncode, 2, url)
            self.assertIn('refused', r.stderr)

    def test_refuses_dest_outside_cache(self):
        for dest in ('/tmp/x', '../x', 'a/../../x'):
            r = self.run_fetch('https://zenodo.org/x', dest)
            self.assertEqual(r.returncode, 2, dest)

    def test_refuses_big_range(self):
        self.assertEqual(self.run_fetch('--range', '0-300000000', 'https://zenodo.org/x').returncode, 2)


class Chunks(unittest.TestCase):
    def test_big_range_is_read_in_retried_chunks(self):
        from unittest import mock
        data = bytes(range(256)) * 100
        calls, fail_once = [], {10}

        def once(url, a, b):
            calls.append((a, b))
            if a in fail_once:
                fail_once.discard(a)
                raise IOError('closed early')
            return data[a:b + 1]
        with mock.patch.object(C, '_range_once', once), mock.patch.object(C, 'CHUNK', 7):
            got = C.get_range('u', 3, 24, sleep=lambda s: None)
        self.assertEqual(got, data[3:25])
        self.assertEqual(calls, [(3, 9), (10, 16), (10, 16), (17, 23), (24, 24)])


if __name__ == '__main__':
    unittest.main()
