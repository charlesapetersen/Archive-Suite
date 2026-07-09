export const meta = {
  name: 'review-sweep',
  description: 'Parallel lean review of MANY subsystem units at once — for when there is usage headroom and you want all findings fast (vs lean-review one-unit-per-session)',
  whenToUse: 'When you have spare usage and want to front-load bug discovery across a FEW units at once. Read-only. Pass args={units:[{unit,paths,focusNote?}]}. CAP AT ~2-3 UNITS PER RUN: an 8-unit sweep is ~80 agents/~3M tokens and hits the session usage cap mid-run (verifiers die → raw, unverified findings). See REVIEW.md "Batch sizing". Default to the paced daemon (lean-review, one unit/session) for the full codebase.',
  phases: [
    { title: 'Find', detail: 'every unit × 6 dimensions, all in parallel (global cap throttles)' },
    { title: 'Verify', detail: 'refute-by-default single verifier per finding' },
    { title: 'Synthesize', detail: 'per-unit confirmed findings, ranked' },
  ],
}

// Same finder/verify contract as .claude/workflows/lean-review.js, but fans out over N units at once.
// This is the "usage-headroom" variant: ~N×6 finders + verifiers run concurrently (capped internally),
// turning a multi-hour serial review into one ~30-min burst. Read-only — the caller triages the results.

let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}
const units = (A.units || []).filter((u) => u && u.unit && u.paths)

const DEFAULT_DIMENSIONS = [
  { key: 'correctness', prompt: 'logic bugs, wrong/edge-case behavior, nil/optional force-unwraps, off-by-one, error paths that swallow or mis-handle failures, state that can desync' },
  { key: 'concurrency', prompt: 'Swift 6 strict-concurrency / actor-isolation defects: data races, missing @MainActor, non-Sendable captured across isolation, await gaps that let state change underneath, re-entrancy' },
  { key: 'file-safety', prompt: 'data-integrity / no-undo hazards: any write to a real corpus, finalize/move/organize output, tag/xattr writes, PDF render/merge — could it lose, overwrite, mis-file, or duplicate a document? (PRIME for Reader TagWriter + Processor finalize)' },
  { key: 'protocol', prompt: 'contract conformance: relay object format, phone↔Mac wire protocol (group/seq/ack, resend, drain-gate), and the tag/PDF SPEC (tag vocabulary, 2-page PDF format, dates/priority/color/classification). Any divergence in how tags/format are written vs parsed?' },
  { key: 'resource-perf', prompt: 'leaks, retain cycles, unbounded growth, main-thread blocking work, O(n^2)/whole-collection re-computation on hot paths, file handles / tasks not released' },
  { key: 'robustness', prompt: 'API misuse and fragile assumptions: force-try, unhandled throws, URL/regex/date/JSON misuse, assumptions about ordering/presence, missing timeouts/cancellation, silent catch-all' },
]

const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: { findings: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['file', 'summary', 'failure_scenario', 'severity'],
    properties: {
      file: { type: 'string' }, line: { type: 'integer' },
      summary: { type: 'string' }, failure_scenario: { type: 'string' },
      severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    } } } },
}
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean' }, reason: { type: 'string' },
    corrected_severity: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
}
const rank = { high: 0, medium: 1, low: 2 }

function reviewUnit(u) {
  const dims = u.dimensions || DEFAULT_DIMENSIONS
  const focusNote = u.focusNote || ''
  return pipeline(
    dims,
    (d) => agent(
      `You are reviewing ONE subsystem of the Archive Suite: **${u.unit}**.\n` +
      `Scope your review to these paths ONLY: ${u.paths}\n` +
      (focusNote ? `Unit focus note: ${focusNote}\n` : '') +
      `Read SPEC/tag-format.md and SPEC/relay-object-format.md if your dimension touches tags/format/relay.\n\n` +
      `Find real, high-signal DEFECTS along this dimension: ${d.prompt}.\n\n` +
      `Rules: (1) Only report a defect you can tie to a CONCRETE failing input/state and a wrong result — no ` +
      `style nits. (2) Cite file + line. (3) Prefer few real bugs over many speculative ones. (4) Use ` +
      `Read/Grep/Bash to inspect the code; do not guess. Return findings (empty array if none).`,
      { label: `find:${u.unit}:${d.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, model: 'opus', effort: 'max' }
    ).then((r) => ({ dim: d.key, findings: (r && r.findings) || [] })),

    (found) => parallel(
      found.findings.map((f) => () =>
        agent(
          `Adversarially VERIFY this claimed defect in the Archive Suite unit "${u.unit}".\n\n` +
          `File: ${f.file}:${f.line || '?'}\nClaim: ${f.summary}\nAlleged failure: ${f.failure_scenario}\n\n` +
          `Your job is to REFUTE it. Read the actual code + surrounding context. Set refuted=true unless you ` +
          `can state a concrete, realistic input/state that reaches this code and produces the wrong result. ` +
          `Default refuted=true when uncertain, when the path is unreachable, or when existing guards prevent it.`,
          { label: `verify:${u.unit}:${(f.file || '').split('/').pop()}:${f.line || 0}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'max' }
        ).then((v) => ({ ...f, dim: found.dim, verdict: v }))
      )
    )
  ).then((perDim) => {
    const all = perDim.flat().filter(Boolean)
    const confirmed = all
      .filter((f) => f.verdict && f.verdict.refuted === false)
      .map((f) => ({ ...f, severity: (f.verdict && f.verdict.corrected_severity) || f.severity }))
      .sort((a, b) => rank[a.severity] - rank[b.severity])
    return {
      unit: u.unit, paths: u.paths, raw_count: all.length, confirmed,
      refuted: all.filter((f) => !f.verdict || f.verdict.refuted !== false)
        .map((f) => ({ file: f.file, line: f.line, summary: f.summary, reason: f.verdict && f.verdict.reason })),
    }
  })
}

log(`review-sweep: ${units.length} units in parallel — ${units.map((u) => u.unit).join(', ')}`)
const results = (await parallel(units.map((u) => () => reviewUnit(u)))).filter(Boolean)
phase('Synthesize')
const totalConfirmed = results.reduce((n, r) => n + r.confirmed.length, 0)
log(`review-sweep done: ${results.length} units, ${totalConfirmed} confirmed findings total`)
return { units: results, totalConfirmed }
