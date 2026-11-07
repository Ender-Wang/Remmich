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
        let request = Self.request(coordinate, endpoint: endpoint, language: language)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 1_048_576 else { throw PlaceLookupError.invalidResponse }
        let decoded = try JSONDecoder().decode(PhotonResponse.self, from: data)
        return decoded.location(language: language)
    }

    nonisolated static func request(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage) -> URLRequest {
        var components = URLComponents(url: endpoint.appending(path: "reverse"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "lat", value: String(coordinate.latitude)),
            .init(name: "lon", value: String(coordinate.longitude)),
            .init(name: "lang", value: language.photonValue),
            .init(name: "limit", value: "5"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Remmich/0.5 (+https://github.com/Ender-Wang/Remmich)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
