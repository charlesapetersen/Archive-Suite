#!/usr/bin/env python3
"""W46.ocr-family-coverage, the CPU setup job's Python (setup-job.sh runs every step inside the vLLM image).

  family_setup.py prompts CANDIDATES [--from DIR]      each `prompt_from` read from the model's own source, in place
  family_setup.py download CANDIDATES ROOT895 ROOT96   boxes_setup.download: pinned snapshots, prepared.json in both
  family_setup.py subset ROOT895 KEY IDS_FILE          a key's page subset of public895.jsonl (CHURRO's 455)
  family_setup.py check KEY ROOT895 ROOT96             in the key's python: vLLM serves the architecture, the prompt
                                                       is there, the card's logits processor and client import

prompts: a candidate's `prompt` is a transcription made on the Mac (2026-11-17; the session had no network, so two
came through a web summary); `prompt_from` names the source the card's own tooling uses, a PyPI package (`pypi`,
`file`) or a raw file (`url`), and `expr`, the variable or call that gives the prompt. The file is run on its own in
a fresh namespace (a prompt built by an f-string or a function cannot be read without running it) and `expr`
evaluated there. The source wins where the two differ; `prompt_check` records the archive or URL, the file's
sha256, whether they matched and the transcription it replaced. If the source cannot be fetched or run, the
transcription stands and `prompt_check` says why; a candidate left with no prompt is skipped at check.
`--from DIR` reads DIR/<basename of the url or the package name> instead of fetching (tests, a dry run).
"""
from pathlib import Path
import hashlib
import json
import os
import sys
import tempfile
import traceback
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent / 'new-open-boxes'), str(HERE.parent / 'new-open')]
import boxes_setup as S  # noqa: E402
import prompt_source as PS  # noqa: E402


def evaluate(source, expr):
    ns = {'__name__': 'family_prompt_source', '__builtins__': __builtins__}
    exec(compile(source, 'prompt-source', 'exec'), ns)  # noqa: S102  the card's own prompt file, nothing else
    value = eval(expr, ns)  # noqa: S307
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'{expr} is not a non-empty string')
    return value


def fetch_source(spec, local=None):
    """(file text, where it came from)."""
    if 'url' in spec:
        if local:
            p = Path(local) / Path(spec['url']).name
            return p.read_text(), str(p)
        with urllib.request.urlopen(spec['url'], timeout=60) as r:
            return r.read().decode(), spec['url']
    if local:
        archive = next(p for p in sorted(Path(local).iterdir()) if p.name.startswith(spec['pypi'].replace('-', '_'))
                       or p.name.startswith(spec['pypi']))
    else:
        archive = PS.fetch(spec['pypi'], tempfile.mkdtemp(prefix='famprompt-'))
    return PS.read_member(archive, spec['file']), Path(archive).name


def prompts(cands, local=None):
    path = Path(cands)
    data = json.loads(path.read_text())
    for c in data:
        spec = c.get('prompt_from')
        if not spec:
            continue
        try:
            text, where = fetch_source(spec, local)
            found = evaluate(text, spec['expr'])
        except Exception as exc:  # noqa: BLE001
            c['prompt_check'] = {'error': f'{type(exc).__name__}: {exc}'[:500],
                                 'used': 'the transcription' if c.get('prompt') else 'nothing: no prompt'}
            print(c['key'], 'prompt source failed:', c['prompt_check']['error'][:200])
            continue
        check = {'source': where, 'file_sha256': hashlib.sha256(text.encode()).hexdigest(),
                 'same_as_transcription': found == c.get('prompt')}
        if found != c.get('prompt'):
            check['transcription'] = c.get('prompt')
            c['prompt'] = found
        c['prompt_check'] = check
        print(c['key'], 'prompt from', where, 'same' if check['same_as_transcription'] else 'REPLACED the transcription')
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + '\n')


def subset(root, key, ids_file):
    root = Path(root)
    want = [x.strip() for x in Path(ids_file).read_text().splitlines() if x.strip()]
    rows = [json.loads(x) for x in (root / 'public895.jsonl').read_text().splitlines() if x.strip()]
    keep = [r for r in rows if r['id'] in set(want)]
    if len(keep) != len(want) or len(set(want)) != len(want):
        raise SystemExit(f'{key}: {len(keep)} of {len(want)} subset pages found in public895.jsonl')
    name = f'public895-{key}.jsonl'
    (root / name).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in keep))
    p = root / key / 'prepared.json'
    rec = json.loads(p.read_text())
    rec['manifest_895'] = name
    S.save(p, rec)
    print(key, 'subset', name, len(keep))


def check(key, roots):
    rec = json.loads((roots[0] / key / 'prepared.json').read_text())
    if rec['state'] != 'downloaded':
        print(key, rec['state'], 'not checked')
        return
    try:
        if not (rec.get('prompt') or '').strip():
            raise RuntimeError('no prompt: ' + json.dumps(rec.get('prompt_check')))
        import importlib
        import torch
        import vllm
        from vllm import ModelRegistry
        versions = {'torch': torch.__version__, 'vllm': vllm.__version__, 'python': sys.version.split()[0]}
        if not torch.__version__.endswith('+cu129'):
            raise RuntimeError('the environment replaced the image torch: ' + torch.__version__)
        archs = json.loads(Path(rec['snapshot'], 'config.json').read_text()).get('architectures') or []
        if not set(archs) & set(ModelRegistry.get_supported_archs()):
            raise RuntimeError(f'architecture {archs} unsupported by the installed vLLM {vllm.__version__}; '
                               'no environment upgrade')
        notes = {}
        for p in (rec.get('vllm') or {}).get('logits_processors', []):
            # Recorded, not fatal: a model module may need the GPU platform this CPU node lacks.
            try:
                getattr(importlib.import_module(p.split(':')[0]), p.split(':')[1])
            except Exception as exc:  # noqa: BLE001
                notes['logits_processor_import'] = f'{type(exc).__name__}: {exc}'[:300]
        if rec.get('check_processor', True):
            # The processor and tokenizer vLLM will load (remote code included), without a weight. Not for
            # DeepSeek-OCR-2, whose processor is vLLM's own, nor MinerU, whose client builds the engine.
            from transformers import AutoProcessor
            AutoProcessor.from_pretrained(rec['snapshot'], local_files_only=True,
                                          trust_remote_code=bool((rec.get('vllm') or {}).get('trust_remote_code')))
        if rec['adapter'] == 'mineru':
            import mineru_vl_utils
            from mineru_vl_utils import MinerUClient, MinerULogitsProcessor  # noqa: F401
            versions['mineru_vl_utils'] = getattr(mineru_vl_utils, '__version__', None) or S_version('mineru-vl-utils')
            drift = S.vllm_drift()
            if drift:
                raise RuntimeError('the overlay moved packages vLLM needs: ' + ', '.join(drift))
        used = Path(sys.prefix, 'constraints-used')
        rec.update(state='ready', python=sys.executable, check_versions=versions, check_notes=notes,
                   constraints_used=used.read_text().strip() if used.exists() else None)
    except Exception:  # noqa: BLE001
        rec.update(state='skipped', reason='check failed: ' + traceback.format_exc()[-1500:])
    S.write_both(roots, key, rec)
    print(key, rec['state'], rec.get('check_versions', ''), rec.get('reason', '')[-400:])


def S_version(name):
    import importlib.metadata as md
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return None


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'prompts':
        prompts(args[0], args[2] if len(args) > 2 and args[1] == '--from' else None)
    elif cmd == 'download':
        S.download(args[0], [Path(p) for p in args[1:3]])
    elif cmd == 'subset':
        subset(*args[:3])
    elif cmd == 'check':
        check(args[0], [Path(p) for p in args[1:3]])
    else:
        raise SystemExit('prompts | download | subset | check')


if __name__ == '__main__':
    os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
    main()
