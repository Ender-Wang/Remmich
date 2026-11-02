import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

struct QueuedGETTransportTests {
    @Test func preservesBasePathQueryAuthorizationAndTypedResponse() async throws {
        let base = try #require(URL(string: "https://photos.example/immich/api"))
        let transport = ImmichQueuedGETTransport { request, operation in
            #expect(request.url?.absoluteString == "https://photos.example/immich/api/timeline/bucket?timeBucket=2026-11-01")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(operation == "getTimeBucket")
            return (Data("{\"ids\":[]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json"])!)
        }
        var request = HTTPRequest(method: .get, scheme: "https", authority: "photos.example",
                                  path: "/timeline/bucket?timeBucket=2026-11-01")
        request.headerFields[.authorization] = "Bearer test-token"
        let (response, body) = try await transport.send(request, body: nil, baseURL: base, operationID: "getTimeBucket")
        #expect(response.status.code == 200)
        #expect(response.headerFields[.contentType] == "application/json")
        let bytes = try await Data(collecting: #require(body), upTo: 1024)
        #expect(bytes == Data("{\"ids\":[]}".utf8))
    }

    @Test func rejectsNonGETAndRequestBodies() async throws {
        let transport = ImmichQueuedGETTransport { _, _ in
            Issue.record("Unsupported requests must not reach the durable queue")
            throw CancellationError()
        }
        let base = try #require(URL(string: "https://photos.example/api"))
        await #expect(throws: ImmichAPIError.invalidResponse) {
            try await transport.send(HTTPRequest(method: .post, scheme: "https", authority: "photos.example", path: "/assets"),
                                     body: nil, baseURL: base, operationID: "mutation")
        }
        await #expect(throws: ImmichAPIError.invalidResponse) {
            try await transport.send(HTTPRequest(method: .get, scheme: "https", authority: "photos.example", path: "/assets"),
                                     body: HTTPBody(Data([1])), baseURL: base, operationID: "getAssets")
        }
    }

    @Test func preservesCancellationForTheCallingPipeline() async throws {
        let transport = ImmichQueuedGETTransport { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await transport.send(HTTPRequest(method: .get, scheme: "https", authority: "photos.example", path: "/assets"),
                                     body: nil, baseURL: #require(URL(string: "https://photos.example/api")), operationID: "getAssets")
        }
    }
}
