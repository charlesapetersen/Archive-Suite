#!/usr/bin/env python3
"""W46.p17-gemma-route-fields: score the Processor's local Gemma label route.

Run under heavy-run.py with the MLX lab Python. This uses the frozen upright
label photos and the app's Swift JPEG encoder, with a loopback-only MLX server.
The resumable cache holds per-photo correctness flags and timings only.
"""
import argparse
import base64
from contextlib import contextmanager
import ctypes
import hashlib
from importlib.metadata import version
import json
import os
import random
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import ct_gemma_route as G
import ct_read as R
import model_store


BASELINE = 60
TOTAL = 195
IN_PROCESS = "gemma3-12b-mlx4"
OUT = Path(R.OUT) / "gemma-route-fields.json"
REPORT = Path(__file__).resolve().parents[2] / "segbench-results/ct-gemma-route-fields.md"
BOOTSTRAP = 10_000
APP = Path(__file__).resolve().parents[2] / "macOS/Sources/ArchiveProcessor"
MODEL_REVISION = "86cc6a8dedbc456dd0e4af01a9d09f396f77e558"
SERVER_VERSION = "0.7.4"
ENCODER = """
import Foundation

let photo = URL(fileURLWithPath: CommandLine.arguments[1])
guard let jpeg = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: 0, longEdge: 1600) else {
    fatalError("Could not encode the benchmark photo")
}
FileHandle.standardOutput.write(jpeg)
"""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


LOCAL = build_opener(ProxyHandler({}), NoRedirect())


def json_request(url, body=None):
    if body is None:
        request = Request(url)
    else:
        request = Request(url, data=json.dumps(body).encode(), method="POST",
                          headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    with LOCAL.open(request, timeout=180 if body else 3) as response:
        return json.load(response)


def server_body(model, jpeg, text_first=False):
    data_url = "data:image/jpeg;base64," + base64.b64encode(jpeg).decode("ascii")
    image = {"type": "image_url", "image_url": {"url": data_url}}
    text = {"type": "text", "text": R.PROMPT}
    return {
        "model": model, "temperature": 0, "max_tokens": R.MAX_TOKENS, "stream": False,
        "messages": [{"role": "user", "content": [text, image] if text_first else [image, text]}],
        "enable_thinking": False, "chat_template_kwargs": {"enable_thinking": False}, "think": False,
    }


@contextmanager
def server(port, *, with_pid=False):
    if version("mlx-vlm") != SERVER_VERSION:
        raise RuntimeError(f"This comparison needs mlx-vlm {SERVER_VERSION}")
    model_store.use()
    if Path(os.environ["HF_HOME"]).resolve() != model_store.HF_HOME.resolve():
        raise RuntimeError("Use the bench's pinned local model cache")
    if not model_store.snapshot(G.MODEL, MODEL_REVISION).is_dir():
        raise RuntimeError("Pinned Gemma snapshot missing from model cache")
    if (model_store.HUB / ("models--" + G.MODEL.replace("/", "--")) / "refs/main").read_text().strip() != MODEL_REVISION:
        raise RuntimeError("Cache's main ref differs from the benchmark snapshot")
    env = dict(os.environ, HF_HUB_CACHE=str(model_store.HUB), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    base = f"http://127.0.0.1:{port}/v1"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))
    child = subprocess.Popen(
        [sys.executable, "-m", "mlx_vlm.server", "--host", "127.0.0.1", "--port", str(port), "--model", G.MODEL],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(180):
            if child.poll() is not None:
                raise RuntimeError(f"MLX server exited during startup ({child.returncode})")
            try:
                listed = [m["id"] for m in json_request(base + "/models")["data"]]
            except OSError:
                time.sleep(1)
                continue
            if child.poll() is not None or G.pick(listed) != G.MODEL:
                raise RuntimeError("The loopback server did not select the pinned Gemma model")
            yield (base, child.pid) if with_pid else base
            return
        raise RuntimeError("MLX server did not become ready")
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def encoder(folder):
    main = Path(folder) / "main.swift"
    main.write_text(ENCODER, encoding="utf-8")
    binary = Path(folder) / "encode"
    subprocess.run(["swiftc", str(APP / "OCR/ImageEncoding.swift"), str(main), "-o", str(binary)], check=True)
    return binary


def read_server(base, jpeg, text_first=False):
    start = time.monotonic()
    reply = json_request(base + "/chat/completions", server_body(G.MODEL, jpeg, text_first))["choices"][0]
    finish = reply.get("finish_reason")
    raw = reply["message"].get("content") or ""
    # Match LocalModelRoute for completed replies, then apply the same bench parser to all Gemma arms.
    while (opening := raw.find("<think>")) >= 0:
        closing = raw.find("</think>", opening)
        if closing < 0:
            raw = ""
            break
        raw = raw[:opening] + raw[closing + len("</think>"):]
    if "</think>" in raw:
        raw = raw.split("</think>", 1)[1]
    return (R.parse(raw) if finish != "length" else None), round(time.monotonic() - start, 2), finish


def inputs():
    rows = {r["id"]: r for r in R.truth()}
    ids = G.sample(TOTAL)
    if len(ids) != TOTAL or len(rows) != TOTAL:
        raise RuntimeError("The complete 195-photo truth and paired in-process replies are required")
    if not all(any((Path(d) / f"{mid}.json").is_file() for d in (R.FINAL_LINES, R.REV_LINES)) for mid in ids):
        raise RuntimeError("Vision line caches are missing from the frozen panel")
    return rows, ids


def correct(field, answer, truth):
    return R.same(field, (answer or {}).get(field), truth)


def original_panel(rows, ids):
    """Recover the pilot's per-field pairs, checking its stored pairing against today's inputs."""
    rec = json.loads(Path(G.OUT).read_text(encoding="utf-8"))
    if rec["photos"] != BASELINE or len(rec["calls"]) != BASELINE:
        raise RuntimeError("The original 60-photo counts are required")
    panel = []
    for mid, call in zip(ids[:BASELINE], rec["calls"]):
        row = rows[mid]
        vision = R.reading(row, "vision")
        in_process = R.reading(row, IN_PROCESS)
        expected = {f for f in G.FOUR if not R.cell_class(row, f).startswith("out")}
        if expected != call["right"].keys():
            raise RuntimeError("Pilot scoring mask differs from the current truth")
        cells = {}
        for field, (app, original) in call["right"].items():
            truth = row["fields"].get(field)
            if original != correct(field, in_process, truth):
                raise RuntimeError("Pilot pairing with the in-process reading has changed")
            cells[field] = [app, original, correct(field, vision, truth)]
        panel.append(dict(cells=cells, wall_s=call["wall_s"], parsed=call["parsed"]))
    return panel


def store(cache, record):
    temp = cache.with_suffix(".tmp")
    temp.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
    temp.replace(cache)


def collect(rows, ids, record, cache, port, limit):
    calls = record["holdout"]
    target = len(ids) if limit is None else min(len(ids), len(calls) + limit)
    if target == len(calls):
        return
    with tempfile.TemporaryDirectory(prefix="ct-gemma-encode-") as folder:
        binary = encoder(folder)
        with server(port) as base:
            print("Pinned Gemma server ready on loopback", flush=True)
            for index in range(len(calls), target):
                mid = ids[index]
                row = rows[mid]
                jpeg = subprocess.check_output([binary, R.page_of(mid)])
                answer, wall, finish = read_server(base, jpeg)
                original = R.reading(row, IN_PROCESS)
                vision = R.reading(row, "vision")
                cells = {}
                for field in G.FOUR:
                    source = R.cell_class(row, field)
                    if source.startswith("out"):
                        continue
                    want = row["fields"].get(field)
                    values = [(prediction or {}).get(field) for prediction in (answer, original, vision)]
                    cells[field] = {
                        "right": [R.same(field, value, want) for value in values],
                        "filled": [bool(value) for value in values],
                        "truth_filled": bool(want), "rule": source == "rule",
                    }
                calls.append(dict(cells=cells, folder=row["colour"] == "Purple",
                                  wall_s=wall, parsed=answer is not None, finish=finish))
                store(cache, record)
                print(f"Held-out label {index + 1}/{len(ids)}: {wall:.2f}s, parsed={answer is not None}", flush=True)



NUMBER = "collection_number"
# Same endpoint, same request settings. Only the JPEG bytes and image marker position vary.
CONTROLS = {
    "app_image_first": (False, False),
    "app_text_first": (False, True),
    "source_image_first": (True, False),
    "source_text_first": (True, True),
}


def diagnostic_selection(holdout):
    present, blanks = [], []
    for index, call in enumerate(holdout):
        cell = call["cells"].get(NUMBER)
        if cell:
            (present if cell["truth_filled"] else blanks).append(index)
    rng = random.Random(R.SEED + 1)
    sample = rng.sample(blanks, 15)
    repeats = set(rng.sample(present, 9) + rng.sample(sample, 3))
    return sorted(present + sample), repeats


def diagnose(rows, ids, record, cache, port):
    """Run the crossed JPEG and chat-order controls on every present number and 15 fixed blanks."""
    holdout = record["holdout"]
    if len(holdout) != TOTAL - BASELINE:
        raise RuntimeError("Finish the held-out panel before running the diagnosis")
    indices, repeats = diagnostic_selection(holdout)
    calls = record.setdefault("diagnosis", [])
    if len(calls) == len(indices):
        return
    with tempfile.TemporaryDirectory(prefix="ct-gemma-diagnostic-") as folder:
        binary = encoder(folder)
        with server(port) as base:
            print("Gemma collection-number controls ready on loopback", flush=True)
            for index in indices[len(calls):]:
                mid = ids[index]
                path = Path(R.page_of(mid))
                want = rows[mid]["fields"].get(NUMBER)
                jpeg = {False: subprocess.check_output([binary, path]), True: path.read_bytes()}
                arms = [arm for arm in CONTROLS if arm != "app_image_first" or index in repeats]
                random.Random(R.SEED + index).shuffle(arms)
                calls_at_photo = {}
                for arm in arms:
                    source, text_first = CONTROLS[arm]
                    prediction, wall, finish = read_server(base, jpeg[source], text_first)
                    value = (prediction or {}).get(NUMBER)
                    calls_at_photo[arm] = dict(right=R.same(NUMBER, value, want), filled=bool(value),
                                               wall_s=wall, finish=finish, parsed=prediction is not None)
                calls.append(calls_at_photo)
                store(cache, record)
                print(f"Diagnostic label {len(calls)}/{len(indices)} done ({len(arms)} requests)", flush=True)


def footprint_reader(pid):
    """Read macOS physical footprint, including memory charged to the server for GPU work."""
    # sys/resource.h: rusage_info_v0 starts with a 16-byte UUID, then ten uint64 fields.
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    rusage = libproc.proc_pid_rusage
    rusage.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
    rusage.restype = ctypes.c_int

    def footprint():
        usage = (ctypes.c_uint64 * 12)()
        if rusage(pid, 0, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
        return usage[9]  # ri_phys_footprint
    return footprint


def measured_request(base, footprint, jpeg, text_first):
    """Sample the server footprint during a single request, including its warm model."""
    stop = threading.Event()
    samples = [footprint()]
    failures = []

    def sample():
        while not stop.wait(0.1):
            try:
                samples.append(footprint())
            except OSError as error:
                failures.append(error)
                return

    thread = threading.Thread(target=sample)
    thread.start()
    try:
        prediction, wall, finish = read_server(base, jpeg, text_first)
    finally:
        stop.set()
        thread.join()
    if failures:
        raise failures[0]
    peak = max(*samples, footprint())
    return prediction, dict(wall_s=wall, peak_bytes=peak, jpeg_bytes=len(jpeg),
                            parsed=prediction is not None, finish=finish)


def validation_jpeg(path, binary, text_first):
    return path.read_bytes() if text_first else subprocess.check_output([binary, path])


def validate(rows, ids, record, cache, port, limit):
    """Compare both external Gemma settings on every held-out label, with fresh reads."""
    if len(record["holdout"]) != len(ids) - BASELINE:
        raise RuntimeError("Finish the held-out panel before running validation")
    calls = record.setdefault("validation", [])
    holdout_ids = ids[BASELINE:]
    target = len(holdout_ids) if limit is None else min(len(holdout_ids), len(calls) + limit)
    if len(calls) >= target:
        return
    with tempfile.TemporaryDirectory(prefix="ct-gemma-validation-") as folder:
        binary = encoder(folder)
        with server(port, with_pid=True) as (base, pid):
            footprint = footprint_reader(pid)
            warmup = Path(R.page_of(ids[0]))
            for revised in (False, True):
                read_server(base, validation_jpeg(warmup, binary, revised), revised)
            print("Gemma validation server warmed on a pilot photo", flush=True)
            for index in range(len(calls), target):
                row = rows[holdout_ids[index]]
                path = Path(R.page_of(row["id"]))
                order = [False, True]
                random.Random(R.SEED + index).shuffle(order)
                metrics, predictions = {}, {}
                for revised in order:
                    start = time.monotonic()
                    jpeg = validation_jpeg(path, binary, revised)
                    preparation = time.monotonic() - start
                    predictions[revised], metrics[revised] = measured_request(base, footprint, jpeg, revised)
                    metrics[revised]["prepare_s"] = round(preparation, 4)
                cells = {}
                for field, control in record["holdout"][index]["cells"].items():
                    want = row["fields"].get(field)
                    values = [(predictions[arm] or {}).get(field) for arm in (False, True)]
                    cells[field] = dict(right=[R.same(field, value, want) for value in values],
                                        filled=[bool(value) for value in values],
                                        truth_filled=control["truth_filled"])
                calls.append(dict(cells=cells, baseline=metrics[False], revised=metrics[True]))
                store(cache, record)
                print(f"Validation label {len(calls)}/{len(holdout_ids)} done (two requests)", flush=True)


def paired_interval(pairs, first, second):
    """One matched photo per pair for this field, including skipped replies as absent values."""
    differences = [int(pair[first]) - int(pair[second]) for pair in pairs]
    n = len(differences)
    if not n:
        raise ValueError("No eligible pairs")
    rng = random.Random(R.SEED)
    boot = sorted(sum(differences[rng.randrange(n)] for _ in pairs) for _ in range(BOOTSTRAP))
    return tuple(100 * total / n for total in
                 (sum(differences), boot[BOOTSTRAP // 40], boot[BOOTSTRAP - 1 - BOOTSTRAP // 40]))


def gap_text(gap):
    delta, lower, upper = gap
    return f"{delta:+.1f} ({lower:+.1f} to {upper:+.1f})"


def comparison(pairs):
    n = len(pairs)
    return [str(n), *[f"{right}/{n} ({100 * right / n:.1f}%)" for right in map(sum, zip(*pairs))],
            gap_text(paired_interval(pairs, 0, 1)), gap_text(paired_interval(pairs, 0, 2))]


def field_pairs(panel, *, pilot=False):
    return {field: [call["cells"][field] if pilot else call["cells"][field]["right"]
                    for call in panel if field in call["cells"]] for field in G.FOUR}


def table(headings, rows):
    return ["| " + " | ".join(headings) + " |", "| " + " | ".join(["---"] * len(headings)) + " |",
            *["| " + " | ".join(row) + " |" for row in rows]]


def value_rows(holdout):
    for field in G.FOUR:
        cells = [call["cells"][field] for call in holdout if field in call["cells"]]
        present = [cell for cell in cells if cell["truth_filled"]]
        absent = [cell for cell in cells if not cell["truth_filled"]]
        for label, index in zip(("Server", "In-process", "Vision + parser"), range(3)):
            yield [field.replace("_", " ").capitalize(), label,
                   f"{sum(c['right'][index] for c in present)}/{len(present)}",
                   f"{sum(c['filled'][index] for c in absent)}/{len(absent)}"]


def interpretation(holdout, pairs):
    number_gap = paired_interval(pairs["collection_number"], 0, 1)
    if number_gap[2] < 0:
        number_result = "The held-out sample also puts the server below in-process Gemma on collection number."
    elif number_gap[1] > 0:
        number_result = "The held-out sample puts the server ahead of in-process Gemma on collection number."
    else:
        number_result = ("The held-out comparison does not confirm the pilot’s collection-number loss. Its interval "
                         "includes zero, leaving the size and direction of any difference unresolved.")
    breakdown = []
    for field in ("collection_number", "date"):
        eligible = [c["cells"][field]["right"] for c in holdout
                    if field in c["cells"] and not c["cells"][field]["rule"]]
        breakdown.append([field.replace("_", " ").capitalize(), *comparison(eligible)])
    boxes = [call["cells"]["collection_number"] for call in holdout
             if not call["folder"] and "collection_number" in call["cells"]]
    fallback_pairs = [(cell["right"][0] if cell["filled"][0] else cell["right"][2], cell["right"][2])
                      for cell in boxes]
    combined, vision = map(sum, zip(*fallback_pairs))
    return [number_result, "",
            "### The owner and unanimous-reader cells", "",
            "This sensitivity drops rule-settled cells to match the truth categories of the number and date headline "
            "in [the in-process report](ct-read.md).", "",
            *table(HEADINGS, breakdown), "",
            "### Collection-number proposals on box markers", "",
            f"On {len(boxes)} eligible box-marker cells, preferring a nonempty server reading and using the benchmark "
            f"Vision parser otherwise gets {combined} right, compared with {vision} for the parser alone. "
            f"The gap is {gap_text(paired_interval(fallback_pairs, 0, 1))} percentage points. "
            "This models field precedence with the benchmark parser. Folder proposals omit collection number.", ""]


def diagnostic_report(holdout, diagnosis):
    indices, repeats = diagnostic_selection(holdout)
    if not diagnosis:
        return []
    if len(diagnosis) != len(indices):
        raise RuntimeError("Complete the paired controls before reporting them")

    present, absent, present_boxes = [], [], []
    repeat_matches = repeat_present = 0
    for index, outcomes in zip(indices, diagnosis, strict=True):
        photo = holdout[index]
        cell = photo["cells"][NUMBER]
        if index in repeats:
            repeat = outcomes["app_image_first"]
            repeat_matches += (repeat["right"], repeat["filled"]) == (cell["right"][0], cell["filled"][0])
            repeat_present += cell["truth_filled"]
        app = {"right": cell["right"][0], "filled": cell["filled"][0], "parsed": photo["parsed"]}
        evidence = {**outcomes, "app_image_first": app, "in_process": {"right": cell["right"][1]}}
        (present if cell["truth_filled"] else absent).append(evidence)
        if cell["truth_filled"] and not photo["folder"]:
            present_boxes.append((evidence, cell["right"][2]))

    arms = (("App JPEG", "Image first", "app_image_first"),
            ("App JPEG", "Text first", "app_text_first"),
            ("Source JPEG", "Image first", "source_image_first"),
            ("Source JPEG", "Text first", "source_text_first"))
    accuracy = [[jpeg, order, f"{sum(c[k]['right'] for c in present)}/{len(present)}",
                 f"{sum(c[k]['filled'] for c in absent)}/{len(absent)}",
                 f"{sum(not c[k]['parsed'] for c in present + absent)}/{len(indices)}"]
                for jpeg, order, k in arms]
    contrasts = (("Text first less image first, app JPEG", "app_text_first", "app_image_first"),
                 ("Text first less image first, source JPEG", "source_text_first", "source_image_first"),
                 ("Source less app JPEG, image first", "source_image_first", "app_image_first"),
                 ("Source JPEG/text first less app JPEG/image first", "source_text_first", "app_image_first"),
                 ("Source less app JPEG, text first", "source_text_first", "app_text_first"),
                 ("Server source JPEG/text first less frozen in-process", "source_text_first", "in_process"))
    contrast_rows = [[name, gap_text(paired_interval([(c[a]["right"], c[b]["right"]) for c in present], 0, 1))]
                     for name, a, b in contrasts]
    interaction = [(c["source_text_first"]["right"] + c["app_image_first"]["right"],
                    c["source_image_first"]["right"] + c["app_text_first"]["right"]) for c in present]
    contrast_rows.insert(5, ["Text-first gain on source less its gain on app JPEG",
                             gap_text(paired_interval(interaction, 0, 1))])
    box_counts = [sum(row[key]["right"] if row[key]["filled"] else parser for row, parser in present_boxes)
                  for key in ("app_image_first", "source_text_first")]
    return [
        "## Collection-number controls", "",
        "All 60 eligible held-out photos with a collection number and a seeded draw of 15 of the 74 eligible "
        "blanks. The same mlx-vlm server received either the app JPEG or the source benchmark JPEG, and the "
        "same image and prompt in either order. Text first puts the image token after the prompt, as in the "
        "in-process benchmark. The other request settings were fixed. Variant order was shuffled within each photo.", "",
        *table(("JPEG", "Chat content order", "Correct where present", "Filled where absent", "Unparsed replies"), accuracy), "",
        "The app JPEG/image-first row comes from the held-out run. On the 12 same-setting repeats "
        f"({repeat_present} with a number), "
        f"the number correctness and value-presence flags agreed with the held-out reads on {repeat_matches}/12. "
        "The other three arms ran in the same diagnostic session.", "",
        *table(("Change on the 60 photos with a number", "Gap in points (95% paired interval)"), contrast_rows), "",
        "On the source JPEG, putting text first improved number accuracy. With text first, the source JPEG improved "
        "accuracy over the app JPEG. Each single change from the shipped setting had an interval containing zero. "
        "Together the changes recovered the same number correctness as frozen in-process Gemma on the 60 written "
        "numbers. The interaction interval reaches zero, so the data leave open how the two effects combine.", "",
        f"Among the {len(present_boxes)} box marks with a number, the modeled Gemma-first policy with the same "
        f"benchmark parser fallback got {box_counts[0]} right with the shipped settings and {box_counts[1]} with the "
        "combined variant. This describes the box subset with an answer in the truth. The diagnostics sampled only "
        "some of the blank cells.", "",
        "The JPEG comparison covers resizing and re-encoding together. The last comparison can also reflect "
        "differences in the server and in-process execution paths. The 15 blank photos give a limited check for "
        "false fills. Title, repository and date were outside these controls, as were the managed reader and "
        "other servers.", "",
    ]


def validation_report(holdout, calls):
    if not calls:
        return []
    if len(calls) != len(holdout):
        raise RuntimeError("Complete all held-out validation pairs before reporting them")

    accuracy, presence, box_pairs = [], [], []
    for field in G.FOUR:
        label = field.replace("_", " ").capitalize()
        cells = [call["cells"][field] for call in calls if field in call["cells"]]
        pairs = [cell["right"] for cell in cells]
        accuracy.append([label, str(len(cells)), *[f"{right}/{len(cells)}" for right in map(sum, zip(*pairs))],
                         gap_text(paired_interval(pairs, 1, 0))])
        present = [cell for cell in cells if cell["truth_filled"]]
        blank = [cell for cell in cells if not cell["truth_filled"]]
        presence.append([label, *[f"{sum(c['right'][arm] for c in present)}/{len(present)}" for arm in range(2)],
                         *[f"{sum(c['filled'][arm] for c in blank)}/{len(blank)}" for arm in range(2)],
                         gap_text(paired_interval([c["filled"] for c in blank], 1, 0))])

    repeats = {field: [0, 0] for field in G.FOUR}
    for prior, call in zip(holdout, calls, strict=True):
        if prior["cells"].keys() != call["cells"].keys():
            raise RuntimeError("Validation scoring mask differs from the original held-out run")
        for field, cell in call["cells"].items():
            first = prior["cells"][field]
            if first["truth_filled"] != cell["truth_filled"]:
                raise RuntimeError("Validation truth presence differs from the original held-out run")
            repeats[field][0] += (first["right"][0], first["filled"][0]) == (cell["right"][0], cell["filled"][0])
            repeats[field][1] += 1
        if prior["folder"] or NUMBER not in call["cells"]:
            continue
        cell = call["cells"][NUMBER]
        vision_correct = prior["cells"][NUMBER]["right"][2]
        box_pairs.append([right if filled else vision_correct
                          for right, filled in zip(cell["right"], cell["filled"], strict=True)])

    def summary(values, digits, scale=1):
        median = statistics.median(values) / scale
        upper = statistics.quantiles(values, n=20, method="inclusive")[-1] / scale
        return f"{median:.{digits}f} / {upper:.{digits}f}"

    resources = []
    for arm, name in (("baseline", "Current"), ("revised", "Revised")):
        metrics = [call[arm] for call in calls]
        resources.append([
            name, f"{sum(m['parsed'] for m in metrics)}/{len(metrics)}",
            str(sum(m["finish"] == "length" for m in metrics)),
            summary([m["jpeg_bytes"] for m in metrics], 2, 1e6),
            summary([m["wall_s"] for m in metrics], 2),
            summary([m["wall_s"] + m["prepare_s"] for m in metrics], 2),
            summary([m["peak_bytes"] for m in metrics], 2, 2**30),
            f"{max(m['peak_bytes'] for m in metrics) / 2**30:.2f}",
        ])
    return [
        "## Paired validation of the revised request", "",
        "Fresh pairs on all 135 held-out photos. The current arm uses the Swift encoder and puts the image first. "
        "The revised arm sends the source benchmark JPEG and puts text first. The same local server read both arms "
        "in a seeded shuffled order per photo. Both arms warmed up on a pilot photo when the server started for "
        "the first pair and again when the run resumed. Truth and scoring follow the held-out comparison. "
        "The intervals describe this cohort, which also supplied the earlier "
        "collection-number diagnostic.", "",
        *table(("Field", "Eligible cells", "Current correct", "Revised correct",
                "Revised less current (95% interval, points)"), accuracy), "",
        *table(("Field", "Current correct where present", "Revised correct where present",
                "Current false fills", "Revised false fills", "False-fill gap (95% interval, points)"), presence), "",
        "Correctness and presence flags agreed between the two runs of the current request on "
        + ", ".join(f"{n}/{total} {field.replace('_', ' ')} cells" for field, (n, total) in repeats.items())
        + ".", "",
        f"With the same benchmark Vision parser fallback, the current and revised routes got "
        f"{sum(pair[0] for pair in box_pairs)}/{len(box_pairs)} and {sum(pair[1] for pair in box_pairs)}/{len(box_pairs)} "
        f"box-marker collection numbers right, respectively ({gap_text(paired_interval(box_pairs, 1, 0))} points). "
        "That calculation uses a cached Vision reading when Gemma supplies no number.", "",
        *table(("Request", "Parseable", "Capped", "JPEG MB (median / p95)", "Request s (median / p95)",
                "With JPEG preparation s (median / p95)", "Server peak GiB (median / p95)",
                "Highest sampled GiB"), resources), "",
        "Request time includes JSON/base64 work and the loopback round trip. Preparation includes launching the "
        "Swift encoder for the current arm and reading the source JPEG for the revised arm. Server physical "
        "footprint was sampled at the start, every 100 ms during each request and at the end. Each request's maximum "
        "includes the warm model and allocations retained by the server. Sampling can miss shorter peaks. These "
        "timings and memory figures cover serial label reads, without an OCR model loaded alongside.", "",
        "The owner approved validation on 2026-11-23. The app continues to use the existing external request and "
        "Gemma-first/Vision-fallback collection-number rule. The source JPEGs here are already upright benchmark "
        "inputs. A production change requires a separate decision.", "",
    ]


HEADINGS = ("Field", "Eligible cells", "Gemma through the server", "Gemma in-process", "Vision + parser",
            "Server less in-process (95% interval)", "Server less Vision (95% interval)")


def report(pilot, holdout, diagnosis, validation=None):
    paired = field_pairs(holdout)
    times = [c["wall_s"] for c in holdout]
    parsed = sum(c["parsed"] for c in holdout)
    capped = sum(c["finish"] == "length" for c in holdout)
    return "\n".join([
        "# Gemma label fields through the Processor’s image path", "",
        "W46.p17-gemma-route-fields · Gemma 3 12B IT, MLX 4-bit · local mlx-vlm 0.7.4 on an 18 GB M3 Pro · $0.", "",
        "Generated by `scripts/segbench/ct_gemma_route_fields.py --report` from counts and the frozen comparator input.", "",
        "## Held-out 135 photos", "",
        "All four fields use the same photo and truth cell for all three readings. The server columns show exact "
        "normalized matches. Differences are in percentage points.", "",
        *table(HEADINGS, [[field.replace("_", " ").capitalize(), *comparison(values)]
                          for field, values in paired.items()]), "",
        f"The server returned {parsed} parseable replies for 135 photos. "
        f"{capped} replies reached the token limit and were scored as having no values. "
        f"Median request time was {statistics.median(times):.2f} s, with JPEG encoding outside the timer. "
        "No paid calls.", "",
        *interpretation(holdout, paired),
        "### When a value is present or absent", "",
        "A correct blank contributes to overall accuracy. These counts show how many actual values each route "
        "read correctly and how often it supplied a value where the truth was blank.", "",
        *table(("Field", "Route", "Correct where present", "Filled where absent"), value_rows(holdout)), "",
        "## Original 60-photo pilot", "",
        "The pilot used Pillow to approximate the app’s 1,600 px JPEG encoding. The held-out run called the Swift "
        "encoder itself. These tables describe the two cohorts separately.", "",
        *table(HEADINGS, [[field.replace("_", " ").capitalize(), *comparison(values)]
                          for field, values in field_pairs(pilot, pilot=True).items()]), "",
        *diagnostic_report(holdout, diagnosis),
        *validation_report(holdout, validation),
        "## Measurement card", "",
        "- **Truth.** The frozen W47.ct-truth-final label set. The owner’s answers and notes, rule-settled cells, "
        "and otherwise three unanimous drafts. Gemini 3.7 Flash, from Google like Gemma, was one of those drafters, "
        "alongside two Qwen readers. Gemma itself drafted none of the truth. The common scorer excludes carried, "
        "illegible, cut-off, and unresolved cells.",
        "- **Selection.** The 135 photos remaining after the fixed seed 4702 draw of 60. Cache preflight verified the "
        "195 truth photos, paired in-process replies and Vision line caches before collection. Reply quality did "
        "not select photos.",
        "- **Comparison.** The app’s ImageIO/CoreGraphics encoder with rotation zero on the already upright photos, "
        "1,600 px long-edge cap, JPEG quality 0.9. Same invented-example prompt, temperature 0, 640-token ceiling "
        "and reasoning off for server Gemma. Its request puts the image before the prompt text. The original "
        "in-process template puts the image token after the text and reads the source JPEG. In-process Gemma "
        "and cached Apple Vision with the bench’s pattern parser are the frozen ct-read comparators. "
        "A parse failure supplies no value. HTTP or transport failure stops "
        "the run so a connectivity problem cannot be mistaken for an absent label field.",
        "- **Noise.** 95% paired percentile bootstrap intervals over the eligible photos for each field "
        "(10,000 resamples). The collection-number comparison against in-process Gemma was specified before the "
        "held-out run. Other intervals are descriptive. One pass per route and cohort leaves rerun variation "
        "unmeasured for the frozen comparators and the revised request. The paired validation repeats the current "
        "server request and reports agreement with its original run. An interval containing zero leaves the direction "
        "unresolved.",
        "- **Scope.** External mlx-vlm server on this Mac, served the pinned Gemma snapshot, on one researcher’s "
        "held-out label photos. Ollama, LM Studio, the Processor-managed Gemma worker, and labels interleaved with "
        "an OCR model were outside this test. The scored fields use the benchmark normalization and parser.",
        "",
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18091)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--cache", type=Path, default=OUT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--report", action="store_true")
    mode.add_argument("--diagnose", action="store_true")
    mode.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    rows, ids = inputs()
    pilot = original_panel(rows, ids)
    # No photo identifiers in the counts file. Pin selection and ordering across restarts.
    fingerprint = hashlib.sha256("\n".join(ids).encode()).hexdigest()
    cache = args.cache
    record = (json.loads(cache.read_text(encoding="utf-8")) if cache.exists()
              else {"schema": 1, "panel": fingerprint, "holdout": []})
    if record.get("schema") != 1:
        raise RuntimeError("Unrecognized schema in the counts file")
    if record["panel"] != fingerprint:
        raise RuntimeError("The photo selection or order has changed since the counts were recorded")
    if args.report:
        if len(record["holdout"]) != TOTAL - BASELINE:
            raise RuntimeError("Run all 135 held-out photos before publishing a report")
        REPORT.write_text(report(pilot, record["holdout"], record.get("diagnosis"), record.get("validation")),
                          encoding="utf-8")
        print(REPORT)
    elif args.diagnose:
        diagnose(rows, ids[BASELINE:], record, cache, args.port)
    elif args.validate:
        validate(rows, ids, record, cache, args.port, args.limit)
    else:
        collect(rows, ids[BASELINE:], record, cache, args.port, args.limit)


if __name__ == "__main__":
    main()
