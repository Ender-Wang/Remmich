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
        try await lookup(coordinate, endpoint: endpoint, language: language, automatic: false)
    }

    func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage, automatic: Bool) async throws -> PlaceLocation? {
        guard !automatic || !PlaceCacheKey.isPublicService(endpoint) else { throw PlaceLookupError.automaticPublicService }
        let decoded = try await response(Self.request(coordinate, endpoint: endpoint, language: language), automatic: automatic)
        let fallback = decoded.location(language: language)
        guard decoded.needsParkContext else { return fallback }
        do {
            let parks = try await response(Self.request(coordinate, endpoint: endpoint, language: language, parksOnly: true), automatic: automatic)
            return decoded.enclosingPark(in: parks, coordinate: coordinate, language: language) ?? fallback
        } catch {
            try Task.checkCancellation()
            if error as? PlaceLookupError == .automaticPublicService {
                throw error
            }
            // A failed optional context lookup must not discard a usable address.
            if let fallback {
                throw PlaceLookupError.contextFailed(fallback, message: error.localizedDescription, retryAfter: (error as? PlaceLookupError)?.retryDelay)
            }
            throw error
        }
    }

    private func response(_ request: URLRequest, automatic: Bool) async throws -> PhotonResponse {
        let (data, response) = try await session.data(for: request, delegate: PhotonRedirectPolicy(automatic: automatic))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw PlaceLookupError.invalidResponse }
        if automatic, (300 ..< 400).contains(response.statusCode),
           let target = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: target, relativeTo: response.url), PlaceCacheKey.isPublicService(url)
        {
            throw PlaceLookupError.automaticPublicService
        }
        guard response.statusCode == 200 else {
            throw PlaceLookupError.httpStatus(response.statusCode, retryAfter: Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard data.count <= 1_048_576 else { throw PlaceLookupError.invalidResponse }
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

    nonisolated static func retryDelay(_ header: String?, now: Date = .now) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}

private final nonisolated class PhotonRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let automatic: Bool
    init(automatic: Bool) {
        self.automatic = automatic
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    {
        if automatic, let url = request.url, PlaceCacheKey.isPublicService(url) {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
