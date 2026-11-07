import Foundation

actor PhotonPlaceClient: PlaceLookingUp {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage) async throws -> PlaceLocation? {
        let decoded = try await response(Self.request(coordinate, endpoint: endpoint, language: language))
        let fallback = decoded.location(language: language)
        guard decoded.needsParkContext else { return fallback }
        do {
            let parks = try await response(Self.request(coordinate, endpoint: endpoint, language: language, parksOnly: true))
            return decoded.enclosingPark(in: parks, coordinate: coordinate, language: language) ?? fallback
        } catch {
            try Task.checkCancellation()
            // A failed optional context lookup must not discard a usable address.
            return fallback
        }
    }

    private func response(_ request: URLRequest) async throws -> PhotonResponse {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 1_048_576 else { throw PlaceLookupError.invalidResponse }
        return try JSONDecoder().decode(PhotonResponse.self, from: data)
    }

    nonisolated static func request(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage, parksOnly: Bool = false) -> URLRequest {
        var components = URLComponents(url: endpoint.appending(path: "reverse"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "lat", value: String(coordinate.latitude)),
            .init(name: "lon", value: String(coordinate.longitude)),
            .init(name: "lang", value: language.photonValue),
            .init(name: "limit", value: parksOnly ? "10" : "5"),
        ]
        if parksOnly {
            components.queryItems?.append(contentsOf: [.init(name: "osm_tag", value: "leisure:park"), .init(name: "radius", value: "2")])
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Remmich/0.5 (+https://github.com/Ender-Wang/Remmich)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
