"""Cloud pilot authority and budget tests: synthetic scratch, zero network/key access."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import ocr_cloud as C
import ocr_panel as P


class Pilot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        self.patch = patch.multiple(P, CACHE=P.CACHE, MODELS=P.MODELS, CAP=P.CAP,
            body=P.body, manifest=P.manifest, endpoint=P.endpoint, reservation=P.reservation, estimate=P.estimate)
        self.patch.start(); self.addCleanup(self.patch.stop)
        self.env = patch.dict('os.environ'); self.env.start(); self.addCleanup(self.env.stop)
        C.configure(); P.CACHE = self.cache
        (self.cache/'images').mkdir()
        self.jobs = []
        for page in sorted(P.PROBE):
            name = page+'-original'
            (self.cache/'images'/(name+'.jpg')).write_bytes(b'image')
            self.jobs.append({'id':name,'page':page,'scale':'original','width':2400,'height':1600,
                              'sha256':P.digest(b'image')})
        self.m = {'jobs':self.jobs,'pilot_pages':sorted(P.PROBE),'cap':C.CAP}

    def test_manifest_refuses_extra_or_ladder_or_changed_authority(self):
        for alter in ('extra','ladder','cap','page','oversize'):
            m = copy.deepcopy(self.m)
            if alter == 'extra': m['jobs'].append(m['jobs'][0])
            if alter == 'ladder': m['jobs'][0]['scale']='half'
            if alter == 'cap': m['cap']=3
            if alter == 'page': m['jobs'][0]['page']='p011'
            if alter == 'oversize': m['jobs'][0]['width']=2401
            with self.subTest(alter=alter), patch.object(C,'_base_manifest',return_value=m):
                with self.assertRaises(SystemExit): C.manifest()
        with patch.object(C,'_base_manifest',return_value=self.m):
            self.assertEqual(len(C.manifest()['jobs'])*len(C.MODELS),36)

    def test_routes_and_reasoning_controls(self):
        prices = {'prompt':'0.000002','completion':'0.00001'}
        for key,spec in C.MODELS.items():
            b=C.body(key,self.jobs[0],prices)
            self.assertTrue(b['provider']['require_parameters'])
            self.assertFalse(b['provider']['allow_fallbacks'])
            self.assertEqual(b['max_tokens'],8192)
            if spec[0].startswith(('openai/','anthropic/')): self.assertNotIn('temperature',b)
            if spec[0].startswith('openai/'):
                self.assertEqual(b['messages'][0]['content'][0]['image_url']['detail'],'high')

    def test_documented_input_bound_full_context_and_price_tiers(self):
        e={'_model':'google/gemini-3.1-pro-preview','context_length':1048576,
           'pricing':{'prompt':'0.000002','completion':'0.000012','image':'0.000002',
                      'overrides':[{'min_prompt_tokens':200000,'prompt':'0.000004'}]}}
        self.assertAlmostEqual(C.reservation(e),32768*.000002+8192*.000012)
        e['_model']='mistralai/mistral-large-4-0'
        self.assertAlmostEqual(C.reservation(e),1048576*.000004+8192*.000012)
        e['pricing']['request']='0.01'
        with self.assertRaisesRegex(SystemExit,'per-request'): C.reservation(e)
        e['pricing'].pop('request');e['pricing']['image']='1'
        with self.assertRaisesRegex(SystemExit,'image price'): C.reservation(e)

    def test_only_unbought_routes_may_be_reconfigured(self):
        old={'jobs':self.jobs,'cap':C.CAP,'models':{'a':['m','p',None,'off',None],'b':['n','p',None,'off',None]}}
        new=copy.deepcopy(old); new['models']['a'][3]='low'
        self.assertTrue(C.reconfigurable(old,new))
        P.append({'key':'a','status':'http-rejected','cost':0})
        self.assertTrue(C.reconfigurable(old,new))
        P.append({'key':'b','status':'ok','cost':.01})
        self.assertTrue(C.reconfigurable(old,new))
        bought=copy.deepcopy(old); bought['models']['b'][3]='low'
        self.assertFalse(C.reconfigurable(old,bought))
        added=copy.deepcopy(old); added['models']['c']=['x','p',None,'off',None]
        self.assertFalse(C.reconfigurable(old,added))
        capped=copy.deepcopy(new); capped['cap']=3
        self.assertFalse(C.reconfigurable(old,capped))
        P.append({'key':'a','status':'ok','cost':.02})
        self.assertFalse(C.reconfigurable(old,new))

    def test_approved_pilot_cap_and_serial_execution(self):
        import os
        self.assertEqual(P.CAP+C.MISTRAL_RESERVE,.75)
        self.assertEqual(os.environ['OCR_PANEL_CONCURRENCY'],'1')
        with patch.object(C,'manifest',return_value=self.m),patch.object(P,'collect') as collect:
            C.pilot()
        collect.assert_called_once_with(probe=True)

    def test_resume_refuses_prior_bound_violation_before_network(self):
        P.append({'model':'openai/gpt-5.6-sol','prompt_tokens':32769,'cost':.01,'reserve':.3})
        with patch.object(C,'manifest',return_value=self.m),patch.object(P,'collect') as collect:
            with self.assertRaisesRegex(SystemExit,'input bound'): C.pilot()
            collect.assert_not_called()

    def test_no_full_run_command(self):
        import sys
        for command in ('collect','full','vision'):
            with patch.object(sys,'argv',['ocr_cloud.py',command]),patch.object(P,'collect') as collect:
                with self.assertRaises(SystemExit) as e: C.main()
                self.assertEqual(e.exception.code,2)
                collect.assert_not_called()

    def test_bound_violation_stops_before_second_paid_call(self):
        import method_openrouter as OR
        e={'_model':'openai/gpt-5.6-sol','_input_bound':32768,'context_length':1050000,
           'pricing':{'prompt':'0.000004','completion':'0.00002'}}
        response=Mock(status_code=200)
        response.json.return_value={'usage':{'cost':.01,'prompt_tokens':32769},
          'choices':[{'finish_reason':'stop','message':{'content':'KIND: printed\nTABLE: no\nTEXT:\nWord'}}]}
        post=Mock(return_value=response)
        with patch.object(P,'manifest',return_value=self.m),patch.object(P,'endpoint',return_value=e),\
             patch.object(OR,'api_key',return_value='fake'),patch('requests.post',post),patch.object(P,'estimate'):
            with self.assertRaisesRegex(SystemExit,'exceeded'): P.collect(probe=True,only='gpt5.6-sol')
        self.assertEqual(post.call_count,1)
        self.assertEqual(P.spent(),.01)

    def test_mistral_flat_billing_and_resume_never_repurchases(self):
        import ocr_cloud_mistral as M
        def fake_run(argv, **kwargs):
            prefix=Path(argv[-1])
            P.save(prefix.with_suffix('.json'),{'text':'synthetic'})
            P.save(Path(str(prefix)+'.http-fake.json'),{'http':200,'body':{'model':'mistral-ocr-4-1','usage_info':{'pages_processed':1}}})
        with patch.object(C,'configure'),patch.object(C,'CACHE',self.cache),\
             patch.object(C,'manifest',return_value=self.m),patch('subprocess.run',side_effect=fake_run) as run:
            M.collect('/tmp/fake-driver')
            self.assertEqual(run.call_count,3)
            summary=json.loads((self.cache/'mistral-summary.json').read_text())
            self.assertEqual(summary,{'completed':3,'accounted_cost':.012})
            M.collect('/tmp/fake-driver');self.assertEqual(run.call_count,3)

    def test_mistral_unknown_outcome_retains_reservation_and_stops_resume(self):
        import ocr_cloud_mistral as M
        with patch.object(C,'configure'),patch.object(C,'CACHE',self.cache),\
             patch.object(C,'manifest',return_value=self.m),patch('subprocess.run',side_effect=RuntimeError('lost reply')) as run:
            with self.assertRaisesRegex(RuntimeError,'lost reply'): M.collect('/tmp/fake-driver')
            with self.assertRaisesRegex(SystemExit,'uncertain OCR'): M.collect('/tmp/fake-driver')
            self.assertEqual(run.call_count,1)
            self.assertEqual(len(list((self.cache/'mistral').glob('*.pending.json'))),1)

    def test_mistral_rate_limit_releases_page_but_other_failures_do_not(self):
        import ocr_cloud_mistral as M
        calls=[]
        def fake_run(argv, **kwargs):
            prefix=Path(argv[-1]);calls.append(prefix.name)
            if len(calls)==1:
                P.save(prefix.with_suffix('.json'),{'errorMessage':'Rate limit exceeded.','errorCode':'429'})
                for n in range(2): P.save(Path(str(prefix)+f'.http-{n}.json'),{'http':429,'body':{'type':'rate_limited'}})
            else:
                P.save(prefix.with_suffix('.json'),{'text':'synthetic'})
                P.save(Path(str(prefix)+'.http-ok.json'),{'http':200,'body':{'model':'mistral-ocr-4-1','usage_info':{'pages_processed':1}}})
        with patch.object(C,'configure'),patch.object(C,'CACHE',self.cache),\
             patch.object(C,'manifest',return_value=self.m),patch('subprocess.run',side_effect=fake_run):
            with self.assertRaisesRegex(SystemExit,'rate limit'): M.collect('/tmp/fake-driver')
            root=self.cache/'mistral'
            self.assertEqual(list(root.glob('*.pending.json')),[])
            self.assertEqual(len(list((root/'rate-limited').glob('*/*.json'))),3)  # kept, not deleted
            M.collect('/tmp/fake-driver')
            self.assertEqual(calls[0],calls[1]);self.assertEqual(len(calls),4)
            self.assertEqual(json.loads((self.cache/'mistral-summary.json').read_text())['accounted_cost'],.012)
            # A pending page with a 200 among its replies, or no client result, is never released.
            pend=root/'x.pending.json';P.save(pend,{'reserve':.004})
            self.assertFalse(M.settle_rate_limited(root,'x'))
            P.save(root/'x.json',{'errorCode':'429'});P.save(root/'x.http-a.json',{'http':429})
            P.save(root/'x.http-b.json',{'http':200})
            self.assertFalse(M.settle_rate_limited(root,'x'));self.assertTrue(pend.exists())

    def test_mistral_unexpected_model_stops_before_another_page(self):
        import ocr_cloud_mistral as M
        def fake_run(argv, **kwargs):
            prefix=Path(argv[-1]);P.save(prefix.with_suffix('.json'),{'text':'synthetic'})
            P.save(Path(str(prefix)+'.http-fake.json'),{'http':200,'body':{'model':'new-unknown-model','usage_info':{'pages_processed':1}}})
        with patch.object(C,'configure'),patch.object(C,'CACHE',self.cache),\
             patch.object(C,'manifest',return_value=self.m),patch('subprocess.run',side_effect=fake_run) as run:
            with self.assertRaisesRegex(SystemExit,'unexpected OCR usage'): M.collect('/tmp/fake-driver')
            self.assertEqual(run.call_count,1)
            self.assertEqual(len(list((self.cache/'mistral').glob('*.pending.json'))),1)

    def test_report_withholds_incomplete_total(self):
        import ocr_cloud_report as R
        import io, contextlib
        truth=self.cache/'truth';truth.mkdir()
        for j in self.jobs: (truth/(j['page']+'.txt')).write_text('synthetic truth')
        with patch.object(C,'manifest',return_value=self.m),patch.object(P,'TRUTH',self.cache),\
             patch.object(P,'RESULTS',self.cache),contextlib.redirect_stdout(io.StringIO()) as stdout:
            R.report()
        self.assertIn('projection withheld',stdout.getvalue())
        self.assertNotIn('99-page mean',stdout.getvalue())
        estimate=json.loads((self.cache/'pilot-estimate.json').read_text())
        self.assertFalse(estimate['complete']);self.assertIsNone(estimate['mean_99'])
        self.assertIn('projection withheld',(self.cache/'ocr-panel-cloud-pilot.md').read_text())


if __name__=='__main__': unittest.main()
