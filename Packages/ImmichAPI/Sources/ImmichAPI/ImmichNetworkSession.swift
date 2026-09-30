import Foundation
import OpenAPIURLSession

enum ImmichNetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    static let transport = URLSessionTransport(configuration: .init(session: shared))

    /// A short-timeout session for background route-health checks, distinct from `shared`.
    /// Route validation must fail fast; interactive onboarding/login keeps the longer patience of `shared`.
    static let routeCheck: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        // `timeoutIntervalForRequest` only bounds stalls in an already-open transfer; it is not
        // a hard wall-clock ceiling on the whole operation (DNS, proxy, TLS, transfer, auth).
        // `timeoutIntervalForResource` is the absolute deadline that actually enforces that.
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()

    static let routeCheckTransport = URLSessionTransport(configuration: .init(session: routeCheck))
}
