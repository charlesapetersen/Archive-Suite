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

    func enqueue(statusCode: Int, data: Data) {
        let resp = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:23119")!,
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

private func bodyMethod(_ request: URLRequest) -> String? {
    guard let body = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return json["method"] as? String
}

@Suite struct ZoteroClientProbeTests {

    @Test func probeSelectsLocalAPIFromItsRoot() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, data: Data("Nothing to see here.".utf8))
        let client = ZoteroClient(transport: stub)

        #expect(await client.availability() == .localAPI)
        #expect(await stub.invocations.first?.request.url?.absoluteString == "http://127.0.0.1:23119/api/")
        #expect(await stub.callCount == 1)
    }

    @Test func probeTriesTheListingWhenTheRootIsMissing() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 404, data: Data())
        await stub.enqueue(statusCode: 200, json: makeLocalAPIProbeResponse())
        let client = ZoteroClient(transport: stub)

        #expect(await client.availability() == .localAPI)
    }

    @Test func probeFallsToBBT() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)

        #expect(await client.availability() == .betterBibTeX)
    }

    @Test func probeLocalAPIOffFallsToBBT() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 403, data: Data("Local API is not enabled".utf8))
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)

        #expect(await client.availability() == .betterBibTeX)
        #expect(await stub.callCount == 2) // a 403 root is final: no listing request
    }

    @Test func probeUnavailableWhenBothFail() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        await stub.enqueueError(URLError(.cannotConnectToHost))
        let client = ZoteroClient(transport: stub)

        let backend = await client.availability()
        #expect(backend == .unavailable)
    }

    /// W40.fix-notes-zotero-fetch: the old probe sent BBT `item.search ""`, which lists every item, and timed
    /// out on a large library. Neither probe may ask for the library's contents.
    @Test func probeNeverListsTheLibrary() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 403, data: Data())
        await stub.enqueue(statusCode: 200, json: makeBBTProbeResponse())
        let client = ZoteroClient(transport: stub)
        _ = await client.availability()

        let requests = await stub.invocations.map(\.request)
        #expect(requests.map { bodyMethod($0) } == [nil, "api.ready"])
        #expect(requests.allSatisfy { $0.timeoutInterval <= 3 })
    }

    @Test func probeCacheTTL() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, data: Data())
        let client = ZoteroClient(transport: stub)

        let first = await client.availability()
        #expect(first == .localAPI)

        // Second call should use cache — no new transport calls
        let callsBefore = await stub.callCount
        let second = await client.availability()
        #expect(second == .localAPI)
        #expect(await stub.callCount == callsBefore)
    }

    @Test func probeResetCache() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, data: Data())
        let client = ZoteroClient(transport: stub)

        _ = await client.availability()
        let callsAfterFirst = await stub.callCount

        await client.resetProbeCache()
        await stub.enqueue(statusCode: 200, data: Data())

        _ = await client.availability()
        #expect(await stub.callCount > callsAfterFirst)
    }
}

// MARK: - CSL fetch tests

private func localCSLResponse(title: String = "Oral History") -> Any {
    [
        "csljson": [
            "type": "document",
            "title": title,
            "author": [["family": "Moore", "given": "Gordon E."]],
            "issued": ["date-parts": [[2001]]],
        ] as [String: Any],
    ] as [String: Any]
}

private func expectClientError(_ expected: ZoteroClient.ClientError,
                               _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected ClientError.\(expected)")
    } catch let error as ZoteroClient.ClientError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Suite struct ZoteroClientFetchTests {

    @Test func fetchCSLviaLocalAPIAsksForTheItemOnly() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: localCSLResponse())

        let client = ZoteroClient(transport: stub)
        let csl = try await client.fetchCSL(makeRef())

        #expect(csl.title == "Oral History")
        #expect(csl.author?.first?.family == "Moore")
        #expect(await stub.callCount == 1) // no probe in front of the fetch
        let req = await stub.invocations[0].request
        #expect(req.url?.path == "/api/users/0/items/ABCD1234")
        #expect(req.timeoutInterval == 10)
    }

    /// The owner's failure (notes-1 rows 50-51): a probe that timed out made every fetch throw
    /// `.unavailable` for 30 s although Zotero answered. A failed probe must not stop a fetch.
    @Test func fetchSucceedsAfterAFailedProbe() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.timedOut))
        await stub.enqueueError(URLError(.timedOut))
        let client = ZoteroClient(transport: stub)
        #expect(await client.availability() == .unavailable)

        await stub.enqueue(statusCode: 200, json: localCSLResponse())
        let csl = try await client.fetchCSL(makeRef())
        #expect(csl.title == "Oral History")
        #expect(await client.availability() == .localAPI) // the fetch refreshed the status
    }

    @Test func fetchCSLviaBBTWhenTheLocalAPIIsOff() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 403, data: Data("Local API is not enabled".utf8))
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
        let csl = try await client.fetchCSL(makeRef())

        #expect(csl.title == "Oral History")
        #expect(csl.author?.count == 1)
        #expect(csl.author?.first?.given == "Gordon E.")
        #expect(csl.issued?.dateParts == [[2001]])
        #expect(await client.availability() == .betterBibTeX)
    }

    @Test func fetchCSLCacheHit() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: localCSLResponse())

        let client = ZoteroClient(transport: stub)
        let ref = makeRef()

        _ = try await client.fetchCSL(ref)
        let callsAfterFirst = await stub.callCount

        let csl2 = try await client.fetchCSL(ref)
        #expect(csl2.title == "Oral History")
        #expect(await stub.callCount == callsAfterFirst)
    }

    @Test func fetchUnreachableIsUnavailableWithoutABBTAttempt() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.cannotConnectToHost))
        let client = ZoteroClient(transport: stub)

        await expectClientError(.unavailable) { _ = try await client.fetchCSL(makeRef()) }
        #expect(await stub.callCount == 1)
    }

    @Test func fetchSlowZoteroIsTimedOut() async {
        let stub = StubZoteroTransport()
        await stub.enqueueError(URLError(.timedOut))
        let client = ZoteroClient(transport: stub)

        await expectClientError(.timedOut) { _ = try await client.fetchCSL(makeRef()) }
        #expect(await stub.callCount == 1)
    }

    /// When BBT cannot help either, the local API's answer is reported: it names the setting to change.
    @Test func localAPIOffIsReportedWhenBBTIsAbsent() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 403, data: Data())
        await stub.enqueue(statusCode: 404, data: Data())
        let client = ZoteroClient(transport: stub)

        await expectClientError(.localAPIOff) { _ = try await client.fetchCSL(makeRef()) }
    }

    @Test func unknownItemIsItemNotFound() async {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 404, data: Data("Not found".utf8))
        await stub.enqueue(statusCode: 404, data: Data())
        let client = ZoteroClient(transport: stub)

        await expectClientError(.itemNotFound) { _ = try await client.fetchCitation(makeRef()) }
    }

    @Test func fetchCitationViaLocalAPI() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, json: [
            "bib": "<div class=\"csl-bib-body\">Moore, Gordon E. <i>Oral History</i>. 2001.</div>",
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let citation = try await client.fetchCitation(makeRef(), styleID: "apa")

        #expect(citation == "Moore, Gordon E. Oral History. 2001.")
        let query = await stub.invocations[0].request.url?.query ?? ""
        #expect(query.contains("include=bib") && query.contains("style=apa"))
    }

    /// BBT renders a style through `item.bibliography` with the style's full URI (`item.export` takes a
    /// translator, so the old call could never succeed).
    @Test func fetchCitationViaBBTUsesBibliography() async throws {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 403, data: Data())
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0", "result": ["1:ABCD1234": "moore2001"], "id": 1,
        ] as [String: Any])
        await stub.enqueue(statusCode: 200, json: [
            "jsonrpc": "2.0", "result": "Moore, Gordon E. Oral History. 2001.", "id": 4,
        ] as [String: Any])

        let client = ZoteroClient(transport: stub)
        let citation = try await client.fetchCitation(makeRef(), styleID: "apa")

        #expect(citation == "Moore, Gordon E. Oral History. 2001.")
        let last = await stub.invocations.last!.request
        #expect(bodyMethod(last) == "item.bibliography")
        let body = try JSONSerialization.jsonObject(with: last.httpBody ?? Data()) as? [String: Any]
        let params = body?["params"] as? [Any]
        #expect((params?.last as? [String: Any])?["id"] as? String == "http://www.zotero.org/styles/apa")
    }

    @Test func fetchGroupLibrary() async throws {
        let stub = StubZoteroTransport()
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

// MARK: - What the user reads (W40.fix-notes-zotero-fetch)

@Suite struct ZoteroClientErrorTextTests {

    /// The sheet showed "(ArchiveNotes.ZoteroClient.ClientError error 0.)". Every case is a sentence.
    @Test(arguments: [ZoteroClient.ClientError.off, .unavailable, .timedOut, .localAPIOff,
                      .itemNotFound, .unexpectedResponse])
    func everyErrorIsASentence(_ error: ZoteroClient.ClientError) {
        let text = error.localizedDescription
        #expect(!text.contains("ClientError"))
        #expect(!text.contains("error 0"))
        #expect(text.hasSuffix("."))
        #expect(text.count > 40)
    }

    @Test func unreachableNamesZoterosSetting() {
        let text = ZoteroClient.ClientError.unavailable.localizedDescription
        #expect(text.contains("Zotero is running"))
        #expect(text.contains("Allow other applications on this computer to communicate with Zotero"))
    }
}

// MARK: - Zotero's real local-API response (W40.fix-notes-zotero-csljson-crash)

/// Zotero 10.0.6's body for `GET /api/users/0/items/5SXHDTMB?include=csljson`, other keys trimmed, as measured
/// by W40.d10 (`verification/evidence/notes/W40.d10-integrations.md`): `csljson` is a string holding an array,
/// and the date parts are strings.
private let realZoteroCSLBody = #"""
{"key": "5SXHDTMB", "csljson": "[\n\t{\n\t\t\"id\": \"http://zotero.org/users/local/JeE49aLm/items/5SXHDTMB\",\n\t\t\"type\": \"book\",\n\t\t\"publisher\": \"Richard and John E. Taylor\",\n\t\t\"publisher-place\": \"London\",\n\t\t\"title\": \"Notes on the Analytical Engine (W40.d10 seed)\",\n\t\t\"author\": [\n\t\t\t{\n\t\t\t\t\"family\": \"Lovelace\",\n\t\t\t\t\"given\": \"Ada\"\n\t\t\t}\n\t\t],\n\t\t\"issued\": {\n\t\t\t\"date-parts\": [\n\t\t\t\t[\n\t\t\t\t\t\"1843\"\n\t\t\t\t]\n\t\t\t]\n\t\t}\n\t}\n]"}
"""#

@Suite struct ZoteroLocalAPIShapeTests {

    private func localAPIClient(body: Data) async -> ZoteroClient {
        let stub = StubZoteroTransport()
        await stub.enqueue(statusCode: 200, data: body)
        return ZoteroClient(transport: stub)
    }

    @Test func realZoteroBodyDecodes() async throws {
        let client = await localAPIClient(body: Data(realZoteroCSLBody.utf8))
        let csl = try await client.fetchCSL(makeRef(key: "5SXHDTMB"))

        #expect(csl.title == "Notes on the Analytical Engine (W40.d10 seed)")
        #expect(csl.type == "book")
        #expect(csl.author?.first?.family == "Lovelace")
        #expect(csl.author?.first?.given == "Ada")
        #expect(csl.issued?.dateParts == [[1843]])
        let (date, precision) = csl.mappedDate()
        #expect(date == "1843")
        #expect(precision == .year)
    }

    @Test func arrayValueDecodes() async throws {
        let body = #"{"csljson": [{"title": "Array Item", "issued": {"date-parts": [[1936, "11"]]}}]}"#
        let client = await localAPIClient(body: Data(body.utf8))
        let csl = try await client.fetchCSL(makeRef())

        #expect(csl.title == "Array Item")
        #expect(csl.issued?.dateParts == [[1936, 11]])
    }

    @Test func emptyArrayIsItemNotFound() async {
        let client = await localAPIClient(body: Data(#"{"csljson": "[]"}"#.utf8))
        await #expect(throws: ZoteroClient.ClientError.self) { try await client.fetchCSL(makeRef()) }
    }

    /// Each of these used to reach `data(withJSONObject:)` unchecked; a string raised an Objective-C
    /// exception and aborted the app. All must come back as a thrown error.
    @Test(arguments: [
        #"{"csljson": 42}"#,
        #"{"csljson": null}"#,
        #"{"csljson": "not json"}"#,
        #"{"csljson": "{\"title\": \"an object, not an array\"}"}"#,
        #"{"csljson": [42]}"#,
        #"{}"#,
    ])
    func unusableValuesThrowInsteadOfCrashing(body: String) async {
        let client = await localAPIClient(body: Data(body.utf8))
        await #expect(throws: (any Error).self) { try await client.fetchCSL(makeRef()) }
    }

    @Test func datePartsKeepTheLeadingWholeNumbers() throws {
        let json = #"[{"issued": {"date-parts": [["1843", "spring"], [" 1844 ", 2, "3"], [1.5]], "raw": "1843"}}]"#
        let item = try JSONDecoder().decode([ZoteroCSLItem].self, from: Data(json.utf8))[0]
        #expect(item.issued?.dateParts == [[1843], [1844, 2, 3], []])
        #expect(item.issued?.raw == "1843")
    }

    @Test func malformedDateDoesNotFailTheItem() throws {
        let json = #"[{"title": "Kept", "issued": {"date-parts": "1843", "raw": 1843}}]"#
        let item = try JSONDecoder().decode([ZoteroCSLItem].self, from: Data(json.utf8))[0]
        #expect(item.title == "Kept")
        #expect(item.issued?.dateParts == nil)
        #expect(item.issued?.raw == nil)
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
