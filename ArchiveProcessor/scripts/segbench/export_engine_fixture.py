"""W36.seg-opt-engine: export one development box's recorded window answers as the Processor engine's test fixture.

    uv run -q --python 3.12 --with numpy --with requests python export_engine_fixture.py Deaver \
        engine-fixture-deaver.json        # read by scripts/test-segmentation-engine.sh

Reads only the bench's response caches (no call is made; a missing window is an error). The fixture holds, per
voter, every window's answer re-serialized in the reply format both prompts ask for — pages numbered 1..N in run
order, cues blanked (they quote the archive's documents and the repo is public), decisions and confidences
exact — plus the truth photo kinds and the bench's own verdict on every document gap: `ensemble.judge` at each
shipped approach's level and rule from options.json. The Swift test feeds the replies through the engine's own
parser and combiner and must reproduce that verdict gap for gap.
"""
from __future__ import annotations

import json
import sys

import data
import options as O  # sets the Gemini voter to 3.8 Flash / low, patches ensemble.voter_gaps, and has the Codex judge
import ensemble as E
import method_gemini as G
import method_window as W
import method_window_cues as MWC
import seg_magazine_rule_app as MRA
from score import PHOTO

# W46.seg-magazine-rule-app: the app's Gemini voter sends g2, and its recorded answers are Gemini 3.7 Flash's g2
# answers through the Stanford gateway (the gateway does not serve 3.8; MRA.EVIDENCE says so in the fixture).
VOTER_JUDGE = {"C": W.judge_window, "G": MRA.answer, "O": O.OPENAI_JUDGE}
VOTER_NAMES = {**O.VOTER_NAMES, "G": MRA.VOTER}


def reply(j: dict, index: dict[int, int]) -> str:
    pages = [{"page": index[n] + 1, "kind": k} for n, k in sorted(j["pages"].items())]
    bounds = [{"between": [index[x] + 1, index[x] + 2], "decision": b["decision"], "cue": "",
               "confidence": b["confidence"]} for x, b in sorted(j["boundaries"].items())]
    return json.dumps({"pages": pages, "boundaries": bounds})


class _Synthetic:
    """A seven-page window with made-up text (one blank page, one past the truncation length), so the fixture
    carries each prompt (w1, g2 and the Codex route's c1) exactly as the bench renders it and nothing from the archive."""
    name = "synthetic"

    def __init__(self):
        self.pages = [type("P", (), {"n": n})() for n in range(1, 8)]
        self._t = {0: "Dear Mr. Smith,\n  thank you.  ", 2: "", 4: ("lorem ipsum " * 300)}

    def text(self, i):
        return self._t.get(i, f"text of page {i + 1}")


def prompts() -> dict:
    col = _Synthetic()
    texts = [col.text(i) for i in range(7)]
    nums = list(range(1, 8))
    t = "\n".join(f"--- page {n} ---\n{W.page_text(col, i)}" for n, i in zip(nums, range(7)))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    files = "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)
    return {"texts": texts,
            "w1": W.PROMPT.format(k=7, files=files, texts=t, gaps=gaps, max_text=W.MAX_TEXT),
            "g2": G.PROMPTS["g2"].format(k=7, texts=t, gaps=gaps, max_text=W.MAX_TEXT,
                                  pages=", ".join(str(n) for n in nums)),
            "c1": MWC.prompt_template("codex").format(k=7, files=files, texts=t, gaps=gaps, max_text=W.MAX_TEXT,
                                                      pages=", ".join(str(n) for n in nums)),
            # W46.seg-text-tier-app: g2 with its image paragraph replaced, as seg_window_gateway.request builds it.
            "g2t": _text_only(G.PROMPTS["g2"].format(k=7, texts=t, gaps=gaps, max_text=W.MAX_TEXT,
                                                     pages=", ".join(str(n) for n in nums)), nums)}


def _text_only(prompt, nums):
    import seg_window_gateway as SWG
    old = SWG.OLD_PARA.format(k=len(nums))
    if prompt.count(old) != 1:
        raise SystemExit("the image paragraph is not unique in g2")
    return prompt.replace(old, SWG.NEW_PARA.format(k=len(nums), a=nums[0], b=nums[-1]), 1)


def main(argv) -> int:
    name, out = argv[1], argv[2]
    col = data.load(name, with_exif=False)
    n = len(col.pages)
    index = {p.n: i for i, p in enumerate(col.pages)}
    spec = json.loads((E.RESULTS / "options.json").read_text())
    voters = {}
    for code, judge in VOTER_JUDGE.items():
        ws = []
        for a, b in W.windows(n):
            j = judge(col, a, b, allow_call=False)
            if j is None:
                raise SystemExit(f"{name} {code}: window {a}-{b} is not in the cache")
            ws.append({"start": a, "end": b, "reply": reply(j, index)})
        voters[code] = ws
    box = E.Box(col, ("C", "O"))
    box.v["G"] = MRA.g2_box(name).v["G"]
    expected = {}
    for ap in spec["approaches"]:
        if not ap["available"] or not ap["voters"]:
            continue
        codes = "".join(c for c, nm in VOTER_NAMES.items() if nm in ap["voters"])
        if len(codes) != len(ap["voters"]):
            continue   # a voter this fixture does not record (the OpenRouter and Mac-local routes have their own tests)
        with O.rule(ap["rule"]):
            verdict = E.judge(box, codes, ap["level"])
        expected[ap["id"]] = [{"gap": i, "decision": d, "flagged": f, "confidence": c, "agreed": g}
                              for i, (d, f, c, g) in sorted(verdict.items())]
    photo = [lab if lab in PHOTO else None for lab in col.labels]
    fixture = {
        "item": "W36.seg-opt-engine",
        "box": name,
        "source": "ArchiveProcessor/scripts/segbench/export_engine_fixture.py (bench response caches; no call)",
        "pages": n,
        "photo_kinds": photo,
        "voters": {c: VOTER_NAMES[c] for c in VOTER_JUDGE},
        "gemini_answers": MRA.EVIDENCE,
        "windows": voters,
        "expected": expected,
        "prompts": prompts(),
    }
    with open(out, "w") as f:
        json.dump(fixture, f, separators=(",", ":"))
        f.write("\n")
    print(f"{name}: {n} pages, {len(voters['C'])} windows per voter, "
          + ", ".join(f"{k} {sum(g['flagged'] for g in v)} flagged of {len(v)}" for k, v in expected.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
