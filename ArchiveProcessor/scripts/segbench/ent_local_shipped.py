#!/usr/bin/env python3
"""W46.ent-local-shipped-prompt: the shipped tagging prompt on the Mac and cluster models, over the 138's Vision text.

    python3 ops/autonomous/heavy-run.py run -- /usr/bin/time -l <lab venv>/bin/python ent_local_shipped.py mac [--limit N]
    python3 ent_local_shipped.py pack       # the 27B's requests as a frozen Sherlock pack (sherlock/ent-local-27b/)
    python3 ent_local_shipped.py collect    # the pack's returned answers -> CACHE/replies/<27B label>/
    python3 ent_local_shipped.py report     # segbench-results/ent-local-shipped.md and .json

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx-vlm). The question: the Mac and cluster entity rows of the
settings table (`13-stage-rules/09-entities.md` §4) rest on replies the old W41 date-tagging sample made from the
ABBYY text layer (ent-truth-owner.md, "tagging reply, ABBYY (82)"), which the app never has (owner, 2026-10-30). Here
the same two models answer the prompt the app sends today, over the text the app has.

The prompt. ent_score_paid.prompt_for("tagging", d): date_tagging.build_prompt over the document's macOS Vision text
(JPEG originals, ent_score_paid's pages and vision steps) and the same nearby-documents context block, with
TAGGING_RULES_BEFORE's three name lines, which is TagGenerator.generateTags as shipped after W46.tagging-prompt-revert
(owner call 10; checked equal to date_tagging.build_prompt on all 138 by `report`). So these replies and the cached
Gemini 3.7 Flash "tagging" replies (ent_score_paid) differ in the model alone.

Models and settings. Qwen3-VL 8B Instruct, MLX 4-bit (mlx-community, the Mac reader of ocr-mac-local.md), on this
Mac (M3 Pro, 18 GB), text only through mlx-vlm with no image; Qwen3.6 27B FP8 on one Sherlock GPU through vLLM, as
the cluster's other 27B packs serve it, thinking off. Both at temperature 0 and MAX_TOKENS (a tagging reply is a few
hundred tokens; a reply that reaches the cap is counted, not dropped). Each Mac reply records its wall seconds,
tokens and MLX's peak memory; `/usr/bin/time -l` around the run gives the whole process's peak footprint, which the
report quotes from the run's log (RUNLOG).

Scoring is ent_truth_owner.scores unchanged (ed2 F1 per field, the sending place also by its city) against the truth
as built, with the owner's answers, and with the owner's answers and the written-place rule (the table's truth). The
paired differences are ent_score_paid.paired (document bootstrap, 95%) over the documents both arms answered; the
rerun floor is ent-prompt-app.md's Gemini one (the local models' is not measured). No money: the Mac run is local and the cluster run is on Sherlock. Replies stay in the bench
cache; the report has aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import shutil
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-local-shipped")
RESULTS = HERE.parent.parent / "segbench-results" / "ent-local-shipped.md"
RUNLOG = os.path.join(CACHE, "mac-run.log")     # the `mac` run's stdout and /usr/bin/time -l's lines
MAX_TOKENS = 2048
MAC = "tagging-qwen3-vl-8b-mlx4"     # labels start "tagging" so ent_score_paid.preds joins name lists as the app does
CLUSTER = "tagging-qwen3.6-27b"
REPO = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
SERVED = "Qwen/Qwen3.6-27B-FP8"
PACK = Path(os.path.expanduser("~/.local/state/archive-autonomous/artifacts/ent-local-27b-20261112"))  # the hand-over
BACK = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/ent-local-27b-20261112"))


def prompt(d):
    return P.prompt_for("tagging", d)


def request(model):
    return {"model": model, "temperature": 0, "max_tokens": MAX_TOKENS}


def cached(label, d, model):
    """The reply under label if it answered this prompt with these settings (ent_score_paid.cached), else None."""
    return P.cached(P.reply_path(label, d["id"], CACHE), prompt(d), request(model))


# --- the Mac ----------------------------------------------------------------------------------------------------

def cmd_mac(a):
    import model_store
    model_store.use()
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    todo = [d for _r, d in P.rows() if cached(MAC, d, REPO) is None][: a.limit or None]
    print(f"{MAC}: {len(todo)} documents to answer", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)    # as ocr_mac_local: freed buffers otherwise inflate the footprint
    t0 = time.time()
    model, processor = load(REPO)
    load_s = time.time() - t0
    for k, d in enumerate(todo, 1):
        p = prompt(d)
        chat = apply_chat_template(processor, model.config, p, num_images=0)
        mx.reset_peak_memory()
        start = time.time(); first = None; text = []; last = None
        for r in stream_generate(model, processor, chat, max_tokens=MAX_TOKENS, temperature=0.0):
            if first is None:
                first = time.time()
            text.append(r.text); last = r
        wall = time.time() - start
        out_tokens = getattr(last, "generation_tokens", 0)
        meta = {"prompt_sha256": P.prompt_sha(p), "request": request(REPO), "runtime": "mlx-vlm " + mlx_vlm.__version__,
                "finish": "length" if out_tokens >= MAX_TOKENS else "stop", "wall_s": round(wall, 2),
                "first_token_s": round((first or start + wall) - start, 2),
                "prompt_tokens": getattr(last, "prompt_tokens", 0), "completion_tokens": out_tokens,
                "mlx_peak_gb": round(mx.get_peak_memory() / 2**30, 2), "load_s": round(load_s, 1), "t": time.time()}
        P.write_reply(P.reply_path(MAC, d["id"], CACHE), {"meta": meta, "raw": "".join(text)})
        print(f"[{k}/{len(todo)}] {d['id']} {meta['finish']} {meta['wall_s']}s "
              f"{meta['prompt_tokens']}+{out_tokens} tok peak {meta['mlx_peak_gb']} GB", flush=True)


# --- the cluster ------------------------------------------------------------------------------------------------

def cmd_pack(a):
    """The 138 prompts as a frozen pack in date-route-27b's form: ent/requests.jsonl for postcorrect_cluster.py (text
    only), the support files, every file hashed in freeze.json (check_pack.py reads it)."""
    if PACK.exists():
        sys.exit(f"{PACK} exists: a frozen pack is never rebuilt in place")
    (PACK / "ent").mkdir(parents=True)
    rows = [{"id": d["id"], "prompt": prompt(d), "max_tokens": MAX_TOKENS} for _r, d in P.rows()]
    with open(PACK / "ent" / "requests.jsonl", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    sh = HERE / "sherlock"
    job = PACK / "support" / "job"
    (job / "bin").mkdir(parents=True)
    shutil.copy2(HERE / "postcorrect_cluster.py", PACK / "support")
    shutil.copy2(sh / "ent-robust" / "check_pack.py", PACK / "support")
    for f in ("submit.sh", "stage-job.sh", "job.sh"):
        shutil.copy2(sh / "ent-local-27b" / f, job)
    shutil.copy2(sh / "sh.env", job)
    for f in (sh / "bin").iterdir():
        shutil.copy2(f, job / "bin")
    meta = {"item": "W46.ent-local-shipped-prompt", "requests": len(rows), "model": SERVED, "max_tokens": MAX_TOKENS,
            "temperature": 0, "thinking": "off", "prompt": "ent_score_paid.prompt_for('tagging', d)",
            "prompts_sha256": hashlib.sha256("".join(r["prompt"] for r in rows).encode()).hexdigest()}
    (PACK / "pack.json").write_text(json.dumps(meta, indent=1) + "\n")
    files = {}
    for dp, dns, fns in os.walk(PACK):
        rel = os.path.relpath(dp, PACK)
        dns[:] = [x for x in dns if x not in ("out", "logs")]     # answers are never frozen
        for fn in fns:
            if rel == "." and fn == "freeze.json":
                continue
            files[os.path.normpath(os.path.join(rel, fn))] = hashlib.sha256(Path(dp, fn).read_bytes()).hexdigest()
    (PACK / "freeze.json").write_text(json.dumps({"item": "W46.ent-local-shipped-prompt", "arms": ["ent"],
                                                  "files": dict(sorted(files.items()))}, indent=1) + "\n")
    size = sum((PACK / f).stat().st_size for f in files)
    print(f"froze {len(files)} files, {size / 1e6:.1f} MB: {len(rows)} requests -> {PACK}")


def cmd_collect(a):
    """The returned replies (the Mac artifact's ent/out, else BACK's) as CLUSTER replies; every request needs one and
    each must answer the prompt as it now stands."""
    out = next((x for x in (PACK / "ent" / "out", BACK / "ent" / "out") if x.is_dir()), None)
    if out is None:
        sys.exit("no returned answers: the pack waits for an owner session on Sherlock")
    docs = {d["id"]: d for _r, d in P.rows()}
    missing, n = [], 0
    for line in open(PACK / "ent" / "requests.jsonl", encoding="utf-8"):
        q = json.loads(line)
        if P.prompt_sha(q["prompt"]) != P.prompt_sha(prompt(docs[q["id"]])):
            sys.exit(f"{q['id']}: the prompt changed since the pack was built; its reply cannot be scored")
        f = out / f"{q['id']}.json"
        if not f.exists():
            missing.append(q["id"]); continue
        r = json.loads(f.read_text())
        meta = {"prompt_sha256": P.prompt_sha(q["prompt"]), "request": request(SERVED), "runtime": "vLLM on Sherlock",
                "finish": r.get("finish"), "wall_s": r.get("seconds")}
        P.write_reply(P.reply_path(CLUSTER, q["id"], CACHE), {"meta": meta, "raw": r.get("text")})
        n += 1
    if missing:
        sys.exit(f"{len(missing)} requests have no reply, e.g. {missing[:3]}")
    print(f"{n} replies -> {CLUSTER}")


# --- report -----------------------------------------------------------------------------------------------------

TRUTHS = ("built", "owner+rule")


def answered(label, model):
    """{doc_id: meta} for the replies under label, each checked against the prompt and settings as they now stand."""
    got = {}
    for _r, d in P.rows():
        hit = cached(label, d, model)
        if hit is not None:
            got[d["id"]] = hit["meta"]
    return got


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def peak_footprint():
    """The largest 'peak memory footprint' /usr/bin/time -l printed in RUNLOG, in GB (None without one)."""
    if not os.path.exists(RUNLOG):
        return None
    vals = [int(l.split()[0]) for l in open(RUNLOG, encoding="utf-8", errors="replace")
            if l.strip().endswith("peak memory footprint")]
    return round(max(vals) / 2**30, 2) if vals else None


def cmd_report(a):
    import date_tagging as DT
    import ent_score as ES
    import ent_truth_owner as EO
    rs = P.rows()
    same = sum(prompt(d) == DT.build_prompt(P.vision_text(d), P.context_of(d["prompt"]), ocr_poor=False) for _r, d in rs)
    P.check_replies("tagging", P.CACHE, lambda d: P.label_prompt("tagging", d))
    T = {k: {r["id"]: r for r in v} for k, v in EO.truths().items() if k in TRUTHS}
    old = ES.reply_preds()
    arms = {"gemini-3.7 tagging, Vision (138)": P.preds("tagging")[0]}
    metas = {}
    for label, model, name in ((MAC, REPO, "qwen3-vl-8b MLX 4-bit"), (CLUSTER, SERVED, "qwen3.6-27b")):
        m = answered(label, model)
        if m:
            metas[label] = m
            arms[f"{name} tagging, Vision ({len(m)})"] = P.preds(label, CACHE)[0]
    on82 = {i for name in ("qwen3-vl-8b", "qwen3.6-27b") for i in old[name]}
    for arm in list(arms):
        arms[arm.rsplit(" (", 1)[0] + " on the 82"] = {i: p for i, p in arms[arm].items() if i in on82}
    for name in ("qwen3-vl-8b", "qwen3.6-27b"):
        arms[f"{name} tagging reply, ABBYY (82)"] = {i: p for i, p in old[name].items() if p is not None}
    s = {"docs": len(rs), "prompt_equals_app": same, "answered": {k: len(v) for k, v in metas.items()},
         "unparsed": {lab: P.preds(lab, CACHE)[1] for lab in metas}, "scores": {}, "paired": {}, "time": {}}
    for arm, pr in arms.items():
        s["scores"][arm] = {k: EO.scores(pr, T[k]) for k in TRUTHS}
    names = list(arms)
    mac = next((x for x in names if x.startswith("qwen3-vl-8b MLX") and not x.endswith("on the 82")), None)
    clu = next((x for x in names if x.startswith("qwen3.6-27b tagging, Vision") and not x.endswith("on the 82")), None)
    pairs = []
    if mac:
        pairs += [("8B: Vision, shipped prompt vs ABBYY, old prompt (82)", "qwen3-vl-8b tagging reply, ABBYY (82)", mac),
                  ("8B on the Mac vs Gemini 3.7, both Vision", "gemini-3.7 tagging, Vision (138)", mac)]
    if clu:
        pairs += [("27B: Vision, shipped prompt vs ABBYY, old prompt (82)", "qwen3.6-27b tagging reply, ABBYY (82)", clu),
                  ("27B vs Gemini 3.7, both Vision", "gemini-3.7 tagging, Vision (138)", clu)]
    if mac and clu:
        pairs.append(("27B vs the 8B, both Vision", mac, clu))
    for what, a_, b_ in pairs:
        pa, pb = arms[a_], arms[b_]
        s["paired"][what] = {"a": a_, "b": b_, **{k: {f: P.paired(pa, pb, sorted(set(pa) & set(pb) & set(T[k])), T[k], f)
                                                      for f in ET.FIELDS} | {"city": EO.paired_city(pa, pb, T[k])["city"]}
                                                  for k in TRUTHS}}
    for label, m in metas.items():
        w = [x["wall_s"] for x in m.values() if x.get("wall_s") is not None]
        row = {"n": len(m), "finish": dict(collections.Counter(x.get("finish") for x in m.values()))}
        if w:
            row |= {"median_s": round(statistics.median(w), 2), "p90_s": round(pct(w, .9), 2), "max_s": max(w),
                    "total_s": round(sum(w), 1)}
        if label == MAC:
            row |= {"mlx_peak_gb_max": max(x["mlx_peak_gb"] for x in m.values()),
                    "mlx_peak_gb_median": statistics.median(x["mlx_peak_gb"] for x in m.values()),
                    "load_s": max(x["load_s"] for x in m.values()),
                    "prompt_tokens_median": statistics.median(x["prompt_tokens"] for x in m.values()),
                    "completion_tokens_median": statistics.median(x["completion_tokens"] for x in m.values()),
                    "footprint_gb": peak_footprint()}
        s["time"][label] = row
    json.dump(s, open(str(RESULTS)[:-3] + ".json", "w"), indent=1)
    RESULTS.write_text(render(s))
    print(RESULTS)


def f2(x):
    return "–" if x is None else f"{x:.2f}"


def render(s):
    L = ["# The shipped tagging prompt on the Mac and cluster models, over Vision text (W46.ent-local-shipped-prompt)", "",
         "Generated by `scripts/segbench/ent_local_shipped.py report`; method in its header. Aggregates only: the "
         "replies stay in the bench cache (`ent-local-shipped/`). $0: the Mac run is local, the cluster run is on "
         "Sherlock.", "",
         f"The prompt is the one TagGenerator sends today (the reverted name lines), over each document's macOS Vision "
         f"text and the same nearby-documents block as Gemini's cached `tagging` replies; it equals "
         f"`date_tagging.build_prompt` on {s['prompt_equals_app']} of the {s['docs']} documents. Answered: "
         + ", ".join(f"{k} {v} of {s['docs']} ({s['unparsed'][k]} unparsed)" for k, v in s["answered"].items())
         + (". The 27B's half waits on its Sherlock pack (`ent-local-27b-20261112`)." if CLUSTER not in s["answered"]
            else "."), "",
         "## Scores", "",
         "ed2 F1 per field; the sending place also by its city. \"owner+rule\" is the truth the settings table uses "
         "(ent-truth-owner.md).", "",
         "| route | n | built: sender / recipient / place · city | owner+rule: sender / recipient / place · city | "
         "owner+rule place filled, no truth |",
         "|---|---|---|---|---|"]
    for arm, sc in s["scores"].items():
        b, o = sc["built"], sc["owner+rule"]
        cell = lambda x: " / ".join(f2(x[f]["f1"]) for f in ET.FIELDS) + " · " + f2(x["city"]["f1"])  # noqa: E731
        L.append(f"| {arm} | {o['n']} | {cell(b)} | {cell(o)} | {o['sending_place']['filled_when_empty']} |")
    L += ["", "## Paired differences", "",
          "b minus a in ed2 F1 over the documents both answered, with a document bootstrap's 95% interval; a gap whose "
          "interval spans zero is a tie. The rerun floor of the Gemini arm is in ent-prompt-app.md; the local models' "
          "floor is not measured.", "",
          "| comparison (a → b) | truth | n | sender | recipient | place | place by city |", "|---|---|---|---|---|---|---|"]
    for what, p in s["paired"].items():
        for k in TRUTHS:
            c = lambda x: f"{x['diff']:+.3f} ({x['lo']:+.3f} to {x['hi']:+.3f})"  # noqa: E731
            L.append(f"| {what} | {k} | {p[k]['sender']['n']} | " + " | ".join(c(p[k][f]) for f in ET.FIELDS)
                     + f" | {c(p[k]['city'])} |")
    L += ["", "## Time and memory", ""]
    for label, t in s["time"].items():
        if label == MAC:
            L += [f"Qwen3-VL 8B MLX 4-bit on an M3 Pro with 18 GB, text only: {t['n']} documents, median "
                  f"{t['median_s']} s a document (90th percentile {t['p90_s']} s, worst {t['max_s']} s), "
                  f"{t['total_s']} s in all after a {t['load_s']} s load; median prompt {t['prompt_tokens_median']:.0f} "
                  f"tokens and reply {t['completion_tokens_median']:.0f}. MLX's peak {t['mlx_peak_gb_max']} GB (median "
                  f"{t['mlx_peak_gb_median']}); whole-process peak footprint "
                  + (f"{t['footprint_gb']} GB" if t["footprint_gb"] else "not recorded")
                  + f". Finish: {t['finish']}.", ""]
        else:
            L += [f"Qwen3.6 27B FP8 on one Sherlock GPU (vLLM, 32 at a time): {t['n']} documents, median "
                  f"{t.get('median_s', '–')} s a request in flight; finish {t['finish']}. Concurrent requests share the "
                  "GPU, so this is not a Mac's seconds a document.", ""]
    L += ["## Measurement card", "",
          "- **Truth**: W46.fix-ent-truth's 138 correspondence documents (model truth: GPT 5.6 Luna and Claude Sonnet 5 "
          "drafts, Sonnet rulings; no Gemini or Qwen drafted or ruled), with the owner's answers on the fields his two "
          "sheets asked and the written-place rule (ent-truth-owner.md); scored also against the truth as built.",
          "- **Selection**: as W46.ent-score-paid: 82 correspondence documents of W41's date-tagging sample plus 56 "
          "chosen by ABBYY text cues, so 56 of the 138 were chosen by the ABBYY text (owner, 2026-10-30); none by a "
          "route tested here. The ABBYY-reply rows exist for the 82 only, so the like-for-like rows are \"on the 82\".",
          "- **Comparison**: one prompt, built by one function, for every Vision arm, with the same text and context; "
          f"temperature 0; the local models capped at {MAX_TOKENS} tokens (finish counts above) and Gemini at 8,192. "
          "The ABBYY rows are the old prompt on the ABBYY text layer, shown as the rows these replace, not as a "
          "like-for-like arm: prompt and text both differ.",
          "- **Noise**: n as given; paired bootstrap intervals over the documents both arms answered. The Gemini rerun "
          "floor is ent-prompt-app.md's; the local models' rerun floor is not measured (greedy decoding at "
          "temperature 0). A gap whose interval spans zero is a tie.",
          "- **Scope**: correspondence only; text only (the 8B's own reading of the page image is ent-robust.md's "
          "route); one Mac (18 GB), so a 27B on a 32 GB Mac stays unmeasured; the 27B's cluster seconds are "
          "throughput under concurrency, not a per-document time on any Mac.", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mac"); m.add_argument("--limit", type=int, default=0)
    sub.add_parser("pack"); sub.add_parser("collect"); sub.add_parser("report")
    a = ap.parse_args()
    {"mac": cmd_mac, "pack": cmd_pack, "collect": cmd_collect, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
