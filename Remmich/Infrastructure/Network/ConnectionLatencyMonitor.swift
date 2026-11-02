import Foundation
import Observation

nonisolated enum ConnectionLatencySample: Equatable, Sendable {
    enum Phase: Equatable { case checking, response, unavailable }

    case checking
    case response(milliseconds: Int)
    case unavailable

    var phase: Phase {
        switch self {
        case .checking: .checking
        case .response: .response
        case .unavailable: .unavailable
        }
    }

    var label: String {
        switch self {
        case .checking: "Checking…"
        case let .response(milliseconds): "\(milliseconds) ms"
        case .unavailable: "Unavailable"
        }
    }
}

nonisolated struct ConnectionLatencyProbe: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let load: Loader
    private struct Ping: Decodable { let res: String }

    init(load: Loader? = nil) {
        if let load {
            self.load = load
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 1
            configuration.timeoutIntervalForResource = 2
            let session = URLSession(configuration: configuration)
            self.load = { try await session.data(for: $0) }
        }
    }

    func measure(_ endpoint: URL) async throws -> Int {
        var request = URLRequest(url: endpoint.appending(path: "server/ping"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 1
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let started = ContinuousClock.now
        let (data, response) = try await load(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              try JSONDecoder().decode(Ping.self, from: data).res == "pong" else { throw URLError(.badServerResponse) }
        let elapsed = started.duration(to: .now).components
        return max(1, Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
    }
}

@MainActor
@Observable
final class ConnectionLatencyMonitor {
    typealias Measure = @Sendable (URL) async throws -> Int
    private(set) var samples: [URL: ConnectionLatencySample] = [:]
    private let measure: Measure
    private let interval: Duration
    private var generation: UInt64 = 0

    init(interval: Duration = .seconds(1), measure: Measure? = nil) {
        self.interval = interval
        if let measure {
            self.measure = measure
        } else {
            let probe = ConnectionLatencyProbe()
            self.measure = { try await probe.measure($0) }
        }
    }

    /// The view owns this task. Cancelling it cancels outstanding probes and
    /// the cadence wait; a newer target list invalidates late older results.
    func run(endpoints: [URL]) async {
        generation &+= 1
        let current = generation
        var seen = Set<URL>()
        let targets = endpoints.filter { seen.insert($0).inserted }
        samples = samples.filter { seen.contains($0.key) }
        for target in targets where samples[target] == nil {
            samples[target] = .checking
        }
        guard !targets.isEmpty else { return }
        let measure = measure
        while !Task.isCancelled, generation == current {
            let started = ContinuousClock.now
            await withTaskGroup(of: (URL, ConnectionLatencySample?).self) { group in
                var iterator = targets.makeIterator()
                func enqueue(_ target: URL) {
                    group.addTask {
                        do { return try await (target, .response(milliseconds: measure(target))) }
                        catch is CancellationError { return (target, nil) }
                        catch { return (target, .unavailable) }
                    }
                }
                for _ in 0 ..< 2 {
                    if let target = iterator.next() {
                        enqueue(target)
                    }
                }
                while let (target, sample) = await group.next() {
                    guard !Task.isCancelled, generation == current else { group.cancelAll(); break }
                    if let sample {
                        samples[target] = sample
                    }
                    if let next = iterator.next() {
                        enqueue(next)
                    }
                }
            }
            guard !Task.isCancelled, generation == current else { return }
            let delay = max(Duration.zero, interval - started.duration(to: .now))
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }
}
