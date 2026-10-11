"""Approach C (W36.seg-whole): one long-context call per folder, as a third voter.

    python method_whole.py estimate                          # countTokens (free) on every unit + cost
    python method_whole.py probe Deaver 0                    # one folder, one paid call, printed
    python method_whole.py collect [Dean Deaver Herrnstein]  # the calls, both variants (cached; dev only)
    python method_whole.py report                            # scores, the length analysis, voting

THE UNIT. A "folder" is a maximal run of document pages between the truth's box/folder label photos (the
photos the archivist takes at every folder change). So both variants take their photo labels from the truth:
what they measure is boundary finding inside a folder, given where the folders are. window-claude finds the
photos itself with no error on these boxes (its own-photo and truth-photo rows are identical), so this is
not a large gift; it is stated in every result. A one-page folder has no gap and needs no call.

THE CALL. Gemini ``gemini-3.8-flash`` through the API (the model that matched Claude on Deaver over windows,
``gemini-variants-Deaver.md``; a different family from window-claude, so an independent voter), thinkingLevel
"low" (3.8 Flash refuses "minimal"), temperature 0, JSON response schema. Each unit is ONE request: per page a
short text part naming it and its image inline (the bench's 1600 px thumbnails), then the prompt with every
page's Apple Vision text. The longest development folder is 82 pages. The key, back-off and reply handling are
method_gemini's (its Keychain read, ``post``, ``response_text``). Responses are cached by content hash.

TWO VARIANTS, one model and one prompt:
- ``whole-gemini`` — the whole folder in one call. This is approach C.
- ``whole-gemini-c10`` — the CONTROL: the same folders cut into pieces of at most 10 pages, consecutive pieces
  sharing one page so every gap is judged exactly once. The plan expects approach C "to degrade past about 10
  pages"; comparing the two on the SAME gaps measures that, with the model and prompt held fixed.

THE PROMPT (wh1) is method_gemini's g1 (the owner's domain cues and the approved document rules) with the
label-photo material removed, since a unit holds document pages only, and the answer asked for boundaries only.
Written once; checked on one probe folder for format only; not revised against page-level errors.

VOTING. With window-claude and window-gemini-lite (both read from their caches, truth photo labels, no new
call): a boundary is accepted when every voter decides it the same way and flagged otherwise, then the review
load to 98% when the agreed boundaries are reviewed after the flagged ones, least confident first.
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import sys
import threading
import time
from contextlib import contextmanager

import data
from methods import METHODS, Method, Prediction  # first: methods imports the window modules
import method_gemini as G
import method_window as W
from score import PHOTO, boundaries_from_labels, score_labels, segment_ids

MODEL = "gemini-3.8-flash"
THINKING = "low"
PROMPT_VERSION = "wh1"
# List price, standard tier, USD per million tokens, as compare_gemini.py found it on 2026-10-05: the
# introductory price to 31 Dec 2026 (then $1.50 / $7.50). Thinking is billed as output.
PRICE_IN, PRICE_OUT = 0.75, 3.75
CHUNK = 10
CONCURRENCY = 3
STAGGER_S = 2.0
TIMEOUT_S = 900
COST_CAP_USD = 10.0
CACHE = data.ResponseCache("whole-gemini")
LOG = data.CACHE_DIR / "whole-gemini-calls.jsonl"

GEN_CONFIG = {
    "temperature": 0,
    "responseMimeType": "application/json",
    "thinkingConfig": {"thinkingLevel": THINKING},
}

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "boundaries": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"between": {"type": "ARRAY", "items": {"type": "INTEGER"}},
                           "decision": {"type": "STRING", "enum": ["new", "continue"]},
                           "cue": {"type": "STRING"},
                           "confidence": {"type": "NUMBER"}},
            "required": ["between", "decision", "cue", "confidence"]}},
    },
    "required": ["boundaries"],
}

PROMPT = """You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through one folder of an archive box, in
order. The {k} images above are consecutive photographs from that folder, each introduced by its page
number{span}. Every one of them is a document page: the box and folder label photos have been taken
out. Answer from the images. The OCR text below is automatic and has errors; the image wins when they
disagree.

WHAT IS ONE DOCUMENT (the archive's rules)
A document is one item an archivist would describe on its own: a letter, memo, report, newspaper
clipping, form, list or printed item. Many are one page; some run long. The photographs are in the
order they were taken and are never reordered.
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter) is its
   own document: its first page is new.
2. An attachment made to go with a letter or memo ("Attachment A", a list, a table, a budget) with no
   date, author or heading of its own is part of that letter: continue.
3. A carbon copy of a letter is the letter: its first page is new, like any letter.
4. Two copies of the same document kept together are two documents: the second copy's first page is new.
5. The same page photographed twice is the same document: the repeat continues.
6. An envelope next to the letter it held is part of that letter: continue. An envelope on its own is
   a document.
7. Each newspaper article is its own document; a second piece of the same article ("continued on page
   8") continues it; several articles in one photograph are one document.
8. A photograph (a print) is its own document; a photo of its back (caption, stamp) continues it.
9. A blank page or blank back of a sheet is part of the document it belongs to: continue.
10. A full magazine is ONE document, cover to end; its articles are not separate clippings.

THINGS THAT MISLEAD, FROM THIS ARCHIVE
- Show-through. Much of the paper is thin onion skin, and the photo (and the OCR) picks up text from
  the sheet BENEATH. A "-2-", "Page 2" or other text read through the paper belongs to the next
  sheet, not this one. A page number is a continuation cue ONLY if it is printed on this sheet itself.
  When the OCR shows a page number but the page also has its own new date, heading, letterhead or
  salutation, trust those: it starts a new document.
- A small item on a full sheet. A telegram, note or small cover letter is often photographed lying on
  top of a full page; the full page shows around or behind it. The small item is this photo's
  document; the sheet underneath is the NEXT document's first page, so the next photo (that sheet
  shown on its own) starts a new document rather than continuing the small item.
- Newspaper clippings. A byline ("By ..."), a wire-service credit such as "(AP)" or "(UPI)", or a
  section heading such as "Opinion" marks the START of an article: continuation pieces of an article
  rarely carry a byline, and a wire service is credited on the first piece only. A newspaper page
  number printed at the top ("Page A8", "14") is where the clipping began in the paper, not a sign
  that it continues the clipping before it.

OTHER CUES
- Continue: a page number of 2 or more printed on this sheet, often with the addressee and date as a
  running head; text running on from the previous page mid-sentence; the same typescript, layout or
  numbered sections continuing; the previous page ending with no closing or signature and this page
  carrying on; a table or list carrying on.
- New: a letterhead; a date line, inside address and salutation ("Dear ..."); a memo heading (TO /
  FROM / SUBJECT / MEMORANDUM); a title page; a masthead or headline; "Page 1"; a clear change of
  paper, type, author or subject. A previous page ending with a closing, a signature, typist's
  initials, "cc:" or "Enclosure" makes the next page likely new, though an attachment or enclosure
  may follow (rules 1 and 2).
- Not evidence on their own: two letters to the same person or on the same subject are still two
  documents; a similar look alone does not join pages.
- Seeing the whole run helps: a document's page count, a running head that recurs, or a sequence of
  page numbers (2, 3, 4 ...) across several photos tells you where each document begins and ends.

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer; it may include text that
shows through from the sheet beneath)
{texts}

ANSWER in the JSON schema given: "boundaries" has one entry for EVERY gap between consecutive pages, in
order, {n_gaps} in all: {gaps}.
"between" is [n, n+1]; "new" means page n+1 starts a new document; "continue" means page n+1 belongs to
the same document as page n. "cue" is the cue you relied on, under 15 words. "confidence" is your
probability, 0 to 1, that the decision is right: 0.95 and above only when the cue is unambiguous, about
0.6 when you are close to guessing.
"""


# --- units ------------------------------------------------------------------------------------

def folders(col) -> list[tuple[int, int]]:
    """[a, b) index runs of document pages between truth label photos, two pages or more."""
    out, a = [], None
    labels = col.labels + ["Folder"]          # a sentinel closes the last run
    for i, lab in enumerate(labels):
        if lab in PHOTO:
            if a is not None and i - a >= 2:
                out.append((a, i))
            a = None
        elif a is None:
            a = i
    return out


def chunks(a: int, b: int, size: int = CHUNK) -> list[tuple[int, int]]:
    """[a, b) cut into pieces of at most ``size`` pages, each sharing its first page with the previous
    piece's last, so every gap a..b-1 lies in exactly one piece."""
    out, s = [], a
    while True:
        e = min(b, s + size)
        out.append((s, e))
        if e >= b:
            return out
        s = e - 1


def units(col, variant: str) -> list[tuple[int, int]]:
    fs = folders(col)
    if variant == "whole":
        return fs
    return [c for a, b in fs for c in chunks(a, b)]


# --- the request ------------------------------------------------------------------------------

def build_request(col, a: int, b: int):
    nums = [col.pages[i].n for i in range(a, b)]
    thumbs = []
    for i in range(a, b):
        t = data.thumbnail(col.name, col.pages[i], W.THUMB_PX)
        if t is None:
            raise RuntimeError(f"{col.name} {col.pages[i].n}: thumbnail failed")
        thumbs.append(t)
    texts = "\n".join(f"--- page {n} ---\n{W.page_text(col, i)}" for n, i in zip(nums, range(a, b)))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    prompt = PROMPT.format(k=len(nums), span=f", pages {nums[0]} to {nums[-1]}", texts=texts, gaps=gaps,
                           n_gaps=len(nums) - 1, max_text=W.MAX_TEXT)
    return prompt, thumbs, nums


def request_body(prompt: str, images: list[bytes], nums: list[int]) -> dict:
    body = G.request_body(prompt, images, nums)
    body["generationConfig"] = dict(GEN_CONFIG, responseSchema=RESPONSE_SCHEMA)
    return body


def cache_key(prompt: str, thumbs) -> str:
    return data.response_cache_key(MODEL, PROMPT_VERSION, GEN_CONFIG, RESPONSE_SCHEMA, prompt,
                                   [data.file_hash(t) for t in thumbs])


def parse_answer(text: str, nums: list[int]) -> dict:
    """{gap's first page number: {decision, confidence, cue}} for every gap of the unit, or ParseError."""
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as e:
        raise W.ParseError(f"bad JSON: {e}") from e
    bounds = {}
    for bd in obj.get("boundaries", []):
        try:
            x, y = (int(v) for v in bd["between"])
        except (KeyError, TypeError, ValueError) as e:
            raise W.ParseError(f"bad 'between' {bd.get('between')!r}") from e
        if y != x + 1 or x not in nums[:-1]:
            raise W.ParseError(f"boundary {[x, y]} not in the unit")
        if x in bounds:
            raise W.ParseError(f"boundary {x} given twice")
        d = bd.get("decision")
        if d not in ("new", "continue"):
            raise W.ParseError(f"boundary {x}: decision {d!r}")
        c = float(bd.get("confidence"))
        if not 0 <= c <= 1:
            raise W.ParseError(f"boundary {x}: confidence {c}")
        bounds[x] = {"decision": d, "confidence": c, "cue": str(bd.get("cue", ""))[:200]}
    if sorted(bounds) != nums[:-1]:
        missing = sorted(set(nums[:-1]) - set(bounds))
        raise W.ParseError(f"{len(bounds)} of {len(nums) - 1} boundaries; missing {missing[:10]}")
    return bounds


def usage(resp: dict) -> dict:
    return G.usage(resp)


def cost_usd(u: dict) -> float:
    return (u["in"] * PRICE_IN + (u["out"] + u["thought"]) * PRICE_OUT) / 1e6


# --- calling ----------------------------------------------------------------------------------

_log_lock = threading.Lock()


def log(rec: dict) -> None:
    with _log_lock:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(json.dumps(rec) + "\n")


def calls() -> list[dict]:
    recs = [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []
    return [r for r in recs if r.get("event") in ("call", "parse-failure")]


def spent() -> float:
    return sum(r.get("usd", 0) for r in calls())


def judge_unit(col, a: int, b: int, allow_call: bool = True) -> dict | None:
    prompt, thumbs, nums = build_request(col, a, b)
    key = cache_key(prompt, thumbs)
    hit = CACHE.get(key)
    if hit is not None:
        return parse_answer(G.response_text(hit["response"]), nums)
    if not allow_call:
        return None
    body = request_body(prompt, [t.read_bytes() for t in thumbs], nums)
    last = None
    for attempt in range(3):
        t0 = time.time()
        resp = G.post("generateContent", body, model=MODEL, timeout_s=TIMEOUT_S)
        u = usage(resp)
        rec = {"collection": col.name, "unit": [nums[0], nums[-1]], "pages": len(nums), "event": "call",
               "attempt": attempt, "model": MODEL, "wall_s": round(time.time() - t0, 1), **u,
               "usd": round(cost_usd(u), 6), "t": time.time()}
        try:
            parsed = parse_answer(G.response_text(resp), nums)
        except (W.ParseError, G.Blocked) as e:
            last = e
            rec.update(event="parse-failure", error=str(e)[:300])
            log(rec)
            continue
        log(rec)
        CACHE.put(key, {"response": resp, "model": MODEL, "thinking": THINKING, "usage": u})
        return parsed
    raise RuntimeError(f"{col.name} {nums[0]}-{nums[-1]}: no valid answer after 3 calls: {last}")


def all_jobs(names, variants=("whole", "c10")):
    jobs, seen = [], set()
    for name in names:
        col = data.load(name, with_exif=False)
        for v in variants:
            for a, b in units(col, v):
                if (name, a, b) not in seen:      # a folder of 10 pages or fewer is the same unit in both
                    seen.add((name, a, b))
                    jobs.append((col, a, b))
    return jobs


def estimate(names) -> float:
    """countTokens (free) on every unit; output at the mean measured so far, else 70 tokens a gap."""
    G.refuse_test(names)
    jobs = all_jobs(names)
    done = [r for r in calls()]
    per_gap_out = (sum(r["out"] + r["thought"] for r in done) / sum(r["pages"] - 1 for r in done)
                   if done else 70)
    tin = tout = 0
    todo = 0
    for col, a, b in jobs:
        if judge_unit(col, a, b, allow_call=False) is not None:
            continue
        todo += 1
        prompt, thumbs, nums = build_request(col, a, b)
        body = request_body(prompt, [t.read_bytes() for t in thumbs], nums)
        r = G.post("countTokens", {"generateContentRequest": dict(body, model=f"models/{MODEL}")}, model=MODEL)
        tin += r.get("totalTokens", 0)
        tout += per_gap_out * (len(nums) - 1)
    usd = (tin * PRICE_IN + tout * PRICE_OUT) / 1e6
    print(f"{len(jobs)} units, {todo} to call; {tin:,} input tokens (countTokens), ~{tout:,.0f} output "
          f"({'measured' if done else 'guessed'} {per_gap_out:.0f}/gap); ${PRICE_IN}/${PRICE_OUT} per M -> "
          f"${usd:.2f} (x1.2 for retries: ${1.2 * usd:.2f})", flush=True)
    return usd


def collect(names) -> None:
    G.refuse_test(names)
    est = estimate(names)
    if 1.2 * est > COST_CAP_USD:
        raise SystemExit(f"estimate ${1.2 * est:.2f} exceeds the ${COST_CAP_USD:.0f} cap; not running")
    todo = [j for j in all_jobs(names) if judge_unit(*j, allow_call=False) is None]
    todo.sort(key=lambda j: j[1] - j[2])    # longest first, so the slow calls start early
    print(f"{len(todo)} to call", flush=True)
    stop = threading.Event()
    t0, done = time.time(), [0]

    def work(job, delay):
        time.sleep(delay)
        if stop.is_set():
            return
        col, a, b = job
        try:
            judge_unit(col, a, b)
        except G.Fatal as e:
            stop.set()
            print(f"FATAL, stopping: {e}", flush=True)
            return
        except Exception as e:  # noqa: BLE001 - one unit failing does not stop the rest
            print(f"FAILED {col.name} {col.pages[a].n}-{col.pages[b - 1].n}: {str(e)[:200]}", flush=True)
            return
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {col.pages[a].n}-{col.pages[b - 1].n} "
              f"(${spent():.2f})", flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        futs = [ex.submit(work, j, STAGGER_S * k if k < CONCURRENCY else 0) for k, j in enumerate(todo)]
        for f in cf.as_completed(futs):
            f.result()
    print(f"done in {time.time() - t0:.0f}s; spent so far ${spent():.4f}", flush=True)


# --- the method -------------------------------------------------------------------------------

def predict_gaps(col, variant: str, judge=None) -> list[dict | None]:
    """Per gap: the judgement {decision, confidence, cue, unit_pages, pos} or None (a gap beside a photo)."""
    judge = judge or judge_unit
    index = {p.n: i for i, p in enumerate(col.pages)}
    gaps: list[dict | None] = [None] * (len(col.pages) - 1)
    for a, b in units(col, variant):
        j = judge(col, a, b, allow_call=False)
        if j is None:
            raise RuntimeError(f"{col.name}: unit {col.pages[a].n}-{col.pages[b - 1].n} not collected; "
                               "run `method_whole.py collect` first")
        for x, bd in j.items():
            i = index[x]
            gaps[i] = dict(bd, unit_pages=b - a, pos=i - a + 1)   # pos: the gap's place in its call, 1-based
    return gaps


def assemble(col, gaps) -> Prediction:
    truth = col.labels
    labels = []
    for i, t in enumerate(truth):
        if t in PHOTO:
            labels.append(t)
        elif i == 0 or truth[i - 1] in PHOTO or (gaps[i - 1] and gaps[i - 1]["decision"] == "new"):
            labels.append("New")
        else:
            labels.append("Cont")
    bounds = []
    for i, d in enumerate(boundaries_from_labels(labels)):
        g = gaps[i]
        if g is None:
            bounds.append({"decision": d, "confidence": 1.0, "cue": "beside a label photo", "agree": True,
                           "fixed": True})
        else:
            bounds.append({"decision": d, "confidence": g["confidence"], "cue": g["cue"], "agree": True,
                           "fixed": False})
    return Prediction(labels, bounds)


class WholeGemini(Method):
    tuning = True
    oracle_photos = True
    held_out = ("no: prompt written after reading the owner's notes on dev pages, not tuned on its errors; "
                "no fitted parameters")
    tuned_on = ("nothing fitted. The prompt is method_gemini's g1 adapted to a folder of document pages, written "
                "once and checked on one probe folder for format only; not revised against page-level errors")

    def __init__(self, variant: str):
        self.variant = variant
        self.name = "whole-gemini" if variant == "whole" else f"whole-gemini-{variant}"

    @property
    def description(self):   # a property: method_window may still be loading when this module registers
        unit = ("the whole folder in one call" if self.variant == "whole"
                else f"folders cut into pieces of at most {CHUNK} pages sharing one page (the control)")
        return (f"Gemini {MODEL} (API, thinkingLevel {THINKING}, temperature 0), {unit}, folders "
                            f"taken from the truth's label photos; images at {W.THUMB_PX} px plus Apple Vision "
                            f"text, prompt {PROMPT_VERSION} with the owner's domain cues; every gap judged once; "
                            "photo labels from the truth")

    def predict(self, collection):
        G.refuse_test([collection.name])
        return assemble(collection, predict_gaps(collection, self.variant))


for _m in (WholeGemini("whole"), WholeGemini("c10")):
    METHODS[_m.name] = _m


# --- analysis ---------------------------------------------------------------------------------

def _pct(x):
    return f"{100 * x:.1f}%"


def gap_rows(cols, variant: str, judge=None):
    """One row per document gap (truth both sides): (collection, i, unit_pages, pos, wrong, confidence)."""
    rows = []
    for c in cols:
        gaps = predict_gaps(c, variant, judge)
        pred = assemble(c, gaps)
        t_ids, p_ids = segment_ids(c.labels), segment_ids(pred.labels)
        for i, g in enumerate(gaps):
            if g is None:
                continue
            wrong = (t_ids[i] != t_ids[i + 1]) != (p_ids[i] != p_ids[i + 1])
            rows.append((c.name, i, g["unit_pages"], g["pos"], wrong, g["confidence"]))
    return rows


LEN_BUCKETS = ((2, 10), (11, 20), (21, 40), (41, 999))


def _bucket(n):
    return next(f"{lo}–{hi}" if hi < 999 else f"{lo}+" for lo, hi in LEN_BUCKETS if lo <= n <= hi)


def length_lines(cols) -> list[str]:
    """Error rate by folder length and by position in the call, whole vs the 10-page control on the same gaps."""
    whole = {(r[0], r[1]): r for r in gap_rows(cols, "whole")}
    c10 = {(r[0], r[1]): r for r in gap_rows(cols, "c10")}
    assert whole.keys() == c10.keys()
    L = ["## Does one long call degrade with length?", "",
         "Every document gap inside a folder of two pages or more, judged once by each variant. The same model "
         "and prompt; only how much of the folder the call sees differs. A folder of 10 pages or fewer is the "
         "same call in both, so those rows match by construction.", "",
         "### By folder length", "",
         "| folder length (pages) | folders | gaps | whole: errors | whole: error rate | 10-page pieces: errors "
         "| 10-page pieces: error rate | gaps only whole got wrong | gaps only the pieces got wrong |",
         "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    lens = {}
    for c in cols:
        for a, b in folders(c):
            lens.setdefault(_bucket(b - a), []).append(b - a)
    for lo, hi in LEN_BUCKETS:
        tag = f"{lo}–{hi}" if hi < 999 else f"{lo}+"
        ks = [k for k, r in whole.items() if _bucket(r[2]) == tag]
        if not ks:
            continue
        ew, ec = sum(whole[k][4] for k in ks), sum(c10[k][4] for k in ks)
        ow = sum(whole[k][4] and not c10[k][4] for k in ks)
        oc = sum(c10[k][4] and not whole[k][4] for k in ks)
        L.append(f"| {tag} | {len(lens.get(tag, []))} | {len(ks)} | {ew} | {_pct(ew / len(ks))} | {ec} | "
                 f"{_pct(ec / len(ks))} | {ow} | {oc} |")
    ks = list(whole)
    ew, ec = sum(whole[k][4] for k in ks), sum(c10[k][4] for k in ks)
    L.append(f"| all | {sum(len(v) for v in lens.values())} | {len(ks)} | {ew} | {_pct(ew / len(ks))} | {ec} | "
             f"{_pct(ec / len(ks))} | {sum(whole[k][4] and not c10[k][4] for k in ks)} | "
             f"{sum(c10[k][4] and not whole[k][4] for k in ks)} |")
    L += ["", "### By the gap's place in the whole-folder call", "",
          "Gap 1 is between the folder's first and second page. Only folders longer than 10 pages, so the rows "
          "say whether a long call is worse late in the folder than early in it.", "",
          "| gap position in the call | gaps | whole: errors | whole: error rate | 10-page pieces: errors |",
          "|---|---:|---:|---:|---:|"]
    for lo, hi in ((1, 10), (11, 20), (21, 40), (41, 999)):
        ks = [k for k, r in whole.items() if r[2] > 10 and lo <= r[3] <= hi]
        if not ks:
            continue
        ew = sum(whole[k][4] for k in ks)
        tag = f"{lo}–{hi}" if hi < 999 else f"{lo} and later"
        L.append(f"| {tag} | {len(ks)} | {ew} | {_pct(ew / len(ks))} | {sum(c10[k][4] for k in ks)} |")
    L.append("")
    return L


def voters():
    """name -> per-collection assembled Prediction (truth photo labels)."""
    return {
        "window-claude": lambda c: W.assemble(c, W.combine(c, W.judge_window), True),
        "window-gemini-lite": lambda c: W.assemble(c, W.combine(c, G.judge_window), True),
        "whole-gemini": lambda c: assemble(c, predict_gaps(c, "whole")),
    }


def vote_labels(truth, preds, reviewed: set[int]) -> list[str]:
    """Labels from several predictions (truth photos): where they agree their call; at a reviewed gap the
    truth's; at an unreviewed disagreement the majority, a tie going to the most confident voter."""
    t_ids = segment_ids(truth)
    dec = []
    for bs in zip(*(p.boundaries for p in preds)):
        news = [b for b in bs if b["decision"] == "new"]
        conts = [b for b in bs if b["decision"] == "continue"]
        if len(news) != len(conts):
            dec.append("new" if len(news) > len(conts) else "continue")
        else:
            dec.append(max(bs, key=lambda b: b["confidence"])["decision"])
    for i in reviewed:
        dec[i] = "new" if t_ids[i] != t_ids[i + 1] else "continue"
    out = []
    for i, t in enumerate(truth):
        if t in PHOTO:
            out.append(t)
        elif i == 0 or truth[i - 1] in PHOTO or dec[i - 1] == "new":
            out.append("New")
        else:
            out.append("Cont")
    return out


def vote(cols, names: list[str]):
    """Per collection rows and a pooled review curve for one set of voters."""
    vs = voters()
    rows, items, state = [], [], {}
    for c in cols:
        preds = [vs[n](c) for n in names]
        t_ids = segment_ids(c.labels)
        ids = [segment_ids(p.labels) for p in preds]
        doc = [i for i, b in enumerate(preds[0].boundaries) if not b.get("fixed")]
        fl = [i for i in doc if len({p.boundaries[i]["decision"] for p in preds}) > 1]
        wrong = lambda pid, i: (t_ids[i] != t_ids[i + 1]) != (pid[i] != pid[i + 1])
        agreed_err = sum(1 for i in doc if i not in fl and wrong(ids[0], i))
        rows.append({"name": c.name, "pages": len(c.labels), "doc_gaps": len(doc), "flagged": len(fl),
                     "agreed_err": agreed_err,
                     "own_err_at_flagged": [sum(wrong(pid, i) for i in fl) for pid in ids],
                     "own_err": [sum(wrong(pid, i) for i in doc) for pid in ids],
                     "before": score_labels(c.labels, vote_labels(c.labels, preds, set())),
                     "after": score_labels(c.labels, vote_labels(c.labels, preds, set(fl)))})
        state[c.name] = (c, preds, set(fl))
        for i in doc:
            if i not in fl:
                items.append((round(min(p.boundaries[i]["confidence"] for p in preds), 6), c.name, i))
    items.sort(key=lambda t: t[0])
    reviewed = {n: set(s[2]) for n, s in state.items()}

    def pooled():
        ex = dp = 0
        per = {}
        for n, (c, preds, _) in state.items():
            sc = score_labels(c.labels, vote_labels(c.labels, preds, reviewed[n]))
            ex, dp = ex + sc.pages_exact, dp + sc.doc_pages
            per[n] = sc.pages_exact / sc.doc_pages
        return ex / dp, per

    base = sum(len(s[2]) for s in state.values())
    curve = [(base, *pooled())]
    for k, (conf, n, i) in enumerate(items, 1):
        reviewed[n].add(i)
        if k == len(items) or items[k][0] != conf:
            curve.append((base + k, *pooled()))
    return rows, curve


VOTER_SETS = (["window-claude", "whole-gemini"],
              ["window-claude", "window-gemini-lite"],
              ["window-claude", "window-gemini-lite", "whole-gemini"])


def vote_lines(cols, pages: int) -> tuple[list[str], dict]:
    L = ["## Voting", "",
         "Truth photo labels throughout, so only boundaries between two document pages are voted on. window-claude "
         "and window-gemini-lite come from their caches (no new call). A boundary every voter decides the same way "
         "is accepted; any other is flagged for review. Before review a disagreement takes the majority, a tie the "
         "most confident voter. Review corrects a boundary to the truth. After the flagged ones, the agreed "
         "boundaries are reviewed least confident first (the lowest of the voters' confidences), whole ties at a "
         "time.", "",
         "| voters | flagged | flagged per 100 pages | each voter's errors (all / at flagged) | errors left among "
         "agreed | pages in exact doc, no review | after reviewing the flagged | 98% pooled after | per 100 pages "
         "| 98% in every collection after |",
         "|---|---:|---:|---|---:|---:|---:|---:|---:|---:|"]
    head = {}
    for names in VOTER_SETS:
        rows, curve = vote(cols, names)
        tot = {k: sum(r[k] for r in rows) for k in ("pages", "doc_gaps", "flagged", "agreed_err")}
        own = [sum(r["own_err"][j] for r in rows) for j in range(len(names))]
        own_f = [sum(r["own_err_at_flagged"][j] for r in rows) for j in range(len(names))]
        before = sum((r["before"] for r in rows[1:]), rows[0]["before"])
        after = sum((r["after"] for r in rows[1:]), rows[0]["after"])
        pt98 = next((p for p in curve if p[1] >= 0.98), None)
        all98 = next((p for p in curve if min(p[2].values()) >= 0.98), None)
        L.append(f"| {' + '.join(names)} | {tot['flagged']} | {100 * tot['flagged'] / tot['pages']:.1f} | "
                 + "; ".join(f"{n} {e}/{f}" for n, e, f in zip(names, own, own_f))
                 + f" | {tot['agreed_err']} | {_pct(before.pages_exact / before.doc_pages)} | "
                 f"{_pct(after.pages_exact / after.doc_pages)} | {pt98[0] if pt98 else 'not reached'} | "
                 f"{f'{100 * pt98[0] / pages:.1f}' if pt98 else ''} | {all98[0] if all98 else 'not reached'} |")
        head[tuple(names)] = (tot, curve[0], pt98, all98, after)
    L.append("")
    return L, head


@contextmanager
def gemini_variant(model, thinking, cache_ns, log_name):
    """method_gemini's globals swapped for one cached variant (compare_gemini's), then restored."""
    saved = G.MODEL, G.THINKING, G.GEN_CONFIG, G.CACHE, G.LOG
    G.MODEL, G.THINKING = model, thinking
    G.GEN_CONFIG = dict(G.GEN_CONFIG, thinkingConfig={"thinkingLevel": thinking})
    G.CACHE, G.LOG = data.ResponseCache(cache_ns), data.CACHE_DIR / log_name
    try:
        yield
    finally:
        G.MODEL, G.THINKING, G.GEN_CONFIG, G.CACHE, G.LOG = saved


def deaver_window_line() -> list[str]:
    """The same model over 7-page windows (compare_gemini's cache), on Deaver: windows vs whole folders."""
    col = data.load("Deaver")
    out = ["## The same model over 7-page windows, Deaver", "",
           "compare_gemini.py ran gemini-3.8-flash (low) over window-claude's 7-page windows with prompt g1 on Deaver "
           "only. Scored here with truth photo labels, beside this item's two variants on the same box.", "",
           "| method | pages in exact doc | false splits | false merges |", "|---|---:|---:|---:|"]
    try:
        with gemini_variant("gemini-3.8-flash", "low", "window-gemini-3.8-flash-low",
                            "window-gemini-3.8-flash-low-calls.jsonl"):
            pred = W.assemble(col, W.combine(col, G.judge_window), True)
    except RuntimeError as e:
        return out[:2] + [f"Not available: {e}", ""]
    rows = [("gemini-3.8-flash, 7-page windows (g1)", pred.labels),
            ("whole-gemini", METHODS["whole-gemini"].predict(col).labels),
            ("whole-gemini-c10", METHODS["whole-gemini-c10"].predict(col).labels)]
    for name, labels in rows:
        s = score_labels(col.labels, labels, "Deaver")
        out.append(f"| {name} | {_pct(s.pages_exact / s.doc_pages)} | {s.false_splits} | {s.false_merges} |")
    out.append("")
    return out


def report() -> str:
    import csv
    import run
    cols = [data.load(n) for n in data.DEV]
    pages = sum(len(c.pages) for c in cols)
    headlines = {}
    for name in ("whole-gemini", "whole-gemini-c10"):
        rows = run.run(name, list(data.DEV), False)
        run.write(name, list(data.DEV), rows)
        headlines[name] = rows
    n_f = sum(len(folders(c)) for c in cols)
    longest = max(b - a for c in cols for a, b in folders(c))
    L = ["# W36.seg-whole — one long-context call per folder, as a third voter (development set)", "",
         f"Run {__import__('datetime').date.today().isoformat()} on Dean, Deaver and Herrnstein ({pages} pages) only; "
         f"the test collections were not touched. Model {MODEL} through the Gemini API, thinkingLevel \"{THINKING}\", "
         f"temperature 0, JSON response schema; prompt {PROMPT_VERSION} (g1's owner's cues and document rules, adapted "
         f"to a folder of document pages). {n_f} folders of two pages or more, the longest {longest} pages. Folders "
         "come from the truth's label photos, so every figure here uses truth photo labels and measures boundary "
         "finding only. The prompt was written after reading the owner's notes on development pages, checked on "
         "one probe folder for format only and not revised against page-level errors; nothing was fitted.", ""]
    L += ["## Headline", "", "| method | collection | pages in exact doc | docs exact | false splits | false merges | "
          "boundary F1 |", "|---|---|---:|---:|---:|---:|---:|"]
    others = {}
    for k in ("window-claude-truth-photos", "window-gemini-lite-truth-photos", "spring-v1-oracle-photos"):
        with open(run.RESULTS / f"{k}-dev.tsv", newline="") as fh:
            others[k] = list(csv.DictReader(fh, delimiter="\t"))
    for k, rows in list(headlines.items()) + list(others.items()):
        for r in rows:
            col = "pooled" if str(r["collections"]).startswith("POOLED") else r["collections"]
            f = lambda key: float(r[key])
            L.append(f"| {k} | {col} | {_pct(f('pages_in_exact_doc'))} | {_pct(f('docs_exact'))} | "
                     f"{r['false_splits']} | {r['false_merges']} | {f('boundary_f1'):.3f} |")
    L.append("")
    L += length_lines(cols)
    L += deaver_window_line()
    # its own confidence: risk-coverage and the review load to 98%
    rc = sorted(gap_rows(cols, "whole"), key=lambda r: r[5], reverse=True)
    L += ["## Its own confidence (whole-gemini)", "",
          "| threshold | accepted | errors among accepted | error rate | left to review per 100 pages |",
          "|---:|---:|---:|---:|---:|"]
    for t in (0.0, 0.8, 0.9, 0.95, 0.98):
        acc = [r for r in rc if r[5] >= t - 1e-9]
        e = sum(r[4] for r in acc)
        L.append(f"| {t:.2f} | {len(acc)} | {e} | {_pct(e / len(acc)) if acc else '—'} | "
                 f"{100 * (len(rc) - len(acc)) / pages:.1f} |")
    _, curve = vote(cols, ["whole-gemini"])        # one voter: nothing flagged, review by confidence
    own98 = next((p for p in curve if p[1] >= 0.98), None)
    below = [p for p in curve if p[1] < 0.98]
    ties = max(sum(1 for r in rc if round(r[5], 3) == v) for v in {round(r[5], 3) for r in rc})
    L += ["", "Review load to 98% pooled by its own confidence alone: "
          + (f"{own98[0]} boundaries ({100 * own98[0] / pages:.1f} per 100 pages)." if own98 else "not reached.")
          + (f" The step before it is {below[-1][0]} boundaries at {_pct(below[-1][1])}: the confidences are "
             f"coarse ({ties} of {len(rc)} gaps share one value), and a threshold cannot split a tie."
             if below and own98 else ""), ""]
    V, vhead = vote_lines(cols, pages)
    L += V
    cs = calls()
    tin, tout = sum(r["in"] for r in cs), sum(r["out"] + r["thought"] for r in cs)
    L += ["## Calls and cost", "",
          f"Calls made: {len(cs)} ({sum(r['event'] == 'parse-failure' for r in cs)} parse failures). Tokens: "
          f"{tin:,} in, {tout:,} out (of them {sum(r['thought'] for r in cs):,} thinking). Longest call "
          f"{max((r['wall_s'] for r in cs), default=0):.0f} s. Cost at the assumed list price (${PRICE_IN} / "
          f"${PRICE_OUT} per million tokens in / out, 3.8 Flash's introductory price): ${spent():.2f}.", ""]
    text = "\n".join(L) + "\n"
    (run.RESULTS / "whole-gemini-report.md").write_text(text)
    wg = float(headlines["whole-gemini"][-1]["pages_in_exact_doc"])
    wc10 = float(headlines["whole-gemini-c10"][-1]["pages_in_exact_doc"])
    wcl = float(others["window-claude-truth-photos"][-1]["pages_in_exact_doc"])
    tot, _, pt98, all98, after = vhead[("window-claude", "whole-gemini")]
    tot3, _, pt98_3, _, after3 = vhead[tuple(VOTER_SETS[2])]
    sec = ["", "## W36.seg-whole — one long-context call per folder, as a third voter (development set)", "",
           f"Model {MODEL}, thinkingLevel {THINKING}, temperature 0, prompt {PROMPT_VERSION}; folders from the truth's "
           "label photos (truth photo labels). Detail: whole-gemini-report.md.", "",
           f"Pages in an exact document, pooled: whole-gemini {_pct(wg)}, the same model and prompt over pieces of at "
           f"most {CHUNK} pages {_pct(wc10)}, window-claude {_pct(wcl)}.", "",
           f"Voting with window-claude: {tot['flagged']} boundaries flagged ({100 * tot['flagged'] / tot['pages']:.1f} "
           f"per 100 pages), {tot['agreed_err']} errors left among the agreed, "
           f"{_pct(after.pages_exact / after.doc_pages)} after reviewing the flagged"
           + (f"; 98% pooled after {pt98[0]} reviews ({100 * pt98[0] / pages:.1f} per 100 pages)." if pt98 else
              "; 98% not reached.")
           + f" All three voters: {tot3['flagged']} flagged, {tot3['agreed_err']} errors left among the agreed, "
           f"{_pct(after3.pages_exact / after3.doc_pages)} after reviewing the flagged"
           + (f"; 98% pooled after {pt98_3[0]} reviews." if pt98_3 else "; 98% not reached.")]
    (run.RESULTS / "whole-gemini.summary-section.md").write_text("\n".join(sec) + "\n")
    run.write_summary()
    return text


def main(argv) -> int:
    if not argv or argv[0] not in ("estimate", "collect", "probe", "report"):
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "estimate":
        estimate(rest or list(data.DEV))
    elif cmd == "collect":
        collect(rest or list(data.DEV))
    elif cmd == "probe":
        name, k = rest[0], int(rest[1])
        G.refuse_test([name])
        c = data.load(name, with_exif=False)
        a, b = folders(c)[k]
        print(json.dumps(judge_unit(c, a, b), indent=1))
        print(f"spent so far ${spent():.4f}")
    else:
        print(report())
    return 0


if __name__ == "__main__":
    import method_whole as _M   # the registered module, not a second copy as __main__
    sys.exit(_M.main(sys.argv[1:]))
