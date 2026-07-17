#!/usr/bin/env swift
import Foundation

// Standalone, $0, no-GUI, no-network test of the LocalAgent backend's two riskiest pieces:
//   (1) the SUBPROCESS PLUMBING — spawn / stdin-feed / concurrent-drain / hard-timeout — exercised
//       against the committed fake CLI (scripts/localagent-fake-cli.sh); and
//   (2) the Codable BACK-COMPAT SEMANTICS that make the PendingRun `localAgent` carrier resume-safe.
//
// The `runProcess` below is kept BYTE-IDENTICAL to LocalAgentClient.runProcess (OCR/LocalAgentClient.swift).
// If you change one, change both. Run:  swift ArchiveProcessor/scripts/localagent-mechanism-test.swift
//
// (The in-app LocalAgentTestDriver drives the REAL LocalAgentClient end-to-end against the same fake
// CLI; its RUN needs an app launch, so it is deferred — this standalone proves the mechanism headlessly.)

// ---------------------------------------------------------------------------------------------------
// COPY of LocalAgentClient.runProcess (+ its CLIRun / PipeSink). Keep in sync.
struct CLIRun: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let spawnFailed: Bool
}
final class PipeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func set(_ d: Data) { lock.lock(); buf = d; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return buf }
}
func runProcess(binaryPath: String, args: [String], stdinText: String, timeout: TimeInterval) -> CLIRun {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: binaryPath)
    proc.arguments = args
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CLAUDECODE")
    proc.environment = env

    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    do { try proc.run() } catch {
        return CLIRun(exitCode: -1, stdout: "", stderr: "", timedOut: false, spawnFailed: true)
    }

    let outSink = PipeSink(), errSink = PipeSink()
    let group = DispatchGroup()
    for (handle, sink) in [(outPipe.fileHandleForReading, outSink), (errPipe.fileHandleForReading, errSink)] {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            sink.set(handle.readDataToEndOfFile())
            group.leave()
        }
    }

    let inHandle = inPipe.fileHandleForWriting
    if let data = stdinText.data(using: .utf8) { try? inHandle.write(contentsOf: data) }
    try? inHandle.close()

    var timedOut = false
    let exitSem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async { proc.waitUntilExit(); exitSem.signal() }
    if exitSem.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        proc.terminate()
        if exitSem.wait(timeout: .now() + 3) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)
            _ = exitSem.wait(timeout: .now() + 3)
        }
    }
    _ = group.wait(timeout: .now() + 5)

    let exitCode: Int32 = proc.isRunning ? -2 : proc.terminationStatus
    return CLIRun(exitCode: exitCode,
                  stdout: String(decoding: outSink.value, as: UTF8.self),
                  stderr: String(decoding: errSink.value, as: UTF8.self),
                  timedOut: timedOut,
                  spawnFailed: false)
}
// ---------------------------------------------------------------------------------------------------

// Byte-identical copy of LocalAgentConfig/LocalAgentTool (Models/LocalAgentConfig.swift), for (2).
enum LocalAgentTool: String, Codable, Sendable, CaseIterable { case claude, gemini, codex }
struct LocalAgentConfig: Codable, Equatable, Sendable {
    var tool: LocalAgentTool
    var binaryPath: String
    var modelOverride: String?
    var concurrencyCap: Int
    init(tool: LocalAgentTool, binaryPath: String = "", modelOverride: String? = nil, concurrencyCap: Int = 1) {
        self.tool = tool; self.binaryPath = binaryPath; self.modelOverride = modelOverride; self.concurrencyCap = concurrencyCap
    }
}
// Stand-in for the trailing-optional carrier shape added to PendingRun / SessionProcessingConfig.
struct RunLike: Codable {
    let provider: String
    let startedAt: Date
    var gatewayConfig: String?
    var exportOriginals: Bool? = nil
    var localAgent: LocalAgentConfig? = nil
}

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool) { if ok { pass += 1; print("PASS: \(name)") } else { fail += 1; print("FAIL: \(name)") } }

// Locate the committed fake CLI next to this script.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fakeCLI = scriptDir.appendingPathComponent("localagent-fake-cli.sh").path
guard FileManager.default.isExecutableFile(atPath: fakeCLI) else {
    print("FAIL: fake CLI not executable at \(fakeCLI) — run: chmod +x scripts/localagent-fake-cli.sh")
    exit(1)
}
let claudeArgs = ["-p", "--output-format", "json", "--allowedTools", "Read", "--no-session-persistence"]

// ===== (1) SUBPROCESS MECHANISM =====
setenv("LOCALAGENT_FAKE_MODE", "ok", 1)
let ok = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "the prompt", timeout: 15)
check("ok: exit 0", ok.exitCode == 0 && !ok.timedOut && !ok.spawnFailed)
if let j = try? JSONSerialization.jsonObject(with: Data(ok.stdout.utf8)) as? [String: Any], let r = j["result"] as? String {
    check("ok: stdout is JSON with .result", true)
    check("ok: .result carries the OCR token + tags", r.contains("FAKE-CLI-OCR-TOKEN") && r.contains("[document_start]"))
} else { check("ok: stdout is JSON with .result", false); check("ok: .result carries the OCR token + tags", false) }

setenv("LOCALAGENT_FAKE_MODE", "echostdin", 1)
let echoed = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "PROMPT-ON-STDIN-1234", timeout: 15)
if let j = try? JSONSerialization.jsonObject(with: Data(echoed.stdout.utf8)) as? [String: Any], let r = j["result"] as? String {
    // "PROMPT-ON-STDIN-1234" = 20 bytes; assert the CLI received exactly the prompt on stdin (not argv).
    check("stdin: the prompt is delivered on STDIN (not argv)", r == "STDIN_BYTES=20")
} else { check("stdin: the prompt is delivered on STDIN (not argv)", false) }

setenv("LOCALAGENT_FAKE_MODE", "fail", 1)
let failed = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "x", timeout: 15)
check("fail: non-zero exit surfaced", failed.exitCode == 3 && !failed.timedOut)
check("fail: stderr captured", failed.stderr.contains("internal error"))

setenv("LOCALAGENT_FAKE_MODE", "notlogged", 1)
let notLogged = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "x", timeout: 15)
check("notlogged: exit 1 + 'logged' in stderr (client maps → cli_not_logged_in)", notLogged.exitCode == 1 && notLogged.stderr.lowercased().contains("logged"))

setenv("LOCALAGENT_FAKE_MODE", "garbage", 1)
let garbage = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "x", timeout: 15)
check("garbage: exit 0 but stdout is not JSON", garbage.exitCode == 0 && (try? JSONSerialization.jsonObject(with: Data(garbage.stdout.utf8))) == nil)

setenv("LOCALAGENT_FAKE_MODE", "timeout", 1)
let t0 = Date()
let timedOut = runProcess(binaryPath: fakeCLI, args: claudeArgs, stdinText: "x", timeout: 2)
let elapsed = Date().timeIntervalSince(t0)
check("timeout: flagged timedOut", timedOut.timedOut)
check("timeout: child KILLED promptly (not the 30s sleep)", elapsed < 8)
unsetenv("LOCALAGENT_FAKE_MODE")

// ===== (2) CODABLE BACK-COMPAT (PendingRun carrier resume-safety) =====
let enc = JSONEncoder(); let dec = JSONDecoder()
let oldJSON = #"{"provider":"gemini","startedAt":768000000,"gatewayConfig":null,"exportOriginals":true}"#
if let loaded = try? dec.decode(RunLike.self, from: Data(oldJSON.utf8)) {
    check("resume: old manifest (no localAgent key) decodes, localAgent nil", loaded.localAgent == nil && loaded.provider == "gemini")
} else { check("resume: old manifest (no localAgent key) decodes, localAgent nil", false) }

let nilRun = RunLike(provider: "gemini", startedAt: Date(timeIntervalSince1970: 768000000), gatewayConfig: nil)
let nilStr = String(decoding: try! enc.encode(nilRun), as: UTF8.self)
check("resume: nil localAgent is OMITTED on encode (manifest byte-compatible with old format)", !nilStr.contains("localAgent"))

var setRun = RunLike(provider: "anthropic", startedAt: Date(timeIntervalSince1970: 768000000), gatewayConfig: nil)
setRun.localAgent = LocalAgentConfig(tool: .claude, binaryPath: "/usr/local/bin/claude", modelOverride: "sonnet")
let restored = try! dec.decode(RunLike.self, from: try! enc.encode(setRun))
check("resume: populated localAgent round-trips", restored.localAgent?.tool == .claude && restored.localAgent?.binaryPath == "/usr/local/bin/claude" && restored.localAgent?.modelOverride == "sonnet")

let futureJSON = #"{"tool":"claude","binaryPath":"","concurrencyCap":1,"someFutureField":42}"#
check("forward-compat: LocalAgentConfig ignores an unknown extra key", (try? dec.decode(LocalAgentConfig.self, from: Data(futureJSON.utf8))) != nil)

print("\n\(fail == 0 ? "ALL PASS" : "SOME FAILED") (\(pass) pass, \(fail) fail)")
exit(fail == 0 ? 0 : 1)
