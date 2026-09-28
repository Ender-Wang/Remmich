import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

@Suite("Server URL normalization")
struct ServerURLNormalizerTests {
    @Test(arguments: [
        ("photos.example.com", "https://photos.example.com/api"),
        ("https://photos.example.com", "https://photos.example.com/api"),
        ("https://photos.example.com/api/", "https://photos.example.com/api"),
        ("http://192.168.1.20:2283", "http://192.168.1.20:2283/api"),
        ("https://example.com/immich", "https://example.com/immich/api"),
        ("https://example.com/immich/api?ignored=yes#fragment", "https://example.com/immich/api"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerURLNormalizer.normalize(input).absoluteString == expected)
    }

    @Test func rejectsUnsupportedSchemes() {
        #expect(throws: ImmichAPIError.unsupportedScheme) {
            try ServerURLNormalizer.normalize("ftp://photos.example.com")
        }
    }
}

@Suite("Read-only request boundary")
struct AuthenticationMiddlewareTests {
    @Test func attachesBearerToReads() async throws {
        let middleware = AuthenticationMiddleware(credential: .bearer("secret"))
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/api/server/ping")
        let (response, _) = try await middleware.intercept(
            request,
            body: nil,
            baseURL: #require(URL(string: "https://example.com/api")),
            operationID: "pingServer"
        ) { forwarded, _, _ in
            #expect(forwarded.headerFields[.authorization] == "Bearer secret")
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(response.status == .ok)
    }

    @Test func attachesAPIKeyToReads() async throws {
        let middleware = AuthenticationMiddleware(credential: .apiKey("key"))
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/api/server/ping")
        _ = try await middleware.intercept(
            request,
            body: nil,
            baseURL: #require(URL(string: "https://example.com/api")),
            operationID: "pingServer"
        ) { forwarded, _, _ in
            #expect(forwarded.headerFields[HTTPField.Name("x-api-key")!] == "key")
            return (HTTPResponse(status: .ok), nil)
        }
    }

    @Test func blocksServerMutation() async throws {
        let middleware = AuthenticationMiddleware(credential: nil)
        let request = HTTPRequest(method: .delete, scheme: "https", authority: "example.com", path: "/api/assets/id")
        await #expect(throws: ImmichAPIError.readOnlyPolicyViolation(operationID: "deleteAssets")) {
            _ = try await middleware.intercept(
                request,
                body: nil,
                baseURL: #require(URL(string: "https://example.com/api")),
                operationID: "deleteAssets"
            ) { _, _, _ in
                Issue.record("A blocked request reached transport")
                return (HTTPResponse(status: .ok), nil)
            }
        }
    }

    @Test(arguments: ["login", "logout"])
    func permitsSessionOperations(operationID: String) throws {
        let request = HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/api/auth")
        #expect(throws: Never.self) {
            try ReadOnlyOperationPolicy.validate(request: request, operationID: operationID)
        }
    }
}

@Suite("Discovery and error mapping")
struct DiscoveryTests {
    @Test func resolvesAdvertisedEndpoint() async throws {
        let discovery = ImmichServerDiscovery { request in
            #expect(request.url?.absoluteString == "https://photos.example.com/.well-known/immich")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(#"{"api":{"endpoint":"/immich/api"}}"#.utf8), response)
        }
        #expect(try await discovery.discover("photos.example.com") == URL(string: "https://photos.example.com/immich/api")!)
    }

    @Test(arguments: [
        (401, ImmichAPIError.unauthorized),
        (403, ImmichAPIError.forbidden),
        (404, ImmichAPIError.notFound),
        (429, ImmichAPIError.rateLimited),
        (503, ImmichAPIError.serverError(503)),
    ])
    func mapsStatuses(status: Int, expected: ImmichAPIError) {
        #expect(ImmichClient.map(status: status) == expected)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ImmichAPIError.timedOut),
        (.notConnectedToInternet, .offline),
        (.serverCertificateUntrusted, .certificateUntrusted),
        (.cancelled, .cancelled),
    ])
    func mapsNetworkErrors(code: URLError.Code, expected: ImmichAPIError) {
        #expect(ImmichClient.map(URLError(code)) == expected)
    }

    @Test func malformedDiscoveryDocumentFallsBackToEnteredAddress() async throws {
        let discovery = ImmichServerDiscovery { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("not-json".utf8), response)
        }
        #expect(try await discovery.discover("photos.example.com") == URL(string: "https://photos.example.com/api")!)
    }
}

@Suite("Onboarding operation audit")
struct OnboardingOperationAuditTests {
    @Test func recordsOnlyApprovedOperations() async throws {
        let recorder = OperationRecorder()
        let client = try ImmichClient(
            apiURL: #require(URL(string: "https://photos.example.com/api")),
            transport: OnboardingTransport(recorder: recorder)
        )

        let info = try await client.validateServer()
        let session = try await client.login(email: "reader@example.com", password: "password")
        let userID = try await client.authenticatedUserID()
        try await client.logout()

        #expect(info.version.description == "v3.2.0")
        #expect(session.userEmail == "reader@example.com")
        #expect(userID == session.userID)
        let operations = await recorder.operations
        #expect(Set(operations.map(\.id)) == [
            "pingServer", "getServerVersion", "getServerConfig", "getServerFeatures", "login", "getMyUser", "logout",
        ])
        #expect(operations.allSatisfy { operation in
            operation.method == .get ||
                (operation.method == .post && ["login", "logout"].contains(operation.id))
        })
    }
}

private actor OperationRecorder {
    struct Operation: Sendable {
        let id: String
        let method: HTTPRequest.Method
    }

    private(set) var operations: [Operation] = []

    func record(id: String, method: HTTPRequest.Method) {
        operations.append(.init(id: id, method: method))
    }
}

private struct OnboardingTransport: ClientTransport {
    let recorder: OperationRecorder

    func send(
        _ request: HTTPRequest,
        body _: HTTPBody?,
        baseURL _: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await recorder.record(id: operationID, method: request.method)
        let (status, json): (HTTPResponse.Status, String) = switch operationID {
        case "pingServer": (.ok, #"{"res":"pong"}"#)
        case "getServerVersion": (.ok, #"{"major":3,"minor":2,"patch":0}"#)
        case "getServerConfig": (.ok, #"{"externalDomain":"https://photos.example.com","isInitialized":true,"isOnboarded":true,"loginPageMessage":"","maintenanceMode":false,"mapDarkStyleUrl":"","mapLightStyleUrl":"","minFaces":3,"oauthButtonText":"Login with OAuth","publicUsers":false,"trashDays":30,"userDeleteDelay":7}"#)
        case "getServerFeatures": (.ok, #"{"configFile":true,"duplicateDetection":true,"email":false,"facialRecognition":true,"importFaces":true,"map":true,"oauth":false,"oauthAutoLaunch":false,"ocr":true,"passwordLogin":true,"realtimeTranscoding":true,"reverseGeocoding":true,"search":true,"sidecar":true,"smartSearch":true,"trash":true}"#)
        case "login": (.created, #"{"accessToken":"token","isAdmin":false,"isOnboarded":true,"name":"Reader","profileImagePath":"","shouldChangePassword":false,"userEmail":"reader@example.com","userId":"123e4567-e89b-42d3-a456-426614174000"}"#)
        case "getMyUser": (.ok, #"{"avatarColor":"primary","clusterGroupId":"223e4567-e89b-42d3-a456-426614174000","createdAt":"2026-01-01T00:00:00Z","deletedAt":null,"email":"reader@example.com","id":"123e4567-e89b-42d3-a456-426614174000","isAdmin":false,"license":null,"name":"Reader","oauthId":"","profileChangedAt":"2026-01-01T00:00:00Z","profileImagePath":"","quotaSizeInBytes":null,"quotaUsageInBytes":0,"shouldChangePassword":false,"status":"active","storageLabel":null,"updatedAt":"2026-01-01T00:00:00Z"}"#)
        case "logout": (.ok, #"{"redirectUri":"/","successful":true}"#)
        default: throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
        }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}
