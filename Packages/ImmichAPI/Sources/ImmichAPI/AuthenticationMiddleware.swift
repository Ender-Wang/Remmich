import Foundation
import HTTPTypes
import OpenAPIRuntime

struct AuthenticationMiddleware: ClientMiddleware {
    let credential: ImmichCredential?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try ReadOnlyOperationPolicy.validate(request: request, operationID: operationID)

        var request = request
        switch credential {
        case let .bearer(token):
            request.headerFields[.authorization] = "Bearer \(token)"
        case let .apiKey(key):
            request.headerFields[HTTPField.Name("x-api-key")!] = key
        case nil:
            break
        }
        return try await next(request, body, baseURL)
    }
}

enum ReadOnlyOperationPolicy {
    /// Immich search uses POST to receive its query and filters in a JSON body.
    /// It is server-read-only; every actual mutation remains blocked here.
    private static let allowedNonReadOperations: Set<String> = ["login", "logout", "searchAssets", "searchSmart"]

    static func validate(request: HTTPRequest, operationID: String) throws {
        let readMethods: Set<HTTPRequest.Method> = [.get, .head, .options]
        guard readMethods.contains(request.method)
            || (request.method == .post && allowedNonReadOperations.contains(operationID))
        else {
            throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
        }
    }
}
