import Foundation

public struct ImmichServerDiscovery: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct WellKnown: Decodable {
        struct API: Decodable {
            let endpoint: String
        }

        let api: API
    }

    private let load: Loader

    public init(load: @escaping Loader = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.load = load
    }

    public func discover(_ input: String) async throws -> URL {
        let fallback = try ServerURLNormalizer.normalize(input)
        let discoveryURL = try ServerURLNormalizer.wellKnownURL(fromAPIURL: fallback)
        var request = URLRequest(url: discoveryURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await load(request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                return fallback
            }
            let wellKnown = try JSONDecoder().decode(WellKnown.self, from: data)
            return try ServerURLNormalizer.resolve(endpoint: wellKnown.api.endpoint, relativeTo: fallback)
        } catch { return fallback }
    }

    public func discoverAndValidate(_ input: String) async throws -> ImmichServerInfo {
        let apiURL = try await discover(input)
        return try await ImmichClient(apiURL: apiURL).validateServer()
    }
}
