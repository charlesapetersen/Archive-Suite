import struct
import unittest

import sevenz
import src_voc as s

XML = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15"><Metadata>
<TranskribusMetadata docId="1" pageId="2" imgUrl="https://files.transkribus.eu/Get?id=X"/></Metadata>
<Page imageFilename="NL-HaNA_1.04.02_7000_0001.jpg">
<ReadingOrder><OrderedGroup id="g"><RegionRefIndexed index="0" regionRef="r1"/><RegionRefIndexed index="1" regionRef="r2"/></OrderedGroup></ReadingOrder>
<TextRegion id="r2"><TextLine id="r2l1" custom="readingOrder {index:0;}"><TextEquiv><Unicode>2 a 3</Unicode></TextEquiv></TextLine></TextRegion>
<TextRegion id="r1"><TextLine id="r1l1" custom="readingOrder {index:0;} unclear {offset:0; length:4;}"><TextEquiv><Unicode>ofte vel„</Unicode></TextEquiv></TextLine>
<TextLine id="r1l2"><TextEquiv><Unicode>theer met d’ onse\r</Unicode></TextEquiv></TextLine>
<TextEquiv><Unicode>ofte vel„\ntheer met d’ onse</Unicode></TextEquiv></TextRegion>
</Page></PcGts>'''.encode('utf-8')

SLT = '''
Listing archive: x.7z

--
Path = x.7z
Type = 7z
Solid = +
Blocks = 2

----------
Path = NL-HaNA_1.04.02_7000_0001.jpg
Size = 100
Packed Size = 5000
CRC = 0000ABCD
Block = 0

Path = NL-HaNA_1.04.02_7000_0002.jpg
Size = 200
Packed Size =
CRC = 00001234
Block = 0

Path = NL-HlmNHA_1617_1703_0123.jpg
Size = 300
Packed Size = 7000
CRC = 00005678
Block = 1
'''


class T(unittest.TestCase):
    def test_truth_lines_in_reading_order_without_cr(self):
        self.assertEqual(s.truth(XML), 'ofte vel„\ntheer met d’ onse\n\n2 a 3')

    def test_collection_and_part(self):
        self.assertEqual(s.collection('NL-HaNA_1.04.02_7815_0405'), 'NL-HaNA_1.04.02_7815')
        self.assertEqual(s.collection('NL-HlmNHA_1617_1703_0123'), 'NL-HlmNHA_1617_1703')
        self.assertEqual(s.collection('NL-0400410000_26_004011_000464'), 'NL-0400410000_26_004011')
        self.assertEqual(s.part_of('NL-HaNA_1.04.02_7815_0405'), 'voc')
        self.assertEqual(s.part_of('NL-HlmNHA_1972_7_0056'), 'notarial')

    def test_slt_listing_and_block_offsets(self):
        ms, packed = sevenz.parse_slt(SLT)
        self.assertEqual([(m.name[-8:], m.size, m.block, m.crc) for m in ms],
                         [('0001.jpg', 100, 0, '0000ABCD'), ('0002.jpg', 200, 0, '00001234'),
                          ('0123.jpg', 300, 1, '00005678')])
        self.assertEqual(packed, {0: 5000, 1: 7000})
        self.assertEqual(sevenz.block_starts(packed), {0: 32, 1: 5032})

    def test_choose_leading_members_with_xml(self):
        ms, _ = sevenz.parse_slt(SLT)
        got = s.choose(ms, {'NL-HaNA_1.04.02_7000_0002', 'NL-HlmNHA_1617_1703_0123'}, 1)
        self.assertEqual({b: [m.name for m in v] for b, v in got.items() if v},
                         {0: ['NL-HaNA_1.04.02_7000_0002.jpg'], 1: ['NL-HlmNHA_1617_1703_0123.jpg']})

    def test_7z_header_numbers(self):
        self.assertEqual(sevenz.number(bytes([0x7F]), 0), (0x7F, 1))
        self.assertEqual(sevenz.number(bytes([0x80, 0x90]), 0), (0x90, 2))
        self.assertEqual(sevenz.number(bytes([0xC1, 0x34, 0x12]), 0), (0x11234, 3))
        head = b"7z\xbc\xaf'\x1c\x00\x04" + b'\0' * 4 + struct.pack('<QQI', 1000, 40, 0)
        self.assertEqual(sevenz.start_header(head), (1000, 40))
        self.assertEqual(sevenz.encoded_header_pack(bytes([0x17, 0x06, 0x7F, 0x01, 0x09, 0x80, 0x90, 0x00])),
                         (0x7F, 0x90))
        self.assertIsNone(sevenz.encoded_header_pack(bytes([0x01])))

    def test_listing_needs_an_extracted_scan(self):
        self.assertEqual(s.list_pages(['a_1', 'b_2'], ['a_1.jpg', 'c_3.jpg']), [('a_1', 'a_1.jpg')])


if __name__ == '__main__':
    unittest.main()
