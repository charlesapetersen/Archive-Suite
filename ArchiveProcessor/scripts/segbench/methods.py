"""The method interface and the trivial baselines (W36.seg-bench).

A method has a ``name``, a ``tuning`` flag (True while its prompts, thresholds or weights are
still being chosen; such a method is refused on the test collections), and
``predict(collection) -> Prediction``:

* ``labels``: one of Box / Folder / New / Cont per page;
* ``boundaries``: one dict per gap between page i and i+1,
  ``{"decision": "new"|"continue", "confidence": float in [0,1] or None, "cue": str}``.
  The decisions must agree with the labels (score.check_prediction enforces it).

The full baselines — the shipped per-page prompt and rule cues — are W36.seg-base. The two
here are the floor and the ceiling of doing nothing. Both take the box/folder photo labels
from the truth (``oracle_photos``), because photo detection is scored apart and is not what
they are a baseline for; say so wherever their numbers are quoted.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from score import PHOTO, boundaries_from_labels


@dataclass
class Prediction:
    labels: list[str]
    boundaries: list[dict]


def from_labels(labels: list[str], confidence=None, cue: str = "") -> Prediction:
    return Prediction(labels, [{"decision": d, "confidence": confidence, "cue": cue}
                               for d in boundaries_from_labels(labels)])


class Method:
    name = "method"
    tuning = True
    oracle_photos = False
    description = ""
    tuned_on = None   # a sentence for the result file when "tuning" alone would mislead
    held_out = ""     # SUMMARY.md: are this method's development numbers held out?

    def predict(self, collection) -> Prediction:
        raise NotImplementedError

    def notes(self) -> list[str]:
        """Extra markdown lines for the result file, about the predictions made so far."""
        return []


class AllNew(Method):
    name = "all-new"
    tuning = False
    oracle_photos = True
    description = "every document page starts a new document; photo labels from the truth"
    held_out = "no parameters"

    def predict(self, collection):
        return from_labels([lab if lab in PHOTO else "New" for lab in collection.labels],
                           cue="all-new")


class NoBoundaries(Method):
    name = "no-boundaries"
    tuning = False
    oracle_photos = True
    description = "no document boundaries: each folder's pages are one document; photo labels from the truth"
    held_out = "no parameters"

    def predict(self, collection):
        return from_labels([lab if lab in PHOTO else "Cont" for lab in collection.labels],
                           cue="no-boundaries")


_PAGE_N = re.compile(r"^\s*(?:-\s*(\d{1,2})\s*-|page\s+(\d{1,2})(?:\s+of\s+\d+)?)\s*$", re.I | re.M)
_SALUTATION = re.compile(r"^\s*(dear|my dear|gentlemen|sir|madam)\b", re.I | re.M)


class RuleCuesSketch(Method):
    """A deliberately small sketch of rule cues so the interface has a text-reading example;
    the real rule-cue baseline is W36.seg-base. A page with a page number of 2 or more near
    its top continues; a salutation starts; otherwise New. Needs the OCR cache."""
    name = "rule-cues-sketch"
    tuning = True
    oracle_photos = True
    description = "page-number and salutation cues on Apple Vision text (sketch; W36.seg-base builds the real one)"
    held_out = "untuned sketch, written after reading dev pages"

    def predict(self, collection):
        labels, bounds = [], []
        for i, lab in enumerate(collection.labels):
            if lab in PHOTO:
                labels.append(lab)
                cue, conf = "photo (oracle)", 1.0
            else:
                head = "\n".join((collection.text(i) or "").splitlines()[:6])
                m = _PAGE_N.search(head)
                num = int(m.group(1) or m.group(2)) if m else None
                if num and num >= 2:
                    labels.append("Cont"); cue, conf = f"page number {num}", 0.7
                elif _SALUTATION.search(head):
                    labels.append("New"); cue, conf = "salutation", 0.7
                else:
                    labels.append("New"); cue, conf = "default new", 0.5
            if i:
                bounds.append({"decision": None, "confidence": conf, "cue": cue})
        for b, d in zip(bounds, boundaries_from_labels(labels)):
            b["decision"] = d
        return Prediction(labels, bounds)


class SpringRun(Method):
    """A March 2026 Gemini run, read from its saved per-page labels (data.read_spring). No call is
    made. The run's own Box/Folder calls are used, unless ``oracle_photos``: then photo calls are
    replaced by the truth's, like the other baselines — truth photo pages get their Box/Folder
    label, and a document page the model called a photo becomes New."""
    tuning = False   # the prompts are frozen; nothing on the bench is chosen from data
    held_out = "NO: the prompts were tuned on all five collections"
    tuned_on = ("the spring prompts were written while looking at errors on all five collections "
                "(Dean, Deaver, Herrnstein, Stanton, RG 165), so these development numbers are NOT held out")

    def __init__(self, name, run, description, oracle_photos=False):
        self.name, self.run, self.description, self.oracle_photos = name, run, description, oracle_photos
        self.failed: dict[str, list[int]] = {}

    def predict(self, collection):
        import data
        labels, failed = data.read_spring(data.spring_path(collection.name, self.run), len(collection.pages))
        self.failed[collection.name] = failed
        cues = ["run failed: no label, New as the app does" if p.n in failed else f"spring {self.run}"
                for p in collection.pages]
        if self.oracle_photos:
            labels = [t if t in PHOTO else ("New" if lab in PHOTO else lab)
                      for t, lab in zip(collection.labels, labels)]
        pred = from_labels(labels)
        for b, cue in zip(pred.boundaries, cues[1:]):
            b["cue"] = cue
        return pred

    def notes(self):
        tot = sum(len(v) for v in self.failed.values())
        per = ", ".join(f"{k} {len(v)}" for k, v in self.failed.items())
        return [f"Failed pages (no label saved: the call failed or the reply had no tag): {tot} ({per}). "
                "Each is scored as New, which is what the app does with a missing classification, and its "
                "errors count against the run.",
                "All three spring runs sent the previous page's image and the end of its text with each page; "
                "there is no saved run without the previous image."]


class RuleCues(Method):
    """The rule-cue baseline (rules.py): an ordered rule list on Apple Vision text, its free
    parameters fitted leave-one-collection-out on the development collections only."""
    name = "rule-cues"
    tuning = True   # fitted on the development set; never scored on the test set until frozen
    held_out = "yes, leave-one-collection-out (the rule list itself was written after reading dev pages)"
    oracle_photos = True
    description = ("ordered rule cues (page numbers, openings, date lines, closings, jump lines, blank pages) "
                   "on Apple Vision text; photo labels from the truth")
    tuned_on = ("leave-one-collection-out on the development set: each collection's row uses rule switches and "
                "thresholds fitted on the other two, so every row, and the pooled row, is held out in those. "
                "The rule list and its patterns were written after reading development pages, so the rules "
                "themselves are not held out")

    def __init__(self, train_loader=None):
        self._load = train_loader
        self.folds: dict[str, tuple] = {}
        self.predictions: list[tuple] = []

    def _train(self, name):
        import data
        load = self._load or (lambda n: data.load(n, with_exif=False))
        return [load(n) for n in data.DEV if n != name]

    def predict(self, collection):
        import rules
        if collection.name not in self.folds:
            train = self._train(collection.name)
            params, stats = rules.fit(train)
            self.folds[collection.name] = (params, stats, [c.name for c in train])
        params, stats, _ = self.folds[collection.name]
        feats = rules._features(collection, params.top_lines, params.end_lines, params.blank_chars)
        labels, deciders = rules.predict_labels(feats, params)
        self.predictions.append((collection.name, collection.labels, labels, deciders))
        pred = from_labels(labels)
        for b, rule in zip(pred.boundaries, deciders[1:]):
            b["cue"] = rule
            b["confidence"] = 1.0 if rule == "photo (oracle)" else rules.precision(stats, rule)
        return pred

    def notes(self):
        import rules
        out = ["Fitted parameters per held-out collection (fitted on the other two):", ""]
        for name, (params, _, train) in self.folds.items():
            out.append(f"- {name} (fitted on {' + '.join(train)}): {params.describe()}")
        stats = rules.rule_stats([(t, p, d) for _, t, p, d in self.predictions])
        out += ["", "Deciding rule over document gaps, held-out predictions pooled "
                "(hits = gaps the rule decided; precision = share decided correctly):", "",
                "| rule | decides | hits | correct | precision |", "|---|---|---:|---:|---:|"]
        for rule in rules.RULES + ("default",):
            if rule not in stats:
                continue
            hits, ok = stats[rule]
            dec = {"blank": "Cont", "page-one": "New", "page-number": "Cont", "bare-number": "Cont",
                   "jump-from": "Cont", "opening": "New", "date-line": "New", "prev-jump": "Cont",
                   "prev-closing": "New", "flows-on": "Cont"}.get(rule, "default")
            out.append(f"| {rule} | {dec} | {hits} | {ok} | {100 * ok / hits:.1f}% |")
        return out


METHODS = {m.name: m for m in (
    AllNew(), NoBoundaries(), RuleCuesSketch(),
    SpringRun("spring-baseline", "baseline", "spring 2026 Gemini baseline prompt, saved March outputs"),
    SpringRun("spring-v1", "v1", "spring 2026 Gemini improved_v1 prompt (the one the app ships), saved March outputs"),
    SpringRun("spring-v2", "v2", "spring 2026 Gemini improved_v2 prompt, saved March outputs"),
    SpringRun("spring-v1-oracle-photos", "v1", "spring improved_v1 saved outputs with truth photo pages forced "
              "to their Box/Folder labels (isolates boundary finding)", oracle_photos=True),
    RuleCues(),
)}


# W36.seg-features: the on-device feature model lives in its own module, which adds itself to METHODS.
import method_features  # noqa: E402,F401

# W36.seg-window: approach A, Claude over overlapping page windows; adds itself to METHODS.
import method_window  # noqa: E402,F401

# W36.seg-second: approach B, Gemini Flash-Lite over the same windows; adds itself to METHODS.
import method_gemini  # noqa: E402,F401
