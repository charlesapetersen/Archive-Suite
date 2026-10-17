import io
import unittest
import zipfile

import src_btp as B

HEAD = 'Campaign,Project,Item,ItemId,Asset,AssetId,AssetStatus,DownloadUrl,Transcription,Tags\n'


def zip_of(*csvs):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for i, body in enumerate(csvs):
            z.writestr(f'campaign_{i}.csv', '﻿' + HEAD + body)
        z.writestr('README_campaign.txt', 'not a csv')
    return buf.getvalue()


class Truth(unittest.TestCase):
    def test_markup_removed_text_kept(self):
        t = 'Dear [*in margin*] Sir\r\nI [have] ? received\r\n[?] yours\r\n\r\n'
        self.assertEqual(B.truth(t), 'Dear in margin Sir\nI have received\nyours')

    def test_question_inside_a_word_stays(self):
        self.assertEqual(B.truth('What? said he'), 'What? said he')


class Rows(unittest.TestCase):
    def test_reads_every_csv_once_per_asset(self):
        a = 'C,P,I,i1,i1-1,1,completed,https://tile.loc.gov/a.jpg,text,\n'
        b = 'C,P,I,i1,i1-2,2,completed,https://tile.loc.gov/b.jpg,more,\n'
        rows = B.rows_of(zip_of(a + b, a))
        self.assertEqual([r['Asset'] for r in rows], ['i1-1', 'i1-2'])

    def test_scored(self):
        ok = {'AssetStatus': 'completed', 'Transcription': 'x', 'DownloadUrl': 'http://tile.loc.gov/a.jpg'}
        self.assertTrue(B.scored(ok))
        self.assertFalse(B.scored({**ok, 'Transcription': 'Nothing to transcribe'}))
        self.assertFalse(B.scored({**ok, 'Transcription': '[?]'}))
        self.assertFalse(B.scored({**ok, 'AssetStatus': 'in_progress'}))
        self.assertFalse(B.scored({**ok, 'DownloadUrl': 'https://example.com/a.jpg'}))


class Images(unittest.TestCase):
    def test_https_and_full_size(self):
        self.assertEqual(B.image_url('http://tile.loc.gov/image-services/iiif/service:mss:x:001/full/pct:50/0/default.jpg'),
                         'https://tile.loc.gov/image-services/iiif/service:mss:x:001/full/pct:100/0/default.jpg')
        u = 'https://tile.loc.gov/storage-services/master/mss/mgw/1499.jpg'
        self.assertEqual(B.image_url(u), u)

    def test_not_hand(self):
        for s in ('typed', 'Typewritten letter', 'Annotated transcripts; 1918', 'printed matter'):
            self.assertTrue(B.NOT_HAND.search(s), s)
        for s in ('Diary 1918', 'reprinting', 'Correspondence'):
            self.assertFalse(B.NOT_HAND.search(s), s)


class Datasets(unittest.TestCase):
    def test_every_dataset_has_a_tile_zip(self):
        urls = B.zip_urls()
        for item in B.DATASETS:
            self.assertTrue(urls[item].startswith('https://tile.loc.gov/') and urls[item].endswith('.zip'), item)


if __name__ == '__main__':
    unittest.main()
