import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

struct SearchReadTests {
    @Test func metadataAppliesLiteralPathAndCombinedFilters() async throws {
        let client = try client { request, body, operation in
            #expect(operation == "searchAssets")
            #expect(request.method == .post)
            #expect(request.path == "/search/metadata")
            let payload = try #require(body)
            let bytes = try await Data(collecting: payload, upTo: 16384)
            let json = try JSONSerialization.jsonObject(with: bytes)
            let object = try #require(json as? [String: Any])
            let filter = try #require(object["filter"] as? [String: [String: Any]])
            #expect(object["cursor"] as? String == "cursor")
            #expect(filter["originalPath"]?["like"] as? String == #"Trips/Kyoto\_\%"#)
            #expect(filter["lensModel"]?["eq"] as? String == "Lens")
            #expect(filter["personIds"]?["all"] as? [String] == ["person"])
            #expect(filter["hasAlbums"]?["eq"] as? Bool == false)
            #expect(filter["isFavorite"]?["eq"] as? Bool == true)
            #expect(filter["visibility"]?["eq"] as? String == "archive")
            #expect(filter["type"]?["eq"] as? String == "VIDEO")
            #expect(filter["takenAt"]?["gte"] != nil)
            #expect(filter["takenAt"]?["lt"] != nil)
            return Self.page(cursor: "next")
        }
        var request = ImmichSearchRequest(mode: .path, text: "Trips/Kyoto_%")
        request.personIDs = ["person"]
        request.lens = "Lens"
        request.notInAlbum = true
        request.favorites = true
        request.archive = true
        request.media = .video
        request.taken = .init(start: .distantPast, duration: 86400)
        #expect(try await client.search(request, cursor: "cursor").nextCursor == "next")
    }

    @Test(arguments: [true, false])
    func contextUsesSmartSearchOnlyWhenTextIsPresent(hasText: Bool) async throws {
        let client = try client { request, body, operation in
            #expect(request.method == .post)
            #expect(operation == (hasText ? "searchSmart" : "searchAssets"))
            #expect(request.path == (hasText ? "/search/smart" : "/search/metadata"))
            let payload = try #require(body)
            let bytes = try await Data(collecting: payload, upTo: 16384)
            let json = try JSONSerialization.jsonObject(with: bytes)
            let object = try #require(json as? [String: Any])
            #expect(object["query"] as? String == (hasText ? "Kyoto at night" : nil))
            let filter = try #require(object["filter"] as? [String: [String: Any]])
            #expect(filter["city"]?["eq"] as? String == "Kyoto")
            return Self.page(cursor: nil)
        }
        var request = ImmichSearchRequest(mode: .context, text: hasText ? "Kyoto at night" : "")
        request.city = "Kyoto"
        #expect(try await client.search(request).assets.isEmpty)
    }

    @Test func contextExpandsTheRankedWindowOnlyWhileItIsFull() async throws {
        let request = ImmichSearchRequest(mode: .context, text: "birds")
        let windows: [(cursor: String?, size: Int, count: Int, next: String?)] = [
            (nil, 100, 100, "200"),
            ("200", 200, 200, "400"),
            ("400", 400, 215, nil),
            ("800", 800, 800, "1000"),
            ("1000", 1000, 1000, nil),
        ]
        for window in windows {
            let client = try client { request, body, operation in
                #expect(operation == "searchSmart")
                #expect(request.path == "/search/smart")
                let bytes = try await Data(collecting: #require(body), upTo: 16384)
                let payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(payload["size"] as? Int == window.size)
                #expect(payload["cursor"] == nil)
                return Self.page(cursor: nil, count: window.count)
            }
            let page = try await client.search(request, cursor: window.cursor)
            #expect(page.assets.count == window.count)
            #expect(page.nextCursor == window.next)
        }
    }

    @Test func selectsIndexedOCRAndScopesLensSuggestions() async throws {
        let client = try client { request, body, operation in
            if operation == "searchAssets" {
                let payload = try #require(body)
                let bytes = try await Data(collecting: payload, upTo: 16384)
                let json = try JSONSerialization.jsonObject(with: bytes)
                let object = try #require(json as? [String: Any])
                let filter = try #require(object["filter"] as? [String: [String: Any]])
                #expect(filter["ocr"]?["matches"] as? String == "駅")
                return Self.page(cursor: nil)
            }
            #expect(operation == "getSearchSuggestions")
            #expect(request.method == .get)
            let path = try #require(request.path)
            let queries = URLComponents(string: path)?.queryItems ?? []
            #expect(queries.contains(URLQueryItem(name: "type", value: "camera-lens-model")))
            #expect(queries.contains(URLQueryItem(name: "make", value: "Apple")))
            #expect(queries.contains(URLQueryItem(name: "model", value: "iPhone")))
            return #"["Back camera"]"#
        }
        _ = try await client.search(.init(mode: .ocr, text: "駅"))
        #expect(try await client.searchSuggestions(.lens, make: "Apple", model: "iPhone") == ["Back camera"])
    }

    @Test func smartOperationIdentifierCannotAuthorizeADelete() {
        let mutation = HTTPRequest(method: .delete, scheme: "https", authority: "example.com", path: "/assets")
        #expect(throws: ImmichAPIError.readOnlyPolicyViolation(operationID: "searchSmart")) {
            try ReadOnlyOperationPolicy.validate(request: mutation, operationID: "searchSmart")
        }
    }

    private func client(
        respond: @escaping @Sendable (HTTPRequest, HTTPBody?, String) async throws -> String
    ) throws -> ImmichClient {
        try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("token"),
                         transport: SearchRequestTransport(respond: respond))
    }

    private static func page(cursor: String?, count: Int = 0) -> String {
        let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
        let items = (0 ..< count).map { id in
            #"{"id":"\#(id)","originalPath":"image.jpg","checksum":"check","createdAt":"2026-11-01T00:00:00Z","fileCreatedAt":"2026-11-01T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"isTrashed":false,"localDateTime":"2026-11-01T00:00:00Z","originalFileName":"image.jpg","ownerId":"owner","type":"IMAGE","updatedAt":"2026-11-01T00:00:00Z","visibility":"timeline"}"#
        }.joined(separator: ",")
        return #"{"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":\#(count),"facets":[],"items":[\#(items)],"nextCursor":\#(cursorJSON),"total":\#(count)}}"#
    }
}

private struct SearchRequestTransport: ClientTransport {
    let respond: @Sendable (HTTPRequest, HTTPBody?, String) async throws -> String

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.headerFields[.authorization] == "Bearer token")
        let json = try await respond(request, body, operationID)
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
    }
}
