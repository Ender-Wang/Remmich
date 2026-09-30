import Foundation
import NetworkExtension

nonisolated protocol SSIDProviding: Sendable {
    func currentSSID() async -> String?
}

struct CurrentSSIDProvider: SSIDProviding {
    func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}

actor NetworkRouteCoordinator {
    typealias Validator = @Sendable (URL) async -> Bool

    private let ssidProvider: any SSIDProviding
    private let validate: Validator
    private var generation = 0
    private(set) var activeRoute: ActiveConnectionRoute?

    init(
        ssidProvider: any SSIDProviding,
        validate: @escaping Validator
    ) {
        self.ssidProvider = ssidProvider
        self.validate = validate
    }

    func evaluate(
        _ profile: ConnectionProfile,
        preferredEndpoint: URL? = nil,
        allowSSIDlessLocalProbe: Bool = false
    ) async -> ActiveConnectionRoute? {
        generation += 1
        let evaluation = generation
        var candidates = await candidates(
            for: profile,
            allowSSIDlessLocalProbe: allowSSIDlessLocalProbe
        )
        if let preferredEndpoint,
           let index = candidates.firstIndex(where: { $0.endpoint == preferredEndpoint })
        {
            candidates.insert(candidates.remove(at: index), at: 0)
        }

        for candidate in candidates {
            // A cancelled or superseded evaluation must stop before probing another candidate,
            // not just before writing its result — otherwise a stale evaluation keeps making
            // network requests after the replacement evaluation has already started.
            guard !Task.isCancelled, evaluation == generation else { return activeRoute }
            let isReachable = await validate(candidate.endpoint)
            // Re-check immediately after the await, not only before it: cancellation can arrive
            // while `validate` is in flight, and a stale success must not be accepted just
            // because nothing else has raced ahead to bump `generation` yet.
            guard !Task.isCancelled, evaluation == generation else { return activeRoute }
            guard isReachable else { continue }
            activeRoute = candidate
            return candidate
        }
        guard !Task.isCancelled, evaluation == generation else { return activeRoute }
        activeRoute = nil
        return nil
    }

    private func candidates(
        for profile: ConnectionProfile,
        allowSSIDlessLocalProbe: Bool
    ) async -> [ActiveConnectionRoute] {
        var candidates: [ActiveConnectionRoute] = []
        if let endpoint = profile.localEndpoint {
            if allowSSIDlessLocalProbe {
                candidates.append(.init(kind: .local, endpoint: endpoint))
            } else if profile.isSSIDMatchingEnabled {
                // Only consult the SSID API when exact-SSID matching is actually in effect;
                // the entitlement-free (Personal Team) path this bypasses must not depend on it.
                let currentSSID = await ssidProvider.currentSSID()
                if currentSSID == profile.preferredSSID {
                    candidates.append(.init(kind: .local, endpoint: endpoint))
                }
            }
        }
        candidates.append(contentsOf: profile.externalEndpoints.map {
            .init(kind: .external, endpoint: $0)
        })
        return candidates
    }
}

actor ConnectionProfileStore {
    private let defaults: UserDefaults
    private let key = "connection-profile"

    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> ConnectionProfile {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: data)
        else { return .init() }
        return profile
    }

    func save(_ profile: ConnectionProfile) throws {
        try defaults.set(JSONEncoder().encode(profile), forKey: key)
    }
}
