#!/usr/bin/env python3
"""W46.seg-boxes-score (measurement audit SEG-8, SEG-10): the segmentation routes on the three locked boxes, and the
shipped cloud route at three window offsets on the test boxes.

  python3 seg_boxes_score.py plan        # windows, cached answers and the gateway estimate (no calls)
  python3 seg_boxes_score.py collect     # Gemini 3.7 Flash g1 windows through the gateway (paid, capped)
  <lab venv>/bin/python seg_boxes_score.py mac   # the shipped 8-bit 2B on this Mac (heavy lock, below)
  python3 seg_boxes_score.py score       # -> segbench-results/seg-boxes-score.{json,md} (no calls)
  python3 seg_boxes_score.py score --local-only  # explicit partial report while gateway arms are blocked

  HF_HUB_OFFLINE=1 python3 ops/autonomous/heavy-run.py run -- \\
      ~/.local/share/visionocr-ocrlab/venv/bin/python seg_boxes_score.py mac

THE ARMS, fixed before any answer:
- Boxes: Sasha (held out: no student trained on it), the Illustrated Review and SC0122 (both wholly in the students'
  training split: trained-on, owner 2026-10-29), whole, in method_window's 7-page windows at stride 3.
  * Gemini 3.7 Flash through the Stanford gateway (the 3.8 Flash the bench's cloud figures used is not served there):
    prompt g1, 1600 px images and cached Vision text, temperature 0, reasoning low, the request
    seg_lincoln_gateway.py sends (its ledger, cap check and parser, with this item's own store and cap).
  * The shipped build: the fine-tuned Qwen3.5 2B at 8-bit MLX on this Mac (method_local's seg-2b-8bit, prompt l1,
    1,024 px), the model the Processor ships.
  * The Qwen3.5 27B teacher and the fine-tuned 2B (bf16, the shipped build's source) and 4B: W46.kit-gate-sherlock's
    answers on the same windows and Vision text (one Sherlock job shared, not rerun).
- Scoring: method_window.combine and assemble with the truth's photo labels, kit_gate.box_record's known gaps (the
  owner's unsure gaps out of every count) and kit_gate.documents' pages exact over the documents no unsure gap
  touches (the same support for every route). SC0122 also on its owner-ruled gaps: the 37 gaps where tag and teacher
  disagreed (the owner ruled each) and the 60 blind controls from the 162 where they agreed (W46.seg-truth-sheet),
  the agreed stratum's accuracy weighted N/n per control stratum, N and n counted over gaps between two document
  pages.
- Offsets (SEG-10): Gemini 3.7 g1 on Stanton and RG165 (363 pages) with the windows starting 0, 1 and 2 pages later
  (seg_window_modality.spans; offset 0 is method_window.windows), each scored with options.py's frozen Gemini rule
  and level (options-frozen.json, fitted on the development boxes for 3.8), so options.md's five figures become a
  range over offsets. Offset 0 is rerun on 3.7 too, so the range is one model's; the 3.8 figure is shown beside it.
- A window whose reply fails validation votes the bench's neutral 0.5 and is counted in the report.
Money: the gateway is real money on a Stanford PTA; CAP keeps this item under the $7 rule. Owner images and text go
only to the gateway and the caches, never into git (the repo is public).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import data  # noqa: E402

TAG = "W46.seg-boxes-score"
REHEARSAL = Path.home() / "Library/Caches/ArchiveSuiteRehearsal"
SEGBENCH = REHEARSAL / "segbench"
STORE = REHEARSAL / "seg-boxes-score-gateway"
CAP = 6.80
RESULTS = HERE.parents[1] / "segbench-results"
BOXES = ("Sasha", "IllustratedReview", "SC0122")
HELD_OUT = ("Sasha",)
OFFSET_BOXES = ("Stanton", "RG165")
OFFSETS = (1, 2, 0)          # collection order: the two new offsets first, then 3.7 at 3.8's offset
LOCAL = "seg-2b-8bit"
SHERLOCK = {"teacher": "fs-qwen3.5-27b", "fs-2b": "fs-seg-2b", "fs-4b": "fs-seg-4b"}
ROUTES = ("gemini", "mac-2b", "teacher", "fs-2b", "fs-4b")
STUDENTS = ("mac-2b", "fs-2b", "fs-4b")
LABEL = {"gemini": "Gemini 3.7 Flash, g1 (gateway)", "mac-2b": "shipped 2B, 8-bit MLX on this Mac",
         "teacher": "Qwen3.5 27B teacher", "fs-2b": "fine-tuned 2B, bf16 (the shipped build's source)",
         "fs-4b": "fine-tuned 4B, bf16"}
SEED_DRAFT = REHEARSAL / "seg-boxes/sc0122/draft.json"


def _mods():
    data.CACHE_DIR = SEGBENCH
    import method_local as L
    import method_window as W
    import seg_lincoln_gateway as S
    import seg_window_modality as M
    S.STORE, S.CAP = STORE, CAP
    S.use_cache(SEGBENCH)
    return L, W, S, M


def jobs():
    """[(set, col, a, b)] every gateway window, in collection order, without repeats."""
    _, W, _, M = _mods()
    out, seen = [], set()
    for box in BOXES:
        col = data.load(box, with_exif=False)
        out += [("boxes", col, a, b) for a, b in W.windows(len(col.pages))]
    cols = {b: data.load(b, with_exif=False) for b in OFFSET_BOXES}
    for o in OFFSETS:
        for b, col in cols.items():
            out += [(f"o{o}", col, a, z) for a, z in M.spans(len(col.pages), 7, o)]
    uniq = []
    for j in out:
        k = (j[1].name, j[2], j[3])
        if k not in seen:
            seen.add(k)
            uniq.append(j)
    return uniq


def gemini_answer(col, a, b):
    """The parsed gateway reply, the neutral vote for a recorded invalid reply, or None if never asked."""
    L, _, S, _ = _mods()
    body, key, nums = S.request("gemini", col, a, b)
    hit = S.cache_hit(body, key)
    if hit is None:
        return None
    if hit.get("valid"):
        return S.parse(hit["raw"], nums, False)
    rec = next((r for r in S.effective_records() if r["id"] == hit["request"]["id"]), {})
    if not invalid_model_reply(hit, rec):
        raise RuntimeError(f"{col.name} {nums[0]}-{nums[-1]}: provider/usage failure, not a model vote")
    return L.neutral(nums)


def cmd_plan(_a):
    L, W, S, _ = _mods()
    js = jobs()
    missing_text = sorted({(c.name, p.n) for _, c, a, b in js for p in c.pages[a:b]
                           if not data.ocr_cache_path(c.name, p.n).is_file()})
    todo = [j for j in js if gemini_answer(*j[1:]) is None]
    per = sum(r["charge"] for r in S.settled()) / max(1, len(S.settled())) if S.settled() else 0.0097
    print(f"gateway windows {len(js)}, uncached {len(todo)}, spent ${S.spent():.4f} of ${CAP:.2f}; "
          f"about ${per * len(todo):.2f} to go at ${per:.4f} a window")
    for s in sorted({j[0] for j in js}):
        print(f"  {s}: {sum(j[0] == s for j in js)} windows, {sum(j[0] == s for j in todo)} uncached")
    jw = L.judge(LOCAL)
    for box in BOXES:
        col = data.load(box, with_exif=False)
        ws = W.windows(len(col.pages))
        print(f"  mac {box}: {len(ws)} windows, {sum(jw(col, a, b) is None for a, b in ws)} to run")
    print(f"pages without Vision text: {missing_text[:10]}{' ...' if len(missing_text) > 10 else ''}")


def gateway_key():
    """Read the gateway key with a deadline. A locked login keychain (the Mac asleep and locked, 2026-11-01 04:14)
    makes `security` wait on an unlock dialog on the owner's screen instead of failing; stop instead."""
    import subprocess
    import gateway_gemini as GW
    try:
        r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                            "-a", "Gateway", "-w"], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        sys.exit("the Keychain did not answer in 20 s (locked?): no gateway call made")
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("no gateway key in the Keychain (com.archiveprocessor.app / Gateway)")
    GW._key = r.stdout.strip()


def check_prior_failures(S):
    """A new uncertain outcome remains a stop on resume, before credentials or another send.

    The original pre-HTTP Keychain reservation already has its explicit retry-approved ledger
    entry, with its full allowance retained. Collection never approves another uncertain retry.
    """
    for r in S.effective_records():
        if r["event"] in ("reserve", "unknown"):
            raise RuntimeError("unsettled request: full allowance retained; inspect before continuing")
        if r["event"] == "settle" and not r.get("valid"):
            hit = S.cached(r["request_sha256"])
            if not invalid_model_reply(hit, r):
                raise RuntimeError("saved provider/usage failure: inspect before continuing")


def check_reservations(S):
    """An overrun remains a stop on resume, even when the saved answer parsed successfully."""
    reserved = {r["id"]: r["charge"] for r in S.records() if r["event"] == "reserve"}
    for r in S.effective_records():
        charge, allowance = r["charge"], reserved.get(r["id"])
        if (allowance is None or not math.isfinite(charge) or charge < 0
                or not math.isfinite(allowance) or charge > allowance):
            raise RuntimeError("ledger charge exceeded its reservation or is invalid; inspect before continuing")


def cmd_collect(a):
    _, _, S, _ = _mods()
    # S.call reserves and fsyncs before HTTP, but its check + append are not thread-safe.
    # Keep the entire collector serial and locked, including recovery of unsettled calls.
    if a.workers != 1:
        raise SystemExit("collect requires --workers 1 to keep the item spending cap exact")
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check_reservations(S)
        check_prior_failures(S)
        gateway_key()
        todo = [j for j in jobs() if gemini_answer(*j[1:]) is None][: a.limit or None]
        print(f"{len(todo)} windows to send, item spent ${S.spent():.4f} of ${CAP:.2f}", flush=True)
        invalid = []
        for _, col, lo, hi in todo:
            try:
                S.call("gemini", col, lo, hi)
            except RuntimeError as e:
                body, key, nums = S.request("gemini", col, lo, hi)
                hit = S.cache_hit(body, key)
                rec = next((r for r in S.effective_records()
                            if hit is not None and r["id"] == hit["request"]["id"]), {})
                # Only a completed, billed model answer that fails parsing is neutral.
                # A transport/provider/cap failure stops collection with a failing exit.
                if not invalid_model_reply(hit, rec):
                    raise
                invalid.append(f"{col.name} {nums[0]}-{nums[-1]}: {e}")
                if len(invalid) > 5:
                    raise RuntimeError("more than five invalid model replies; inspect before continuing") from e
    print(f"done; item spent ${S.spent():.4f}; invalid replies {len(invalid)}", flush=True)
    for x in invalid:
        print("  invalid", x)


def invalid_model_reply(hit, rec):
    if hit is None or hit.get("valid"):
        return False
    response = hit.get("response", {})
    usage = response.get("usage") or {}
    choices = response.get("choices") or [{}]
    return (rec.get("http") == 200 and rec.get("event") == "settle"
            and rec.get("charge", float("inf")) <= hit["request"]["charge"]
            and choices[0].get("finish_reason") == "stop"
            and all(type(usage.get(k)) is int and usage[k] >= 0
                    for k in ("prompt_tokens", "completion_tokens")))


def cmd_mac(a):
    L, W, _, _ = _mods()
    W.refuse_test = lambda names: None if set(names) <= set(BOXES) else sys.exit(f"refused: {names}")
    L.collect(LOCAL, list(BOXES), a.limit)


# --- scoring --------------------------------------------------------------------------------------

def judges():
    L, W, S, _ = _mods()
    import method_openrouter as R

    def gem(col, a, b, allow_call=False):
        return gemini_answer(col, a, b)
    return {"gemini": gem, "mac-2b": L.judge(LOCAL), **{k: R.judge(v) for k, v in SHERLOCK.items()}}


def route_split(route, box):
    if route not in ("mac-2b", "fs-2b", "fs-4b"):
        return "not fine-tuned"
    return "held-out" if box in HELD_OUT else "trained-on"


def box_record(col, js):
    """kit_gate.box_record over these routes: truth and each route's (decision, confidence) per known gap."""
    _, W, _, _ = _mods()
    from score import PHOTO, segment_ids, doc_unsure
    labels = col.labels
    ids, unsure = segment_ids(labels), doc_unsure(labels)
    gaps = [i for i in range(len(labels) - 1)
            if labels[i] not in PHOTO and labels[i + 1] not in PHOTO and i + 1 not in unsure]
    rec = {"box": col.name, "pages": len(labels), "labels": list(labels), "unsure": sorted(unsure),
           "gaps": [{"i": i, "truth": "new" if ids[i] != ids[i + 1] else "continue"} for i in gaps], "models": {},
           "failed_windows": {}}
    for key, j in js.items():
        pred = W.assemble(col, W.combine(col, j), True)
        rec["models"][key] = {"labels": pred.labels,
                              "gaps": [[pred.boundaries[g["i"]]["decision"],
                                        float(pred.boundaries[g["i"]]["confidence"])] for g in rec["gaps"]]}
        rec["failed_windows"][key] = sum(
            all(bd.get("cue") == "(window failed)" for bd in (j(col, a, b) or {"boundaries": {}})["boundaries"].values())
            and bool((j(col, a, b) or {}).get("boundaries")) for a, b in W.windows(len(col.pages)))
    return rec


def sc0122_owner(col, rec):
    """SC0122 on its owner-ruled gaps: the 37 asked (tag against teacher) and the 60 controls weighted to the agreed
    stratum, both over gaps between two document pages."""
    lock = json.loads((data.DATA_DIR / data.LOCKED["SC0122"] / "lock.json").read_text())
    import seg_truth_sheet as TS
    draft = json.loads(SEED_DRAFT.read_text())["pages"]
    index = {p.n: i for i, p in enumerate(col.pages)}
    known = {g["i"]: k for k, g in enumerate(rec["gaps"])}
    asked, agreed = [], {}
    for r in draft[1:]:
        i = index[r["n"]] - 1          # the gap before photo n
        if i not in known:
            continue
        if r["ask"]:
            asked.append(known[i])
        else:
            agreed.setdefault(TS.stratum_of(r["p_new"]), []).append(i)
    controls = []
    for g in lock["owner_ruled_controls"]["gaps"]:
        i = index[g["right"]] - 1
        if i in known:
            if i not in agreed.get(g["stratum"], []):
                raise SystemExit(f"control {g['id']} is not in its agreed stratum")
            controls.append((known[i], g["stratum"]))
    n_ctl = {s: sum(x == s for _, x in controls) for s in agreed}
    weight = {s: len(agreed[s]) / n_ctl[s] for s in agreed if n_ctl[s]}
    uncovered = [s for s in agreed if not n_ctl[s]]
    if uncovered:
        raise ValueError(f"SC0122 owner controls do not cover agreed strata: {uncovered}")
    N = sum(len(v) for s, v in agreed.items() if s in weight)
    out = {"asked_known": len(asked), "controls": len(controls), "agreed_doc_gaps": sum(map(len, agreed.values())),
           "strata": {s: [len(agreed[s]), n_ctl[s]] for s in agreed}, "uncovered_strata": uncovered, "models": {}}
    for key, m in rec["models"].items():
        ok = lambda k: m["gaps"][k][0] == rec["gaps"][k]["truth"]  # noqa: E731
        a_right = sum(ok(k) for k in asked)
        c_right = sum(ok(k) for k, _ in controls)
        w_right = sum(weight[s] for k, s in controls if ok(k))
        w_acc = w_right / N if N else None
        out["models"][key] = {"asked_right": a_right, "controls_right": c_right, "agreed_weighted_accuracy": w_acc,
                              "owner_weighted_accuracy": (a_right + w_acc * N) / (len(asked) + N) if N else None}
    return out


def offset_cost(S, col, spans):
    """Standalone run cost: every window once, every attempt charged, including retained allowances.

    A window shared by offsets belongs to each standalone route's cost; experiment spend deduplicates it.
    Missing billing is an error, never a free window. No paid request is made here.
    """
    keys = set()
    rows = S.effective_records()
    for a, b in spans:
        body, key, _ = S.request("gemini", col, a, b)
        hit = S.cache_hit(body, key)
        if hit is None:
            raise RuntimeError("offset cost requires every cached window")
        req = hit["request"]
        if not any(r["id"] == req["id"] and r["event"] == "settle" for r in rows):
            raise RuntimeError("offset cost requires settled billing for every cached window")
        keys.add(req["request_sha256"])
    charged = [r for r in rows if r["request_sha256"] in keys]
    total = sum(r["charge"] for r in charged)
    settled = sum(r["charge"] for r in charged if r["event"] == "settle")
    return {"windows": len(keys), "attempts": len(charged), "charged_usd": total, "settled_usd": settled,
            "usd_per_1000_pages": 1000 * total / len(col.pages)}


def unflagged_gaps(box, S, level):
    """The accepted (unflagged) gaps the route gets wrong, as 1-based page pairs 'a|b' with the call made."""
    import ensemble as E
    j = E.judge(box, S, level)
    return [{"gap": f"{i + 1}|{i + 2}", "said": j[i][0], "truth": box.truth[i], "confidence": round(j[i][2], 6)}
            for i in box.gaps if not j[i][1] and j[i][0] != box.truth[i] and i not in box.unsure]


def offsets(js_gem):
    """Each offset's five figures on Stanton + RG165, at options.py's frozen Gemini rule and level."""
    _, W, S, M = _mods()
    check_reservations(S)
    import ensemble as E
    import options as O
    fz = json.loads((RESULTS / "options-frozen.json").read_text())["approaches"]["gemini"]
    rows = {}
    for o in sorted(OFFSETS):
        per, costs, failed, wrong = [], {}, 0, {}
        for b in OFFSET_BOXES:
            col = data.load(b, with_exif=False)
            spans = M.spans(len(col.pages), 7, o)
            costs[b] = offset_cost(S, col, spans)
            for a, z in spans:
                j = js_gem(col, a, z)
                failed += j is not None and bool(j["boundaries"]) and all(
                    x.get("cue") == "(window failed)" for x in j["boundaries"].values())
            comb = M.combine_units(col, spans, lambda c, a, z: js_gem(c, a, z))
            box = E.Box(col, "")
            box.v = {"G": E._from_bounds(col, W.assemble(col, comb, True))}
            with O.rule(fz["rule"]):
                per.append(E.evaluate(box, tuple(fz["voters"]), fz["level"]) | {"name": b})
                wrong[b] = unflagged_gaps(box, tuple(fz["voters"]), fz["level"])
        p = E.pooled(per)
        fig = O.figures(p)
        fig["usd_per_1000_pages"] = 1000 * sum(c["charged_usd"] for c in costs.values()) / p["pages"]
        fig["usd_settled_per_1000_pages"] = 1000 * sum(c["settled_usd"] for c in costs.values()) / p["pages"]
        rows[f"o{o}"] = {"figures": fig, "by_box": {r["name"]: O.figures(r) for r in per}, "cost_by_box": costs,
                         "failed_windows": failed, "unflagged_gaps": wrong}
    wrong38 = {}
    for b in OFFSET_BOXES:  # the cached 3.8 test-box answers options.py scored (no call)
        with O.rule(fz["rule"]):
            wrong38[b] = unflagged_gaps(E.Box(data.load(b), tuple(fz["voters"])), tuple(fz["voters"]), fz["level"])
    ref = next(x for x in json.loads((RESULTS / "options.json").read_text())["approaches"] if x["id"] == "gemini")
    ref_fig = {**ref["figures"]["test"],
               "usd_per_1000_pages": ref["cost"]["total"]["list_usd_per_1000_pages"]}
    return {"rule": fz["rule"], "level": fz["level"], "rows": rows, "gemini38_o0": ref_fig,
            "gemini38_o0_by_box": ref["figures"]["test_by_box"], "gemini38_o0_unflagged_gaps": wrong38}


def cmd_score(a):
    import rescore
    rescore.no_network()
    import kit_gate as K
    import kit_gate_sherlock as KS
    _, _, S, _ = _mods()
    js = judges()
    if a.local_only:
        js.pop("gemini")
    boxes, observed, paired, sc = [], [], [], None
    for b in BOXES:
        col = data.load(b, with_exif=False)
        rec = box_record(col, js)
        rec["split"] = "held-out" if b in HELD_OUT else "trained-on"
        boxes.append(rec)
        docs = K.documents(rec)
        pages = sum(d["exact_pages"] for d in docs)
        for key, m in rec["models"].items():
            calls = [(m["gaps"][k][0], g["truth"]) for k, g in enumerate(rec["gaps"])]
            observed.append({"route": key, "box": b, "split": route_split(key, b), "known gaps": len(calls),
                             "unsure": len(rec["unsure"]), "right": sum(c == t for c, t in calls),
                             "gap accuracy": sum(c == t for c, t in calls) / len(calls),
                             "false splits": sum(c == "new" and t == "continue" for c, t in calls),
                             "false merges": sum(c == "continue" and t == "new" for c, t in calls),
                             "pages exact": sum(d["exact_pages"] for d in docs if d["m"][key][0]) / pages,
                             "resolved pages": pages, "failed windows": rec["failed_windows"][key]})
        for x, y in (("mac-2b", "gemini"), ("mac-2b", "fs-2b"), ("gemini", "teacher"), ("mac-2b", "teacher")):
            if x not in js or y not in js:
                continue
            paired.append(KS.paired_row(f"{x} vs {y}", b, [
                (rec["models"][x]["gaps"][k][0] == g["truth"], rec["models"][y]["gaps"][k][0] == g["truth"])
                for k, g in enumerate(rec["gaps"])]))
        if b == "SC0122":
            sc = sc0122_owner(col, rec)
    off = None if a.local_only else offsets(js["gemini"])
    calls = S.settled()
    usage = {"calls": len(calls), "spent": S.spent(), "billed": S.settled_billed(),
             "input_tokens": sum(r["usage"].get("prompt_tokens", 0) for r in calls),
             "output_tokens": sum(r["usage"].get("completion_tokens", 0) for r in calls),
             "invalid": sum(not r.get("valid") for r in calls),
             "mean_seconds": sum(r.get("wall_s", 0) for r in calls) / max(1, len(calls))}
    out = {"tag": TAG, "observed": observed, "paired": paired, "sc0122_owner": sc, "offsets": off,
           "newsletter_gaps": None if a.local_only else newsletter_calls(), "gateway": usage, "status": "offline arms only; gateway and offsets pending" if a.local_only else "complete"}
    out["note"] = reading(out)
    stem = "seg-boxes-score-local" if a.local_only else "seg-boxes-score"
    (RESULTS / f"{stem}.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / f"{stem}.md").write_text(render(out))
    for r in observed:
        print(f"{r['box']:18} {r['route']:8} {r['right']}/{r['known gaps']}  pages exact {r['pages exact']:.3f}")
    for k, r in (off["rows"] if off else {}).items():
        f = r["figures"]
        print(k, {x: round(f[x], 4) for x in ("pages_exact_no_review", "flagged_per_100_pages",
                                               "pages_exact_after_review", "unflagged_errors_per_500_pages")})


# --- the report -----------------------------------------------------------------------------------

def _p(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def reading(out):
    obs = {(r["route"], r["box"]): r for r in out["observed"]}
    mac, teacher, source = [obs[(k, "Sasha")] for k in ("mac-2b", "teacher", "fs-2b")]
    text = (f"On held-out Sasha the shipped Mac 2B scores {_p(mac['gap accuracy'])} on {mac['known gaps']} known gaps "
            f"(pages exact {_p(mac['pages exact'])}), against the teacher's {_p(teacher['gap accuracy'])} and its "
            f"bf16 source's {_p(source['gap accuracy'])}. The source's pages exact is {_p(source['pages exact'])}: "
            "similar gap accuracy can leave different long documents wrong, and these single runs do not rank "
            "quantizations. The Illustrated Review and SC0122 are trained-on "
            "diagnostics for the students, not evidence of generalization. SC0122's supported comparison is its "
            "owner-ruled disagreement gaps plus controls weighted to the agreed strata; document-exact scores "
            "there remain conditional on tag/teacher-drafted truth. ")
    if out["offsets"] is None:
        return text + "Partial report: Gemini and all three cloud window offsets remain unmeasured; no cloud-versus-Mac recommendation follows."
    gem, gir = obs[("gemini", "Sasha")], obs[("gemini", "IllustratedReview")]
    pair = next(r for r in out["paired"] if r["pair"] == "mac-2b vs gemini" and r["scope"] == "Sasha")
    text += (f"Gemini 3.7 Flash scores {_p(gem['gap accuracy'])} on held-out Sasha (pages exact {_p(gem['pages exact'])}); "
             f"paired against the Mac 2B it is {-pair['difference points']:.1f} points ahead on gap accuracy "
             f"(sign test p {pair['sign test p']:.2g}), and far ahead on whole documents. On the Illustrated Review it "
             f"merges {gir['false merges']} article gaps, against the teacher's "
             f"{obs[('teacher', 'IllustratedReview')]['false merges']} and the students' "
             f"{min(obs[(k, 'IllustratedReview')]['false merges'] for k in STUDENTS)}-"
             f"{max(obs[(k, 'IllustratedReview')]['false merges'] for k in STUDENTS)}; that g1 still asks for the "
             "full magazine issue (W46.seg-magazine-rule-redo) explains at most the excess over those, and its pages "
             "exact there is no test of reading ability. ")
    figures = [r["figures"] for r in out["offsets"]["rows"].values()]
    exact = [r["pages_exact_no_review"] for r in figures]
    flags = [r["flagged_per_100_pages"] for r in figures]
    cause = newsletter_cause(out["newsletter_gaps"])
    return text + (f"Across three offsets of Gemini 3.7 at the shipped route's 3.8-fitted rule and level, no-check "
                   f"exact pages range {_p(min(exact))}–{_p(max(exact))} and checks per 100 pages "
                   f"{min(flags):.1f}–{max(flags):.1f}; the shipped 3.8 route's own offset range is unmeasured." +
                   (" Its two unflagged errors are Stanton 101|102 and 102|103 at every offset and for 3.8: " + cause + "."
                    if newsletter_only(out["offsets"]) and cause else ""))


# The Stanton gaps the owner re-ruled on 2026-10-31 under the article-within-issue rule (W46.seg-truth-sheet): the
# newsletter issue 101-105 split at 101|102 and 102|103. g1's rule 10 still tells the model to merge them, but every
# cloud route merges them, rule or not (newsletter_calls; W46.seg-offsets-cause).
NEWSLETTER_GAPS = {("Stanton", "101|102"), ("Stanton", "102|103")}


def wrong_sets(off):
    """Each cloud run's unflagged errors as a set of (box, gap): the three 3.7 offsets, then the cached 3.8."""
    runs = {f"3.7 {k}": r["unflagged_gaps"] for k, r in off["rows"].items()}
    runs["3.8 o0"] = off["gemini38_o0_unflagged_gaps"]
    return {k: {(b, g["gap"]) for b, gs in v.items() for g in gs} for k, v in runs.items()}


def unflagged_note(off, nl):
    sets = wrong_sets(off)
    same = len({frozenset(v) for v in sets.values()}) == 1
    listed = "; ".join(f"{k}: {', '.join(f'{b} {g}' for b, g in sorted(v)) or 'none'}" for k, v in sets.items())
    text = f"Unflagged errors, by gap: {listed}. "
    cause = newsletter_cause(nl)
    if same and next(iter(sets.values())) == NEWSLETTER_GAPS and cause:
        text += ("Every run's are the same pair, both a confident continue (0.98-0.99): " + cause + ". So the "
                 "route's 2.8 unflagged errors per 500 pages, here and in options.md, is the cloud models' own reading "
                 "of those pages, which rule 10 agrees with rather than causes, and \"after checking 98.5%\" is the "
                 "same at every offset because the same confident pair is wrong every time. ")
    return text + ("The other approaches' unflagged errors in options.md, from its cached test-box answers at their "
                   "frozen levels (W46.seg-offsets-label): GLM-5.3 Flash's 3 are the same pair and Stanton 144|145; "
                   "Claude's 3 (Stanton 124|125 and 144|145, RG165 99|100) and the Mac 2B's 1 (a false split at "
                   "Stanton 108|109) do not include it.")


def newsletter_only(off):
    """True when every cloud run's unflagged errors are exactly the two re-ruled newsletter gaps."""
    return all(v == NEWSLETTER_GAPS for v in wrong_sets(off).values())


# Each options.md approach's voter codes, as options.py and method_openrouter.py score them (W46.seg-offsets-cause).
APPROACH_CODES = {"claude": ("C",), "gemini": ("G",), "openai": ("O",), "mix": ("C", "O"),
                  "glm": ("X:glm5.3-flash",), "local": ("X:fs-seg-2b",)}
MAGAZINE_RULE_PROMPTS = {"g1"}  # rule 10, the full-magazine rule (W46.seg-magazine-rule-redo)


def newsletter_calls():
    """Every options.md approach's decision, confidence and flag at the two newsletter gaps, from its cached
    test-box answers at its frozen rule and level (no call)."""
    import re
    import ensemble as E
    import options as O
    import method_openrouter as R
    base = E.voter_gaps

    def voter_gaps(code, col):
        if code.startswith("X:"):
            return E._from_bounds(col, R.W.assemble(col, R.W.combine(col, R.judge(code[2:])), True))
        return base(code, col)
    aps = [a for a in json.loads(O.OUT_JSON.read_text())["approaches"] if a["id"] in APPROACH_CODES]
    E.voter_gaps = voter_gaps
    try:
        box = E.Box(data.load("Stanton"), sorted({c for a in aps for c in APPROACH_CODES[a["id"]]}))
    finally:
        E.voter_gaps = base
    wanted = sorted(int(g.split("|")[0]) - 1 for b, g in NEWSLETTER_GAPS)
    rows = []
    for a in aps:
        S = APPROACH_CODES[a["id"]]
        with O.rule(a["rule"]):
            j = E.judge(box, S, a["level"])
        prompts = sorted({m for v in a["voters"] for m in re.findall(r"prompt (\w+)", v)})
        rows.append({"id": a["id"], "label": a["label"], "rule": a["rule"], "level": a["level"], "prompts": prompts,
                     "magazine_rule": bool(MAGAZINE_RULE_PROMPTS & set(prompts)),
                     "gaps": {f"{i + 1}|{i + 2}": {"truth": box.truth[i], "said": j[i][0],
                                                     "confidence": round(j[i][2], 6), "flagged": j[i][1],
                                                     "votes": {c: list(box.v[c][i]) for c in S}}
                              for i in wanted}})
    return {"box": "Stanton", "source": "options.json's approaches, cached test-box answers, frozen rule and level",
            "approaches": rows}


def newsletter_table(nl):
    L = ["", "At the two newsletter gaps (truth: new at both), every options.md approach from its cached test-box "
         "answers at its frozen rule and level (no call):", "",
         "| approach | prompt | magazine rule | Stanton 101\\|102 | Stanton 102\\|103 |", "|---|---|---|---|---|"]
    for a in nl["approaches"]:
        cells = [f"{g['said']} {g['confidence']:.3f}, {'flagged' if g['flagged'] else 'accepted'}"
                 for g in a["gaps"].values()]
        L.append(f"| {a['label']} | {', '.join(a['prompts'])} | {'yes' if a['magazine_rule'] else 'no'} | "
                 f"{' | '.join(cells)} |")
    return L


def newsletter_cause(nl):
    """The two gaps' cause as the cached answers show it, or None when they no longer show it."""
    rows = {a["id"]: a for a in nl["approaches"]}
    cloud = [a for k, a in rows.items() if k != "local"]
    merged = all(g["said"] == "continue" for a in cloud for g in a["gaps"].values())
    local_splits = "local" in rows and all(g["said"] == "new" for g in rows["local"]["gaps"].values())
    ruled = [a for a in cloud if a["magazine_rule"]]
    if not (merged and local_splits and len(ruled) < len(cloud)):
        return None
    return ("the newsletter gaps the owner re-ruled on 2026-10-31 under the article-within-issue rule, which every "
            "cloud route merges with or without the magazine rule (only Gemini's g1 carries it) and only the 2B "
            "trained on the owner's corpus splits; the prompt change (W46.seg-magazine-rule-redo) is the first thing "
            "to try and is unmeasured on these gaps")


def offset_spread(out):
    """Points of no-check exact pages between the best and worst cloud offset, or None offline."""
    if out["offsets"] is None:
        return None
    exact = [r["figures"]["pages_exact_no_review"] for r in out["offsets"]["rows"].values()]
    return 100 * (max(exact) - min(exact))


def render(out) -> str:
    import seg_card
    obs = {(r["route"], r["box"]): r for r in out["observed"]}
    routes = [k for k in ROUTES if (k, "Sasha") in obs]
    g = out["gateway"]
    bill = g["billed"]
    gateway_total = "unavailable" if bill["gateway"] is None else f"${bill['gateway']:.4f}"
    command = "score --local-only" if out["offsets"] is None else "score"
    L = ["# W46.seg-boxes-score — the segmentation routes on the three locked boxes, and Gemini 3.7 (gateway) at the shipped route's rule and level, three window offsets", "",
         f"Generated by `ArchiveProcessor/scripts/segbench/seg_boxes_score.py {command}` from cached answers (no calls). "
         "Gemini 3.7 Flash through the Stanford AI API gateway (prompt g1, 1600 px images with Apple Vision text, "
         "temperature 0, reasoning low; the gateway does not serve the 3.8 Flash of options.md); the shipped 8-bit "
         "MLX 2B on this Mac (prompt l1, 1,024 px); the 27B teacher and the bf16 2B and 4B from "
         "W46.kit-gate-sherlock's Sherlock run on the same windows. Seven-page windows at stride 3, combined and "
         "assembled with the truth's photo labels. No ABBYY text.", "",
         f"Status: **{out['status']}**. Missing routes have no score, not a neutral or zero score.", "",
         f"Gateway: {g['calls']} calls, {g['input_tokens']:,} input and {g['output_tokens']:,} output tokens, "
         f"{g['invalid']} invalid, ${g['spent']:.4f} counted including unsettled reservations and the larger of "
         "returned gateway cost or list-token estimate (Gemini $0.75/$3.75 per million; "
         f"settled token estimate ${bill['estimate']:.4f}, returned gateway total {gateway_total} from "
         f"{bill['gateway_calls']}/{bill['calls']} settled calls), {g['mean_seconds']:.1f} s a call. "
         f"Authorized item cap ${CAP:.2f}, including every attempt and retained reservation.", "",
         "## The three locked boxes", "",
         "Known gaps only (the owner's unsure gaps out); pages exact over the documents no unsure gap touches, the "
         "same pages for every route. Sasha is the one box no student trained on; the Illustrated Review and SC0122 "
         "are in the students' training split (trained-on). Gemini and the teacher were not fine-tuned on these "
         "boxes. SC0122's all-known scores below are diagnostics against its locked draft, which includes "
         "tag/teacher agreement beyond the owner's controls; its document-exact scores are conditional on that "
         "draft. Use the separate owner-supported weighted gap comparison for accuracy conclusions there.", "",
         "Common support: " + "; ".join(
             f"{b}: {obs[(routes[0], b)]['known gaps']} known gaps, "
             f"{obs[(routes[0], b)]['unsure']} unsure gaps excluded, "
             f"{obs[(routes[0], b)]['resolved pages']} resolved document pages" for b in BOXES) + ".", "",
         "| route | box | split | known gaps | gap accuracy | false splits | false merges | pages exact | "
         "failed windows |", "|---|---|---|---:|---:|---:|---:|---:|---:|"]
    for b in BOXES:
        for k in routes:
            r = obs[(k, b)]
            L.append(f"| {LABEL[k]} | {b} | {r['split']} | {r['known gaps']} | {_p(r['gap accuracy'])} | "
                     f"{r['false splits']} | {r['false merges']} | {_p(r['pages exact'])} | {r['failed windows']} |")
    L += ["", "Pooled over the three boxes, a diagnostic and not a ranking: sums of gaps over boxes that differ in kind, "
          "two of which the students trained on, with Gemini's Illustrated Review row scored against the "
          "article-within-issue truth while g1 still asks for the full issue. A pool is not a population rate.", "", "| route | known gaps | gap accuracy | false splits | false merges |", "|---|---:|---:|---:|---:|"]
    for k in routes:
        rs = [obs[(k, b)] for b in BOXES]
        n = sum(r["known gaps"] for r in rs)
        L.append(f"| {LABEL[k]} | {n} | {_p(sum(r['right'] for r in rs) / n)} | "
                 f"{sum(r['false splits'] for r in rs)} | {sum(r['false merges'] for r in rs)} |")
    sc = out["sc0122_owner"]
    L += ["", "## SC0122 on its owner-ruled gaps", "",
          f"The {sc['asked_known']} known gaps where the corpus tag and the teacher disagreed (each ruled by the owner) "
          f"and the {sc['controls']} blind controls drawn from the {sc['agreed_doc_gaps']} where they agreed "
          "(W46.seg-truth-sheet; the owner agreed with the truth on all 60), counted over gaps between two document "
          "pages. The agreed stratum's accuracy is the controls' weighted N/n by control stratum "
          f"({', '.join(f'{s}: {N}/{n}' for s, (N, n) in sc['strata'].items())}); the combined figure weights the two "
          "strata by their sizes. The tag/teacher disagreements are the hard gaps, and every student trained on the "
          "teacher's label for them. These are stratified-sample point estimates, not a census of owner-ruled "
          "agreed gaps; the paired sign tests below do not include uncertainty from this control subsampling.", "",
          "| route | disagreement gaps right | controls right | agreed stratum, weighted | owner-ruled, weighted |",
          "|---|---:|---:|---:|---:|"]
    for k in routes:
        m = sc["models"][k]
        L.append(f"| {LABEL[k]} | {m['asked_right']}/{sc['asked_known']} | {m['controls_right']}/{sc['controls']} | "
                 f"{_p(m['agreed_weighted_accuracy'])} | {_p(m['owner_weighted_accuracy'])} |")
    L += ["", "## Paired differences", "",
          "Same gaps, same windows; discordant gaps and the exact two-sided sign test on them. Sampling only: the "
          "rerun floor (1.4-3.2 points a box, measured in pages exact, not in gap accuracy) is not in it, and gaps in one "
          "box are not independent.", "",
          "| pair | box | gaps | only first right | only second right | difference | p |",
          "|---|---|---:|---:|---:|---:|---:|"]
    for r in out["paired"]:
        L.append(f"| {r['pair']} | {r['scope']} | {r['gaps']} | {r['only first right']} | {r['only second right']} | "
                 f"{r['difference points']:+.1f} points | {r['sign test p']:.3g} |")
    off = out["offsets"]
    if off is not None:
        F = (("pages_exact_no_review", "pages in an exact document, no checking", lambda x: _p(x)),
             ("flagged_per_100_pages", "boundaries to check per 100 pages", lambda x: f"{x:.1f}"),
             ("pages_exact_after_review", "pages right after checking", lambda x: _p(x)),
             ("unflagged_errors_per_500_pages", "unflagged errors per 500 pages", lambda x: f"{x:.1f}"),
             ("usd_per_1000_pages", "charged $ per 1,000 pages, all attempts (3.8: reference list estimate)",
              lambda x: f"${x:.2f}"),
             ("usd_settled_per_1000_pages", "settled $ per 1,000 pages, retained allowances out", lambda x: f"${x:.2f}"))
        rows = off["rows"]
        L += ["", "## Gemini 3.7 (gateway) at the shipped route's rule and level, three window offsets (Stanton and RG165, 363 pages)", "",
              f"options.py's frozen Gemini approach (rule {off['rule']}, flag at or below {off['level']}), applied to "
              "Gemini 3.7 windows starting 0, 1 and 2 pages later; nothing refit. The app's cloud voter is Gemini 3.8 "
              "Flash on the user's own key, and the level was fitted for 3.8 on the development boxes; the gateway "
              "serves only 3.7. So this is 3.7's offset range at another model's level, not the shipped route's own, "
              "and 3.7's flag load at it is not 3.7's own best level. Cost counts each offset's "
              "windows once and all their attempts, including retained allowances, divided by all 363 input pages "
              "and scaled to 1,000. Each charge is the larger of returned gateway cost or list-token estimate. "
              "A window shared by offsets counts in each standalone route's cost; total experiment spend counts it "
              "once; the settled row leaves out allowances retained for calls the gateway never billed. The 3.8 cost is "
              "options.md's reference list estimate, with a different measurement basis.", "",
              "| figure | 3.7, offset 0 | 3.7, offset 1 | 3.7, offset 2 | 3.7 range | 3.8, offset 0 (options.md) |",
              "|---|---:|---:|---:|---:|---:|"]
        for k, name, fmt in F:
            v = [rows[f"o{o}"]["figures"][k] for o in (0, 1, 2)]
            ref = off["gemini38_o0"].get(k)
            L.append(f"| {name} | {' | '.join(fmt(x) for x in v)} | {fmt(min(v))}–{fmt(max(v))} | "
                     f"{'—' if ref is None else fmt(ref)} |")
        L += ["", "By box:", "", "| offset | box | no checking | to check per 100 pages | after checking | "
              "unflagged errors |", "|---|---|---:|---:|---:|---:|"]
        for o in (0, 1, 2):
            for b, f in rows[f"o{o}"]["by_box"].items():
                L.append(f"| 3.7 o{o} | {b} | {_p(f['pages_exact_no_review'])} | {f['flagged_per_100_pages']:.1f} | "
                         f"{_p(f['pages_exact_after_review'])} | {f['unflagged_errors']} |")
        for b, f in off["gemini38_o0_by_box"].items():
            L.append(f"| 3.8 o0 | {b} | {_p(f['pages_exact_no_review'])} | {f['flagged_per_100_pages']:.1f} | "
                     f"{_p(f['pages_exact_after_review'])} | {f['unflagged_errors']} |")
        L += ["", unflagged_note(off, out["newsletter_gaps"])] + newsletter_table(out["newsletter_gaps"])
    L += ["", "## Reading", "", out["note"], ""]
    L += seg_card.card(
        truth="The three locked boxes' truths (Sasha owner-ruled from label tags, locked 2026-10-30; the Illustrated "
              "Review owner-ruled on the article-within-issue rule; SC0122 tags and teacher where they agreed, the "
              "owner's rulings where they did not, locked 2026-10-29/30) with every unsure gap out; Stanton and RG165 "
              "as options.md scores them (Stanton with the owner's 2026-10-31 sheet rulings). No scored route drafted "
              "a truth, except that SC0122's agreed stratum is where the teacher agreed with the tag: the owner's 60 "
              "blind controls on it found no error, and the SC0122 section reports it apart.",
        selection="The boxes whole, named by the owner before any of these routes ran on them; the offset boxes are "
                  "options.md's test set. Nothing chosen by a tested route or by ABBYY text.",
        comparison="Every route on the same windows and Vision text, scored on the same known gaps and resolved "
                   "documents. The Mac 2B and the Sherlock models see 1,024 px images and prompt l1; Gemini sees "
                   "1,600 px and g1, as each is run in the bench and the app. Both OCR sets do not apply: this is "
                   "segmentation.",
        noise="Single runs at temperature 0. " +
              ("The cloud offset spread is unavailable in an offline-only report; "
               if offset_spread(out) is None else
               f"Gemini 3.7's window offsets, at the 3.8-fitted level, move no-check exact pages by "
               f"{offset_spread(out):.1f} points; the shipped 3.8 route's own offset range is unmeasured. ") +
              "A difference between routes smaller than the offset spread, or than the 1.4-3.2-point rerun floor a "
              "box (measured in pages exact; applied to gap accuracy it is a guide, not a measured floor), is a tie. " +
              ("The unflagged-error figures do not move across offsets because the same two confident Stanton gaps "
               "are wrong every time. " if out["offsets"] is not None and newsletter_only(out["offsets"]) else "") +
              "Sign tests are sampling only.",
        scope=("Only the three owner boxes scored; the two test boxes' cloud offsets remain pending. "
               if out["offsets"] is None else "Three owner boxes and two test boxes. ") +
              "It does not settle a prompt change for the article-within-issue "
              "rule (g1 still says full magazine: W46.seg-magazine-rule-redo; no route has been run on these gaps "
              "with a prompt that states the new rule), 3.8 against 3.7 on these boxes, the "
              "shipped 3.8 route's own offset range (the gateway serves only 3.7), or a level fitted for 3.7.")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("plan", "collect", "mac", "score"))
    ap.add_argument("--limit", type=int)
    ap.add_argument("--local-only", action="store_true", help="score only completed Mac/Sherlock arms, explicitly partial")
    ap.add_argument("--workers", type=int, choices=(1,), default=1,
                    help="collection is serial so reservation checks cannot race")
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "mac": cmd_mac, "score": cmd_score}[a.command](a)


if __name__ == "__main__":
    main()
