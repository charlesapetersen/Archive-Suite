import Testing
import Foundation
@testable import ArchiveNotes

// MARK: - Stub transport (never touches the network)

/// Records requests and returns canned responses for deterministic testing.
/// An actor so all state is safely isolated in async contexts (Swift 6).
actor StubZoteroTransport: ZoteroTransport {
    struct Invocation: Sendable {
        let request: URLRequest
    }
    private var _invocations: [Invocation] = []
    private var _responses: [(Data, HTTPURLResponse)] = []
    private var _pendingErrors: [Error] = []

    var invocations: [Invocation] { _invocations }
    var callCount: Int { _invocations.count }

    func enqueue(statusCode: Int, json: Any, url: URL? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let resp = HTTPURLResponse(
            url: url ?? URL(string: "http://127.0.0.1:23119")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        _responses.append((data, resp))
    }

    func enqueueError(_ error: Error = URLError(.timedOut)) {
        _pendingErrors.append(error)
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await _send(request)
    }

    private func _send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        _invocations.append(Invocation(request: request))
        if !_pendingErrors.isEmpty {
            throw _pendingErrors.removeFirst()
        }
        guard !_responses.isEmpty else {
            throw URLError(.timedOut)
        }
        return _responses.removeFirst()
    }
}

// MARK: - Test helpers

private let sampleCSLJSON = """
[{"type":"document","title":"Oral History","author":[{"family":"Moore","given":"Gordon E."}],"issued":{"date-parts":[[2001]]}}]
"""

private let sampleCSLWithMonth = """
[{"type":"article-journal","title":"On Computable Numbers","author":[{"family":"Turing","given":"Alan M."}],"issued":{"date-parts":[[1936,11]]}}]
"""

private let sampleCSLWithDay = """
[{"type":"speech","title":"I Have a Dream","author":[{"literal":"Martin Luther King Jr."}],"issued":{"date-parts":[[1963,8,28]]}}]
"""

private func makeBBTProbeResponse() -> Any {
    ["jsonrpc": "2.0", "result": [] as [Any], "id": 1] as [String: Any]
}

private func makeLocalAPIProbeResponse() -> Any {
    [["key": "TEST1234", "data": ["title": "Test"]]] as [[String: Any]]
}

private func makeRef(key: String = "ABCD1234", library: ZoteroLibrary = .user) -> ZoteroRef {
    ZoteroRef(
        selectLink: "zotero://select/library/items/\(key)",
        itemKey: key,
        library: library
    )
}

// MARK: - Probe tests

@Suite struct ZoteroClientProbeTests {

    @Test func probeSelectsBBT() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)

        let backend = await client.availability()
        #expect(backend == .betterBibTeX)
    }

    @Test func probeFallsToLocalAPI() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueue(statusCode: 200, json: makeLocalAPIProbeResponse())
        let client = ZoteroClient(transport: stub)

        let backend = await client.availability()
        #expect(backend == .localAPI)
    }

    @Test func probeUnavailableWhenBothFail() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueueError(URLError(.cannotConnectToHost))
        let client = ZoteroClient(transport: stub)

        let backend = await client.availability()
        #expect(backend == .unavailable)
    }

    @Test func probeCacheTTL() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)

        let first = await client.availability()
        #expect(first == .betterBibTeX)

        // Second call should use cache — no new transport calls
        let callsBefore = await stub.callCount
        let second = await client.availability()
        #expect(second == .betterBibTeX)
        #expect(await stub.callCount == callsBefore)
    }

    @Test func probeResetCache() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)

        _ = await client.availability()
        let callsAfterFirst = await stub.callCount

        await client.resetProbeCache()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())

        _ = await client.availability()
        #expect(await stub.callCount > callsAfterFirst)
    }
}

// MARK: - CSL fetch tests

@Suite struct ZoteroClientFetchTests {

    @Test func fetchCSLviaBBT() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0",
            "result": ["1:ABCD1234": "moore2001"],
            "id": 1,
        ] as [String: Any])
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0",
            "result": sampleCSLJSON,
            "id": 2,
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()
        let csl = try await client.fetchCSL(ref)

        #expect(csl.title == "Oral History")
        #expect(csl.author?.count == 1)
        #expect(csl.author?.first?.family == "Moore")
        #expect(csl.author?.first?.given == "Gordon E.")
        #expect(csl.issued?.dateParts == [[2001]])
    }

    @Test func fetchCSLviaLocalAPI() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueue(statusCode: 200, json: makeLocalAPIProbeResponse())
        await stub.enqueue(statusCode: 200, json: [
            "csljson": [
                "type": "document",
                "title": "Oral History",
                "author": [["family": "Moore", "given": "Gordon E."]],
                "issued": ["date-parts": [[2001]]],
            ] as [String: Any],
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()
        let csl = try await client.fetchCSL(ref)

        #expect(csl.title == "Oral History")
        #expect(csl.author?.first?.family == "Moore")
    }

    @Test func fetchCSLCacheHit() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0",
            "result": ["1:ABCD1234": "moore2001"],
            "id": 1,
        ] as [String: Any])
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0",
            "result": sampleCSLJSON,
            "id": 2,
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()

        _ = try await client.fetchCSL(ref)
        let callsAfterFirst = await stub.callCount

        let csl2 = try await client.fetchCSL(ref)
        #expect(csl2.title == "Oral History")
        #expect(await stub.callCount == callsAfterFirst)
    }

    @Test func fetchUnavailableThrows() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueueError(URLError(.cannotConnectToHost))

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()

        do {
            _ = try await client.fetchCSL(ref)
            Issue.record("Expected ClientError.unavailable")
        } catch is ZoteroClient.ClientError {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func fetchCitationViaLocalAPI() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueue(statusCode: 200, json: makeLocalAPIProbeResponse())
        await stub.enqueue(statusCode: 200, json: [
            "bib": "<div class=\"csl-bib-body\">Moore, Gordon E. <i>Oral History</i>. 2001.</div>",
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()
        let citation = try await client.fetchCitation(ref)

        #expect(citation == "Moore, Gordon E. Oral History. 2001.")
    }

    @Test func fetchGroupLibrary() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueue(statusCode: 200, json: makeLocalAPIProbeResponse())
        await stub.enqueue(statusCode: 200, json: [
            "csljson": [
                "type": "document",
                "title": "Group Item",
            ] as [String: Any],
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let ref = makeRef(key: "XYZW5678", library: .group(42))
        let csl = try await client.fetchCSL(ref)

        #expect(csl.title == "Group Item")
        let fetchReq = await stub.invocations.last!.request
        #expect(fetchReq.url?.path.contains("/groups/42/") == true)
    }
}

// MARK: - CSL mapping tests

@Suite struct ZoteroCSLMappingTests {

    @Test func yearPrecision() throws {
        let data = sampleCSLJSON.data(using: .utf8)!
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
        let csl = items[0]

        #expect(csl.issued?.dateParts == [[2001]])
        let parts = csl.issued!.dateParts![0]
        #expect(parts.count == 1)
    }

    @Test func monthPrecision() throws {
        let data = sampleCSLWithMonth.data(using: .utf8)!
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
        let csl = items[0]

        let parts = csl.issued!.dateParts![0]
        #expect(parts.count == 2)
        #expect(parts[0] == 1936)
        #expect(parts[1] == 11)
    }

    @Test func dayPrecision() throws {
        let data = sampleCSLWithDay.data(using: .utf8)!
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
        let csl = items[0]

        let parts = csl.issued!.dateParts![0]
        #expect(parts.count == 3)
        #expect(parts == [1963, 8, 28])
    }

    @Test func literalAuthor() throws {
        let data = sampleCSLWithDay.data(using: .utf8)!
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
        let name = items[0].author!.first!

        #expect(name.literal == "Martin Luther King Jr.")
        #expect(name.displayName == "Martin Luther King Jr.")
    }

    @Test func givenFamilyAuthor() throws {
        let data = sampleCSLJSON.data(using: .utf8)!
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
        let name = items[0].author!.first!

        #expect(name.family == "Moore")
        #expect(name.given == "Gordon E.")
        #expect(name.displayName == "Gordon E. Moore")
    }
}

// MARK: - Cache store tests

@Suite struct ZoteroCacheStoreTests {

    @Test func roundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroCacheTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ZoteroCacheStore(directory: tmp)
        let entry = ZoteroCacheStore.Entry(
            csl: ZoteroCSLItem(type: "document", title: "Test"),
            citation: "Test Author. Test. 2024.",
            styleID: "chicago-note-bibliography",
            fetchedAt: Date()
        )

        await store.set("library/TEST1234", entry: entry)
        await store.save()

        let store2 = ZoteroCacheStore(directory: tmp)
        await store2.load()
        let loaded = await store2.get("library/TEST1234")

        #expect(loaded != nil)
        #expect(loaded?.csl.title == "Test")
        #expect(loaded?.citation == "Test Author. Test. 2024.")
    }

    @Test func loadMissing() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroCacheTest-\(UUID().uuidString)", isDirectory: true)
        let store = ZoteroCacheStore(directory: tmp)
        await store.load()
        #expect(await store.count == 0)
    }

    @Test func cacheKey() {
        let userRef = ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                                itemKey: "ABCD1234", library: .user)
        #expect(ZoteroCacheStore.cacheKey(for: userRef) == "library/ABCD1234")

        let groupRef = ZoteroRef(selectLink: "zotero://select/groups/42/items/XYZW5678",
                                 itemKey: "XYZW5678", library: .group(42))
        #expect(ZoteroCacheStore.cacheKey(for: groupRef) == "42/XYZW5678")
    }
}
