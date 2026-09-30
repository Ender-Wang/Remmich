import CryptoKit
import Foundation

nonisolated struct MediaAccountScope: Hashable, Sendable {
    let serverIdentity: String
    let userID: String

    init(session: AccountSession) {
        serverIdentity = Self.canonicalServerIdentity(session.apiURL)
        userID = session.userID
    }

    var cacheNamespace: String {
        let digest = SHA256.hash(data: Data("\(serverIdentity)|\(userID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalServerIdentity(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        components?.query = nil
        components?.fragment = nil
        if components?.path.hasSuffix("/") == true {
            components?.path.removeLast()
        }
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

nonisolated enum MediaDerivative: String, Hashable, Sendable {
    case thumbnail
    case preview
    case fullSize
    case original
    case videoPlayback
}

nonisolated struct MediaPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

nonisolated struct MediaRequestDescriptor: Hashable, Sendable {
    let assetID: String
    let updatedAt: Date
    let derivative: MediaDerivative
    let targetPixels: MediaPixelSize?

    func cacheKey(in scope: MediaAccountScope) -> String {
        let size = targetPixels.map { "\($0.width)x\($0.height)" } ?? "source"
        return [
            "remmich-v1", scope.serverIdentity, scope.userID, assetID,
            derivative.rawValue, updatedAt.ISO8601Format(), size,
        ].joined(separator: "|")
    }
}

nonisolated struct DownloadedMedia: Sendable {
    let fileURL: URL
    let suggestedFilename: String
    let mimeType: String?
}
