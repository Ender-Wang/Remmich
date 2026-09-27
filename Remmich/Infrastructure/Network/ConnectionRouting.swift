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

    init(ssidProvider: any SSIDProviding, validate: @escaping Validator) {
        self.ssidProvider = ssidProvider
        self.validate = validate
    }

    func evaluate(_ profile: ConnectionProfile) async -> ActiveConnectionRoute? {
        generation += 1
        let evaluation = generation
        let candidates = await candidates(for: profile)

        for candidate in candidates where await validate(candidate.endpoint) {
            guard evaluation == generation else { return activeRoute }
            activeRoute = candidate
            return candidate
        }
        guard evaluation == generation else { return activeRoute }
        activeRoute = nil
        return nil
    }

    private func candidates(for profile: ConnectionProfile) async -> [ActiveConnectionRoute] {
        if let endpoint = profile.manualEndpoint {
            return [.init(kind: .manual, endpoint: endpoint)]
        }

        var candidates: [ActiveConnectionRoute] = []
        if profile.isAutomaticSwitchingEnabled,
           await ssidProvider.currentSSID() == profile.preferredSSID,
           let endpoint = profile.localEndpoint
        {
            candidates.append(.init(kind: .local, endpoint: endpoint))
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
