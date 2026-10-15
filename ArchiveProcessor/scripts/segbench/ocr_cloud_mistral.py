"""Run ONLY the three approved images through a compiled production MistralClient harness.

Compile (under heavy-run.py), from the suite root:
 swiftc -parse-as-library -warnings-as-errors <segbench>/ocr-cloud-mistral.swift \
 <app>/OCR/{MistralClient,ImageEncoding,NetworkSession,OCRErrorMessages}.swift -o /tmp/w41-ocr-mistral
Then: ocr_cloud_mistral.py /tmp/w41-ocr-mistral        (the pilot's three pages)
  or: ocr_cloud_mistral.py --full /tmp/w41-ocr-mistral (the owner-approved 99 originals, ocr_cloud_full's cache)
No key is ever printed or persisted. Flat-page reservations survive interruption; never retry them.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import ocr_cloud as C
import ocr_panel as P


def settle_rate_limited(root, job_id):
    """Release a page whose every recorded reply was a 429 and whose client finished on that 429.

    Mistral bills processed pages, and a 429 processed none. The replies are moved aside, never deleted,
    so the page can be tried again later. Anything else (no result, a 200, another status) stays uncertain.
    """
    pending, dest = root/(job_id+'.pending.json'), root/(job_id+'.json')
    http = sorted(root.glob(job_id+'.http-*.json'))
    if not (pending.exists() and dest.exists() and http):
        return False
    if (str(json.loads(dest.read_text()).get('errorCode')) != '429'
            or any(json.loads(h.read_text()).get('http') != 429 for h in http)):
        return False
    aside = root/'rate-limited'/(job_id+'-'+str(int(time.time()*1000)))
    aside.mkdir(parents=True)
    for f in http + [dest]:
        f.rename(aside/f.name)
    pending.unlink()
    return True


def collect(binary, full=False):
    if os.environ.get('OCR_CLOUD_MISTRAL_FIXTURE'):
        raise SystemExit('offline fixtures must not enter the paid ledger')
    if full:
        import ocr_cloud_full as F
        F.configure(); m=F.manifest(); cache, cap, reserve = F.CACHE, F.CAP, F.MISTRAL_RESERVE
    else:
        C.configure(); m=C.manifest(); cache, cap, reserve = C.CACHE, C.CAP, C.MISTRAL_RESERVE
    C.validate_ledger()
    with (cache/'run.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if list((cache/'pending').glob('*.json')):
            raise SystemExit('uncertain chat call: reconcile first')
        root=cache/'mistral';root.mkdir(exist_ok=True)
        for j in m['jobs']:
            dest=root/(j['id']+'.json');pending=root/(j['id']+'.pending.json')
            if pending.exists() and not settle_rate_limited(root, j['id']):
                raise SystemExit('uncertain OCR call: do not repurchase')
            if dest.exists(): continue
            image=cache/'images'/(j['id']+'.jpg')
            if P.digest(image.read_bytes())!=j['sha256']: raise SystemExit('image changed')
            # The whole OCR reserve was held apart from every chat reservation from the start.
            if P.spent()+reserve>cap: raise SystemExit('combined cap')
            P.save(pending,{'reserve':.004,'job':j['id'],'model':'mistral-ocr-4-1'})
            env={**os.environ,'VISIONHYBRID_TEST':'1'}
            subprocess.run([str(Path(binary).resolve()),str(image),str(dest.with_suffix(''))],env=env,check=True)
            if settle_rate_limited(root, j['id']):
                raise SystemExit('Mistral rate limit (429, nothing billed); try again later')
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
        P.save(cache/'mistral-summary.json',{'completed':sum(r['status']=='ok' for r in bills),
                                           'accounted_cost':sum(r['accounted_cost'] for r in bills)})


if __name__=='__main__':
    args=sys.argv[1:]; full=args[:1]==['--full']
    if len(args)!=1+full: raise SystemExit('usage: ocr_cloud_mistral.py [--full] COMPILED_DRIVER')
    collect(args[-1], full)
