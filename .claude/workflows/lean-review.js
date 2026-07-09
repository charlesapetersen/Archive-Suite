export const meta = {
  name: 'lean-review',
  description: 'Paced, resumable lean code review of ONE subsystem unit (~6 finders + refute-verify) — sized to not blow a single usage window',
  whenToUse: 'Review one review UNIT at a time (see REVIEW.md). Pass args={unit,paths,dimensions?,focusNote?}. Run repeatedly, one unit per session, tracking progress in .maintenance/REVIEW_PROGRESS.md.',
  phases: [
    { title: 'Find', detail: 'one finder per dimension, scoped to this unit' },
    { title: 'Verify', detail: 'refute-by-default single verifier per finding' },
    { title: 'Synthesize', detail: 'rank confirmed findings, emit fix list' },
  ],
}

// ---------------------------------------------------------------------------
// Paced lean review of ONE unit. This is deliberately small: the 15-finder
// "suite-audit" monolith burned a whole usage window with 0 usable output
// (memory: overnight-jobs-queue). Here: ~6 dimension finders, each finding
// refuted-by-default ONCE (not a 3-lens panel), one unit per invocation.
// The CALLER decides which unit is next (reads REVIEW_PROGRESS.md) and passes
// it as `args`; this keeps orchestration resumable and the token cost bounded.
// ---------------------------------------------------------------------------

// Robustness: the harness may deliver `args` as an already-parsed object OR as a JSON-encoded STRING
// (observed 2026-07-08 — the first run got a string and silently fell back to UNSPECIFIED/empty scope).
// Normalize both so the unit is always scoped correctly.
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}

const unit = A.unit || 'UNSPECIFIED'
const paths = A.paths || ''
const focusNote = A.focusNote || ''

// Default review dimensions. Override per unit via args.dimensions (array of {key,prompt}).
const DEFAULT_DIMENSIONS = [
  { key: 'correctness', prompt: 'logic bugs, wrong/edge-case behavior, nil/optional force-unwraps, off-by-one, error paths that swallow or mis-handle failures, state that can desync' },
  { key: 'concurrency', prompt: 'Swift 6 strict-concurrency / actor-isolation defects: data races, missing @MainActor, non-Sendable captured across isolation, await gaps that let state change underneath, re-entrancy' },
  { key: 'file-safety', prompt: 'data-integrity / no-undo hazards: any write to a real corpus, finalize/move/organize output, tag/xattr writes, PDF render/merge — could it lose, overwrite, mis-file, or duplicate a document? (this dimension is PRIME for Reader TagWriter + Processor finalize)' },
  { key: 'protocol', prompt: 'contract conformance: relay object format, phone↔Mac wire protocol (group/seq/ack, resend, drain-gate), and the tag/PDF SPEC (tag vocabulary, 2-page PDF format, dates/priority/color/classification). Any divergence in how tags/format are written vs parsed?' },
  { key: 'resource-perf', prompt: 'leaks, retain cycles, unbounded growth, main-thread blocking work, O(n^2)/whole-collection re-computation on hot paths (e.g. per-keystroke), file handles / tasks not released' },
  { key: 'robustness', prompt: 'API misuse and fragile assumptions: force-try, unhandled throws, URL/regex/date/JSON misuse, assumptions about ordering/presence, missing timeouts/cancellation, silent catch-all' },
]
const dimensions = A.dimensions || DEFAULT_DIMENSIONS

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'summary', 'failure_scenario', 'severity'],
        properties: {
          file: { type: 'string', description: 'repo-relative path' },
          line: { type: 'integer', description: '1-indexed anchor line (0 if unknown)' },
          summary: { type: 'string', description: 'one-sentence defect statement' },
          failure_scenario: { type: 'string', description: 'concrete inputs/state -> wrong output/crash' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean', description: 'true if you CANNOT concretely confirm a real failing input->wrong-output (default true when uncertain)' },
    reason: { type: 'string', description: 'the concrete reproduction that confirms it, OR why it does not hold' },
    corrected_severity: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
}

log(`lean-review: unit="${unit}" paths="${paths}" (${dimensions.length} dimensions)`)

const results = await pipeline(
  dimensions,
  (d) => agent(
    `You are reviewing ONE subsystem of the Archive Suite: **${unit}**.\n` +
    `Scope your review to these paths ONLY: ${paths}\n` +
    (focusNote ? `Unit focus note: ${focusNote}\n` : '') +
    `Read the shared contract at SPEC/tag-format.md and SPEC/relay-object-format.md if your dimension touches tags/format/relay.\n\n` +
    `Find real, high-signal DEFECTS along this dimension: ${d.prompt}.\n\n` +
    `Rules: (1) Only report a defect you can tie to a CONCRETE failing input/state and a wrong result — no style nits, no "consider". ` +
    `(2) Cite file + line. (3) Prefer few real bugs over many speculative ones. ` +
    `(4) Use Read/Grep/Bash to actually inspect the code; do not guess. Return findings (empty array if none).`,
    { label: `find:${unit}:${d.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, model: 'opus', effort: 'max' }
  ).then((r) => ({ dim: d.key, findings: (r && r.findings) || [] })),

  // Verify EACH finding of this dimension as soon as the dimension's find completes (no barrier).
  (found) => parallel(
    found.findings.map((f) => () =>
      agent(
        `Adversarially VERIFY this claimed defect in the Archive Suite unit "${unit}".\n\n` +
        `File: ${f.file}:${f.line || '?'}\nClaim: ${f.summary}\nAlleged failure: ${f.failure_scenario}\n\n` +
        `Your job is to REFUTE it. Read the actual code and surrounding context. Set refuted=true unless you can ` +
        `state a concrete, realistic input/state that reaches this code and produces the wrong result. ` +
        `Default to refuted=true when uncertain, when the bad path is unreachable, or when existing guards prevent it.`,
        { label: `verify:${unit}:${f.file.split('/').pop()}:${f.line || 0}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'max' }
      ).then((v) => ({ ...f, dim: found.dim, verdict: v }))
    )
  )
)

// results = array (per dimension) of arrays (per finding) of verified findings.
const all = results.flat().filter(Boolean)
const confirmed = all
  .filter((f) => f.verdict && f.verdict.refuted === false)
  .map((f) => ({ ...f, severity: (f.verdict && f.verdict.corrected_severity) || f.severity }))
  .sort((a, b) => ({ high: 0, medium: 1, low: 2 }[a.severity] - { high: 0, medium: 1, low: 2 }[b.severity]))

phase('Synthesize')
log(`lean-review "${unit}": ${all.length} raw findings, ${confirmed.length} survived refute-verify`)

return {
  unit,
  paths,
  raw_count: all.length,
  confirmed,
  // keep the refuted ones too, so the caller can spot-check the verifier's calls
  refuted: all.filter((f) => !f.verdict || f.verdict.refuted !== false).map((f) => ({ file: f.file, line: f.line, summary: f.summary, reason: f.verdict && f.verdict.reason })),
}
