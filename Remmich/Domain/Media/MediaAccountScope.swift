import CryptoKit
import Foundation

nonisolated struct MediaAccountScope: Hashable, Sendable {
    let serverIdentity: String
    let userID: String

    init(session: AccountSession) {
        serverIdentity = session.cacheServerIdentity ?? Self.canonicalServerIdentity(session.apiURL)
        userID = session.userID
    }

    var cacheNamespace: String {
        let digest = SHA256.hash(data: Data("\(serverIdentity)|\(userID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalServerIdentity(_ url: URL) -> String {
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
