import Foundation
import Testing
@testable import Remmich

struct ConnectionLatencyTests {
    @Test func healthProbeUsesTheAPIBaseAndNoCredentials() async throws {
        let endpoint = try #require(URL(string: "http://photos.example:2283/photos/api"))
        let probe = ConnectionLatencyProbe { request in
            #expect(request.url?.absoluteString == "http://photos.example:2283/photos/api/server/ping")
            #expect(request.httpMethod == "GET" && request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 1)
            return (Data(#"{"res":"pong"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await probe.measure(endpoint) >= 1)
    }

    @Test(arguments: [200, 401, 503]) func invalidResponsesAreNotReportedAsHealthy(status: Int) async throws {
        let endpoint = try #require(URL(string: "https://photos.example/api"))
        let probe = ConnectionLatencyProbe { request in
            (Data(#"{"res":"not-pong"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: URLError.self) { try await probe.measure(endpoint) }
    }

    @Test @MainActor func roundsAreBoundedNonoverlappingAndCancellationStopsThem() async throws {
        let tracker = ConnectionProbeTracker()
        let monitor = ConnectionLatencyMonitor(interval: .milliseconds(10)) { endpoint in try await tracker.measure(endpoint) }
        let targets = (1 ... 3).map { URL(string: "https://photos\($0).example/api")! }
        let work = Task { await monitor.run(endpoints: targets + targets) }
        try await waitUntil { await tracker.finished >= 6 }
        work.cancel()
        await work.value
        #expect(await tracker.peak <= 2)
        #expect(await tracker.active == 0)
        #expect(await tracker.finishedWhenFourthStarted == 3)
        #expect(monitor.samples.count == 3)
        #expect(monitor.samples.values.allSatisfy { $0 == .response(milliseconds: 12) })
        let count = await tracker.started
        try await Task.sleep(for: .milliseconds(20))
        #expect(await tracker.started == count)
    }

    @Test @MainActor func newerTargetsRejectLateOldResults() async throws {
        let gate = ConnectionProbeGate()
        let oldURL = try #require(URL(string: "https://old.example/api"))
        let newURL = try #require(URL(string: "https://new.example/api"))
        let monitor = ConnectionLatencyMonitor { endpoint in
            endpoint == oldURL ? await gate.wait() : 42
        }
        let old = Task { await monitor.run(endpoints: [oldURL]) }
        try await waitUntil { await gate.started }
        let new = Task { await monitor.run(endpoints: [newURL]) }
        try await waitUntil { monitor.samples[newURL] == .response(milliseconds: 42) }
        await gate.resolve()
        await old.value
        new.cancel()
        await new.value
        #expect(monitor.samples[oldURL] == nil)
        #expect(monitor.samples[newURL] == .response(milliseconds: 42))
    }

    @Test @MainActor func emptyTargetsStopAndClearReadings() async {
        let monitor = ConnectionLatencyMonitor { _ in throw URLError(.notConnectedToInternet) }
        await monitor.run(endpoints: [])
        #expect(monitor.samples.isEmpty)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Latency test did not reach the expected state")
    }
}

private actor ConnectionProbeTracker {
    var active = 0
    var peak = 0
    var started = 0
    var finished = 0
    var finishedWhenFourthStarted: Int?
    func measure(_: URL) async throws -> Int {
        active += 1; started += 1; peak = max(peak, active)
        if started == 4 {
            finishedWhenFourthStarted = finished
        }
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        finished += 1
        return 12
    }
}

private actor ConnectionProbeGate {
    var started = false
    private var continuation: CheckedContinuation<Int, Never>?
    func wait() async -> Int {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve() {
        continuation?.resume(returning: 99); continuation = nil
    }
}
