#!/usr/bin/env swift
import Foundation

// Standalone, $0, no-GUI, no-network test of the W13.cli-4 PIPELINE-WIRING decision logic:
//   (1) LocalAgentConfig.fromDefaults — reads the `useLocalAgent` XOR-backend choice + tool/path/model
//       out of UserDefaults into a config (or nil when the Local Agent backend is not selected); and
//   (2) the backend-PRECEDENCE + BATCH-SKIP invariants the construction sites enforce:
//         • prefer localAgent when set (localAgent > gateway > direct API), and
//         • batch + LLM-rotation are SKIPPED when the Local Agent backend is active (same as gateway).
//
// The two pure functions below are kept in sync with the real code:
//   • fromDefaultsLogic  ≙ LocalAgentConfig.fromDefaults (Models/LocalAgentConfig.swift)
//   • batchRuns/chosen   ≙ the guards at OCRProcessor+Pipeline.swift (batch dispatch + history) and the
//                          `if let localAgent … else if let gateway … else <provider>` client-construction
//                          order in LLMTextClient / performOCRCall / classifyViaLLM.
// If you change one, change both. Run:  swift ArchiveProcessor/scripts/localagent-wiring-test.swift
//
// (The in-app LocalAgentTestDriver drives the REAL performOCRCall(localAgent:) end-to-end against the
//  committed fake CLI; its RUN needs an app launch, so it is deferred — this proves the wiring logic
//  headlessly at $0, matching the mechanism/validator/pacing standalone tests.)

// ── Keys (copy of the four Local-Agent DefaultsKeys — Models/DefaultsKeys.swift). ──────────────────
let kUseLocalAgent = "useLocalAgent"
let kUseGateway = "useGateway"
let kTool = "localAgentTool"
let kPath = "localAgentBinaryPath"
let kModel = "localAgentModel"

// ── (1) COPY of LocalAgentConfig.fromDefaults (Models/LocalAgentConfig.swift). Keep in sync. ───────
struct Cfg: Equatable { let tool: String; let path: String; let model: String? }
func fromDefaultsLogic(_ d: UserDefaults) -> Cfg? {
    guard d.bool(forKey: kUseLocalAgent) else { return nil }
    // Real code: LocalAgentTool(rawValue:) ?? .claude — mirror the {claude,gemini,codex} whitelist here.
    let raw = d.string(forKey: kTool) ?? ""
    let tool = ["claude", "gemini", "codex"].contains(raw) ? raw : "claude"
    let path = d.string(forKey: kPath) ?? ""
    let model = d.string(forKey: kModel) ?? ""
    return Cfg(tool: tool, path: path, model: model.isEmpty ? nil : model)
}

// ── (2) COPY of the wiring invariants. Keep in sync. ───────────────────────────────────────────────
// Client-construction order at every seam: localAgent wins, then gateway, then the direct provider path.
func chosenBackend(localAgent: Bool, gateway: Bool) -> String {
    if localAgent { return "localAgent" }
    if gateway { return "gateway" }
    return "direct"
}
// Batch dispatch guard (OCRProcessor+Pipeline.swift): batch runs ONLY on the direct provider path.
func batchRuns(batchMode: Bool, supportsBatch: Bool, gateway: Bool, localAgent: Bool) -> Bool {
    batchMode && supportsBatch && !gateway && !localAgent
}
// LLM comparative rotation is skipped for gateway AND localAgent → local Vision fallback.
func llmRotationSkipped(gateway: Bool, localAgent: Bool) -> Bool { gateway || localAgent }

// ── Harness ────────────────────────────────────────────────────────────────────────────────────────
var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1; print("  ✓ \(name)") } else { fail += 1; print("  ✗ FAIL: \(name)") }
}
func freshDefaults() -> UserDefaults {
    let name = "localagent-wiring-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)   // start clean (no inherited keys)
    return d
}

print("=== LocalAgent wiring test (W13.cli-4) ===")

// (1) fromDefaults decision table.
print("[1] LocalAgentConfig.fromDefaults")
do {
    let d = freshDefaults()
    check("backend not selected (no keys) ⇒ nil", fromDefaultsLogic(d) == nil)
}
do {
    let d = freshDefaults(); d.set(false, forKey: kUseLocalAgent)
    check("useLocalAgent=false ⇒ nil", fromDefaultsLogic(d) == nil)
}
do {
    let d = freshDefaults(); d.set(true, forKey: kUseLocalAgent)
    check("useLocalAgent=true, defaults ⇒ claude / blank path / nil model",
          fromDefaultsLogic(d) == Cfg(tool: "claude", path: "", model: nil))
}
do {
    let d = freshDefaults()
    d.set(true, forKey: kUseLocalAgent); d.set("gemini", forKey: kTool)
    d.set("/opt/homebrew/bin/gemini", forKey: kPath); d.set("gemini-2.5-pro", forKey: kModel)
    check("tool/path/model all honored",
          fromDefaultsLogic(d) == Cfg(tool: "gemini", path: "/opt/homebrew/bin/gemini", model: "gemini-2.5-pro"))
}
do {
    let d = freshDefaults()
    d.set(true, forKey: kUseLocalAgent); d.set("not-a-tool", forKey: kTool)
    check("unknown tool rawValue ⇒ defaults to claude", fromDefaultsLogic(d)?.tool == "claude")
}
do {
    let d = freshDefaults()
    d.set(true, forKey: kUseLocalAgent); d.set("   ", forKey: kModel)
    // Real code treats only "" as nil; a whitespace override is passed through verbatim (CLI's problem).
    check("blank ('') model ⇒ nil override", { let d2 = freshDefaults(); d2.set(true, forKey: kUseLocalAgent); d2.set("", forKey: kModel); return d2.bool(forKey: kUseLocalAgent) && fromDefaultsLogic(d2)?.model == nil }())
}

// (2) backend precedence — localAgent wins over gateway; both-unset ⇒ direct.
print("[2] Construction-site precedence (localAgent > gateway > direct)")
check("localAgent set ⇒ localAgent", chosenBackend(localAgent: true, gateway: false) == "localAgent")
check("localAgent set even if gateway set ⇒ localAgent (prefer it)", chosenBackend(localAgent: true, gateway: true) == "localAgent")
check("gateway only ⇒ gateway", chosenBackend(localAgent: false, gateway: true) == "gateway")
check("neither ⇒ direct provider", chosenBackend(localAgent: false, gateway: false) == "direct")

// (3) batch is skipped whenever localAgent (or gateway) is active.
print("[3] Batch skip when Local Agent active")
check("direct + batchable ⇒ batch RUNS", batchRuns(batchMode: true, supportsBatch: true, gateway: false, localAgent: false) == true)
check("localAgent active ⇒ batch SKIPPED", batchRuns(batchMode: true, supportsBatch: true, gateway: false, localAgent: true) == false)
check("gateway active ⇒ batch SKIPPED", batchRuns(batchMode: true, supportsBatch: true, gateway: true, localAgent: false) == false)
check("provider !supportsBatch ⇒ SKIPPED regardless", batchRuns(batchMode: true, supportsBatch: false, gateway: false, localAgent: false) == false)
check("batchMode off ⇒ SKIPPED", batchRuns(batchMode: false, supportsBatch: true, gateway: false, localAgent: false) == false)

// (4) LLM comparative rotation skipped for localAgent (same as gateway) → local Vision fallback.
print("[4] LLM rotation skip when Local Agent active")
check("localAgent ⇒ LLM rotation skipped", llmRotationSkipped(gateway: false, localAgent: true) == true)
check("gateway ⇒ LLM rotation skipped", llmRotationSkipped(gateway: true, localAgent: false) == true)
check("direct ⇒ LLM rotation allowed", llmRotationSkipped(gateway: false, localAgent: false) == false)

print("")
print("\(pass) passed, \(fail) failed")
if fail == 0 { print("ALL PASS") } else { print("SOME FAILED") }
exit(fail == 0 ? 0 : 1)
