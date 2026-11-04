"""No corpus or model: held-out examples, paired conditions, hashes and failure gate."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import hand_icl as H


class Examples(unittest.TestCase):
    def test_nested_examples_and_target_alias_exclusion(self):
        pool=[dict(id=str(i),source_sha256=str(i//4)) for i in range(40)]
        out=H.sample_lines(pool,'0')
        self.assertEqual(len(out),16)
        self.assertFalse(any(p['source_sha256']=='0' for p in out))
        self.assertEqual(len({p['source_sha256'] for p in out[:8]}),8)
        self.assertEqual(H.sample_lines(pool,'0',8),out[:8])
        with self.assertRaises(ValueError): H.sample_lines(pool[:8],'0')


class Pack(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        (self.root/'target.jpg').write_bytes(b'target')
        (self.root/'line.jpg').write_bytes(b'example')
        examples=[dict(id=str(i),source_sha256='different',image='line.jpg',text='fictional') for i in range(16)]
        self.jobs=[dict(id='p-n'+str(n),page='p',cohort='synthetic',image='target.jpg',
                       examples_n=n,target_source_sha256='targethash',examples=examples[:n]) for n in H.COUNTS]
        self.write()

    def write(self):
        H.dump(self.root/'jobs.json',self.jobs)
        files={p.name:H.sha(p) for p in self.root.iterdir() if p.is_file() and p.name!='freeze.json'}
        H.dump(self.root/'freeze.json',dict(jobs=len(self.jobs),files=files,cohorts={'synthetic':1},max_tokens=8192))

    def test_verified_then_tampered_image_refused(self):
        H.check(self.root)
        (self.root/'target.jpg').write_bytes(b'changed')
        with self.assertRaises(ValueError):H.check(self.root)

    def test_leak_unpaired_and_non_nested_refused(self):
        original=copy.deepcopy(self.jobs)
        for mode in ('leak','unpaired','nested'):
            self.jobs=copy.deepcopy(original)
            if mode=='leak':self.jobs[-1]['examples'][0]['source_sha256']='targethash'
            elif mode=='unpaired':self.jobs.pop()
            else:self.jobs[1]['examples']=list(reversed(self.jobs[1]['examples']))
            self.write()
            with self.assertRaises(ValueError):H.check(self.root)

    def test_target_truth_not_in_messages(self):
        msg=H.messages(self.root,self.jobs[1])
        content=msg[0]['content']
        self.assertEqual(sum(c['type']=='image_url' for c in content),9)
        self.assertNotIn('truth',json.dumps(msg))

    def test_nonlocal_endpoint_refused(self):
        with self.assertRaises(ValueError):H.run(self.root,'https://example.test')

    def test_failed_pilot_stops_and_existing_answers_refuse_repeat(self):
        reply=dict(choices=[dict(finish_reason='length',message=dict(content='fixture'))])
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self):return json.dumps(reply).encode()
        # Add a non-pilot page so the full-stage gate has work to refuse.
        more=[]
        for name in ('q','r'):
            for j in copy.deepcopy(self.jobs):
                j['id']=j['id'].replace('p-',name+'-');j['page']=name;more.append(j)
        self.jobs+=more;self.write()
        with mock.patch.object(H.urllib.request,'urlopen',return_value=Response()) as call:
            self.assertEqual(H.run(self.root,'http://127.0.0.1:12345'),2)
            self.assertEqual(call.call_count,6)
            with self.assertRaises(ValueError):H.run(self.root,'http://127.0.0.1:12345')

    def collect_fixture(self):
        freeze=dict(json.loads((self.root/'freeze.json').read_text()),revision=H.REVISION)
        (self.root/'results').mkdir(exist_ok=True);(self.root/'runtime').mkdir(exist_ok=True)
        H.dump(self.root/'runtime/1.json',dict(revision=H.REVISION))
        H.dump(self.root/'results/status.json',dict(state='completed',completed=len(self.jobs)))
        rows=[dict(id=j['id'],page=j['page'],cohort=j['cohort'],examples_n=j['examples_n'],status='ok',finish='stop',
                   text='fixture',request_sha256=H.hashlib.sha256(H.request_body(self.root,freeze,j)).hexdigest())
              for j in self.jobs]
        return freeze,rows

    def write_rows(self,rows):
        (self.root/'results/answers.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))

    def test_collected_accepts_exact_run_and_refuses_tampering(self):
        freeze,rows=self.collect_fixture()
        self.write_rows(rows)
        by,_,_=H.collected(self.root,self.jobs,freeze)
        self.assertTrue(all(r['ok'] for r in by.values()))
        for mode in ('hash','missing','repeat','stopped'):
            bad=copy.deepcopy(rows)
            if mode=='hash':bad[1]['request_sha256']='0'*64
            elif mode=='missing':bad.pop()
            elif mode=='repeat':bad.append(bad[0])
            self.write_rows(bad)
            if mode=='stopped':H.dump(self.root/'results/status.json',dict(state='pilot_stopped',completed=1))
            with self.assertRaises(ValueError):H.collected(self.root,self.jobs,freeze)

    def test_capped_reply_is_a_failure_not_a_reading(self):
        freeze,rows=self.collect_fixture()
        rows[2].update(status='cap_or_empty',finish='length')
        self.write_rows(rows)
        by,_,_=H.collected(self.root,self.jobs,freeze)
        self.assertFalse(by[rows[2]['id']]['ok'])

    def test_copied_examples_counts_verbatim_lines_only(self):
        job=dict(examples=[dict(text='a long example reading'),dict(text='short')])
        self.assertEqual(H.copied_examples(job,'x a long example reading y'),(1,1))
        self.assertEqual(H.copied_examples(job,'nothing here'),(0,1))


if __name__=='__main__':unittest.main()
