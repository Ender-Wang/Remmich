import Foundation

public enum ServerURLNormalizer {
    public static func normalize(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImmichAPIError.invalidServerURL }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate), components.host != nil else {
            throw ImmichAPIError.invalidServerURL
        }
        guard components.scheme == "http" || components.scheme == "https" else {
            throw ImmichAPIError.unsupportedScheme
        }

        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" {
            path = "/api"
        } else if !path.hasSuffix("/api") {
            path += "/api"
        }
        components.path = path

        guard let url = components.url else { throw ImmichAPIError.invalidServerURL }
        return url
    }

    public static func serverRoot(fromAPIURL apiURL: URL) throws -> URL {
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw ImmichAPIError.invalidServerURL
        }
        var path = components.path
        if path.hasSuffix("/api") {
            path.removeLast(4)
        }
        components.path = path.isEmpty ? "/" : path
        guard let url = components.url else { throw ImmichAPIError.invalidServerURL }
        return url
    }

    public static func wellKnownURL(fromAPIURL apiURL: URL) throws -> URL {
        try serverRoot(fromAPIURL: apiURL)
            .appending(path: ".well-known/immich", directoryHint: .notDirectory)
    }

    static func resolve(endpoint: String, relativeTo apiURL: URL) throws -> URL {
        if let absolute = URL(string: endpoint), absolute.scheme != nil {
            return try normalize(absolute.absoluteString)
        }
        let root = try serverRoot(fromAPIURL: apiURL)
        guard let resolved = URL(string: endpoint, relativeTo: root)?.absoluteURL else {
            throw ImmichAPIError.discoveryFailed
        }
        return try normalize(resolved.absoluteString)
    }
}
