"""W47.wh-seg-magazine: prompt c1, with and without the article-within-issue rule, on the magazine box.

  python3 seg_magazine_c1.py plan                  # windows, cached answers and the cost bound (no calls)
  python3 seg_magazine_c1.py collect --workers 1   # the uncached windows through the Stanford gateway (paid, capped)
  python3 seg_magazine_c1.py release-budget        # free a send the gateway refused for its monthly budget (no charge)
  python3 seg_magazine_c1.py score              # segbench-results/seg-magazine-c1.{md,json}; no call

Owner, 2026-11-19 (call 15): the `magazine` figure ranks nothing for c1 (the ChatGPT, GLM and local 2B voters'
prompt) because c1 still carries g1's full-magazine rule 10. Run c1 with the article-within-issue rule through the
gateway and score it on the Illustrated Review. c3 is c1 with rule 10 replaced by `magazine_rule.RULE10_G2`, the
rewrite that made g2 from g1; nothing else changes. Both prompts are sent, so the pair is like for like.

THE ARMS, fixed before any answer: the gateway's two models in the c1 voters' families, GPT 5.6 Luna (the gateway's
GPT; the app's ChatGPT voter is gpt-6.1-sol through Codex, which the gateway does not serve) and GLM 5.3 Flash (the
app's budget voter's model, there through OpenRouter). Each on c1 and c3: four arms of the Illustrated Review's 50
windows. c1's text is `method_window_cues.prompt_template("codex")` verbatim (the app's c1), with the window's
pages and Vision text filled in as the app does; the images go inline, each after a "Page n:" line, as every
gateway window arm sends them, at the bench's 1600 px. Temperature 0, reasoning low, JSON mode; output caps as
seg_lincoln_gateway (GLM 32768, which it needed) and 16384 for Luna. seg_lincoln_gateway's ledger, pre-send
reservation, cap check and settle are used unchanged, with this item's own store and cap. A reply that does not
parse is recorded and votes neutral, as seg_magazine_rule's invalid replies do; more than five stop the run.

Money: the gateway is real money on a Stanford PTA. CAP keeps the item well under the $7 rule. Owner images and text
go only to the gateway and the caches, never into git (the repo is public).
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import base64
import fcntl
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import data  # noqa: E402
import seg_boxes_score as SB  # noqa: E402

TAG = "W47.wh-seg-magazine"
STORE = SB.REHEARSAL / "seg-magazine-c1-gateway"
CAP = 3.00
RESULTS = SB.RESULTS
REVIEW = "IllustratedReview"
MODELS = {"luna": "gpt-5.6-luna", "glm": "GLM 5.3 Flash"}
PRICES = {"luna": (0.20, 1.20), "glm": (0.15, 0.50)}   # list USD per M in/out (ct_read.py; seg_lincoln_gateway.py)
OUTPUT_CAP = {"luna": 16384, "glm": 32768}
VERSIONS = ("c1", "c3")
ARMS = tuple(f"{m}-{v}" for m in MODELS for v in VERSIONS)
LABEL = {"luna": "GPT 5.6 Luna", "glm": "GLM 5.3 Flash"}


def prompt_text(v):
    import method_window_cues as C
    from magazine_rule import RULE10_G1, RULE10_G2
    c1 = C.prompt_template("codex")
    assert c1.count(RULE10_G1) == 1, "prompt c1 changed"
    return c1 if v == "c1" else c1.replace(RULE10_G1, RULE10_G2)


def request(arm, col, a, b, whole=False):
    """The gateway body for one window under arm `<model>-<version>` (seg_lincoln_gateway.request's signature)."""
    import method_window as W
    model, v = arm.split("-")
    assert not whole and v in VERSIONS
    missing = [p.n for p in col.pages[a:b] if not data.ocr_cache_path(col.name, p.n).is_file()]
    if missing:
        raise ValueError(f"{col.name}: missing cached Vision text for {missing}; refusing changed inputs")
    nums = [col.pages[i].n for i in range(a, b)]
    thumbs = [data.thumbnail(col.name, col.pages[i], W.THUMB_PX) for i in range(a, b)]
    if any(t is None for t in thumbs):
        raise RuntimeError(f"{col.name} {nums}: thumbnail failed")
    files = "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)
    texts = "\n".join(f"--- page {n} ---\n{W.page_text(col, i)}" for n, i in zip(nums, range(a, b)))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    prompt = prompt_text(v).format(k=len(nums), files=files, texts=texts, gaps=gaps, max_text=W.MAX_TEXT,
                                   pages=", ".join(str(n) for n in nums))
    parts = []
    for n, t in zip(nums, thumbs):
        parts += [{"type": "text", "text": f"Page {n}:"},
                  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," +
                                                      base64.b64encode(t.read_bytes()).decode()}}]
    parts.append({"type": "text", "text": prompt})
    body = {"model": MODELS[model], "temperature": 0, "max_tokens": OUTPUT_CAP[model],
            "messages": [{"role": "user", "content": parts}],
            "response_format": {"type": "json_object"}, "reasoning_effort": "low"}
    key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body, key, nums


@contextmanager
def gateway():
    """seg_lincoln_gateway with this item's request builder, models, prices, store and cap; restored after."""
    import seg_lincoln_gateway as S
    prev = (S.request, S.MODELS, S.PRICES, S.STORE, S.CAP)
    S.request = request
    S.MODELS = {**S.MODELS, **{a: MODELS[a.split("-")[0]] for a in ARMS}}
    S.PRICES = {**S.PRICES, **{a: PRICES[a.split("-")[0]] for a in ARMS}}
    S.STORE, S.CAP = STORE, CAP
    try:
        yield S
    finally:
        S.request, S.MODELS, S.PRICES, S.STORE, S.CAP = prev


def answer(arm, col, a, b):
    """The parsed reply, the neutral vote for an invalid model reply, or None (not yet asked)."""
    import method_local as L
    with gateway() as S:
        body, key, nums = request(arm, col, a, b)
        hit = S.cache_hit(body, key)
        if hit is None:
            return None
        if hit.get("valid"):
            return S.parse(hit["raw"], nums, False)
        rec = next((r for r in S.effective_records() if r["id"] == hit["request"]["id"]), {})
        if not SB.invalid_model_reply(hit, rec):
            raise RuntimeError(f"{arm} {col.name} {nums[0]}-{nums[-1]}: provider/usage failure, not a model vote")
        return L.neutral(nums)


def jobs():
    import method_window as W
    col = data.load(REVIEW, with_exif=False)
    return [(arm, col, a, b) for arm in ARMS for a, b in W.windows(len(col.pages))]


def cmd_plan(_a):
    js = jobs()
    with gateway() as S:
        spent = S.spent()
        todo = [j for j in js if answer(*j) is None]
        bound = sum(S.reservation(arm, request(arm, c, a, b)[0]) for arm, c, a, b in todo)
    print(f"windows {len(js)} ({len(ARMS)} arms), uncached {len(todo)}, spent ${spent:.4f} of ${CAP:.2f}; "
          f"reservation bound for the uncached ${bound:.2f} (every image at 8192 tokens and the full output cap)")


def cmd_collect(a):
    if a.workers != 1:
        raise SystemExit("collect requires --workers 1 to keep the item spending cap exact")
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, gateway() as S:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SB.check_reservations(S)
        SB.check_prior_failures(S)
        todo = [j for j in jobs() if answer(*j) is None][: a.limit or None]
        SB.gateway_key()
        print(f"{len(todo)} windows to send, item spent ${S.spent():.4f} of ${CAP:.2f}", flush=True)
        invalid = []
        for arm, col, lo, hi in todo:
            try:
                S.call(arm, col, lo, hi)
            except RuntimeError as e:
                body, key, nums = request(arm, col, lo, hi)
                hit = S.cache_hit(body, key)
                rec = next((r for r in S.effective_records()
                            if hit is not None and r["id"] == hit["request"]["id"]), {})
                if not SB.invalid_model_reply(hit, rec):
                    raise
                invalid.append(f"{arm} {col.name} {nums[0]}-{nums[-1]}: {e}")
                if len(invalid) > 5:
                    raise RuntimeError("more than five invalid model replies; inspect before continuing") from e
        print(f"done; item spent ${S.spent():.4f}; invalid replies {len(invalid)}", flush=True)
        for x in invalid:
            print("  invalid", x)


def cmd_release_budget(_a):
    """Free a request the gateway refused for its key's monthly budget (HTTP 422 `budget_exceeded`, no usage): a
    LiteLLM check before inference, so nothing ran and nothing was billed. Its reply is archived, its charge set to
    0 and one same-settings send approved; any other failure still stops collection. First hit 2026-11-19, when the
    key's November $50 was spent."""
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, gateway() as S:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        n = 0
        for r in S.effective_records():
            if r["event"] != "settle" or r.get("valid") or r.get("http") != 422 or r.get("usage"):
                continue
            src = STORE / "replies" / f"{r['request_sha256']}.json"
            hit = json.loads(src.read_text())
            if (hit["response"].get("error") or {}).get("type") != "budget_exceeded" or hit["request"]["id"] != r["id"]:
                raise RuntimeError(f"{r['id']}: unrecognized 422; keep the reservation")
            archive = STORE / "failed-replies" / f"{r['id']}.json"
            archive.parent.mkdir(parents=True, exist_ok=True)
            if archive.exists():
                raise RuntimeError("archive already exists; inspect without replacing it")
            src.rename(archive)
            S.append({**r, "event": "retry-approved", "charge": 0, "failure_archive": str(archive.relative_to(STORE)),
                      "reason": "gateway key budget exceeded before inference; no tokens, no charge; one resend"})
            n += 1
        print(f"released {n}; item spent ${S.spent():.4f} of ${CAP:.2f}")


# --- scoring --------------------------------------------------------------------------------------

def review_box():
    import kit_gate as K
    import kit_gate_sherlock as KS
    col = data.load(REVIEW, with_exif=False)
    rec = SB.box_record(col, {arm: (lambda c, a, b, allow_call=False, arm=arm: answer(arm, c, a, b)) for arm in ARMS})
    docs = K.documents(rec)
    pages = sum(d["exact_pages"] for d in docs)
    rows = {}
    for arm, m in rec["models"].items():
        calls = [(m["gaps"][k][0], g["truth"]) for k, g in enumerate(rec["gaps"])]
        rows[arm] = {"known gaps": len(calls), "right": sum(c == t for c, t in calls),
                     "gap accuracy": sum(c == t for c, t in calls) / len(calls),
                     "false splits": sum(c == "new" and t == "continue" for c, t in calls),
                     "false merges": sum(c == "continue" and t == "new" for c, t in calls),
                     "pages exact": sum(d["exact_pages"] for d in docs if d["m"][arm][0]) / pages,
                     "resolved pages": pages, "failed windows": rec["failed_windows"][arm]}
    paired = {m: KS.paired_row(f"{m} c3 vs c1", REVIEW, [
        (rec["models"][f"{m}-c3"]["gaps"][k][0] == g["truth"], rec["models"][f"{m}-c1"]["gaps"][k][0] == g["truth"])
        for k, g in enumerate(rec["gaps"])]) for m in MODELS}
    return rows, paired


def earlier():
    """The magazine box's figures already measured: Gemini 3.7 g1 and g2 (seg-magazine-rule.json) and the
    students and teacher (seg-boxes-score.json)."""
    mr = json.loads((RESULTS / "seg-magazine-rule.json").read_text())["review"]
    bs = [r for r in json.loads((RESULTS / "seg-boxes-score.json").read_text())["observed"] if r["box"] == REVIEW]
    return {"gemini-g1": mr["g1"], "gemini-g2": mr["g2"],
            **{r["route"]: r for r in bs if r["route"] in ("mac-2b", "fs-2b", "fs-4b", "teacher")}}


def cost():
    with gateway() as S:
        SB.check_reservations(S)
        import gateway_gemini as GW
        calls = S.settled()
        by = {}
        for arm in ARMS:
            cs = [r for r in calls if r["route"] == arm]
            by[arm] = {"calls": len(cs), "charged_usd": sum(r["charge"] for r in cs),
                       "input_tokens": sum(r["usage"].get("prompt_tokens", 0) for r in cs),
                       "output_tokens": sum(r["usage"].get("completion_tokens", 0) for r in cs),
                       "invalid": sum(not r.get("valid") for r in cs)}
        return {"calls": len(calls), "spent_usd": S.spent(), "billed": S.settled_billed(),
                "billed_note": GW.billed_note(calls, "estimate"),
                "retained_usd": S.spent() - sum(r["charge"] for r in calls), "by_arm": by}


def cmd_score(_a):
    import rescore
    rescore.no_network()
    missing = [(arm, a, b) for arm, c, a, b in jobs() if answer(arm, c, a, b) is None]
    if missing:
        raise SystemExit(f"{len(missing)} windows have no answer, first {missing[:3]}")
    rows, paired = review_box()
    out = {"tag": TAG, "review": rows, "paired": paired, "earlier": earlier(), "gateway": cost(),
           "c3_rule10": __import__("magazine_rule").RULE10_G2}
    (RESULTS / "seg-magazine-c1.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-magazine-c1.md").write_text(render(out))
    print(json.dumps({"review": rows, "paired": paired}, indent=1))


# --- the report -----------------------------------------------------------------------------------

def _p(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def _row(name, r):
    return (f"| {name} | {r['known gaps']} | {r['right']} | {_p(r['gap accuracy'])} | {r['false merges']} | "
            f"{r['false splits']} | {_p(r['pages exact'])} | {r.get('failed windows', 0)} |")


def render(out) -> str:
    rows, pr, e, gw = out["review"], out["paired"], out["earlier"], out["gateway"]
    head = ("| Route | Known gaps | Right | Gap accuracy | False merges | False splits | Pages exact | "
            "Failed windows |\n|---|---|---|---|---|---|---|---|")
    L = [f"# Prompt c1 on the article-within-issue rule, on the magazine box ({TAG})", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_magazine_c1.py score` from the gateway cache; no call "
         "is made in scoring.", "",
         "Owner, 2026-11-19 (call 15): c1, the prompt of the ChatGPT, GLM and local 2B voters, still carries g1's "
         "full-magazine rule 10, so its `magazine` figure ranks nothing. c3 is c1 with rule 10 rewritten to the "
         "owner's article-within-issue rule (`magazine_rule.RULE10_G2`, the rewrite that made g2 from g1); nothing "
         "else changes. Both prompts through the Stanford gateway, on its two models in the c1 voters' families.", "",
         "## Stanford Illustrated Review (the owner's article rulings)", "", head]
    for m in MODELS:
        for v in VERSIONS:
            L.append(_row(f"{LABEL[m]}, {v}", rows[f"{m}-{v}"]))
    L += ["", "Paired on the same gaps:", ""]
    for m in MODELS:
        p = pr[m]
        L.append(f"- {LABEL[m]}: only c3 right {p['only first right']}, only c1 right {p['only second right']}, "
                 f"{p['difference points']:+.1f} points, exact sign test p {p['sign test p']:.3g}")
    L += ["", "Already measured on the same box and truth (seg-magazine-rule.md, seg-boxes-score.md):", "", head]
    names = {"gemini-g1": "Gemini 3.7 Flash, g1", "gemini-g2": "Gemini 3.7 Flash, g2",
             "teacher": "Qwen3.5 27B teacher (not fine-tuned)", "mac-2b": "shipped 2B, Mac (trained-on)",
             "fs-2b": "fine-tuned 2B, bf16 (trained-on)", "fs-4b": "fine-tuned 4B, bf16 (trained-on)"}
    for k, n in names.items():
        if k in e:
            L.append(_row(n, e[k]))
    L += ["", "## Gateway", ""]
    for arm, b in gw["by_arm"].items():
        L.append(f"- {arm}: {b['calls']} settled calls, ${b['charged_usd']:.4f}, {b['input_tokens']:,} input and "
                 f"{b['output_tokens']:,} output tokens, {b['invalid']} invalid")
    L += [f"- Item: ${gw['spent_usd']:.4f} counted of the ${CAP:.2f} cap (retained for unsettled requests "
          f"${gw['retained_usd']:.4f}); {gw['billed_note']}", ""]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    c = sub.add_parser("collect")
    c.add_argument("--workers", type=int, default=1)
    c.add_argument("--limit", type=int, default=0)
    sub.add_parser("release-budget")
    sub.add_parser("score")
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "release-budget": cmd_release_budget, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
