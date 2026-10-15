"""Run ONLY the three approved images through a compiled production MistralClient harness.

Compile (under heavy-run.py), from the suite root:
 swiftc -parse-as-library -warnings-as-errors <segbench>/ocr-cloud-mistral.swift \
 <app>/OCR/{MistralClient,ImageEncoding,NetworkSession,OCRErrorMessages}.swift -o /tmp/w41-ocr-mistral
Then: ocr_cloud_mistral.py /tmp/w41-ocr-mistral
No key is ever printed or persisted. Flat-page reservations survive interruption; never retry them.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import ocr_cloud as C
import ocr_panel as P


def collect(binary):
    if os.environ.get('OCR_CLOUD_MISTRAL_FIXTURE'):
        raise SystemExit('offline fixtures must not enter the paid ledger')
    C.configure(); m=C.manifest(); C.validate_ledger()
    with (C.CACHE/'run.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if list((C.CACHE/'pending').glob('*.json')):
            raise SystemExit('uncertain chat call: reconcile first')
        root=C.CACHE/'mistral';root.mkdir(exist_ok=True)
        for j in m['jobs']:
            dest=root/(j['id']+'.json');pending=root/(j['id']+'.pending.json')
            if pending.exists(): raise SystemExit('uncertain OCR call: do not repurchase')
            if dest.exists(): continue
            image=C.CACHE/'images'/(j['id']+'.jpg')
            if P.digest(image.read_bytes())!=j['sha256']: raise SystemExit('image changed')
            # $0.012 was held apart from every chat reservation from the start.
            if P.spent()+C.MISTRAL_RESERVE>C.CAP: raise SystemExit('combined cap')
            P.save(pending,{'reserve':.004,'job':j['id'],'model':'mistral-ocr-4-1'})
            env={**os.environ,'VISIONHYBRID_TEST':'1'}
            subprocess.run([str(Path(binary).resolve()),str(image),str(dest.with_suffix(''))],env=env,check=True)
            result=json.loads(dest.read_text())
            http=[json.loads(p.read_text()) for p in root.glob(j['id']+'.http-*.json')]
            accepted=[r for r in http if r['http']==200]
            if (len(accepted)!=1 or accepted[0]['body'].get('model')!='mistral-ocr-4-1'
                    or accepted[0]['body'].get('usage_info',{}).get('pages_processed')!=1):
                raise SystemExit('unexpected OCR usage; reservation retained')
            P.save(root/(j['id']+'.billing.json'),{'accounted_cost':.004,'status':'ok' if result.get('text') else 'failed'})
            pending.unlink()
            print('mistral-ocr '+j['id']+' accounted $0.004',flush=True)
        bills=[json.loads(p.read_text()) for p in root.glob('*.billing.json')]
        P.save(C.CACHE/'mistral-summary.json',{'completed':sum(r['status']=='ok' for r in bills),
                                           'accounted_cost':sum(r['accounted_cost'] for r in bills)})


if __name__=='__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: ocr_cloud_mistral.py COMPILED_DRIVER')
    collect(sys.argv[1])
