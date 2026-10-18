#!/usr/bin/env python3
"""W41.farmshare-plan — ESTIMATED pages an hour per L40S and GPU-hours per 100,000 pages. Not a measurement.

  estimate.py            # prints the Markdown table README.md carries

Per page, the GPU does three things, each costed from parameter counts:
  prefill  2 x active LM params x (prompt tokens)          compute-bound    at MFU x peak
  vision   2 x vision-tower params x (4 x image tokens)    compute-bound    (patches before the 2x2 merge)
  decode   output tokens, batched B at a time: each step reads the weights once (memory-bound) and does
           2 x active params x B of compute; the slower of the two sets the step.
Optimistic: MFU 40%, 80% of memory bandwidth, prefill and decode overlapped (vLLM's chunked prefill).
Conservative: MFU 20%, 60% of bandwidth, no overlap. The truth-set job measures the real figure.

Token counts are MEASURED: medians/means of the panels' OpenRouter replies on the 99 truth originals
(~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-{local,cloud}/responses, read 2026-10-15). The Qwen image count
(4,573 a page at the 2400 px cap) is what Chutes, which serves Qwen's own processor, reported; other providers
resized and reported ~1,345, so vLLM with Qwen's defaults is taken to be the 4,573 case. Newspaper pages are
NOT measured: NewsBench's scored pages hold 1,892-5,464 words (mean 3,603); at ~1.35 tokens a word that is
~4,900 output tokens, and a 3584 px cap gives ~10,000 image tokens.
"""
from __future__ import annotations

L40S = {'fp8': 362e12, 'bf16': 181e12, 'bw': 864e9, 'mem': 48e9}  # NVIDIA datasheet, dense (no sparsity)
VIT = 0.6e9          # assumption: Qwen3.x vision tower size, the same order as Qwen2.5-VL's 0.67B
BATCH = 32           # --max-num-seqs in models.sh
PHOTO = {'prompt': 4573 + 300, 'image': 4573, 'output': 460}   # +300: the panel prompt's text tokens
NEWS = {'prompt': 10000 + 300, 'image': 10000, 'output': 4900}

# name: (active LM params, total params read per decode step, bytes/param, precision for compute, GPUs, panel NES)
CANDIDATES = {
    'Qwen3.6 27B fp8 (1 GPU)': (27.2e9, 27.8e9, 1, 'fp8', 1, '94.28'),
    'Qwen3.6 35B-A3B fp8 (1 GPU)': (3.0e9, 35.9e9, 1, 'fp8', 1, '93.02'),
    'Qwen3-VL 8B bf16 (1 GPU)': (8.2e9, 8.8e9, 2, 'bf16', 1, '91.81'),
    'Qwen3.5 27B fp8 (1 GPU; segmentation)': (27.2e9, 27.8e9, 1, 'fp8', 1, '81.80*'),
    'Qwen3.5 122B-A10B fp8 (4 GPUs)': (10e9, 122e9, 1, 'fp8', 4, 'unmeasured'),
}


def seconds_per_page(c, page, mfu, bw_frac, overlap):
    active, total, bpp, prec, gpus, _ = c
    flops = L40S[prec] * mfu * gpus
    prefill = 2 * active * page['prompt'] / flops
    vision = 2 * VIT * 4 * page['image'] / flops
    step_mem = total * bpp / (L40S['bw'] * bw_frac * gpus)
    step_compute = 2 * active * BATCH / flops
    decode = page['output'] * max(step_mem, step_compute) / BATCH
    return max(prefill + vision, decode) if overlap else prefill + vision + decode


def table():
    rows = ['| candidate | panel NES | photos/h/GPU | GPU-h per 100k photos | newspaper pages/h/GPU | GPU-h per 100k newspaper pages |',
            '|---|---:|---:|---:|---:|---:|']
    for name, c in CANDIDATES.items():
        gpus = c[4]
        cells = []
        for page in (PHOTO, NEWS):
            hi = 3600 / seconds_per_page(c, page, 0.40, 0.80, True) / gpus
            lo = 3600 / seconds_per_page(c, page, 0.20, 0.60, False) / gpus
            cells += [f'{lo:,.0f}-{hi:,.0f}', f'{1e5 / hi:,.0f}-{1e5 / lo:,.0f}']
        rows.append(f'| {name} | {c[5]} | {cells[0]} | {cells[1]} | {cells[2]} | {cells[3]} |')
    return '\n'.join(rows)


if __name__ == '__main__':
    print(table())
