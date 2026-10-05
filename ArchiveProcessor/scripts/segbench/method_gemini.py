"""Approach B (W36.seg-second): Gemini Flash-Lite over the same page windows, as a second voter.

    python method_gemini.py estimate                          # token count of sample windows (free) + cost
    python method_gemini.py probe Dean 0                      # one window, one paid call, printed
    python method_gemini.py collect [Dean Deaver Herrnstein]  # the calls (cached; dev only)
    python method_gemini.py report                            # both variants through run.py, the report, voting

THE ROUTE. The Gemini API (v1beta ``generateContent``), model ``gemini-3.1-flash-lite`` with
``thinkingConfig.thinkingLevel = "minimal"`` and temperature 0 (owner, 2026-10-05: Flash-Lite with minimal
thinking; the brief first named gemini-3.8-flash, and no call was made to it). The key is read from the
Keychain (service com.archiveprocessor.app, account Gemini) into memory at the first call and sent only
as the ``x-goog-api-key`` header; it is never printed, logged or written. Each window is ONE request: per
page a short text part naming the page and its image inline (base64 JPEG, the bench's 1600 px
thumbnails), then the prompt with every page's cached Apple Vision text, and a JSON response schema.
Every valid response is cached by content hash in ``ResponseCache("window-gemini-lite")``; at most four
requests run at once, started a second apart, with back-off on 429 and 5xx.

THE WINDOWS, COMBINING AND ASSEMBLY are method_window's, imported (7 pages, stride 3, every gap judged
in two windows, P(new) averaged); so is the risk-coverage and review-load report code.

THE PROMPT is new: it states the owner's domain cues (execution-plans/segmentation/00-plan.md, "The
owner's domain cues") and the approved document rules (02-truth-check.md). It was written after reading
the owner's notes on development pages and checked on one probe window for format only.

VOTING. ``vote`` compares this method with window-claude (its cached responses; no new Claude call):
a boundary both models decide the same way is accepted, one they decide differently is flagged.
"""
from __future__ import annotations

import base64
import concurrent.futures as cf
import json
import subprocess
import sys
import threading
import time

import data
from methods import METHODS, Method  # first: methods imports method_window, then this module
import method_window as W
from score import PHOTO, segment_ids, score_labels

MODEL = "gemini-3.1-flash-lite"
THINKING = "minimal"
API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:{verb}"
PROMPT_VERSION = "g1"
CONCURRENCY = 4
STAGGER_S = 1.0
TIMEOUT_S = 300
MAX_ATTEMPTS = 6
CACHE = data.ResponseCache("window-gemini-lite")
LOG = data.CACHE_DIR / "window-gemini-lite-calls.jsonl"
# The models endpoint carries no prices. Assumed: the Gemini 3.1 Flash Lite list price the app itself
# carries (macOS/Sources/ArchiveProcessor/Models/ProviderModels.swift), USD per million tokens, standard
# (not batch); thinking tokens are billed as output.
PRICE_IN, PRICE_OUT = 0.25, 1.50
COST_CAP_USD = 10.0

GEN_CONFIG = {
    "temperature": 0,
    "responseMimeType": "application/json",
    "thinkingConfig": {"thinkingLevel": THINKING},
}

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "pages": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"page": {"type": "INTEGER"},
                           "kind": {"type": "STRING", "enum": ["box", "folder", "document"]}},
            "required": ["page", "kind"]}},
        "boundaries": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"between": {"type": "ARRAY", "items": {"type": "INTEGER"}},
                           "decision": {"type": "STRING", "enum": ["new", "continue"]},
                           "cue": {"type": "STRING"},
                           "confidence": {"type": "NUMBER"}},
            "required": ["between", "decision", "cue", "confidence"]}},
    },
    "required": ["pages", "boundaries"],
}

PROMPT = """You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through an archive box, in box order. The
{k} images above are consecutive photographs from that stream, each introduced by its page number.
Answer from the images. The OCR text below is automatic and has errors; the image wins when they
disagree.

WHAT THE STREAM CONTAINS
- Box label photos: the end of an archive box or a label on it (repository, collection, box number).
  Kind "box".
- Folder label photos: a folder tab or folder label (title, dates, folder number). Kind "folder".
- Document pages: everything else. A document is one item an archivist would describe on its own: a
  letter, memo, report, newspaper clipping, form, list or printed item. Many are one page; some run long.
- The photographs are in the order they were taken and are never reordered. Runs of several box or
  folder photos in a row are normal: an empty box or folder was examined and nothing in it was
  photographed. Each such photo is still kind "box" or "folder".

WHAT IS ONE DOCUMENT (the archive's rules)
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
11. A box or folder label photo is never part of a document: every gap next to one is "new".

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

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer; it may include text that
shows through from the sheet beneath)
{texts}

ANSWER in the JSON schema given: "pages" has one entry per page in this window ({pages}), in order,
with its kind; "boundaries" has one entry for every gap between consecutive pages: {gaps}.
"between" is [n, n+1]; "new" means page n+1 starts a new document (or is a label photo, or follows one);
"continue" means page n+1 belongs to the same document as page n. "cue" is the cue you relied on, under
15 words. "confidence" is your probability, 0 to 1, that the decision is right: 0.95 and above only when
the cue is unambiguous, about 0.6 when you are close to guessing.
"""


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
    prompt = PROMPT.format(k=len(nums), texts=texts, gaps=gaps, max_text=W.MAX_TEXT,
                           pages=", ".join(str(n) for n in nums))
    return prompt, thumbs, nums


def request_body(prompt: str, images: list[bytes], nums: list[int]) -> dict:
    parts = []
    for n, img in zip(nums, images):
        parts.append({"text": f"Page {n}:"})
        parts.append({"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(img).decode("ascii")}})
    parts.append({"text": prompt})
    return {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": dict(GEN_CONFIG, responseSchema=RESPONSE_SCHEMA)}


def cache_key(prompt: str, thumbs) -> str:
    return data.response_cache_key(MODEL, PROMPT_VERSION, GEN_CONFIG, RESPONSE_SCHEMA, prompt,
                                   [data.file_hash(t) for t in thumbs])


# --- the response -----------------------------------------------------------------------------

class Blocked(ValueError):
    """The reply carried no usable answer (blocked prompt, safety, recitation, truncated). Defined on
    ValueError, not method_window.ParseError, because this module may be imported while method_window is
    still loading (methods.py imports both); nothing here touches method_window at import time."""


def response_text(resp: dict) -> str:
    """The answer text of a generateContent reply: the non-thought text parts of the first candidate."""
    fb = resp.get("promptFeedback") or {}
    if fb.get("blockReason"):
        raise Blocked(f"prompt blocked: {fb['blockReason']}")
    cands = resp.get("candidates") or []
    if not cands:
        raise Blocked("no candidates")
    c = cands[0]
    reason = c.get("finishReason")
    if reason not in (None, "STOP"):
        raise Blocked(f"finishReason {reason}")
    parts = (c.get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
    if not text.strip():
        raise Blocked("empty answer")
    return text


def usage(resp: dict) -> dict:
    u = resp.get("usageMetadata") or {}
    return {"in": u.get("promptTokenCount", 0), "out": u.get("candidatesTokenCount", 0),
            "thought": u.get("thoughtsTokenCount", 0)}


def cost_usd(u: dict) -> float:
    return (u["in"] * PRICE_IN + (u["out"] + u["thought"]) * PRICE_OUT) / 1e6


def parse_response(resp: dict, nums: list[int]) -> dict:
    """Raises Blocked (no usable reply) or method_window.ParseError (a reply that breaks the format)."""
    return W.parse_answer(response_text(resp), nums)


# --- calling ----------------------------------------------------------------------------------

_key = None
_key_lock = threading.Lock()


def api_key() -> str:
    """Read once from the Keychain into memory. Never printed or written."""
    global _key
    with _key_lock:
        if _key is None:
            r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                                "-a", "Gemini", "-w"], capture_output=True, text=True)
            k = r.stdout.strip()
            if r.returncode != 0 or not k:
                raise SystemExit("no Gemini key in the Keychain (com.archiveprocessor.app / Gemini)")
            _key = k
        return _key


class Fatal(RuntimeError):
    pass


def post(verb: str, body: dict) -> dict:
    """POST with back-off on 429/5xx/network errors. Errors name the status, never the key."""
    import requests
    url = API.format(model=MODEL, verb=verb)
    last = None
    for attempt in range(MAX_ATTEMPTS):
        try:
            r = requests.post(url, json=body, timeout=TIMEOUT_S,
                              headers={"x-goog-api-key": api_key(), "Content-Type": "application/json"})
        except requests.RequestException as e:
            last = f"network: {type(e).__name__}"
        else:
            if r.status_code == 200:
                return r.json()
            last = f"HTTP {r.status_code}: {r.text[:300]}"
            if r.status_code != 429 and r.status_code < 500:
                raise Fatal(last)
            ra = r.headers.get("Retry-After")
            if ra and ra.isdigit():
                time.sleep(min(120, int(ra)))
                continue
        time.sleep(min(120, 5 * 2 ** attempt))
    raise RuntimeError(f"gave up after {MAX_ATTEMPTS} attempts: {last}")


_log_lock = threading.Lock()


def log(rec: dict) -> None:
    with _log_lock:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(json.dumps(rec) + "\n")


def judge_window(col, a: int, b: int, allow_call: bool = True) -> dict | None:
    prompt, thumbs, nums = build_request(col, a, b)
    key = cache_key(prompt, thumbs)
    hit = CACHE.get(key)
    if hit is not None:
        return parse_response(hit["response"], nums)
    if not allow_call:
        return None
    body = request_body(prompt, [t.read_bytes() for t in thumbs], nums)
    last = None
    for attempt in range(3):
        t0 = time.time()
        resp = post("generateContent", body)
        u = usage(resp)
        rec = {"collection": col.name, "window": nums, "event": "call", "attempt": attempt, "model": MODEL,
               "wall_s": round(time.time() - t0, 1), **u, "usd": round(cost_usd(u), 6), "t": time.time()}
        try:
            parsed = parse_response(resp, nums)
        except (W.ParseError, Blocked) as e:
            last = e
            rec.update(event="parse-failure", error=str(e)[:300])
            log(rec)
            continue
        log(rec)
        CACHE.put(key, {"response": resp, "model": MODEL, "thinking": THINKING, "usage": u})
        return parsed
    raise RuntimeError(f"{col.name} {nums}: no valid answer after 3 calls: {last}")


def refuse_test(names) -> None:
    bad = [n for n in names if n not in data.DEV]
    if bad:
        raise SystemExit(f"refused: {bad} are not development collections (W36.seg-second runs on "
                         f"{list(data.DEV)} only; the test set is scored once, at W36.seg-ensemble)")


def all_jobs(names):
    jobs = []
    for name in names:
        col = data.load(name, with_exif=False)
        jobs += [(col, a, b) for a, b in W.windows(len(col.pages))]
    return jobs


def estimate(names, sample: int = 3) -> float:
    """countTokens (free) on a few windows per collection; output from the probe calls logged so far,
    else a guess of 900 tokens a window. Prints and returns the estimated total in USD."""
    refuse_test(names)
    jobs = all_jobs(names)
    toks = []
    for name in names:
        js = [j for j in jobs if j[0].name == name]
        for j in (js[1], js[len(js) // 2], js[-2])[:sample]:
            prompt, thumbs, nums = build_request(*j)
            body = request_body(prompt, [t.read_bytes() for t in thumbs], nums)
            r = post("countTokens", {"generateContentRequest": dict(body, model=f"models/{MODEL}")})
            toks.append(r.get("totalTokens", 0))
    mean_in = sum(toks) / len(toks)
    recs = [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []
    calls = [r for r in recs if r.get("event") in ("call", "parse-failure") and r.get("model") == MODEL]
    mean_out = (sum(r["out"] + r["thought"] for r in calls) / len(calls)) if calls else 900
    todo = sum(judge_window(*j, allow_call=False) is None for j in jobs)
    usd = todo * (mean_in * PRICE_IN + mean_out * PRICE_OUT) / 1e6
    print(f"{len(jobs)} windows, {todo} to call; mean input {mean_in:.0f} tokens (countTokens on {len(toks)}), "
          f"mean output+thinking {mean_out:.0f} ({'measured on ' + str(len(calls)) + ' calls' if calls else 'guessed'}); "
          f"assumed price ${PRICE_IN}/${PRICE_OUT} per M in/out -> estimated ${usd:.2f} "
          f"(x1.2 for retries: ${1.2 * usd:.2f})")
    return usd


def collect(names) -> None:
    refuse_test(names)
    est = estimate(names)
    if 1.2 * est > COST_CAP_USD:
        raise SystemExit(f"estimate ${1.2 * est:.2f} exceeds the ${COST_CAP_USD:.0f} cap; not running")
    todo = [j for j in all_jobs(names) if judge_window(*j, allow_call=False) is None]
    print(f"{len(todo)} to call", flush=True)
    stop = threading.Event()
    t0, done = time.time(), [0]

    def work(job, delay):
        time.sleep(delay)
        if stop.is_set():
            return
        col, a, b = job
        try:
            judge_window(col, a, b)
        except Fatal as e:
            stop.set()
            print(f"FATAL, stopping: {e}", flush=True)
            return
        except Exception as e:  # noqa: BLE001 - one window failing does not stop the rest
            print(f"FAILED {col.name} {col.pages[a].n}-{col.pages[b - 1].n}: {str(e)[:200]}", flush=True)
            return
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {col.pages[a].n}-{col.pages[b - 1].n}",
              flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        futs = [ex.submit(work, j, STAGGER_S * k if k < CONCURRENCY else 0) for k, j in enumerate(todo)]
        for f in cf.as_completed(futs):
            f.result()
    print(f"done in {time.time() - t0:.0f}s; spent so far ${spent():.4f}", flush=True)


def spent() -> float:
    recs = [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []
    return sum(r.get("usd", 0) for r in recs if r.get("model") == MODEL)


# --- the method -------------------------------------------------------------------------------

class WindowGemini(Method):
    tuning = True
    held_out = ("no: prompt written after reading the owner's notes on dev pages, not tuned on its errors; "
                "no fitted parameters")
    tuned_on = ("nothing fitted. The prompt was written once from the plan, the owner's domain cues and the approved "
                "document rules, after earlier bench items had read development pages, and checked on one probe "
                "window for format only; it was not revised against page-level errors")

    def __init__(self, truth_photos: bool):
        self.truth_photos = self.oracle_photos = truth_photos
        self.name = "window-gemini-lite-truth-photos" if truth_photos else "window-gemini-lite"

    @property
    def description(self):
        truth_photos = self.truth_photos
        return (f"Gemini {MODEL} (API, thinkingLevel {THINKING}, temperature 0) over {W.WINDOW}-page windows, "
                f"stride {W.STRIDE}, images at {W.THUMB_PX} px plus Apple Vision text, prompt {PROMPT_VERSION} with "
                "the owner's domain cues; every gap judged in two windows, P(new) averaged; "
                + ("photo labels from the truth" if self.truth_photos else "the model's own photo labels"))

    def predict(self, collection):
        refuse_test([collection.name])
        return W.assemble(collection, W.combine(collection, judge_window), self.truth_photos)


for _m in (WindowGemini(False), WindowGemini(True)):
    METHODS[_m.name] = _m


# --- voting with window-claude ----------------------------------------------------------------

def vote_labels(truth, preds, reviewed: set[int]) -> list[str]:
    """Labels from two assembled predictions: where they agree, their common call; at a reviewed gap,
    the truth's boundary and the truth's photo status of its two pages; at an unreviewed disagreement,
    the more confident model's boundary, and the first model's photo calls."""
    t_ids = segment_ids(truth)
    p1, p2 = preds
    photo = [a if a in PHOTO else None for a in p1.labels]
    dec = []
    for b1, b2 in zip(p1.boundaries, p2.boundaries):
        dec.append(b1["decision"] if b1["decision"] == b2["decision"] or b1["confidence"] >= b2["confidence"]
                   else b2["decision"])
    for i in reviewed:
        dec[i] = "new" if t_ids[i] != t_ids[i + 1] else "continue"
        for k in (i, i + 1):
            photo[k] = truth[k] if truth[k] in PHOTO else None
    out = []
    for i in range(len(truth)):
        if photo[i]:
            out.append(photo[i])
        elif i == 0 or photo[i - 1] or dec[i - 1] == "new":
            out.append("New")
        else:
            out.append("Cont")
    return out


def flagged(p1, p2) -> list[int]:
    """Gaps where the two models' assembled segmentations differ (boundary, or a photo call beside it)."""
    out = []
    for i, (b1, b2) in enumerate(zip(p1.boundaries, p2.boundaries)):
        photo_diff = any((p1.labels[k] in PHOTO) != (p2.labels[k] in PHOTO) or
                         (p1.labels[k] in PHOTO and p1.labels[k] != p2.labels[k]) for k in (i, i + 1))
        if b1["decision"] != b2["decision"] or photo_diff:
            out.append(i)
    return out


def vote(cols, truth_photos: bool, other=None):
    """Per collection and pooled: gaps flagged, document-gap errors left among the agreed, and the
    headline before and after review of the flagged gaps; plus the review load to 98% when the agreed
    gaps are reviewed after the flagged ones, least confident (lower of the two) first."""
    other = other or W.judge_window
    rows, items, state = [], [], {}
    for c in cols:
        pc = W.assemble(c, W.combine(c, other), truth_photos)
        pg = W.assemble(c, W.combine(c, judge_window), truth_photos)
        fl = flagged(pc, pg)
        t_ids, pc_ids = segment_ids(c.labels), segment_ids(pc.labels)
        doc = [i for i in range(len(c.labels) - 1) if c.labels[i] not in PHOTO and c.labels[i + 1] not in PHOTO]
        agreed_err = sum(1 for i in doc if i not in fl and (t_ids[i] != t_ids[i + 1]) != (pc_ids[i] != pc_ids[i + 1]))
        flagged_doc = [i for i in doc if i in fl]
        flagged_err_c = sum(1 for i in flagged_doc if (t_ids[i] != t_ids[i + 1]) != (pc_ids[i] != pc_ids[i + 1]))
        pg_ids = segment_ids(pg.labels)
        flagged_err_g = sum(1 for i in flagged_doc if (t_ids[i] != t_ids[i + 1]) != (pg_ids[i] != pg_ids[i + 1]))
        before = score_labels(c.labels, vote_labels(c.labels, (pc, pg), set()))
        after = score_labels(c.labels, vote_labels(c.labels, (pc, pg), set(fl)))
        rows.append({"name": c.name, "pages": len(c.labels), "gaps": len(c.labels) - 1, "flagged": len(fl),
                     "doc_gaps": len(doc), "flagged_doc": len(flagged_doc), "agreed_err": agreed_err,
                     "flagged_err_claude": flagged_err_c, "flagged_err_gemini": flagged_err_g,
                     "before": before, "after": after})
        state[c.name] = (c, pc, pg, set(fl))
        fixed = {i for i, b in enumerate(pc.boundaries) if b.get("fixed")}
        for i in range(len(c.labels) - 1):
            if i in fl or i in fixed:
                continue
            items.append((round(min(pc.boundaries[i]["confidence"], pg.boundaries[i]["confidence"]), 6), c.name, i))
    items.sort(key=lambda t: t[0])
    reviewed = {n: set(s[3]) for n, s in state.items()}

    def pooled():
        ex = dp = 0
        per = {}
        for n, (c, pc, pg, _) in state.items():
            sc = score_labels(c.labels, vote_labels(c.labels, (pc, pg), reviewed[n]))
            ex, dp = ex + sc.pages_exact, dp + sc.doc_pages
            per[n] = sc.pages_exact / sc.doc_pages
        return ex / dp, per

    base = sum(len(s[3]) for s in state.values())
    curve = [(base, *pooled())]
    for k, (conf, n, i) in enumerate(items, 1):
        reviewed[n].add(i)
        if k == len(items) or items[k][0] != conf:
            curve.append((base + k, *pooled()))
    return rows, curve


def _pct(x):
    return f"{100 * x:.1f}%"


def vote_lines(cols, pages: int) -> tuple[list[str], dict]:
    L = ["## Voting with window-claude", "",
         "window-claude's answers come from its cache (no new Claude call). A boundary both models decide the same "
         "way, with the same photo calls on its two pages, is accepted; any other is flagged for review. Before "
         "review a disagreement takes the more confident model's call. Review corrects a flagged boundary to the "
         "truth" + ", with its two pages' photo status." , ""]
    head = {}
    for truth_photos in (False, True):
        var = "photo labels from the truth" if truth_photos else "each model's own photo labels"
        rows, curve = vote(cols, truth_photos)
        L += [f"### {var.capitalize()}", "",
              "| collection | gaps | flagged | flagged per 100 pages | document gaps flagged | errors left among agreed "
              "document gaps | claude's errors at flagged gaps | gemini's errors at flagged gaps | pages in exact doc, "
              "no review | after reviewing the flagged |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        tot = None
        for r in rows:
            L.append(f"| {r['name']} | {r['gaps']} | {r['flagged']} | {100 * r['flagged'] / r['pages']:.1f} | "
                     f"{r['flagged_doc']} | {r['agreed_err']} | {r['flagged_err_claude']} | {r['flagged_err_gemini']} | "
                     f"{_pct(r['before'].pages_exact / r['before'].doc_pages)} | "
                     f"{_pct(r['after'].pages_exact / r['after'].doc_pages)} |")
            if tot is None:
                tot = dict(r)
            else:
                for k in ("pages", "gaps", "flagged", "doc_gaps", "flagged_doc", "agreed_err",
                          "flagged_err_claude", "flagged_err_gemini"):
                    tot[k] += r[k]
                tot["before"] = tot["before"] + r["before"]
                tot["after"] = tot["after"] + r["after"]
        L.append(f"| pooled | {tot['gaps']} | {tot['flagged']} | {100 * tot['flagged'] / tot['pages']:.1f} | "
                 f"{tot['flagged_doc']} | {tot['agreed_err']} | {tot['flagged_err_claude']} | "
                 f"{tot['flagged_err_gemini']} | {_pct(tot['before'].pages_exact / tot['before'].doc_pages)} | "
                 f"{_pct(tot['after'].pages_exact / tot['after'].doc_pages)} |")
        pt98 = next((p for p in curve if p[1] >= 0.98), None)
        all98 = next((p for p in curve if min(p[2].values()) >= 0.98), None)
        L += ["", "Review load to 98% pages in an exact document, reviewing every flagged boundary first and then the "
              "agreed ones least confident first (the lower of the two models' confidences), whole ties at a time:", "",
              "| target | boundaries reviewed | per 100 pages | pooled | " + " | ".join(data.DEV) + " |",
              "|---|---:|---:|---:|" + "---:|" * len(data.DEV)]
        for tag, pt in (("flagged only", curve[0]), ("98% pooled", pt98), ("98% in every collection", all98)):
            if pt is None:
                L.append(f"| {tag} | not reached | | | " + " | " * len(data.DEV))
            else:
                L.append(f"| {tag} | {pt[0]} | {100 * pt[0] / pages:.1f} | {_pct(pt[1])} | "
                         + " | ".join(_pct(pt[2][n]) for n in data.DEV) + " |")
        L.append("")
        head[truth_photos] = (tot, curve, pt98, all98)
    return L, head


def report() -> str:
    import csv
    import run
    cols = [data.load(n) for n in data.DEV]
    pages = sum(len(c.pages) for c in cols)
    headlines = {}
    for name in ("window-gemini-lite", "window-gemini-lite-truth-photos"):
        rows = run.run(name, list(data.DEV), False)
        run.write(name, list(data.DEV), rows)
        headlines[name] = rows
    L = ["# W36.seg-second — Gemini Flash-Lite over overlapping page windows, and voting (development set)", "",
         f"Run 2026-10-05 on Dean, Deaver and Herrnstein ({pages} pages) only; the test collections were not touched. "
         f"Model {MODEL} through the Gemini API, thinkingLevel \"{THINKING}\", temperature 0, JSON response schema. "
         f"The same windows as window-claude ({W.WINDOW} pages, stride {W.STRIDE}, every gap judged in two windows), "
         "with a NEW prompt that states the owner's domain cues and the approved document rules. The prompt was "
         "written after reading the owner's notes on development pages and was not revised against page-level "
         "errors; nothing was fitted. Both the model and the prompt differ from window-claude, so a difference "
         "between them cannot be put down to either alone.", ""]
    L += ["## Headline", "", "| method | collection | pages in exact doc | docs exact | false splits | false merges | "
          "boundary F1 |", "|---|---|---:|---:|---:|---:|---:|"]
    others = {}
    for k in ("window-claude", "spring-v1"):
        with open(run.RESULTS / f"{k}-dev.tsv", newline="") as fh:
            others[k] = list(csv.DictReader(fh, delimiter="\t"))
    for k, rows in list(headlines.items()) + list(others.items()):
        for r in rows:
            col = "pooled" if str(r["collections"]).startswith("POOLED") else r["collections"]
            f = lambda key: float(r[key])
            L.append(f"| {k} | {col} | {_pct(f('pages_in_exact_doc'))} | {_pct(f('docs_exact'))} | "
                     f"{r['false_splits']} | {r['false_merges']} | {f('boundary_f1'):.3f} |")
    L.append("")
    A, load98, (g, dis) = W.analysis_lines(cols, pages, judge_window)
    L += A
    V, vhead = vote_lines(cols, pages)
    L += V
    recs = [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []
    calls = [r for r in recs if r.get("event") in ("call", "parse-failure") and r.get("model") == MODEL]
    tin = sum(r["in"] for r in calls)
    tout = sum(r["out"] + r["thought"] for r in calls)
    L += ["## Calls and cost", "",
          f"Windows: {sum(len(W.windows(len(c.pages))) for c in cols)}. Calls made: {len(calls)} "
          f"({sum(r['event'] == 'parse-failure' for r in calls)} parse failures). Tokens: {tin:,} in, {tout:,} out "
          f"(of them {sum(r['thought'] for r in calls):,} thinking). Mean wall time "
          f"{sum(r['wall_s'] for r in calls) / max(1, len(calls)):.1f} s. Cost at the assumed list price "
          f"(${PRICE_IN} / ${PRICE_OUT} per million tokens in / out; the models endpoint gives no prices): "
          f"${spent():.2f}.", ""]
    text = "\n".join(L) + "\n"
    (run.RESULTS / "window-gemini-lite-report.md").write_text(text)
    gl = headlines["window-gemini-lite"][-1]["pages_in_exact_doc"]
    wc = float(others["window-claude"][-1]["pages_in_exact_doc"])
    sp = float(others["spring-v1"][-1]["pages_in_exact_doc"])
    tot, curve, pt98, _ = vhead[False]
    sec = ["", "## W36.seg-second — Gemini Flash-Lite over page windows, and two-model voting (development set)", "",
           f"Model {MODEL}, thinkingLevel {THINKING}, temperature 0; the window-claude windows with a new prompt carrying "
           "the owner's domain cues. Detail: window-gemini-lite-report.md.", "",
           f"Pages in an exact document, pooled, own photo labels: window-gemini-lite {_pct(gl)}, window-claude "
           f"{_pct(wc)}, spring-v1 {_pct(sp)}. Review load to 98% by its own confidence: "
           + (f"{load98[(False, 'confidence')]} boundaries ({100 * load98[(False, 'confidence')] / pages:.0f} per 100 pages)."
              if (False, 'confidence') in load98 else "not reached."),
           "",
           f"Voting with window-claude (own photo labels): {tot['flagged']} of {tot['gaps']} boundaries flagged "
           f"({100 * tot['flagged'] / tot['pages']:.1f} per 100 pages), holding {tot['flagged_err_claude']} of "
           f"window-claude's errors and {tot['flagged_err_gemini']} of window-gemini-lite's; {tot['agreed_err']} errors "
           f"left among the agreed document boundaries (both models wrong the same way); {_pct(tot['after'].pages_exact / tot['after'].doc_pages)} of pages in an exact "
           "document after reviewing the flagged ones"
           + (f"; 98% pooled after {pt98[0]} reviews ({100 * pt98[0] / pages:.1f} per 100 pages)." if pt98 else
              "; 98% not reached.")]
    (run.RESULTS / "window-gemini-lite.summary-section.md").write_text("\n".join(sec) + "\n")
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
        name, w = rest[0], int(rest[1])
        refuse_test([name])
        c = data.load(name, with_exif=False)
        a, b = W.windows(len(c.pages))[w]
        print(json.dumps(judge_window(c, a, b), indent=1))
        print(f"spent so far ${spent():.4f}")
    else:
        print(report())
    return 0


if __name__ == "__main__":
    import method_gemini as _G   # the registered module, not a second copy as __main__
    sys.exit(_G.main(sys.argv[1:]))
