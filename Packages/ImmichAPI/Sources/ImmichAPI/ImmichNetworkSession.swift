import Foundation
import OpenAPIURLSession

enum ImmichNetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    static let transport = URLSessionTransport(configuration: .init(session: shared))
}
