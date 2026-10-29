#!/usr/bin/env python3
"""W46.ent-robust G17: the RISE-UNIBAS humanities_data_benchmark "Business Letters" task, packed for our vLLM sender
and scored with the benchmark's own code.

    python3 ent_g17.py pack  --root DIR [--image-root PATH] [--original-images]
    python3 ent_g17.py score --root DIR [--label NAME] [--summary FILE]
    python3 ent_g17.py selfcheck

Python: /opt/homebrew/bin/python3 (3.14, pydantic 2.12.5, Pillow 12.1.1). pydantic is needed because the benchmark's
Document dataclass is a pydantic model; Pillow because the harness's client resizes the scans (below).

The benchmark is a GPL-3 clone at ~/Library/Caches/ArchiveSuiteRehearsal/ent-robust/g17 (override with G17_CLONE).
None of its code is copied here: this script puts the clone on sys.path and calls it.

What is unchanged from the harness (scripts/benchmark_base.py + generic-llm-api-client 0.5.2, its `ai_client`):
- The letters: Benchmark.get_all_basenames over images/ with BusinessLetters' `_p\\d+$` page pattern (57 letters,
  98 pages, every one with a ground truth), each letter's pages from Benchmark.get_image_paths (sorted, all pages of
  one letter in one request).
- The prompt: Benchmark.load_prompt on prompts/prompt.txt, called on a bench object built here. For a chat-API model
  (no `api_style: responses` rule) no schema text is appended to the prompt; the schema goes as structured output.
- Structured output: for the chat API (openai/openrouter/scicore providers, all OpenAIClient) the harness passes the
  Document class as `response_format`, which the client sends through the OpenAI SDK's
  beta.chat.completions.parse, i.e. {"type":"json_schema","json_schema":{"name":"Document","schema":<strict schema>,
  "strict":true}}. The strict schema is Document.model_json_schema() put through the SDK's to_strict_json_schema
  rules (additionalProperties false on every object, every property required, None defaults dropped, $ref with
  siblings inlined), reimplemented below in `strict_schema`.
- Images: the client resizes any image whose longer side exceeds max_image_size=2048 (the harness never overrides
  it) with PIL Image.thumbnail((2048, 2048), LANCZOS) and re-encodes it JPEG quality 85, optimize=True. `pack`
  does the same (our Pillow is 12.1.1, the harness pins 11.1, so bytes may differ slightly, pixels should not).
  --original-images copies the scans unchanged instead.
- Temperature 0.0 (benchmarks_tests.csv for every business_letters row).
- Scoring: BusinessLetters.score_request_answer per letter and BusinessLetters.score_benchmark over the list, the
  benchmark's own code. An unparseable reply is scored as a miss (score_unparseable_as_miss), as the harness does.
- Parsing a reply into LLMResponse.parsed: as the client's structured path, the reply's JSON is validated with
  Document and parsed = Document(...).model_dump() (its validator drops null/blank list entries); if it does not
  validate, the client would fall back to a json_object request and use the extracted JSON unvalidated, which is
  what we use. JSON is extracted as ai_client.utils.extract_json_from_text does (```json fence, else ``` fence,
  else the whole text) and a reply that is the schema echoed back is rejected (rejects_schema_echo).
- Signed/unsigned split: the card's two rule variants (skip_signatures / skip_non_signatures) score the 25 unsigned
  and 32 signed letters separately; here score_benchmark is run on each subset of the same replies (ground truth
  has_signatures), which is what those variants compute.

What is ours, and differs from a harness run:
- Nothing in the request: postcorrect_cluster.py sends the harness's system message (`system`), its order (prompt
  first, then images: `content_order: "text-first"`) and its 16384-token cap (`max_tokens`) as the pack gives them.
- Thinking off (the sender), as every bench 27B row.
- The model, Qwen3.6-27B-FP8 on vLLM, whose guided decoding enforces the schema rather than OpenAI's.
- The structured-path fallback (a second, json_object request) is not made; the first reply is used as above.
"""
import argparse, hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile, types

CLONE = pathlib.Path(os.environ.get('G17_CLONE', '~/Library/Caches/ArchiveSuiteRehearsal/ent-robust/g17')).expanduser()
BENCH_DIR = CLONE / 'benchmarks' / 'business_letters'
SUMMARY = pathlib.Path('~/Library/Caches/ArchiveSuiteRehearsal/ent-robust/g17-summary.json').expanduser()
ROLE = 'You are a historian with keyword knowledge and an expert in the field of 20th century Swiss history'
MAX_IMAGE = 2048          # ai_client BaseAIClient max_image_size default
JPEG_QUALITY = 85         # ai_client BaseAIClient image_quality default
_SCHEMA_KEYWORDS = ('$schema', '$defs', 'definitions', 'properties', 'required', 'additionalProperties', 'type')


# ---------------------------------------------------------------- the clone, with the API client stubbed
def _stub_ai_client():
    """The scorer imports ai_client (generic-llm-api-client) only for LLMResponse; give it a minimal stand-in."""
    try:
        import ai_client  # noqa: F401  -- the real one, if installed
        return
    except ImportError:
        pass

    class LLMResponse:
        def __init__(self, text='', parsed=None, **kw):
            self.text, self.parsed = text, parsed
            self.__dict__.update(kw)

    class Usage:
        def __init__(self, **kw):
            self.__dict__.update(kw)

    class OpenAIClient:
        @classmethod
        def _rejects_custom_temperature(cls, model):
            return False

    class MistralClient:
        def _create_response_from_raw(self, *a, **k):
            raise NotImplementedError

    class Lenient(types.ModuleType):
        """Any other name the clone imports (PricingManager, ...) resolves to an inert placeholder."""
        def __getattr__(self, name):
            if name.startswith('__'):
                raise AttributeError(name)
            return type(name, (), {'__init__': lambda self, *a, **k: None})

    root = Lenient('ai_client')
    root.LLMResponse, root.Usage = LLMResponse, Usage
    root.create_ai_client = lambda *a, **k: None
    pricing = Lenient('ai_client.pricing')
    pricing.apply_costs = lambda *a, **k: None
    pricing.set_pricing_file = lambda *a, **k: None
    oc = Lenient('ai_client.openai_client')
    oc.OpenAIClient, oc.FIXED_TEMPERATURE_FAMILIES = OpenAIClient, ()
    mc = Lenient('ai_client.mistral_client')
    mc.MistralClient = MistralClient
    root.pricing, root.openai_client, root.mistral_client = pricing, oc, mc
    sys.modules.update({'ai_client': root, 'ai_client.pricing': pricing,
                        'ai_client.openai_client': oc, 'ai_client.mistral_client': mc})


def load_bench():
    """A BusinessLetters object with only what pack/score need; __init__ is bypassed (it builds an API client)."""
    for p in (str(CLONE), str(CLONE / 'scripts')):
        if p not in sys.path:
            sys.path.insert(0, p)
    _stub_ai_client()
    import logging
    logging.disable(logging.CRITICAL)   # load_prompt logs the whole prompt at INFO; the scorer logs each miss
    # scripts/__init__.py makes ./logs and a log file in the working directory; keep that out of the caller's.
    here, logs = os.getcwd(), pathlib.Path(tempfile.gettempdir()) / 'ent-g17-import'
    logs.mkdir(exist_ok=True); os.chdir(logs)
    try:
        from benchmarks.business_letters.benchmark import BusinessLetters
        from benchmarks.business_letters.dataclass import Document
    finally:
        os.chdir(here)
    from ai_client import LLMResponse
    b = BusinessLetters.__new__(BusinessLetters)
    b.id, b.name, b.benchmark_dir = 'G17', 'business_letters', str(BENCH_DIR)
    b.provider, b.model, b.role_description = 'scicore', 'Qwen3.6-27B-FP8', ROLE
    b.prompt_file, b.temperature, b.rules, b.dataclass_name, b.dataclass = 'prompt.txt', 0.0, None, 'Document', Document
    return b, Document, LLMResponse


def letters(b):
    """The harness's object list; the scored letters are those with a ground truth (all of them here)."""
    names = b.get_all_basenames([os.path.join(b.benchmark_dir, 'images'), os.path.join(b.benchmark_dir, 'texts')],
                                page_pattern=b.get_basename_pattern())
    return [n for n in names if (BENCH_DIR / 'ground_truths' / f'{n}.json').exists()]


# ---------------------------------------------------------------- structured output, as the OpenAI SDK builds it
def strict_schema(schema, root=None):
    """The OpenAI SDK's to_strict_json_schema rules, applied to a pydantic model_json_schema() dict (mutates it)."""
    root = schema if root is None else root
    for key in ('$defs', 'definitions'):
        if isinstance(schema.get(key), dict):
            for sub in schema[key].values():
                strict_schema(sub, root)
    if schema.get('type') == 'object' and 'additionalProperties' not in schema:
        schema['additionalProperties'] = False
    if isinstance(schema.get('properties'), dict):
        schema['required'] = list(schema['properties'])
        schema['properties'] = {k: strict_schema(v, root) for k, v in schema['properties'].items()}
    if isinstance(schema.get('items'), dict):
        schema['items'] = strict_schema(schema['items'], root)
    if isinstance(schema.get('anyOf'), list):
        schema['anyOf'] = [strict_schema(v, root) for v in schema['anyOf']]
    if isinstance(schema.get('allOf'), list):
        if len(schema['allOf']) == 1:
            schema.update(strict_schema(schema['allOf'][0], root)); schema.pop('allOf')
        else:
            schema['allOf'] = [strict_schema(v, root) for v in schema['allOf']]
    if 'default' in schema and schema['default'] is None:
        schema.pop('default')
    ref = schema.get('$ref')
    if ref and len(schema) > 1:
        node = root
        for part in ref[2:].split('/'):
            node = node[part]
        schema.update({**node, **schema}); schema.pop('$ref')
        return strict_schema(schema, root)
    return schema


def response_format(Document):
    return {'type': 'json_schema',
            'json_schema': {'schema': strict_schema(Document.model_json_schema()), 'name': Document.__name__, 'strict': True}}


# ---------------------------------------------------------------- pack
def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def prepare_image(src, dst, original):
    """Copy, or resize and re-encode exactly as ai_client.utils.resize_image_if_needed does."""
    if original:
        shutil.copyfile(src, dst); return 'copied'
    from PIL import Image
    img = Image.open(src)
    if max(img.size) <= MAX_IMAGE:
        shutil.copyfile(src, dst); return 'copied (within 2048)'
    img.thumbnail((MAX_IMAGE, MAX_IMAGE), Image.Resampling.LANCZOS)
    if img.mode in ('RGBA', 'LA', 'P'):
        rgb = Image.new('RGB', img.size, (255, 255, 255))
        rgb.paste(img, mask=img.split()[-1] if img.mode == 'RGBA' else None)
        img = rgb
    img.save(dst, 'JPEG', quality=JPEG_QUALITY, optimize=True)
    return 'resized'


def pack(root, image_root=None, original=False):
    b, Document, _ = load_bench()
    root = pathlib.Path(root); (root / 'images').mkdir(parents=True, exist_ok=True)
    image_root = str(image_root or (root / 'images').resolve())
    rf = response_format(Document)
    reqs, images, prompts, how = [], [], set(), {}
    for name in letters(b):
        prompt = b.load_prompt(name)
        prompts.add(prompt)
        paths, digests = [], []
        for src in b.get_image_paths(name):
            base = os.path.basename(src)
            dst = root / 'images' / base
            how[base] = prepare_image(src, dst, original)
            digests.append(sha256(dst)); paths.append(f'{image_root.rstrip("/")}/{base}')
            images.append({'file': base, 'sha256': digests[-1], 'source_sha256': sha256(src), 'how': how[base]})
        reqs.append({'id': f'g17-{name}', 'prompt': prompt, 'images': paths, 'image_sha256s': digests,
                     'response_format': rf, 'system': ROLE, 'content_order': 'text-first', 'max_tokens': 16384})
    assert len(prompts) == 1, 'the prompt is not per-letter for this task'
    (root / 'requests.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in reqs))
    commit = subprocess.run(['git', '-C', str(CLONE), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    meta = {'benchmark': 'RISE-UNIBAS humanities_data_benchmark business_letters', 'benchmark_commit': commit,
            'prompt_sha256': hashlib.sha256(prompts.pop().encode()).hexdigest(), 'system': ROLE,
            'response_format': rf, 'temperature': 0.0,
            'image_handling': 'original' if original else f'resized to <= {MAX_IMAGE}px LANCZOS, JPEG q{JPEG_QUALITY} optimize',
            'letters': [r['id'][4:] for r in reqs], 'images': images}
    (root / 'g17-pack.json').write_text(json.dumps(meta, indent=1, ensure_ascii=False))
    return meta


# ---------------------------------------------------------------- score
def extract_json(text):
    """As ai_client.utils.extract_json_from_text."""
    if not text or not isinstance(text, str):
        return None
    content = text.strip()
    try:
        if '```json' in content:
            m = re.search(r'```json\s*([\s\S]*?)\s*```', content)
            if m:
                content = m.group(1).strip()
        elif '```' in content:
            m = re.search(r'```\s*([\s\S]*?)\s*```', content)
            if m:
                content = m.group(1).strip()
        data = json.loads(content)
        return data if isinstance(data, (dict, list)) else None
    except (json.JSONDecodeError, ValueError):
        return None


def is_schema_echo(data, Document):
    """Approximates ai_client's rejects_schema_echo for this schema: schema keywords at the top level."""
    declared = set(Document.model_json_schema().get('properties', {}))
    return isinstance(data, dict) and any(k in data and k not in declared for k in _SCHEMA_KEYWORDS)


def parse_reply(text, Document):
    data = extract_json(text)
    if data is None or is_schema_echo(data, Document):
        return None
    if isinstance(data, dict):
        try:
            return json.loads(Document(**data).model_dump_json())
        except Exception:
            pass
    return data   # the client's fallback keeps unvalidated JSON; the scorer decides whether it fits


def _counts(cats):
    return {k: {'tp': c.tp, 'fp': c.fp, 'fn': c.fn, 'f1': round(c.get_f1(), 4)} for k, c in cats.items()}


def score(root, label=None, summary=SUMMARY):
    b, Document, LLMResponse = load_bench()
    from benchmarks.business_letters.category import Category
    root = pathlib.Path(root); out = root / 'out'
    per, unparsed, missing, truncated = {}, [], [], []
    signed = {}
    for name in letters(b):
        gt = b.load_ground_truth(name)
        signed[name] = gt.get('has_signatures') is True or gt.get('has_signatures') == 'TRUE'
        f = out / f'g17-{name}.json'
        text = ''
        if f.exists():
            rec = json.loads(f.read_text())
            text = rec.get('text') or ''
            if rec.get('finish') == 'length':
                truncated.append(name)
        else:
            missing.append(name)
        parsed = parse_reply(text, Document)
        if parsed is None:
            unparsed.append(name)
        per[name] = b.score_request_answer(name, LLMResponse(text=text, parsed=parsed), gt)

    def block(names):
        scores = [per[n] for n in names]
        cats = {k: Category() for k in ('send_date', 'sender_persons', 'receiver_persons')}
        for s in scores:
            if s is None:
                continue
            for k, c in cats.items():
                c.tp += s[f'{k}_tp']; c.fp += s[f'{k}_fp']; c.fn += s[f'{k}_fn']
        r = b.score_benchmark(scores)
        r.update(letters=len(names), categories=_counts(cats))
        return r

    names = list(per)
    res = block(names)
    res.update(signed=block([n for n in names if signed[n]]), unsigned=block([n for n in names if not signed[n]]),
               unparsed=len(unparsed), unparsed_letters=unparsed, missing_replies=len(missing),
               truncated=len(truncated), root=str(root.resolve()),
               note='f1 values from BusinessLetters.score_benchmark (rounded to 2 dp, as published); '
                    'signed/unsigned = the card\'s skip_non_signatures / skip_signatures variants')
    label = label or root.name
    if summary is not None:
        summary = pathlib.Path(summary); summary.parent.mkdir(parents=True, exist_ok=True)
        allres = json.loads(summary.read_text()) if summary.exists() else {}
        allres[label] = res
        summary.write_text(json.dumps(allres, indent=1, ensure_ascii=False))
    return res


# ---------------------------------------------------------------- selfcheck
def selfcheck():
    b, Document, _ = load_bench()
    names = letters(b)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        meta = pack(tmp / 'pack', image_root='/cluster/path/images')
        reqs = [json.loads(l) for l in (tmp / 'pack' / 'requests.jsonl').read_text().splitlines()]
        n_img = sum(len(r['images']) for r in reqs)
        on_disk = len(list((tmp / 'pack' / 'images').glob('*.jpg')))
        ok_hash = all(sha256(tmp / 'pack' / 'images' / os.path.basename(p)) == d
                      for r in reqs for p, d in zip(r['images'], r['image_sha256s']))
        from PIL import Image
        sizes = {Image.open(p).size for p in (tmp / 'pack' / 'images').glob('*.jpg')}
        print(f'pack: {len(reqs)} requests, {n_img} image refs, {on_disk} images on disk, hashes ok={ok_hash}, '
              f'max side {max(max(s) for s in sizes)}px, commit {meta["benchmark_commit"][:12]}, '
              f'prompt sha256 {meta["prompt_sha256"][:12]}, images under {reqs[0]["images"][0].rsplit("/", 1)[0]}')
        assert len(reqs) == 57 and n_img == 98 == on_disk and ok_hash

        def inferred(p):
            return isinstance(p, str) and p.strip().startswith('<') and p.strip().endswith('>')

        results = {}
        for kind in ('gt-verbatim', 'gt-uninferred', 'gt-uninferred-fenced', 'empty'):
            root = tmp / kind; (root / 'out').mkdir(parents=True)
            for name in names:
                gt = b.load_ground_truth(name)
                md = {k: gt[k] for k in ('send_date', 'letter_title', 'sender_persons', 'receiver_persons')}
                if kind != 'gt-verbatim':   # what a letter alone can support: the inferred persons left out
                    for k in ('sender_persons', 'receiver_persons'):
                        md[k] = [p for p in md[k] or [] if not inferred(p)]
                body = json.dumps({'metadata': md}, ensure_ascii=False)
                text = {'gt-verbatim': body, 'gt-uninferred': body,
                        'gt-uninferred-fenced': 'Here it is:\n```json\n' + body + '\n```', 'empty': ''}[kind]
                (root / 'out' / f'g17-{name}.json').write_text(json.dumps({'id': f'g17-{name}', 'text': text, 'finish': 'stop'}))
            r = results[kind] = score(root, label=kind, summary=None)
            print(f'{kind:21s} f1_macro {r["f1_macro"]} f1_micro {r["f1_micro"]} unparsed {r["unparsed"]} '
                  f'signed {r["signed"]["f1_macro"]} ({r["signed"]["letters"]}) unsigned {r["unsigned"]["f1_macro"]} '
                  f'({r["unsigned"]["letters"]}) ' +
                  ' '.join(f'{k}:{v["tp"]}/{v["fp"]}/{v["fn"]}' for k, v in r['categories'].items()))
            if kind == 'empty':
                assert r['f1_macro'] == 0 and r['unparsed'] == 57
            elif kind != 'gt-verbatim':
                assert r['f1_macro'] == 1.0 and r['f1_micro'] == 1.0 and r['unparsed'] == 0
    # Why the verbatim ground truth is not 1.0: it marks persons inferred from function (<Name>) or from the
    # correspondence history (<<Name>>); the scorer drops them from the truth set (a single letter cannot support
    # them), but the same strings in a reply are parsed to the bare name and count as false positives.
    n_inf = sum(1 for n in names for k in ('sender_persons', 'receiver_persons')
                for p in b.load_ground_truth(n).get(k) or [] if inferred(p))
    fp = sum(v['fp'] for v in results['gt-verbatim']['categories'].values())
    print(f'inferred persons in the ground truth: {n_inf}; false positives of the verbatim echo: {fp}')
    assert n_inf == fp
    print('selfcheck ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack'); p.add_argument('--root', required=True); p.add_argument('--image-root')
    p.add_argument('--original-images', action='store_true', help='copy scans unchanged instead of the harness resize')
    s = sub.add_parser('score'); s.add_argument('--root', required=True); s.add_argument('--label')
    s.add_argument('--summary', default=str(SUMMARY))
    sub.add_parser('selfcheck')
    a = ap.parse_args()
    if a.cmd == 'pack':
        m = pack(a.root, a.image_root, a.original_images)
        print(json.dumps({k: m[k] for k in ('benchmark_commit', 'prompt_sha256', 'image_handling')}), len(m['letters']),
              'letters', len(m['images']), 'images')
    elif a.cmd == 'score':
        print(json.dumps(score(a.root, a.label, a.summary), indent=1, ensure_ascii=False))
    else:
        selfcheck()


if __name__ == '__main__':
    main()
