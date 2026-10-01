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
        (.secureConnectionFailed, .secureConnectionFailed),
        (.cancelled, .cancelled),
    ])
    func mapsNetworkErrors(code: URLError.Code, expected: ImmichAPIError) {
        #expect(ImmichClient.map(URLError(code)) == expected)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ImmichAPIError.timedOut),
        (.notConnectedToInternet, .offline),
        (.serverCertificateUntrusted, .certificateUntrusted),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.cancelled, .cancelled),
    ])
    func mapsClientErrorWrappedNetworkErrors(code: URLError.Code, expected: ImmichAPIError) {
        // OpenAPI-generated operations (getMyUser, pingServer, ...) throw OpenAPIRuntime.ClientError,
        // wrapping the real transport failure in `underlyingError` rather than throwing a bare
        // URLError directly. If this isn't unwrapped, every one of these collapses to the generic
        // `.invalidResponse` ("could not understand the response") regardless of the real cause.
        let clientError = ClientError(
            operationID: "getMyUser",
            operationInput: "unused",
            causeDescription: "transport failure",
            underlyingError: URLError(code)
        )
        #expect(ImmichClient.map(clientError) == expected)
    }

    @Test func malformedDiscoveryDocumentFallsBackToEnteredAddress() async throws {
        let discovery = ImmichServerDiscovery { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("not-json".utf8), response)
        }
        #expect(try await discovery.discover("photos.example.com") == URL(string: "https://photos.example.com/api")!)
    }
}

@Suite("Route identity validation")
struct RouteIdentityValidationTests {
    @Test func acceptsMinimalIdentityFromVersionVariantUserResponse() throws {
        let response = Data(
            #"{"id":"123e4567-e89b-42d3-a456-426614174000","futureServerField":true}"#.utf8
        )

        #expect(
            try ImmichClient.routeUserID(from: response) ==
                "123e4567-e89b-42d3-a456-426614174000"
        )
    }

    @Test func rejectsResponseWithoutIdentity() {
        #expect(throws: ImmichAPIError.invalidResponse) {
            try ImmichClient.routeUserID(from: Data(#"{"email":"reader@example.com"}"#.utf8))
        }
    }
}

@Suite("Timeline read contract")
struct TimelineReadContractTests {
    @Test func readsBucketsAndAssetsThroughApprovedGetOperations() async throws {
        let recorder = TimelineOperationRecorder()
        let client = try ImmichClient(
            apiURL: #require(URL(string: "https://photos.example.com/api")),
            credential: .bearer("reader-token"),
            transport: TimelineTransport(recorder: recorder)
        )

        let buckets = try await client.timelineBuckets()
        let assets = try await client.timelineAssets(in: buckets[0].id)
        let memories = try await client.memories()

        #expect(buckets == [.init(id: "2026-09-01T00:00:00.000Z", assetCount: 1)])
        #expect(assets.count == 1)
        #expect(assets[0].id == "asset-1")
        #expect(assets[0].mediaKind == .image)
        #expect(try memories == [
            .init(
                id: "memory-1",
                ownerID: "owner-1",
                memoryAt: #require(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")),
                kind: .onThisDay,
                assets: []
            ),
        ])
        let operations = await recorder.operations
        #expect(operations.map(\.id) == ["getTimeBuckets", "getTimeBucket", "searchMemories"])
        #expect(operations.allSatisfy { $0.method == .get })
        #expect(operations.allSatisfy { $0.authorization == "Bearer reader-token" })
        #expect(operations[0].path.contains("order=desc"))
        #expect(operations[0].path.contains("orderBy=takenAt"))
        #expect(operations[0].path.contains("visibility=timeline"))
        #expect(operations[0].path.contains("isTrashed=false"))
        #expect(operations[0].path.contains("withPartners=true"))
        #expect(operations[0].path.contains("withStacked=true"))
        #expect(operations[1].path.contains("timeBucket=2026-09-01T00%3A00%3A00.000Z"))
        #expect(operations[2].path.contains("isTrashed=false"))
        #expect(operations[2].path.contains("order=desc"))
        #expect(operations[2].path.contains("page=1"))
        #expect(operations[2].path.contains("size=20"))
    }

    @Test func preservesFractionalOffsetsAndMediaMetadata() throws {
        let response = timelineResponse(
            count: 2,
            createdAt: ["2026-03-08T01:59:59-05:00", "2026-03-08T03:00:00.125-04:00"],
            fileCreatedAt: ["2026-03-08T01:59:59.500-05:00", "2026-03-08T03:00:00-04:00"],
            duration: [nil, 12345],
            isImage: [true, false],
            localOffsetHours: [5.5, -9.75],
            livePhotoVideoID: ["live-video", nil],
            stack: [["stack-1", "4"], nil]
        )

        let assets = try ImmichClient.timelineAssets(from: response)

        #expect(assets.count == 2)
        #expect(assets[0].localOffsetHours == 5.5)
        #expect(assets[0].livePhotoVideoID == "live-video")
        #expect(assets[0].stack == .init(id: "stack-1", assetCount: 4))
        #expect(assets[1].localOffsetHours == -9.75)
        #expect(assets[1].mediaKind == .video)
        #expect(assets[1].durationMilliseconds == 12345)
    }

    @Test func toleratesMissingAndShortOptionalColumns() throws {
        var response = timelineResponse(count: 3)
        response.city = ["Shanghai"]
        response.country = nil
        response.latitude = [31.23, nil]
        response.longitude = []
        response.stack = [["stack-1", "2"]]

        let assets = try ImmichClient.timelineAssets(from: response)

        #expect(assets[0].city == "Shanghai")
        #expect(assets[1].city == nil)
        #expect(assets[2].latitude == nil)
        #expect(assets.allSatisfy { $0.country == nil && $0.longitude == nil })
    }

    @Test func rejectsMismatchedRequiredColumns() {
        var response = timelineResponse(count: 2)
        response.ownerId.removeLast()

        #expect(throws: ImmichAPIError.invalidResponse) {
            try ImmichClient.timelineAssets(from: response)
        }
    }

    @Test func rejectsInvalidDatesAndAspectRatios() {
        var response = timelineResponse(count: 1)
        response.fileCreatedAt[0] = "not-a-date"
        #expect(throws: ImmichAPIError.invalidResponse) {
            try ImmichClient.timelineAssets(from: response)
        }

        response = timelineResponse(count: 1)
        response.ratio[0] = 0
        #expect(throws: ImmichAPIError.invalidResponse) {
            try ImmichClient.timelineAssets(from: response)
        }
    }

    @Test func decodesLargeBucketWithoutChangingOrder() throws {
        let assets = try ImmichClient.timelineAssets(from: timelineResponse(count: 5000))

        #expect(assets.count == 5000)
        #expect(assets.first?.id == "asset-0")
        #expect(assets.last?.id == "asset-4999")
    }

    @Test func retainsUnknownFutureVisibilityAtStableBoundary() throws {
        let visibility = try JSONDecoder().decode(
            ImmichAssetVisibility.self,
            from: Data(#""future-scope""#.utf8)
        )

        #expect(visibility == .unknown("future-scope"))
        #expect(visibility.serverValue == "future-scope")
        #expect(try JSONEncoder().encode(visibility) == Data(#""future-scope""#.utf8))
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

private actor TimelineOperationRecorder {
    struct Operation: Sendable {
        let id: String
        let method: HTTPRequest.Method
        let path: String
        let authorization: String?
    }

    private(set) var operations: [Operation] = []

    func record(_ request: HTTPRequest, operationID: String) {
        operations.append(.init(
            id: operationID,
            method: request.method,
            path: request.path ?? "",
            authorization: request.headerFields[.authorization]
        ))
    }
}

private struct TimelineTransport: ClientTransport {
    let recorder: TimelineOperationRecorder

    func send(
        _ request: HTTPRequest,
        body _: HTTPBody?,
        baseURL _: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await recorder.record(request, operationID: operationID)
        let json: String = switch operationID {
        case "getTimeBuckets":
            #"[{"count":1,"timeBucket":"2026-09-01T00:00:00.000Z"}]"#
        case "getTimeBucket":
            #"{"createdAt":["2026-09-01T00:00:01Z"],"duration":[null],"fileCreatedAt":["2026-09-01T00:00:00.125Z"],"id":["asset-1"],"isFavorite":[false],"isImage":[true],"isTrashed":[false],"livePhotoVideoId":[null],"localOffsetHours":[5.5],"ownerId":["owner-1"],"projectionType":[null],"ratio":[1.5],"thumbhash":[null],"visibility":["timeline"]}"#
        case "searchMemories":
            #"[{"assets":[],"createdAt":"2026-09-01T00:00:00Z","data":{"year":2025},"id":"memory-1","isSaved":false,"memoryAt":"2026-09-01T00:00:00Z","ownerId":"owner-1","type":"on_this_day","updatedAt":"2026-09-01T00:00:00Z"}]"#
        default:
            throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

private func timelineResponse(
    count: Int,
    createdAt: [String]? = nil,
    fileCreatedAt: [String]? = nil,
    duration: [Int?]? = nil,
    isImage: [Bool]? = nil,
    localOffsetHours: [Double]? = nil,
    livePhotoVideoID: [String?]? = nil,
    stack: [[String]?]? = nil
) -> Components.Schemas.TimeBucketAssetResponseDto {
    Components.Schemas.TimeBucketAssetResponseDto(
        createdAt: createdAt ?? Array(repeating: "2026-09-01T00:00:01Z", count: count),
        duration: duration ?? Array(repeating: nil, count: count),
        fileCreatedAt: fileCreatedAt ?? Array(repeating: "2026-09-01T00:00:00.125Z", count: count),
        id: (0 ..< count).map { "asset-\($0)" },
        isFavorite: Array(repeating: false, count: count),
        isImage: isImage ?? Array(repeating: true, count: count),
        isTrashed: Array(repeating: false, count: count),
        livePhotoVideoId: livePhotoVideoID ?? Array(repeating: nil, count: count),
        localOffsetHours: localOffsetHours ?? Array(repeating: 0, count: count),
        ownerId: Array(repeating: "owner-1", count: count),
        projectionType: Array(repeating: nil, count: count),
        ratio: Array(repeating: 1.5, count: count),
        stack: stack,
        thumbhash: Array(repeating: nil, count: count),
        visibility: Array(repeating: .timeline, count: count)
    )
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
