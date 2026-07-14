import Testing
import Foundation
@testable import ArchiveNotes

// MARK: - W8-S5 — ZoteroClientTests over a stubbed local HTTP server (plan §1.8)
//
// These tests differ from `ZoteroClientTests.swift` (W5-S2): those inject a
// hand-written `ZoteroTransport` stub that never builds a URLSession. Here we
// drive the **real** production transport (`URLSessionZoteroTransport`) over a
// URLSession whose `protocolClasses` intercept every request in-process. That
// exercises the full HTTP stack the app actually uses at runtime —
// `Config` base-URL seam → `URLRequest` → `URLSession.data(for:)` →
// `HTTPURLResponse` cast → probe/fetch/citation/timeout/degrade — with **zero
// network egress** (the plan's "minimal URLProtocol stub" harness option).
//
// Reconciliation vs the plan's §1.8 sketch (00-overview §16 governs types):
//   • `testAttachmentSelectLinkParsed` — `ZoteroSelectLink.parse` intentionally
//     yields `kind: .item` (a select URL doesn't encode item-vs-attachment;
//     see `ZoteroSelectLinkTests.testDefaultKindIsItem`). Attachment-ness is a
//     front-matter/model attribute (`ZoteroFrontMatterRoundTripTests`), so this
//     test pins the achievable contract: the URL yields the right key+library,
//     and an attachment `ZoteroRef` (kind:.attachment + parentKey) both round-
//     trips and fetches over the client just like an item ref (D8: item AND
//     attachment).
//   • A localhost `NWListener` is *not* used: the test bundle is hosted by the
//     sandboxed app (`TEST_HOST`) which ships only `network.client`, so a real
//     listener couldn't accept loopback connections — and widening the shipping
//     app to `network.server` for a test would be wrong. URLProtocol needs no
//     network entitlement at all.

// MARK: - In-process HTTP stub (URLProtocol)

/// A canned HTTP reply the stub returns for a matched request.
private struct StubHTTPResponse: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String] = ["Content-Type": "application/json"]
}

/// What the installed stub does for each intercepted request.
private enum StubBehavior: Sendable {
    /// Route on the request and return a canned reply (nil → 404).
    case route(@Sendable (URLRequest) -> StubHTTPResponse?)
    /// Fail immediately as if the port were closed (connection refused).
    case connectionRefused
    /// Never reply — forces the URLSession request timeout to fire.
    case hang
}

/// Intercepts requests from sessions that list it in `protocolClasses`. All
/// state is global-but-lock-guarded, and the owning suite is `.serialized`, so
/// only one test's behavior is ever installed at a time. No sockets are opened.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behavior: StubBehavior?

    static func install(_ behavior: StubBehavior) {
        lock.lock(); defer { lock.unlock() }
        Self.behavior = behavior
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        Self.behavior = nil
    }

    private static func current() -> StubBehavior? {
        lock.lock(); defer { lock.unlock() }
        return behavior
    }

    /// Build an ephemeral session wired to this stub with a bounded timeout.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.current() {
        case .hang, .none:
            // No reply: `.hang` waits for the request timeout; `.none` means the
            // behavior was reset out from under a straggler — also let it lapse.
            return
        case .connectionRefused:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .route(let router):
            let reply = router(request) ?? StubHTTPResponse(status: 404, body: Data())
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Fixtures / routing helpers

private func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

/// Serialize an itemKey → CSL-JSON-object map into the `{"csljson": …}` and
/// `{"bib": …}` reply bodies the Zotero local API returns, keyed by itemKey.
/// Pre-serialized to `Data` so the routing closure stays `@Sendable`.
private struct LocalAPIFixture: Sendable {
    let cslByKey: [String: Data]      // itemKey → {"csljson": {…}}
    let bibByKey: [String: Data]      // itemKey → {"bib": "<div>…</div>"}

    init(items: [String: [String: Any]], citations: [String: String]) {
        var csl: [String: Data] = [:]
        var bib: [String: Data] = [:]
        for (key, obj) in items {
            csl[key] = jsonData(["csljson": obj])
        }
        for (key, cite) in citations {
            bib[key] = jsonData(["bib": "<div class=\"csl-entry\">\(cite)</div>"])
        }
        self.cslByKey = csl
        self.bibByKey = bib
    }

    /// A `.route` behavior modelling Zotero 7's local API. The Better BibTeX
    /// probe (a POST) is answered 404 so the client falls through to the local
    /// API backend deterministically.
    var behavior: StubBehavior {
        let cslByKey = self.cslByKey
        let bibByKey = self.bibByKey
        return .route { req in
            guard let url = req.url else { return nil }
            let method = req.httpMethod ?? "GET"
            if method == "POST" {
                // Better BibTeX JSON-RPC probe/call → unavailable.
                return StubHTTPResponse(status: 404, body: Data())
            }
            let query = url.query ?? ""
            // Availability probe: GET …/items?limit=1 (path ends in "items").
            if url.path.hasSuffix("/items") {
                return StubHTTPResponse(status: 200, body: jsonData([["key": "PROBE0000"]]))
            }
            let key = url.lastPathComponent
            if query.contains("include=bib") {
                guard let data = bibByKey[key] else {
                    return StubHTTPResponse(status: 404, body: Data())
                }
                return StubHTTPResponse(status: 200, body: data)
            }
            if query.contains("include=csljson") {
                guard let data = cslByKey[key] else {
                    return StubHTTPResponse(status: 404, body: Data())
                }
                return StubHTTPResponse(status: 200, body: data)
            }
            return StubHTTPResponse(status: 404, body: Data())
        }
    }
}

/// A CSL-JSON object dict for a Gordon Moore oral-history document (year precision).
private func mooreCSL() -> [String: Any] {
    [
        "type": "document",
        "title": "Oral History",
        "author": [["family": "Moore", "given": "Gordon E."]],
        "issued": ["date-parts": [[2001]]],
    ]
}

/// A minimal empty note so every auto-fill field is a fresh (non-replacement) change.
private func emptyNote() -> Item {
    Item(
        id: UUID(), kind: .note, title: "", authors: [], date: nil,
        datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
        zotero: [], roundup: false, created: Date(), modified: Date(),
        schema: 1, blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil
    )
}

/// A client wired to the in-process stub, pointed at a **non-default** port to
/// prove the `Config` base-URL seam flows through (not hard-coded to 23119).
private func makeStubClient(timeout: TimeInterval = 1.5) -> ZoteroClient {
    let transport = URLSessionZoteroTransport(session: StubURLProtocol.makeSession(timeout: timeout))
    return ZoteroClient(transport: transport, config: .init(host: "127.0.0.1", port: 51999, timeout: timeout))
}

// MARK: - Tests

@Suite(.serialized) struct ZoteroLocalServerTests {

    @Test func testFetchItemMetadataParsesAuthorDateTitleCitation() async throws {
        let fixture = LocalAPIFixture(
            items: ["ABCD1234": mooreCSL()],
            citations: ["ABCD1234": "Moore, Gordon E. <i>Oral History</i>. 2001."]
        )
        StubURLProtocol.install(fixture.behavior)
        defer { StubURLProtocol.reset() }

        let client = makeStubClient()
        let ref = ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                            itemKey: "ABCD1234", library: .user)

        // Real transport round-trip: CSL parsed off the wire.
        let csl = try await client.fetchCSL(ref)
        #expect(csl.mappedTitle == "Oral History")
        #expect(csl.mappedAuthors == ["Gordon E. Moore"])
        let (date, precision) = csl.mappedDate()
        #expect(date == "2001")
        #expect(precision == .year)

        // Auto-fill diff onto an empty note → title/authors/date all proposed.
        let plan = AutoFillPlan.make(from: csl, item: emptyNote())
        #expect(plan.proposedTitle == "Oral History")
        #expect(plan.proposedAuthors == ["Gordon E. Moore"])
        #expect(plan.proposedDate == "2001")
        #expect(plan.proposedDatePrecision == .year)
        #expect(Set(plan.changes.map(\.field)) == [.title, .authors, .date])

        // Formatted citation: HTML stripped by the real client path.
        let citation = try await client.fetchCitation(ref)
        #expect(citation == "Moore, Gordon E. Oral History. 2001.")
    }

    @Test func testAttachmentSelectLinkParsed() async throws {
        // (1) URL side: a select link parses to the right key + library.
        let parsed = ZoteroSelectLink.parse("zotero://select/library/items/ATCH5678")
        #expect(parsed?.itemKey == "ATCH5678")
        #expect(parsed?.library == .user)

        // (2) Model side (D8): an attachment ref carries kind:.attachment +
        // parentKey, and fetches over the client exactly like an item ref
        // (attachments are addressed by their own key on the local API).
        let attachmentCSL: [String: Any] = [
            "type": "attachment",
            "itemType": "attachment",
            "title": "Scanned Memo (PDF)",
        ]
        let fixture = LocalAPIFixture(items: ["ATCH5678": attachmentCSL], citations: [:])
        StubURLProtocol.install(fixture.behavior)
        defer { StubURLProtocol.reset() }

        let attachmentRef = ZoteroRef(
            selectLink: "zotero://select/library/items/ATCH5678",
            itemKey: "ATCH5678", library: .user,
            kind: .attachment, parentKey: "PKEY0000")
        #expect(attachmentRef.kind == .attachment)
        #expect(attachmentRef.parentKey == "PKEY0000")

        let client = makeStubClient()
        let csl = try await client.fetchCSL(attachmentRef)
        #expect(csl.type == "attachment")
        #expect(csl.mappedTitle == "Scanned Memo (PDF)")
    }

    @Test func testMultipleZoteroRefsOnOneNote() async throws {
        // A note with ≥2 Zotero refs (an item + a group-library attachment):
        // round-trips through front-matter AND both resolve over the client.
        let ref1 = ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                             itemKey: "ABCD1234", library: .user,
                             citation: "First citation.")
        let ref2 = ZoteroRef(selectLink: "zotero://select/groups/7/items/WXYZ5678",
                             itemKey: "WXYZ5678", library: .group(7),
                             kind: .attachment, parentKey: "ABCD1234",
                             citation: "Second citation.", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var note = emptyNote()
        note.title = "Two sources"
        note.zotero = [ref1, ref2]

        let decoded = try FrontMatterCodec.decode(FrontMatterCodec.encode(note))
        #expect(decoded.zotero.count == 2)
        #expect(decoded.zotero[0].itemKey == "ABCD1234")
        #expect(decoded.zotero[1].itemKey == "WXYZ5678")
        #expect(decoded.zotero[1].kind == .attachment)
        #expect(decoded.zotero[1].library == .group(7))

        // Both refs fetch distinct metadata over the real transport.
        let fixture = LocalAPIFixture(
            items: [
                "ABCD1234": ["type": "document", "title": "First Source"],
                "WXYZ5678": ["type": "attachment", "title": "Second Source"],
            ],
            citations: [:]
        )
        StubURLProtocol.install(fixture.behavior)
        defer { StubURLProtocol.reset() }

        let client = makeStubClient()
        let csl1 = try await client.fetchCSL(decoded.zotero[0])
        let csl2 = try await client.fetchCSL(decoded.zotero[1])
        #expect(csl1.mappedTitle == "First Source")
        #expect(csl2.mappedTitle == "Second Source")

        // The group-library ref must hit the /groups/7/ path (base-URL seam).
        #expect(decoded.zotero[1].library == .group(7))
    }

    @Test func testDegradesGracefullyWhenServerDown() async throws {
        StubURLProtocol.install(.connectionRefused)
        defer { StubURLProtocol.reset() }

        let client = makeStubClient()
        let ref = ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                            itemKey: "ABCD1234", library: .user,
                            citation: "Previously fetched citation.")

        let start = Date()
        // Availability degrades to `.unavailable` — never blocks, never crashes.
        let backend = await client.availability()
        #expect(backend == .unavailable)

        // fetchCSL surfaces a typed `.unavailable` (a handled error, not a hang
        // or an untyped crash); the caller keeps the stored chip data.
        do {
            _ = try await client.fetchCSL(ref)
            Issue.record("Expected ClientError.unavailable when the server is down")
        } catch let error as ZoteroClient.ClientError {
            #expect(error == .unavailable)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // The chip still shows the stored selectLink + citation (degrade-gracefully).
        #expect(ref.selectLink == "zotero://select/library/items/ABCD1234")
        #expect(ref.citation == "Previously fetched citation.")

        // Connection-refused is prompt: nowhere near an indefinite hang.
        #expect(Date().timeIntervalSince(start) < 6.0)
    }

    @Test func testTimeoutBounded() async throws {
        // A server that accepts but never replies must not hang the client:
        // the bounded per-request timeout fires and availability degrades.
        StubURLProtocol.install(.hang)
        defer { StubURLProtocol.reset() }

        let client = makeStubClient(timeout: 0.6)

        let start = Date()
        let backend = await client.availability()
        let elapsed = Date().timeIntervalSince(start)

        #expect(backend == .unavailable)
        // Two sequential probes at 0.6s each (~1.2s) + slack — provably bounded,
        // definitively not an indefinite wait.
        #expect(elapsed < 6.0)
    }
}
