#!/usr/bin/env python3
"""Gap audit item 32 / G-entities Test 7, the office-term probe: do office holders named in a document date it?

On the 54 owner-answered dating documents (33 class A, 21 class D: date_traceable.owner_docs("abbyy") restricted to
cls A/D; the loader's ids, classes and years agree with cases/truth-sets.json `records` on all 54), find person
mentions that carry an office, link each to Wikidata, and test whether the term of office brackets the owner's year.

Extraction (rule-based, on the corpus text cache, whole document). An all-caps line is title-cased first (same
length, so offsets hold). OFFICES is the office vocabulary (President, Vice President, Dean, Provost, Chancellor,
Senator, Governor, Secretary [of X], Director, Mayor, Ambassador, Commissioner, Chairman, Justice, Judge,
Congressman, Representative, Attorney General, Prime Minister, Minister, Bishop, ...). A NAME is one to four
capitalised tokens (initials allowed), leading honorifics (Mr., Dr., Hon., ...) and a trailing Jr./'s dropped, then
rejected if any token is a stopword (The, United, University, Committee, a month, ...). Three forms, scanned in this order; a span already claimed is not read again:
  title    OFFICE NAME                       "Senator Smith", "Secretary of Labor Jane Roe" (capitalised OFFICE; the
                                             name may wrap once onto the next line)
  comma    NAME, [the] OFFICE [of [the] ORG] "John Smith, President of X", "John Smith, chairman of X"
                                             (OFFICE capitalised or lower case; NAME at least two tokens)
  block    NAME on one line, OFFICE starting the next line (a signature block; NAME at least two tokens)
"Secretary of X" and "OFFICE of ORG" keep X / ORG as the org. Mentions are deduplicated per document by
(name, office).

Linking (Wikidata, free public API; every response cached as JSON under CACHE/wikidata/, so a rerun makes no call;
a descriptive User-Agent; at most 2 requests a second):
  1. wbsearchentities(name, language en, type item, limit 10); for a surname alone, which that search rarely
     ranks, the full-text search "<surname> haswbstatement:P31=Q5 haswbstatement:P39" (50 results) instead
  2. wbgetentities on the candidates: keep humans (P31 = Q5) with at least one P39 (position held) statement
  3. wbgetentities for the labels of those P39 positions and of their P642 (of) / P1001 (jurisdiction) qualifiers
  A P39 statement MATCHES when the office's key (ALIASES: Congressman -> representative, Chairman -> chair, ...) is
  a case-insensitive substring of the position label (not as part of "vice / lieutenant / deputy / assistant
  <office>", so President does not match a vice-presidency), or the mention's org is a substring of the position label or
  a qualifier label. Outcome per mention: nil (no candidate holds a matching position), ambiguous (more than one
  does), linked (exactly one). A linked person's range is the envelope of their matching statements, from P580
  (start) and P582 (end); a missing end is open (to the present), a missing start open backwards; no start and no
  end at all is "undated". Then: bracket (start <= owner year <= end), exclude (outside), and the width in years
  (end, or this year when open, minus start; none when the start is missing).

    python3 ent_office.py probe      # extraction + lookups, writes CACHE/office.jsonl (names in it: private cache)
    python3 ent_office.py summary    # prints aggregates as JSON (no names, no text)

Read-only on the corpus. $0: Wikidata is free; spend is reported as the number of network calls.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import statistics
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-robust")
WD_CACHE = os.path.join(CACHE, "wikidata")
OUT = os.path.join(CACHE, "office.jsonl")
CALLS = os.path.join(CACHE, "office-calls.json")
API = "https://www.wikidata.org/w/api.php"
UA = "ArchiveSuite-segbench/1.0 (research; https://github.com/charlesapetersen/Archive-Suite)"
MIN_GAP = 0.5            # seconds between network calls: <= 2 a second
NOW = time.gmtime().tm_year

OFFICES = ("Vice President", "Attorney General", "Prime Minister", "Lieutenant Governor", "Secretary General",
           "Solicitor General", "Chief Justice", "Postmaster General", "President", "Dean", "Provost", "Chancellor",
           "Senator", "Sen.", "Governor", "Gov.", "Secretary", "Director", "Mayor", "Ambassador", "Commissioner",
           "Chairman", "Chairwoman", "Justice", "Judge", "Congressman", "Congresswoman", "Representative", "Rep.",
           "Minister", "Bishop", "Archbishop", "Cardinal", "Rector", "Superintendent", "Treasurer", "Comptroller")
ALIASES = {"sen.": "senator", "gov.": "governor", "rep.": "representative", "congressman": "representative",
           "congresswoman": "representative", "chairman": "chair", "chairwoman": "chair",
           "chief justice": "chief justice", "justice": "justice"}
STOP = {"The", "A", "An", "Of", "And", "For", "In", "On", "To", "United", "States", "University", "College",
        "Committee", "Department", "Office", "Board", "School", "Council", "House", "Senate", "Mr", "Mr.", "Mrs",
        "Mrs.", "Ms", "Ms.", "Dr", "Dr.", "Hon", "Hon.", "Honorable", "Dear", "Sincerely", "Yours", "Very", "Truly",
        "Cordially", "This", "That", "We", "I", "He", "She", "It", "They", "His", "Her", "Our", "Your", "Federal",
        "National", "American", "General", "Assistant", "Deputy", "Executive", "Vice", "Acting", "Former", "Elect",
        "Emeritus", "State", "City", "County", "Foundation", "Institute", "Association", "Society", "Inc", "Inc.",
        "Company", "Corporation", "Center", "Program", "Project", "Library", "Press", "Division", "Bureau",
        "Agency", "Administration", "Commission", "Dean", "President", "Secretary", "Director", "Chairman",
        "Senator", "Governor", "Mayor", "Judge", "Justice", "Minister", "Bishop", "Provost", "Chancellor", "Re",
        "Subject", "Memorandum", "From", "Date", "Cc", "Copy", "Enclosure", "Attachment", "Page", "January",
        "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
        "December", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Jr", "Jr.",
        "Sr", "Sr.", "Washington"}
TOK = r"(?:[A-Z][a-z]+(?:[-'][A-Z]?[a-z]+)?|[A-Z]\.|Mc[A-Z][a-z]+|O'[A-Z][a-z]+)"
NAME = rf"{TOK}(?:[ \t]+{TOK}){{0,3}}"
NAME_NL = rf"{TOK}(?:[ \t]*\n?[ \t]*{TOK}){{0,3}}"     # title form: a name may wrap once a line
OFF_LC = "|".join(re.escape(o.lower()).replace(r"\ ", r"[ \t]+") for o in OFFICES if not o.endswith("."))
OFF = "|".join(re.escape(o).replace(r"\ ", r"[ \t]+") for o in OFFICES)
ORGW = r"[A-Z][A-Za-z.&'-]*"
ORG = rf"{ORGW}(?:[ \t]+(?:of|and|for|the|&)?[ \t]*{ORGW}){{0,5}}"
SECOF = rf"[ \t]+of[ \t]+(?:the[ \t]+)?(?P<sorg>{ORGW}(?:[ \t]+(?:and[ \t]+)?{ORGW}){{0,2}})"
R_TITLE = re.compile(rf"\b(?:(?P<sec>Secretary){SECOF}|(?P<off>{OFF}))[ \t]*\n?[ \t]*(?P<name>{NAME_NL})")
R_COMMA = re.compile(rf"\b(?P<name>{NAME}),[ \t]+(?:the[ \t]+)?(?P<off>{OFF}|{OFF_LC})(?:[ \t]+of[ \t]+(?:the[ \t]+)?(?P<org>{ORG}))?")
R_BLOCK = re.compile(rf"^[ \t]*(?P<name>{NAME})[ \t]*,?[ \t]*\n[ \t]*(?P<off>{OFF})(?:[ \t]+of[ \t]+(?:the[ \t]+)?(?P<org>{ORG}))?",
                     re.M)


# ---- extraction -----------------------------------------------------------------------------------------------------

def normalise(text):
    """All-caps lines title-cased (lengths kept, so offsets point into the original text)."""
    return "".join(ln.title() if ln.isupper() and len(ln.strip()) > 3 else ln for ln in text.splitlines(True))


HONOR = {"Mr", "Mr.", "Mrs", "Mrs.", "Ms", "Ms.", "Dr", "Dr.", "Hon", "Hon.", "Honorable", "The"}


def clean_name(raw):
    toks = re.sub(r"'s$", "", re.sub(r"\s+", " ", raw).strip()).split()
    while toks and toks[0] in HONOR:
        toks.pop(0)
    while toks and toks[-1] in ("Jr", "Jr.", "Sr", "Sr."):
        toks.pop()
    if not toks or any(t in STOP for t in toks) or all(len(t) <= 2 for t in toks):
        return None
    return " ".join(toks)


def office_key(off):
    o = re.sub(r"\s+", " ", off).lower()
    return ALIASES.get(o, o)


def mentions(text):
    t, claimed, out, seen = normalise(text), [], [], set()
    for form, rx, min_toks in (("title", R_TITLE, 1), ("comma", R_COMMA, 2), ("block", R_BLOCK, 2)):
        for m in rx.finditer(t):
            s, e = m.span()
            if any(s < ce and cs < e for cs, ce in claimed):
                continue
            name = clean_name(m.group("name"))
            if not name or len(name.split()) < min_toks:
                continue
            gd = m.groupdict()
            org = gd.get("sorg") or gd.get("org")
            off = re.sub(r"\s+", " ", gd.get("off") or gd["sec"])
            key = (name, office_key(off))
            claimed.append((s, e))
            if key in seen:
                continue
            seen.add(key)
            out.append({"form": form, "name": name, "office": off, "office_key": office_key(off),
                        "org": org.strip() if org else None, "offset": s, "quote": text[s:e]})
    return sorted(out, key=lambda x: x["offset"])


# ---- Wikidata -------------------------------------------------------------------------------------------------------

_last = [0.0]
_calls = [0]


def wd(params):
    params = dict(params, format="json")
    q = urllib.parse.urlencode(sorted(params.items()))
    path = os.path.join(WD_CACHE, hashlib.sha256(q.encode()).hexdigest()[:24] + ".json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)["response"]
    wait = MIN_GAP - (time.time() - _last[0])
    if wait > 0:
        time.sleep(wait)
    for attempt in range(4):
        try:
            req = urllib.request.Request(API + "?" + q, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.load(r)
            break
        except Exception as ex:  # noqa: BLE001 — retry politely, then give up loudly
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))
    _last[0] = time.time()
    _calls[0] += 1
    os.makedirs(WD_CACHE, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"query": q, "response": data}, f)
    os.replace(tmp, path)
    return data


def entities(ids, props="claims|labels"):
    out = {}
    ids = sorted(set(ids))
    for i in range(0, len(ids), 50):
        r = wd({"action": "wbgetentities", "ids": "|".join(ids[i:i + 50]), "props": props, "languages": "en"})
        out.update(r.get("entities", {}))
    return out


def label(ent):
    return (ent or {}).get("labels", {}).get("en", {}).get("value", "")


def item_ids(claims, prop):
    return [c["mainsnak"]["datavalue"]["value"]["id"] for c in claims.get(prop, [])
            if c["mainsnak"].get("snaktype") == "value"]


def qual_year(stmt, prop):
    for q in stmt.get("qualifiers", {}).get(prop, []):
        if q.get("snaktype") == "value":
            t = q["datavalue"]["value"]["time"]
            m = re.match(r"([+-])(\d+)-", t)
            if m:
                return int(m.group(2)) * (-1 if m.group(1) == "-" else 1)
    return None


def qual_ids(stmt, props=("P642", "P1001")):
    return [q["datavalue"]["value"]["id"] for p in props for q in stmt.get("qualifiers", {}).get(p, [])
            if q.get("snaktype") == "value" and isinstance(q["datavalue"]["value"], dict)
            and "id" in q["datavalue"]["value"]]


def link(m):
    """Resolve one mention; returns the outcome record (evidence kept)."""
    if len(m["name"].split()) == 1:
        # A surname alone ("Governor Reagan") rarely puts the person in wbsearchentities' top ten, so search the
        # full text for people of that name who hold any position; the office match below then chooses.
        s = wd({"action": "query", "list": "search", "srlimit": "50", "srnamespace": "0",
                "srsearch": f'{m["name"]} haswbstatement:P31=Q5 haswbstatement:P39'})
        cands = [c["title"] for c in s.get("query", {}).get("search", [])]
    else:
        s = wd({"action": "wbsearchentities", "search": m["name"], "language": "en", "type": "item", "limit": "10"})
        cands = [c["id"] for c in s.get("search", [])]
    if not cands:
        return {"outcome": "nil", "why": "no search hit", "candidates": 0}
    ents = entities(cands)
    humans = {q: e for q, e in ents.items() if "Q5" in item_ids(e.get("claims", {}), "P31")
              and e.get("claims", {}).get("P39")}
    if not humans:
        return {"outcome": "nil", "why": "no human with P39", "candidates": len(cands)}
    need = set()
    for e in humans.values():
        for st in e["claims"]["P39"]:
            if st["mainsnak"].get("snaktype") == "value":
                need.add(st["mainsnak"]["datavalue"]["value"]["id"])
            need.update(qual_ids(st))
    labs = {q: label(e).lower() for q, e in entities(need, props="labels").items()}
    key, org = m["office_key"], (m["org"] or "").lower()
    matched = {}
    for q, e in humans.items():
        hits = []
        for st in e["claims"]["P39"]:
            if st["mainsnak"].get("snaktype") != "value":
                continue
            pos = st["mainsnak"]["datavalue"]["value"]["id"]
            plab = labs.get(pos, "")
            qlabs = [labs.get(x, "") for x in qual_ids(st)]
            vice = any(f"{p} {key}" in plab for p in ("vice", "lieutenant", "deputy", "assistant"))
            if (key and key in plab and not vice) or (org and (org in plab or any(org in x for x in qlabs if x))):
                hits.append({"statement": st["id"], "position": pos, "position_label": plab,
                             "qualifier_labels": [x for x in qlabs if x],
                             "start": qual_year(st, "P580"), "end": qual_year(st, "P582")})
        if hits:
            matched[q] = hits
    if not matched:
        return {"outcome": "nil", "why": "no matching position", "candidates": len(cands), "humans_p39": len(humans)}
    if len(matched) > 1:
        return {"outcome": "ambiguous", "qids": sorted(matched), "candidates": len(cands), "humans_p39": len(humans)}
    (qid, hits), = matched.items()
    starts = [h["start"] for h in hits]
    ends = [h["end"] for h in hits]
    if all(x is None for x in starts) and all(x is None for x in ends):
        nb = na = None
    else:
        nb = None if any(x is None for x in starts) else min(starts)
        na = None if any(x is None for x in ends) else max(ends)
    return {"outcome": "linked", "qid": qid, "person_label": label(humans[qid]), "statements": hits,
            "notBefore": nb, "notAfter": na, "candidates": len(cands), "humans_p39": len(humans)}


def judge(rec, year):
    """bracket / exclude / undated against the owner's year, and the width in years."""
    if rec["outcome"] != "linked":
        return
    nb, na = rec["notBefore"], rec["notAfter"]
    if nb is None and na is None and all(h["start"] is None and h["end"] is None for h in rec["statements"]):
        rec["verdict"], rec["width"] = "undated", None
        return
    lo = nb if nb is not None else -10 ** 6
    hi = na if na is not None else NOW
    rec["verdict"] = None if year is None else ("bracket" if lo <= year <= hi else "exclude")
    rec["width"] = None if nb is None else hi - nb


# ---- commands -------------------------------------------------------------------------------------------------------

def docs():
    import date_traceable as T
    out = [d for d in T.owner_docs("abbyy") if d["cls"] in ("A", "D")]
    n = collections.Counter(d["cls"] for d in out)
    assert n == {"A": 33, "D": 21}, n
    return out


def cmd_probe(a):
    os.makedirs(CACHE, exist_ok=True)
    rows = []
    for d in docs():
        year = (d.get("truth") or {}).get("year")
        ms = mentions(d["text"])
        for m in ms:
            m.update(link(m))
            judge(m, year)
        rows.append({"doc": d["id"], "cls": d["cls"], "year": year, "mentions": ms})
        print(f"{d['id']} {d['cls']} mentions={len(ms)} calls={_calls[0]}", file=sys.stderr)
    with open(OUT + ".tmp", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    os.replace(OUT + ".tmp", OUT)
    tot = json.load(open(CALLS)) if os.path.exists(CALLS) else {"total": 0}
    tot = {"total": tot["total"] + _calls[0], "last_run": _calls[0]}
    json.dump(tot, open(CALLS, "w"))
    print(f"wrote {OUT}; network calls this run {_calls[0]}", file=sys.stderr)


def agg(rows):
    c = collections.Counter()
    widths = []
    for r in rows:
        c["documents"] += 1
        ms = r["mentions"]
        c["mentions"] += len(ms)
        c["documents_with_mention"] += bool(ms)
        for m in ms:
            c["form_" + m["form"]] += 1
            c[m["outcome"]] += 1
            if m["outcome"] == "nil":
                c["nil_" + m["why"].replace(" ", "_")] += 1
            if m["outcome"] == "linked":
                c[m["verdict"] or "no_year"] += 1
                if m["verdict"] == "bracket" and m["width"] is not None:
                    widths.append(m["width"])
        c["documents_bracketed"] += any(m.get("verdict") == "bracket" for m in ms)
        c["documents_with_link"] += any(m["outcome"] == "linked" for m in ms)
        c["documents_only_excluding"] += (any(m.get("verdict") == "exclude" for m in ms)
                                          and not any(m.get("verdict") == "bracket" for m in ms))
    out = dict(sorted(c.items()))
    out["bracket_width_median"] = statistics.median(widths) if widths else None
    out["bracket_width_le_4"] = sum(w <= 4 for w in widths)
    out["bracket_width_le_10"] = sum(w <= 10 for w in widths)
    return out


def cmd_summary(a):
    rows = [json.loads(ln) for ln in open(OUT)]
    out = {"overall": agg(rows)}
    for k in ("A", "D"):
        out["class_" + k] = agg([r for r in rows if r["cls"] == k])
    tot = json.load(open(CALLS)) if os.path.exists(CALLS) else {"total": 0, "last_run": 0}
    out["spend"] = {"wikidata_calls": tot["total"], "wikidata_calls_last_run": tot["last_run"], "usd": 0}
    print(json.dumps(out, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("probe").set_defaults(fn=cmd_probe)
    sub.add_parser("summary").set_defaults(fn=cmd_summary)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
