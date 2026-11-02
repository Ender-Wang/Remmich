import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Preserve generated request construction and decoding while an app-owned
/// durable queue provides the GET response bytes.
public struct ImmichQueuedGETTransport: ClientTransport {
    public typealias Loader = @Sendable (URLRequest, String) async throws -> (Data, HTTPURLResponse)
    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        guard request.method == .get, body == nil,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let path = URLComponents(string: request.path ?? "") else { throw ImmichAPIError.invalidResponse }
        components.percentEncodedPath += path.percentEncodedPath
        components.percentEncodedQuery = path.percentEncodedQuery
        guard let url = components.url else { throw ImmichAPIError.invalidResponse }
        var nativeRequest = URLRequest(url: url)
        nativeRequest.httpMethod = "GET"
        for field in request.headerFields {
            nativeRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        let (data, response) = try await loader(nativeRequest, operationID)
        guard (100 ... 599).contains(response.statusCode) else { throw ImmichAPIError.invalidResponse }
        var result = HTTPResponse(status: .init(code: response.statusCode))
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            result.headerFields[.contentType] = contentType
        }
        return (result, HTTPBody(data, length: .known(Int64(data.count)), iterationBehavior: .multiple))
    }
}
