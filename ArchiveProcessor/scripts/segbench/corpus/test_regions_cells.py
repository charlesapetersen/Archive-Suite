"""Frozen field pilot regressions: synthetic images, no model/cluster calls."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
import regions_cells as R


def cell(cid, value, role='entry', medium='hand', kind='free_text'):
    return dict(id=cid, value=value, role=role, medium=medium, type=kind,
                box=[.101,.102,.399,.398], reviewed=True,
                **({'unknown_reason':'unreadable'} if value is None else {}))


class Pilot(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='cells spaced path ')
        self.addCleanup(tmp.cleanup); self.root = Path(tmp.name)
        (self.root/'images').mkdir(); pages=[]
        for pid, kind in [('public1','L4'), ('p024','owner96'), ('public2','L4')]:
            image=self.root/'images'/(pid+'.jpg'); Image.new('RGB',(107,211),'white').save(image)
            fields=[cell('heading','A heading','heading','print' if kind=='owner96' else 'hand'),
                    cell('text','some words'),cell('blank',''),cell('unknown',None),cell('num','10.5',kind='formatted')]
            pages.append(dict(id=pid,set=kind,sha256=R.digest(image.read_bytes()),size=[107,211],
                              capability=pid!='public2',tables=[dict(id='t1',box=[.05,.05,.95,.95],cells=fields)]))
        self.truth=dict(protocol=R.PROTOCOL,audit='synthetic test only',pages=pages)
        self.draft=self.root/'draft.json'; self.draft.write_bytes(R.encoded(self.truth))
        self.routes=self.root/'routes.json'
        self.routes.write_bytes(R.encoded({r:dict(model='org/'+r,served=r,vllm_args='--max-model-len 16384') for r in R.ROUTES}))
        self.frozen=R.freeze(self.root,self.draft,self.routes)

    def runtime(self,route):
        return dict(**self.frozen['routes'][route],revision='a'*40,job='123',vllm_version='test',
                    transformers_version='test',code_sha256=R.code_hashes())

    def collect(self,answer=None,finish='stop'):
        for route in R.ROUTES:
            for arm in R.ARMS:
                def post(url,body,timeout):
                    fields=json.loads(body['messages'][0]['content'][1]['text'].split('Fields: ')[1])
                    vals={'heading':'A heading','text':'some words','blank':'','unknown':'guessed','num':'10.5'}
                    return (answer if answer is not None else json.dumps({k:vals[k] for k in fields}),finish,{})
                with patch.object(R.C,'post',side_effect=post),patch('builtins.print'):
                    R.read(self.root,route,arm,'http://127.0.0.1:12345',self.runtime(route))

    def test_frozen_repeat_cannot_change_truth(self):
        R.freeze(self.root,self.draft,self.routes)
        self.draft.write_bytes(R.encoded({**self.truth,'audit':'changed'}))
        with self.assertRaisesRegex(ValueError,'changed existing'): R.freeze(self.root,self.draft,self.routes)
        self.assertEqual(R.check(self.root)[1],self.truth)

    def test_atomic_publish_does_not_leave_partial_final(self):
        dest = self.root / 'receipt.json'
        with patch.object(R.os, 'link', side_effect=OSError('simulated publish failure')):
            with self.assertRaises(OSError): R.write_new(dest, b'complete data')
        self.assertFalse(dest.exists())
        R.write_new(dest, b'complete data')
        self.assertEqual(dest.read_bytes(), b'complete data')

    def test_hash_geometry_ids_unknown_and_selection_validation(self):
        for change in ('image','cell','id','unknown','phase'):
            t=copy.deepcopy(self.truth)
            if change=='image': t['pages'][0]['sha256']='0'*64
            if change=='cell': t['pages'][0]['tables'][0]['cells'][0]['box']=[0,0,.5,.5]
            if change=='id': t['pages'][0]['id']='../x'
            if change=='unknown': del t['pages'][0]['tables'][0]['cells'][3]['unknown_reason']
            if change=='phase': t['pages'][0]['capability']=False
            with self.subTest(change=change),self.assertRaises(ValueError): R.validate(t,self.root)

    def test_protocol_code_and_image_drift_rejected(self):
        with patch.object(R,'INSTRUCTION',R.INSTRUCTION+'changed'):
            with self.assertRaisesRegex(ValueError,'protocol'): R.check(self.root)
        with patch.object(R,'code_hashes',return_value={}):
            with self.assertRaisesRegex(ValueError,'protocol'): R.check(self.root)
        (self.root/'images/public1.jpg').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'hash'): R.check(self.root)

    def test_rounded_cell_coordinates_exact_no_truth_sent(self):
        body,meta=R.request(self.root,next(R.tasks(self.truth,'cell')),'model')
        prompt=body['messages'][0]['content'][1]['text']
        self.assertEqual(json.loads(prompt.split('Fields: ')[1]),{'heading':[0,0,1,1]})
        self.assertNotIn('A heading',prompt); self.assertNotIn('reviewed',prompt)

    def test_scoring_never_reencodes_jpeg_and_frozen_inputs_cannot_drift(self):
        self.collect()
        with patch.object(R.C, 'jpeg_crop', side_effect=AssertionError('must use frozen JPEGs')):
            R.score(self.root)
        path = next((self.root / 'inputs').rglob('*.jpg')); path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'JPEG input changed'): R.check(self.root)

    def test_empty_object_is_not_capability_success(self):
        self.collect(answer='{}')
        self.assertTrue(all(not x['schema_and_coverage_ok'] for x in R.score(self.root)['capability'].values()))

    def test_capability_is_two_pages_all_phase_is_larger(self):
        self.assertEqual(len(list(R.tasks(self.truth,'whole'))),2)
        self.assertEqual(len(list(R.tasks(self.truth,'whole','all'))),3)

    def test_remote_urls_duplicate_keys_nonfinite_nonstring_and_extra_keys(self):
        for url in ['https://127.0.0.1:1','http://example.com:1','http://localhost:1/path','http://localhost','http://u@localhost:1']:
            with self.subTest(url=url),self.assertRaises(ValueError): R.server_url(url)
        for raw in ['{"x":"a","x":"b"}','{"x":NaN}','{"x":12}','[]']:
            with self.subTest(raw=raw),self.assertRaises(ValueError): R.parse_prediction(raw,['x'])
        self.assertEqual(R.parse_prediction('{"x":"a","extra":"b"}',['x','y']),({'x':'a','y':None},{'extra':'b'}))

    def test_equal_pooled_denominators_and_correct_cross_splits(self):
        self.collect(); report=R.score(self.root)
        rows=[r for r in report['summary'] if r['set']=='both' and r['group']=='all']
        self.assertEqual(len(rows),6)
        self.assertTrue(all(r['known']==8 and r['unknown']==2 and r['exact']==1 for r in rows))
        self.assertTrue(all(r['free_text_wer']['reference']==8 for r in rows))
        for group,n in [('handwritten_entries',6),('printed_headings',1)]:
            self.assertTrue(all(r['known']==n for r in report['summary'] if r['group']==group and r['set']=='both'))

    def test_parse_failures_preserve_comparison_and_missing_blank_coverage(self):
        self.collect(answer='not JSON'); report=R.score(self.root)
        for row in report['summary']:
            if row['group']=='all':
                self.assertEqual(row['known_responded'],0)
                self.assertIsNone(row['blank_fabrication_among_responses'])
                self.assertEqual(row['blank_exact'],0)
        self.assertTrue(all(report['requests'][r][a]['parse']>0 for r in R.ROUTES for a in R.ARMS))

    def test_caps_get_no_blank_credit(self):
        self.collect(finish='length')
        self.assertTrue(all(x['exact']==0 for x in R.score(self.root)['summary'] if x['group']=='all'))

    def test_fabricated_blanks_unknown_truth_and_missing_count_separately(self):
        m=R.metrics([cell('a',''),cell('b',''),cell('c',None),cell('d','abc')],{'a':'invented','c':'anything'})
        self.assertEqual((m['known'],m['unknown'],m['missing']),(3,1,2))
        self.assertEqual((m['blank_fabrication_rate'],m['blank_fabrication_among_responses'],m['blank_responded']),(.5,1,1))

    def test_incomplete_stale_and_mixed_revision_receipts_rejected(self):
        with self.assertRaisesRegex(ValueError,'incomplete'): R.score(self.root)
        self.collect(); path=self.root/'out/glm-ocr/whole/public1/t1/all.json'
        rec=R.load(path); rec['request_sha256']='wrong'; path.write_bytes(R.encoded(rec))
        with self.assertRaisesRegex(ValueError,'differs'): R.score(self.root)
        with self.assertRaisesRegex(ValueError,'stale'):
            R.read(self.root,'glm-ocr','whole','http://127.0.0.1:1',self.runtime('glm-ocr'))
        rec['request_sha256']=R.request(self.root,next(R.tasks(self.truth,'whole')),'glm-ocr')[1]['request_sha256']
        rec['runtime']['revision']='b'*40; path.write_bytes(R.encoded(rec))
        with self.assertRaisesRegex(ValueError,'mixed runtimes'): R.score(self.root)

    def test_resume_never_sends_again_and_runtime_mismatch_refuses(self):
        self.collect()
        resumed = self.runtime('glm-ocr'); resumed['job'] = '124'
        with patch.object(R.C,'post',side_effect=AssertionError('should not send')),patch('builtins.print'):
            self.assertEqual(R.read(self.root,'glm-ocr','cell','http://127.0.0.1:1',resumed)['sent'],0)
        runtime=self.runtime('glm-ocr'); runtime['model']='wrong'
        with self.assertRaisesRegex(ValueError,'runtime'):
            R.read(self.root,'glm-ocr','cell','http://127.0.0.1:1',runtime)


if __name__=='__main__': unittest.main()
