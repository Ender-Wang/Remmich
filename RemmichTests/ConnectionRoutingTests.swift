import Foundation
import Testing
@testable import Remmich

struct ConnectionRoutingTests {
    @Test func primaryThenFallbacksAreCheckedInOrder() async {
        let recorder = ConnectionEndpointRecorder()
        let profile = profile()
        let coordinator = NetworkRouteCoordinator { endpoint in
            await recorder.append(endpoint)
            return endpoint == profile.fallbackEndpoints.last
        }
        let route = await coordinator.evaluate(profile)
        #expect(route == profile.routes.last)
        #expect(await recorder.values == profile.endpoints)
    }

    @Test func aNewEvaluationRecoversPrimaryAfterUsingFallback() async {
        let state = ConnectionReachability()
        let profile = profile()
        let coordinator = NetworkRouteCoordinator { endpoint in await state.accept(endpoint, primary: profile.primaryEndpoint!) }
        #expect(await coordinator.evaluate(profile)?.kind == .fallback)
        await state.enablePrimary()
        #expect(await coordinator.evaluate(profile)?.kind == .primary)
    }

    @Test func duplicateAddressesAreCheckedOnceAndPrimaryIsOptional() async throws {
        let url = try #require(URL(string: "https://photos.example/api"))
        let profile = ConnectionProfile(primaryEndpoint: url, fallbackEndpoints: [url, url])
        #expect(profile.endpoints == [url])
        #expect(profile.routes.first?.kind == .primary)
        let fallbackOnly = ConnectionProfile(fallbackEndpoints: [url])
        let coordinator = NetworkRouteCoordinator { _ in true }
        #expect(await coordinator.evaluate(fallbackOnly)?.kind == .fallback)
    }

    @Test func cancellationRejectsLateSuccessWithoutProbingFallbacks() async throws {
        let gate = ConnectionValidationGate()
        let recorder = ConnectionEndpointRecorder()
        let coordinator = NetworkRouteCoordinator { endpoint in
            await recorder.append(endpoint)
            return await gate.wait()
        }
        let profile = profile()
        let evaluation = Task { await coordinator.evaluate(profile) }
        try await waitUntil { await gate.started }
        evaluation.cancel()
        await gate.resolve(true)
        #expect(await evaluation.value == nil)
        #expect(try await recorder.values == [#require(profile.primaryEndpoint)])
    }

    @Test func supersededEvaluationCannotReplaceTheNewerRoute() async throws {
        let gate = ConnectionValidationGate()
        let first = profile()
        let second = ConnectionProfile(fallbackEndpoints: [first.fallbackEndpoints[1]])
        let coordinator = NetworkRouteCoordinator { endpoint in
            endpoint == first.primaryEndpoint ? await gate.wait() : true
        }
        let pending = Task { await coordinator.evaluate(first) }
        try await waitUntil { await gate.started }
        let chosen = await coordinator.evaluate(second)
        await gate.resolve(true)
        #expect(await pending.value == chosen)
        #expect(await coordinator.activeRoute == chosen)
    }

    @Test(arguments: ["https://photos.example/api", "http://photos.example:2283/photos/api", "https://photos.example/apiary"])
    func displayHidesOnlyTheTrailingAPIComponent(input: String) throws {
        let endpoint = try #require(URL(string: input))
        let expected = input.hasSuffix("/api") ? String(input.dropLast(4)) : input
        #expect(ConnectionAddressFormatting.serverAddress(endpoint) == expected)
        #expect(endpoint.absoluteString == input)
    }

    @Test func profileEncodingUsesOnlyPrimaryAndFallbackFields() throws {
        let original = profile()
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["primaryEndpoint", "fallbackEndpoints"])
        #expect(try JSONDecoder().decode(ConnectionProfile.self, from: data) == original)
    }

    private func profile() -> ConnectionProfile {
        .init(primaryEndpoint: URL(string: "http://photos.example:2283/api")!,
              fallbackEndpoints: [URL(string: "https://one.example/api")!, URL(string: "https://two.example/api")!])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 100 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Route test did not reach its suspended validation")
    }
}

private actor ConnectionEndpointRecorder {
    var values: [URL] = []
    func append(_ value: URL) {
        values.append(value)
    }
}

private actor ConnectionReachability {
    var primaryAvailable = false
    func enablePrimary() {
        primaryAvailable = true
    }

    func accept(_ endpoint: URL, primary: URL) -> Bool {
        endpoint != primary || primaryAvailable
    }
}

private actor ConnectionValidationGate {
    var started = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: Bool) {
        continuation?.resume(returning: value); continuation = nil
    }
}
