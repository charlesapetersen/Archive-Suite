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

    def predict(self, collection) -> Prediction:
        raise NotImplementedError


class AllNew(Method):
    name = "all-new"
    tuning = False
    oracle_photos = True
    description = "every document page starts a new document; photo labels from the truth"

    def predict(self, collection):
        return from_labels([lab if lab in PHOTO else "New" for lab in collection.labels],
                           cue="all-new")


class NoBoundaries(Method):
    name = "no-boundaries"
    tuning = False
    oracle_photos = True
    description = "no document boundaries: each folder's pages are one document; photo labels from the truth"

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


METHODS = {m.name: m for m in (AllNew(), NoBoundaries(), RuleCuesSketch())}
