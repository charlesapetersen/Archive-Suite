"""Approach A (W36.seg-window): Claude judging every boundary in overlapping page windows.

    python method_window.py collect [Dean Deaver Herrnstein]   # make the calls (cached; dev only)
    python method_window.py probe Dean 0                       # one window, printed, for inspection
    python method_window.py report                             # both variants through run.py + the report

THE ROUTE. Each window is one headless Claude Code call (``claude -p``) on the owner's subscription,
model ``claude-sonnet-5-5``, started with every ``CLAUDE*`` variable removed from the environment (a
nested session refuses otherwise), with the working directory set to a scratch folder that holds the
window's page images (``sips -Z 1600``, under the bench cache, outside git). The model reads them with
its Read tool — the only tool allowed — and gets each page's cached Apple Vision text in the prompt.
No API key, no Keychain. Every valid response is stored by content hash (model, prompt text and the
image bytes' hashes) in ``ResponseCache("window-claude")``, so a rerun makes no call. At most three
calls run at once, started a few seconds apart, with back-off on errors.

THE WINDOWS. 7 pages, stride 3, starting 3 pages before the stream (the first window is clipped to
4 pages), so EVERY gap between two pages lies inside at least two windows. The brief said 6 pages with
stride 3 "so each internal boundary is judged in two windows"; a 6-page window has 5 gaps and two
windows 3 apart share only 2 of them, so one gap in three would be judged once. 7 pages is the
smallest window that honours the two-judgement rule at stride 3 (the plan allows 6-8), at the same
number of calls.

COMBINING. Each judgement is read as a probability of "new": confidence c on "new" is c, on
"continue" is 1 - c. A boundary's P(new) is the mean over the windows that judged it; the decision is
"new" when P(new) >= 0.5 (an exact tie goes to "new", as the app's prompt prefers a document start
when unsure), and the combined confidence is max(P, 1 - P). Two agreeing judgements give the mean of
their confidences; two disagreeing ones give the higher-confidence side, its confidence pulled toward
0.5 by the other — and the boundary is flagged ``disagree``. Box/folder labels per page are a majority
vote over the windows that saw the page (ties go to "document").

TWO VARIANTS. ``window-claude`` uses the model's own photo labels; ``window-claude-truth-photos``
takes them from the truth, like the bench's baselines (a page after a truth photo opens a document).

TUNING. The prompt was written once, from the plan's description of the material and the draft
document rules in execution-plans/segmentation/02-truth-check.md, after the bench's earlier items had
read development pages. It was checked on ONE probe window for format; it was NOT revised against
page-level errors. The method is marked ``tuning`` so the bench refuses the test collections, and
``collect`` refuses them too.
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import data
from methods import METHODS, Method, Prediction
from score import PHOTO, boundaries_from_labels, segment_ids, derived, score_labels

MODEL = "claude-sonnet-5-5"
CLAUDE_BIN = "/Users/cp1/.local/bin/claude"
WINDOW, STRIDE = 7, 3
THUMB_PX = 1600
MAX_TEXT = 2500          # characters of OCR text per page in the prompt
CONCURRENCY = 3
STAGGER_S = 4.0
CALL_TIMEOUT_S = 900
CACHE = data.ResponseCache("window-claude")
WORK = data.CACHE_DIR / "windows"
LOG = data.CACHE_DIR / "window-claude-calls.jsonl"

PROMPT_VERSION = "w1"


# --- windows ----------------------------------------------------------------------------------

def windows(n: int) -> list[tuple[int, int]]:
    """[start, end) page-index windows: 7 pages, stride 3, the first starting 3 before the stream."""
    out = []
    s = -STRIDE
    while True:
        a, b = max(0, s), min(n, s + WINDOW)
        if b - a >= 2 and (not out or (a, b) != out[-1]):
            out.append((a, b))
        if s + WINDOW >= n + STRIDE:
            break
        s += STRIDE
    return out


def coverage(n: int) -> list[int]:
    """How many windows contain each gap i|i+1."""
    cov = [0] * (n - 1)
    for a, b in windows(n):
        for i in range(a, b - 1):
            cov[i] += 1
    return cov


# --- the prompt -------------------------------------------------------------------------------

PROMPT = """You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through an archive box, in box order.
This window holds {k} consecutive photographs from the stream. Their files are in the current directory:

{files}

FIRST read every one of these image files with the Read tool (issue all the Read calls together, in one
turn). Then answer from the images, using the OCR text below as a help for reading (the OCR is automatic
and has errors; the image wins when they disagree).

WHAT THE STREAM CONTAINS
- Box label photos: the end of an archive box or a label on it (repository, collection name, box number,
  call number). Kind "box".
- Folder label photos: a folder tab or folder label (folder title, dates, folder number), photographed
  to mark the start of a folder. Kind "folder".
- Document pages: everything else. A document is one item an archivist would describe on its own: a
  letter, a memo, a report, a newspaper clipping, a form, a list, a printed item. Many documents are one
  page; some run to many pages.

THE RULES FOR WHAT IS ONE DOCUMENT
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter) is its
   own document: its first page is new.
2. An attachment made to go with a letter or memo ("Attachment A", a list, a table, a budget) with no
   date, author or heading of its own continues that letter.
3. A carbon copy of a letter is a document like any letter: its first page is new.
4. Two copies of the same document kept together are two documents: the second copy's first page is new.
5. The same page photographed twice by mistake: the repeat continues.
6. An envelope next to the letter it held continues that letter; an envelope on its own is a document.
7. Each newspaper article is its own document; a second piece of the same article ("continued on page
   8") continues it; several articles in one photograph are one document.
8. A photograph (a print) is its own document; a photo of its back continues it.
9. A blank page or the blank back of a sheet continues the document it belongs to.
10. A box or folder label photo is never part of a document: every gap next to one is "new".

CUES
- Continue: a page number of 2 or more ("-2-", "Page 2", "2."), often with the addressee's name and the
  date repeated as a running head; text that runs on from the previous page mid-sentence or
  mid-paragraph; the same typescript, report layout or numbered sections continuing; the previous page
  ends without a closing or signature and this page carries on and ends with one; a table or list
  carrying on.
- New: a letterhead; a date line, inside address and salutation ("Dear ..."); a memo heading (TO /
  FROM / SUBJECT / MEMORANDUM); a title page; a new masthead, headline or dateline of a clipping;
  "Page 1"; a clear change of paper, type, author or subject. A previous page that ends with a closing
  ("Sincerely", "Yours truly"), a signature, typist's initials, "cc:" or "Enclosure" makes the next
  page likely new — but an attachment or enclosure may follow (rules 1 and 2).
- Not evidence on their own: two letters to the same person, or on the same subject, are still two
  documents; a similar look alone does not join pages.

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer)
{texts}

ANSWER with one JSON object and nothing else (no prose, no code fence):
{{
  "pages": [{{"page": <page number>, "kind": "box" | "folder" | "document"}}, ...one per page, in order],
  "boundaries": [
    {{"between": [<n>, <n+1>], "decision": "new" | "continue", "cue": "<the cue you saw, under 15 words>",
      "confidence": <0 to 1, your probability that the decision is right>}},
    ...one for every gap between consecutive pages in this window: {gaps}
  ]
}}
"new" means page n+1 starts a new document (or is a label photo, or follows one); "continue" means
page n+1 belongs to the same document as page n. Use confidence honestly: 0.95 and above only when the
cue is unambiguous, about 0.6 when you are close to guessing.
"""


def page_text(col, i: int) -> str:
    t = (col.text(i) or "").strip()
    if not t:
        return "(no text found)"
    return t if len(t) <= MAX_TEXT else t[:MAX_TEXT] + " [...]"


def fname(n: int) -> str:
    return f"page-{n:04d}.jpg"


def build_request(col, a: int, b: int) -> tuple[str, list[Path], list[int]]:
    nums = [col.pages[i].n for i in range(a, b)]
    thumbs = []
    for i in range(a, b):
        t = data.thumbnail(col.name, col.pages[i], THUMB_PX)
        if t is None:
            raise RuntimeError(f"{col.name} {col.pages[i].n}: thumbnail failed")
        thumbs.append(t)
    files = "\n".join(f"- {fname(n)}  (page {n})" for n in nums)
    texts = "\n".join(f"--- page {n} ---\n{page_text(col, i)}" for n, i in zip(nums, range(a, b)))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    prompt = PROMPT.format(k=len(nums), files=files, texts=texts, gaps=gaps, max_text=MAX_TEXT)
    return prompt, thumbs, nums


def cache_key(prompt: str, thumbs: list[Path]) -> str:
    return data.response_cache_key(MODEL, PROMPT_VERSION, prompt, [data.file_hash(t) for t in thumbs])


# --- parsing ----------------------------------------------------------------------------------

class ParseError(ValueError):
    pass


def parse_answer(text: str, nums: list[int]) -> dict:
    s = text.strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j < 0:
        raise ParseError("no JSON object in the reply")
    try:
        obj = json.loads(s[i:j + 1])
    except json.JSONDecodeError as e:
        raise ParseError(f"bad JSON: {e}") from e
    pages = {}
    for p in obj.get("pages", []):
        k = p.get("kind")
        if k not in ("box", "folder", "document"):
            raise ParseError(f"page {p.get('page')}: kind {k!r}")
        pages[int(p["page"])] = k
    if sorted(pages) != nums:
        raise ParseError(f"pages {sorted(pages)} for {nums}")
    bounds = {}
    for bd in obj.get("boundaries", []):
        x, y = (int(v) for v in bd["between"])
        if y != x + 1 or x not in nums[:-1]:
            raise ParseError(f"boundary {[x, y]} not in the window")
        d = bd.get("decision")
        if d not in ("new", "continue"):
            raise ParseError(f"boundary {x}: decision {d!r}")
        c = float(bd.get("confidence"))
        if not 0 <= c <= 1:
            raise ParseError(f"boundary {x}: confidence {c}")
        bounds[x] = {"decision": d, "confidence": c, "cue": str(bd.get("cue", ""))[:200]}
    if sorted(bounds) != nums[:-1]:
        raise ParseError(f"boundaries for {sorted(bounds)}, wanted {nums[:-1]}")
    return {"pages": pages, "boundaries": bounds}


# --- calling ----------------------------------------------------------------------------------

class UsageLimit(RuntimeError):
    pass


def clean_env() -> dict:
    return {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}


def call_claude(prompt: str, workdir: Path) -> dict:
    cmd = [CLAUDE_BIN, "-p", prompt, "--model", MODEL, "--output-format", "json",
           "--allowedTools", "Read", "--permission-mode", "default", "--no-session-persistence"]
    t0 = time.time()
    r = subprocess.run(cmd, cwd=workdir, env=clean_env(), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=CALL_TIMEOUT_S)
    wall = time.time() - t0
    try:
        out = json.loads(r.stdout)
    except json.JSONDecodeError:
        msg = (r.stdout + r.stderr)[-600:]
        if re.search(r"usage limit|rate limit|429|limit reached", msg, re.I):
            raise UsageLimit(msg)
        raise RuntimeError(f"exit {r.returncode}, no JSON: {msg}")
    if out.get("is_error") or out.get("subtype") != "success":
        msg = str(out.get("result") or out)[-600:]
        if re.search(r"usage limit|rate limit|429|limit reached", msg, re.I):
            raise UsageLimit(msg)
        raise RuntimeError(f"claude error: {msg}")
    out["_wall_s"] = wall
    return out


_log_lock = threading.Lock()


def log(rec: dict) -> None:
    with _log_lock:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(json.dumps(rec) + "\n")


def judge_window(col, a: int, b: int, allow_call: bool = True) -> dict | None:
    """The parsed judgement for one window, from the cache or (if allowed) one call."""
    prompt, thumbs, nums = build_request(col, a, b)
    key = cache_key(prompt, thumbs)
    hit = CACHE.get(key)
    if hit is not None:
        return parse_answer(hit["result"], nums)
    if not allow_call:
        return None
    wd = WORK / col.name / f"{nums[0]:04d}-{nums[-1]:04d}"
    if wd.exists():
        shutil.rmtree(wd)
    wd.mkdir(parents=True)
    for n, t in zip(nums, thumbs):
        shutil.copyfile(t, wd / fname(n))
    last = None
    for attempt in range(3):
        try:
            out = call_claude(prompt, wd)
        except UsageLimit:
            log({"collection": col.name, "window": nums, "event": "usage-limit", "t": time.time()})
            raise
        except Exception as e:  # noqa: BLE001 - logged and retried with back-off
            last = e
            log({"collection": col.name, "window": nums, "event": "error", "attempt": attempt,
                 "error": str(e)[:400], "t": time.time()})
            time.sleep(30 * (attempt + 1) ** 2)
            continue
        reads = sum(1 for d in out.get("permission_denials", []) if d)  # denials, if any
        rec = {"collection": col.name, "window": nums, "event": "call", "attempt": attempt,
               "wall_s": round(out["_wall_s"], 1), "turns": out.get("num_turns"),
               "denials": reads, "notional_usd": out.get("total_cost_usd"), "t": time.time()}
        try:
            parsed = parse_answer(out.get("result") or "", nums)
        except ParseError as e:
            last = e
            rec.update(event="parse-failure", error=str(e)[:300], reply=(out.get("result") or "")[:300])
            log(rec)
            continue
        log(rec)
        CACHE.put(key, {"result": out["result"], "model": MODEL, "num_turns": out.get("num_turns"),
                        "notional_usd": out.get("total_cost_usd"), "wall_s": out["_wall_s"],
                        "session_id": out.get("session_id")})
        shutil.rmtree(wd, ignore_errors=True)
        return parsed
    raise RuntimeError(f"{col.name} {nums}: gave up after 3 attempts: {last}")


def refuse_test(names) -> None:
    bad = [n for n in names if n not in data.DEV]
    if bad:
        raise SystemExit(f"refused: {bad} are not development collections (W36.seg-window runs on "
                         f"{list(data.DEV)} only; the test set is scored once, at W36.seg-ensemble)")


def collect(names) -> None:
    refuse_test(names)
    jobs = []
    for name in names:
        col = data.load(name, with_exif=False)
        for a, b in windows(len(col.pages)):
            jobs.append((col, a, b))
    todo = [j for j in jobs if judge_window(*j, allow_call=False) is None]
    print(f"{len(jobs)} windows, {len(jobs) - len(todo)} cached, {len(todo)} to call", flush=True)
    stop = threading.Event()
    t0 = time.time()
    done = [0]

    def work(job, delay):
        time.sleep(delay)
        if stop.is_set():
            return
        col, a, b = job
        try:
            judge_window(col, a, b)
        except UsageLimit as e:
            stop.set()
            print(f"USAGE LIMIT, stopping: {str(e)[:300]}", flush=True)
            return
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} pages "
              f"{col.pages[a].n}-{col.pages[b - 1].n}", flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        futs = [ex.submit(work, j, STAGGER_S * k if k < CONCURRENCY else 0) for k, j in enumerate(todo)]
        for f in cf.as_completed(futs):
            f.result()
    print(f"done in {time.time() - t0:.0f}s", flush=True)


# --- combining ----------------------------------------------------------------------------------

def combine(col) -> dict:
    """Per gap: P(new), decision, confidence, judgements; per page: photo kind by vote."""
    n = len(col.pages)
    votes_new = [[] for _ in range(n - 1)]
    cues = [[] for _ in range(n - 1)]
    kinds = [[] for _ in range(n)]
    index = {p.n: i for i, p in enumerate(col.pages)}
    for a, b in windows(n):
        j = judge_window(col, a, b, allow_call=False)
        if j is None:
            raise RuntimeError(f"{col.name}: window {col.pages[a].n}-{col.pages[b - 1].n} not collected; "
                               "run `method_window.py collect` first")
        for num, kind in j["pages"].items():
            kinds[index[num]].append(kind)
        for x, bd in j["boundaries"].items():
            i = index[x]
            p = bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"]
            votes_new[i].append(p)
            cues[i].append(f"{bd['decision']}:{bd['cue']}")
    gaps = []
    for i in range(n - 1):
        ps = votes_new[i]
        p = sum(ps) / len(ps)
        decs = {x >= 0.5 for x in ps}
        gaps.append({"p_new": p, "decision": "new" if p >= 0.5 else "continue",
                     "confidence": max(p, 1 - p), "n_judged": len(ps), "agree": len(decs) == 1,
                     "cue": " | ".join(cues[i])[:300]})
    photo = []
    for ks in kinds:
        cnt = {k: ks.count(k) for k in ("box", "folder", "document")}
        best = max(("box", "folder"), key=lambda k: cnt[k])
        photo.append(("Box" if best == "box" else "Folder") if cnt[best] > cnt["document"] else None)
    return {"gaps": gaps, "photo": photo, "kind_votes": kinds}


def assemble(col, comb, truth_photos: bool) -> Prediction:
    truth = col.labels
    photo = [(t if t in PHOTO else None) for t in truth] if truth_photos else comb["photo"]
    labels = []
    for i in range(len(truth)):
        if photo[i]:
            labels.append(photo[i])
        elif i == 0 or photo[i - 1] or comb["gaps"][i - 1]["decision"] == "new":
            labels.append("New")
        else:
            labels.append("Cont")
    implied = boundaries_from_labels(labels)
    bounds = []
    for i, d in enumerate(implied):
        g = comb["gaps"][i]
        if photo[i] or photo[i + 1]:
            # A gap beside a photo is a boundary by construction. With truth photos that is certain;
            # with the model's photos, the confidence is that of the photo call (vote share).
            if truth_photos:
                conf = 1.0
            else:
                shares = []
                for k in (i, i + 1):
                    if photo[k]:
                        v = comb["kind_votes"][k]
                        shares.append(sum(x != "document" for x in v) / len(v))
                conf = min(shares)
            bounds.append({"decision": d, "confidence": conf, "cue": "beside a label photo",
                           "agree": True, "fixed": truth_photos})
        else:
            bounds.append({"decision": d, "confidence": g["confidence"], "cue": g["cue"],
                           "agree": g["agree"], "fixed": False})
    return Prediction(labels, bounds)


class WindowClaude(Method):
    tuning = True
    held_out = ("no: prompt written after reading dev pages, not tuned on its errors; "
                "no fitted parameters")
    tuned_on = ("nothing fitted. The prompt was written once from the plan and the draft document rules, after "
                "earlier bench items had read development pages, and checked on one probe window for format only; "
                "it was not revised against page-level errors")

    def __init__(self, truth_photos: bool):
        self.truth_photos = truth_photos
        self.oracle_photos = truth_photos
        self.name = "window-claude-truth-photos" if truth_photos else "window-claude"
        self.description = (f"Claude Sonnet 5.5 (claude -p, subscription) over {WINDOW}-page windows, stride {STRIDE}, "
                            f"images at {THUMB_PX} px plus Apple Vision text; every gap judged in two windows, "
                            "P(new) averaged; " + ("photo labels from the truth" if truth_photos
                                                   else "the model's own photo labels"))

    def predict(self, collection):
        refuse_test([collection.name])
        return assemble(collection, combine(collection), self.truth_photos)


for _m in (WindowClaude(False), WindowClaude(True)):
    METHODS[_m.name] = _m


# --- the report: risk-coverage and the review load to 98% ----------------------------------------

def headline(truth, labels) -> float:
    c = score_labels(truth, labels)
    return c.pages_exact / c.doc_pages


def review(col, comb, truth_photos: bool, reviewed: set[int]) -> list[str]:
    """Labels after the owner corrects the reviewed gaps: each reviewed gap takes the truth's
    boundary, and (own-photo variant) the truth's photo status for the two pages beside it."""
    truth = col.labels
    t_ids = segment_ids(truth)
    photo = [(t if t in PHOTO else None) for t in truth] if truth_photos else list(comb["photo"])
    dec = [g["decision"] for g in comb["gaps"]]
    for i in reviewed:
        dec[i] = "new" if t_ids[i] != t_ids[i + 1] else "continue"
        if not truth_photos:
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


def order(pred, signal: str) -> list[int]:
    """Gaps in review order (least trusted first). Only gaps beside a TRUTH photo (the truth-photo
    variant) are never reviewed; a gap the model judged at confidence 1.0, or one beside a photo the
    model called unanimously, is still reviewable, last."""
    idx = [i for i, b in enumerate(pred.boundaries) if not b.get("fixed")]
    if signal == "confidence":
        return sorted(idx, key=lambda i: pred.boundaries[i]["confidence"])
    # agreement first: every disagreement, then the agreed gaps by confidence
    return sorted(idx, key=lambda i: (pred.boundaries[i]["agree"], pred.boundaries[i]["confidence"]))


def review_curve(cols, truth_photos: bool, signal: str):
    """Pooled: review the least-trusted gaps across the collections (one global order by the
    signal); returns [(k, pooled headline, {name: headline})] at k = 0 and at the end of each TIE
    GROUP. The model's confidences are coarse (0.97 alone covers 81 of 494 document gaps), so within
    a tie the order is arbitrary and any point inside a group would depend on it (a stable sort
    reviews Dean before Herrnstein). A threshold cannot split a tie either, so the curve steps a whole
    group at a time: the review load it reports is the one a confidence threshold would give."""
    preds = {c.name: (c, combine(c)) for c in cols}
    items = []
    for name, (c, comb) in preds.items():
        pred = assemble(c, comb, truth_photos)
        for rank_i in order(pred, signal):
            b = pred.boundaries[rank_i]
            conf = round(b["confidence"], 6)
            key = ((b["agree"], conf) if signal != "confidence" else (conf,))
            items.append((key, name, rank_i))
    items.sort(key=lambda t: t[0])
    reviewed = {n: set() for n in preds}
    curve = []

    def point(k):
        per, ex, dp = {}, 0, 0
        for name, (c, comb) in preds.items():
            labs = review(c, comb, truth_photos, reviewed[name])
            sc = score_labels(c.labels, labs)
            per[name] = sc.pages_exact / sc.doc_pages
            ex += sc.pages_exact
            dp += sc.doc_pages
        return (k, ex / dp, per)

    curve.append(point(0))
    for k, (key, name, i) in enumerate(items, 1):
        reviewed[name].add(i)
        if k == len(items) or items[k][0] != key:
            curve.append(point(k))
    return curve


def rc_table(cols, truth_photos: bool, signal: str):
    """Risk-coverage over document gaps (truth both sides), pooled: accept the most trusted first."""
    rows = []
    for c in cols:
        comb = combine(c)
        pred = assemble(c, comb, truth_photos)
        t_ids, p_ids = segment_ids(c.labels), segment_ids(pred.labels)
        for i, b in enumerate(pred.boundaries):
            if c.labels[i] in PHOTO or c.labels[i + 1] in PHOTO:
                continue
            wrong = (t_ids[i] != t_ids[i + 1]) != (p_ids[i] != p_ids[i + 1])
            key = (b["confidence"],) if signal == "confidence" else (b["agree"], b["confidence"])
            rows.append((key, wrong))
    rows.sort(key=lambda r: r[0], reverse=True)
    return rows


# The suspected label errors of execution-plans/segmentation/02-truth-check.md, applied as the truth-check
# suggests. NOT the owner's ruling (W36.seg-truth-owner-ok is open): a sensitivity, reported apart.
SUSPECTED = {"Dean": {13: "Cont", 15: "Cont"},                      # "-2-" pages labelled New
             "Herrnstein": {19: "Folder", 20: "New", 21: "Cont", 22: "New", 23: "Cont", 24: "Cont",
                            25: "New"}}                            # 19-25 read one row down


def with_suspected(col):
    import copy
    import dataclasses
    c = copy.copy(col)
    fix = SUSPECTED.get(col.name, {})
    c.pages = [dataclasses.replace(p, label=fix.get(p.n, p.label)) for p in col.pages]
    return c


def _pct(x):
    return f"{100 * x:.1f}%"


def report() -> str:
    import run
    cols = [data.load(n) for n in data.DEV]
    pages = sum(len(c.pages) for c in cols)
    headlines = {}
    for name in ("window-claude", "window-claude-truth-photos"):
        rows = run.run(name, list(data.DEV), False)
        run.write(name, list(data.DEV), rows)
        headlines[name] = rows
    L = ["# W36.seg-window — Claude over overlapping page windows (development set)", "",
         f"Run 2026-10-05 on Dean, Deaver and Herrnstein ({pages} pages) only; the test collections were not "
         "touched. Model claude-sonnet-5-5 through `claude -p` on the owner's subscription. "
         f"Windows of {WINDOW} pages, stride {STRIDE}, every gap judged in two windows "
         "(see method_window.py for why 7 and not 6). The prompt was written once, after earlier bench items had read "
         "development pages, and was not revised against page-level errors; nothing was fitted. So these are "
         "development numbers, not held-out ones in the strict sense.", ""]
    # agreement statistics
    L += ["## Two-window agreement", "", "| collection | document gaps | judged twice+ | disagreements | "
          "error rate when agreed | error rate when disagreed |", "|---|---:|---:|---:|---:|---:|"]
    tot = [0, 0, 0, 0, 0, 0]
    for c in cols:
        comb = combine(c)
        pred = assemble(c, comb, True)
        t_ids, p_ids = segment_ids(c.labels), segment_ids(pred.labels)
        g = tw = dis = ea = ed = na = 0
        for i, gp in enumerate(comb["gaps"]):
            if c.labels[i] in PHOTO or c.labels[i + 1] in PHOTO:
                continue
            g += 1
            tw += gp["n_judged"] >= 2
            wrong = (t_ids[i] != t_ids[i + 1]) != (p_ids[i] != p_ids[i + 1])
            if gp["agree"]:
                na += 1
                ea += wrong
            else:
                dis += 1
                ed += wrong
        tot = [x + y for x, y in zip(tot, (g, tw, dis, ea, ed, na))]
        L.append(f"| {c.name} | {g} | {tw} | {dis} | {_pct(ea / na) if na else '—'} ({ea}/{na}) | "
                 f"{_pct(ed / dis) if dis else '—'} ({ed}/{dis}) |")
    g, tw, dis, ea, ed, na = tot
    L.append(f"| pooled | {g} | {tw} | {dis} | {_pct(ea / na)} ({ea}/{na}) | "
             f"{_pct(ed / dis) if dis else '—'} ({ed}/{dis}) |")
    L.append("")
    load98 = {}
    for truth_photos in (True, False):
        var = "photo labels from the truth" if truth_photos else "the model's own photo labels"
        L += [f"## Risk–coverage, {var}", "",
              "Document gaps (both pages are document pages in the truth), pooled over the three collections, "
              "accepted when the combined confidence is at or above a threshold (with agreement: only gaps "
              "both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the "
              "confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose "
              "boundary is wrong.", "",
              "| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |",
              "|---|---:|---:|---:|---:|---:|---:|"]
        for signal in ("confidence", "agreement, then confidence"):
            rows = rc_table(cols, truth_photos, "confidence" if signal == "confidence" else "agree")
            n = len(rows)
            for t in (0.0, 0.8, 0.9, 0.93, 0.95, 0.96, 0.97, 0.98):
                acc = [w for key, w in rows if key[-1] >= t - 1e-9 and (signal == "confidence" or key[0])]
                k, err = len(acc), sum(acc)
                L.append(f"| {signal} | {t:.2f} | {_pct(k / n)} | {k} | {err} | "
                         f"{_pct(err / k) if k else '—'} | {100 * (n - k) / pages:.1f} |")
        L += ["", f"### Review load to reach 98% pages in an exact document, {var}", "",
              "Simulated review: the owner checks the least-trusted boundaries in one order across all three "
              "collections (a single threshold) and each checked boundary is corrected to the truth"
              + ("" if truth_photos else ", together with the photo/document status of its two pages")
              + ". Counted in boundaries reviewed per 100 pages.", "",
              "| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |",
              "|---|---:|---:|---:|---:|---:|---:|"]
        for signal in ("confidence", "agree"):
            curve = review_curve(cols, truth_photos, signal)
            label = "confidence" if signal == "confidence" else "agreement, then confidence"
            shown = set()
            for target in (None, 0.90, 0.95, 0.98, "all98"):
                if target is None:
                    pt = curve[0]
                elif target == "all98":
                    pt = next((p for p in curve if min(p[2].values()) >= 0.98), None)
                else:
                    pt = next((p for p in curve if p[1] >= target), None)
                if pt is None:
                    L.append(f"| {label} | not reached | | | | | |")
                    continue
                if pt[0] in shown:
                    continue
                shown.add(pt[0])
                if target == 0.98:
                    load98[(truth_photos, signal)] = pt[0]
                tag = {None: " (no review)", "all98": " (98% in every collection)"}.get(target, "")
                L.append(f"| {label}{tag} | {pt[0]} | {100 * pt[0] / pages:.1f} | {_pct(pt[1])} | "
                         + " | ".join(_pct(pt[2][n]) for n in data.DEV) + " |")
        L.append("")
    # sensitivity: the suspected label errors corrected as suggested
    scols = [with_suspected(c) for c in cols]
    L += ["## Sensitivity: the suspected label errors corrected", "",
          "The truth-check (02-truth-check.md) suspects Dean 13 and 15 (\"-2-\" pages labelled New) and a one-row "
          "shift at Herrnstein 19-25. The owner has NOT ruled on them; this applies them as suggested "
          "(`SUSPECTED` in method_window.py) to show how much of the result they carry. Own photo labels.", "",
          "| truth | pooled | Dean | Deaver | Herrnstein | doc-gap errors | of them at confidence >= 0.95 | "
          "boundaries reviewed to 98% pooled | per 100 pages |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for tname, cs in (("as labelled", cols), ("suspected errors corrected", scols)):
        curve = review_curve(cs, False, "confidence")
        rows = rc_table(cs, False, "confidence")
        pt = next((p for p in curve if p[1] >= 0.98), None)
        L.append(f"| {tname} | {_pct(curve[0][1])} | " + " | ".join(_pct(curve[0][2][n]) for n in data.DEV)
                 + f" | {sum(w for _, w in rows)} | {sum(w for k, w in rows if k[0] >= 0.95 - 1e-9)} | "
                 + (f"{pt[0]} | {100 * pt[0] / pages:.1f} |" if pt else "not reached | |"))
    L.append("")
    # call accounting
    recs = [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []
    calls = [r for r in recs if r["event"] in ("call", "parse-failure")]
    L += ["## Calls", "",
          f"Windows: {sum(len(windows(len(c.pages))) for c in cols)}. Calls made: {len(calls)} "
          f"({sum(r['event'] == 'parse-failure' for r in recs)} parse failures, "
          f"{sum(r['event'] == 'error' for r in recs)} errors, "
          f"{sum(r['event'] == 'usage-limit' for r in recs)} usage-limit stops). "
          f"Mean wall time per call {sum(r['wall_s'] for r in calls) / max(1, len(calls)):.0f} s. "
          "The notional list price the CLI reports, which the subscription does not charge: "
          f"${sum(r.get('notional_usd') or 0 for r in calls):.2f}.", ""]
    text = "\n".join(L) + "\n"
    (run.RESULTS / "window-claude-report.md").write_text(text)
    pooled = {k: v[-1] for k, v in headlines.items()}
    sec = ["", "## W36.seg-window — Claude over overlapping page windows (development set)", "",
           f"Claude Sonnet 5.5 via `claude -p`, {WINDOW}-page windows, stride {STRIDE}, every gap judged twice. "
           "Prompt written after reading dev pages, not tuned on its errors. Detail and the risk–coverage and "
           "review-load tables: window-claude-report.md.", "",
           "| variant | pages in exact doc | docs exact | false splits | false merges | boundary F1 |",
           "|---|---:|---:|---:|---:|---:|"]
    import csv
    with open(run.RESULTS / "spring-v1-dev.tsv", newline="") as fh:
        spring = list(csv.DictReader(fh, delimiter="\t"))
    sec[-2:] = ["| variant | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |",
                "|---|---|---:|---:|---:|---:|---:|"]
    for k, rows in list(headlines.items()) + [("spring-v1 (for comparison)", spring)]:
        for r in rows:
            col = "pooled" if str(r["collections"]).startswith("POOLED") else r["collections"]
            f = lambda key: float(r[key])
            sec.append(f"| {k} | {col} | {_pct(f('pages_in_exact_doc'))} | {_pct(f('docs_exact'))} | "
                       f"{r['false_splits']} | {r['false_merges']} | {f('boundary_f1'):.3f} |")
    sp = float(spring[-1]["pages_in_exact_doc"])
    wc = pooled["window-claude"]["pages_in_exact_doc"]
    sec += ["", f"Against spring-v1 (the shipped per-page prompt, {_pct(sp)} pooled; tuned on all five collections), "
            f"the window method scores {_pct(wc)} pooled, {100 * (wc - sp):+.1f} points, with its own photo labels. "
            "Review load to 98% pages in an exact document, pooled, by a single confidence threshold: "
            f"{load98[(False, 'confidence')]} boundaries ({100 * load98[(False, 'confidence')] / pages:.0f} per 100 "
            f"pages) with its own photo labels, {load98[(True, 'confidence')]} "
            f"({100 * load98[(True, 'confidence')] / pages:.0f} per 100) with the truth's. Two-window agreement adds "
            f"nothing: the windows disagreed on {dis} of {g} document gaps, and those already had the lowest confidence. "
            "Most of the high-confidence errors sit at the truth-check's suspected label errors; with those "
            "corrected as suggested (not yet the owner's ruling) the figures change a good deal, see the "
            "sensitivity section of window-claude-report.md."]
    (run.RESULTS / "window-claude.summary-section.md").write_text("\n".join(sec) + "\n")
    run.write_summary()
    return text


def main(argv) -> int:
    if not argv or argv[0] not in ("collect", "probe", "report", "windows"):
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "windows":
        for n in data.DEV:
            c = data.load(n, with_exif=False)
            print(n, len(c.pages), len(windows(len(c.pages))), "min coverage", min(coverage(len(c.pages))))
    elif cmd == "collect":
        collect(rest or list(data.DEV))
    elif cmd == "probe":
        name, w = rest[0], int(rest[1])
        refuse_test([name])
        c = data.load(name, with_exif=False)
        a, b = windows(len(c.pages))[w]
        print(json.dumps(judge_window(c, a, b), indent=1))
    else:
        print(report())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
