#if DEBUG // a test driver, compiled out of Release
import ArchiveCore
import Darwin
import Foundation

/// Headless, $0 self-test of receiving Improve OCR hand-offs (W44.reocr-processor), gated by
/// `REOCR_REQUEST_STORE_TEST=1` (does nothing in normal use). Scratch folders under a fresh temporary directory only;
/// no corpus, no network, no Keychain, no window. Run by `scripts/test-reocr-request-store.sh`.
///
/// What has to be true:
///   1. A staged manifest opens once; a repeat focuses it (`alreadyOpened`), across a fresh store value too.
///   2. An inline request opens once; an inline request whose ID also has a staged manifest is refused.
///   3. Unsafe staging is refused: a linked manifest, a manifest others can read, a folder others can reach, a
///      folder that is a link, an oversize manifest. None of them is recorded as consumed.
///   4. A missing or day-old manifest asks to select the files again; a malformed one is refused; neither is consumed.
@MainActor
enum ImproveOCRRequestStoreTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_REQUEST_STORE_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    private static func isRefused(_ o: ImproveOCRRequestStore.Outcome) -> Bool {
        if case .refused = o { return true }
        return false
    }

    private static func isSelectAgain(_ o: ImproveOCRRequestStore.Outcome) -> Bool {
        if case .selectAgain = o { return true }
        return false
    }

    static func run() {
        defer { finish() }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("reocr-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let shared = base.appendingPathComponent("shared", isDirectory: true)
        let requests = shared.appendingPathComponent("Requests", isDirectory: true)
        let state = base.appendingPathComponent("private", isDirectory: true)
        do {
            try fm.createDirectory(at: requests, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            check("0 scratch folders", false, "\(error)")
            return
        }
        let store = ImproveOCRRequestStore(sharedSupport: shared, privateState: state)
        let root = UUID()
        let now = Date()

        func manifest(_ id: UUID, created: Date = now) -> ImproveOCRManifest {
            ImproveOCRManifest(requestID: id, createdAt: created, rootGUID: root, rootPathHint: "/Volumes/Scratch",
                               entries: [.init(relativePath: "Box 1/a.pdf", pairIndices: [2, 0], fileNumber: 7,
                                               byteCount: 1234, sha256: String(repeating: "0f", count: 32))])
        }

        @discardableResult
        func stage(_ id: UUID, data: Data? = nil, mode: Int = 0o600, created: Date = now) -> URL {
            let url = requests.appendingPathComponent(id.uuidString.lowercased() + ".json")
            let bytes = data ?? ((try? manifest(id, created: created).encoded()) ?? Data())
            fm.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: mode])
            return url
        }

        // 1. A manifest opens once.
        let m1 = UUID()
        stage(m1)
        let first = store.receive(.manifest(requestID: m1), now: now)
        if case .open(let r) = first {
            eq("1 the manifest's root", r.rootGUID, root)
            eq("1 the manifest's entries, pairs sorted", r.entries.map(\.relativePath), ["Box 1/a.pdf"])
            eq("1 pairs sorted", r.entries.first?.pairIndices, [0, 2])
            eq("1 the expected digest carried", r.entries.first?.expectedSHA256, String(repeating: "0f", count: 32))
        } else {
            check("1 a staged manifest opens", false, "\(first)")
        }
        eq("1 a repeat focuses it", store.receive(.manifest(requestID: m1), now: now), .alreadyOpened(m1))
        let fresh = ImproveOCRRequestStore(sharedSupport: shared, privateState: state)
        eq("1 a repeat after a relaunch focuses it", fresh.receive(.manifest(requestID: m1), now: now), .alreadyOpened(m1))

        // 2. Inline.
        let i1 = UUID()
        let inline = ImproveOCRRequest.inline(requestID: i1, rootGUID: root, relativePaths: ["a.pdf", "b/c.pdf"])
        if case .open(let r) = store.receive(inline, now: now) {
            eq("2 inline entries", r.entries.map(\.relativePath), ["a.pdf", "b/c.pdf"])
            check("2 inline entries carry no expectations", r.entries.allSatisfy { $0.expectedSHA256 == nil })
        } else {
            check("2 an inline request opens", false)
        }
        eq("2 an inline repeat focuses it", store.receive(inline, now: now), .alreadyOpened(i1))
        let i2 = UUID()
        stage(i2)
        check("2 an inline request with a staged manifest of its ID is refused",
              isRefused(store.receive(.inline(requestID: i2, rootGUID: root, relativePaths: ["a.pdf"]), now: now)))
        check("2 and is not consumed", !store.isConsumed(i2))

        // 3. Unsafe staging.
        let target = base.appendingPathComponent("elsewhere.json")
        let linked = UUID()
        fm.createFile(atPath: target.path, contents: try? manifest(linked).encoded(), attributes: [.posixPermissions: 0o600])
        try? fm.createSymbolicLink(at: requests.appendingPathComponent(linked.uuidString.lowercased() + ".json"),
                                   withDestinationURL: target)
        check("3 a linked manifest is refused", isRefused(store.receive(.manifest(requestID: linked), now: now)))
        let readable = UUID()
        stage(readable, mode: 0o644)
        check("3 a manifest others can read is refused", isRefused(store.receive(.manifest(requestID: readable), now: now)))
        let big = UUID()
        stage(big, data: Data(count: ImproveOCRManifest.maxBytes + 1))
        check("3 an oversize manifest is refused", isRefused(store.receive(.manifest(requestID: big), now: now)))
        let open = UUID()
        stage(open)
        chmod(requests.path, 0o755)
        check("3 a folder others can reach is refused", isRefused(store.receive(.manifest(requestID: open), now: now)))
        chmod(requests.path, 0o700)
        let linkedShared = base.appendingPathComponent("shared-link", isDirectory: true)
        try? fm.createDirectory(at: linkedShared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createSymbolicLink(at: linkedShared.appendingPathComponent("Requests"), withDestinationURL: requests)
        let viaLink = ImproveOCRRequestStore(sharedSupport: linkedShared, privateState: state)
        check("3 a requests folder that is a link is refused",
              isRefused(viaLink.receive(.manifest(requestID: open), now: now)))
        check("3 no unsafe request is consumed",
              [linked, readable, big, open].allSatisfy { !store.isConsumed($0) })

        // 4. Missing, expired, malformed.
        let missing = UUID()
        check("4 a missing manifest asks to select again", isSelectAgain(store.receive(.manifest(requestID: missing), now: now)))
        let old = UUID()
        stage(old, created: now.addingTimeInterval(-25 * 3600))
        check("4 a day-old manifest asks to select again", isSelectAgain(store.receive(.manifest(requestID: old), now: now)))
        let bad = UUID()
        stage(bad, data: Data("{".utf8))
        check("4 a malformed manifest is refused", isRefused(store.receive(.manifest(requestID: bad), now: now)))
        let wrongID = UUID()
        stage(wrongID, data: try? manifest(UUID()).encoded())
        check("4 a manifest naming another request is refused",
              isRefused(store.receive(.manifest(requestID: wrongID), now: now)))
        check("4 none of them is consumed", [missing, old, bad, wrongID].allSatisfy { !store.isConsumed($0) })
        check("4 nothing was written to the shared folder but the staged requests",
              ((try? fm.contentsOfDirectory(atPath: shared.path)) ?? []) == ["Requests"])
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_REQUEST_STORE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

#endif
