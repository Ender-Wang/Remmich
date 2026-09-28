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
    private let localProbeTimeout: Duration
    private var generation = 0
    private(set) var activeRoute: ActiveConnectionRoute?

    init(
        ssidProvider: any SSIDProviding,
        localProbeTimeout: Duration = .seconds(2),
        validate: @escaping Validator
    ) {
        self.ssidProvider = ssidProvider
        self.localProbeTimeout = localProbeTimeout
        self.validate = validate
    }

    func evaluate(
        _ profile: ConnectionProfile,
        allowSSIDlessLocalProbe: Bool = false
    ) async -> ActiveConnectionRoute? {
        generation += 1
        let evaluation = generation
        let candidates = await candidates(
            for: profile,
            allowSSIDlessLocalProbe: allowSSIDlessLocalProbe
        )

        for candidate in candidates where await isReachable(candidate) {
            guard evaluation == generation else { return activeRoute }
            activeRoute = candidate
            return candidate
        }
        guard evaluation == generation else { return activeRoute }
        activeRoute = nil
        return nil
    }

    private func isReachable(_ candidate: ActiveConnectionRoute) async -> Bool {
        guard candidate.kind == .local else { return await validate(candidate.endpoint) }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.validate(candidate.endpoint) }
            group.addTask {
                try? await Task.sleep(for: self.localProbeTimeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func candidates(
        for profile: ConnectionProfile,
        allowSSIDlessLocalProbe: Bool
    ) async -> [ActiveConnectionRoute] {
        if let endpoint = profile.manualEndpoint {
            return [.init(kind: .manual, endpoint: endpoint)]
        }

        var candidates: [ActiveConnectionRoute] = []
        if profile.isAutomaticSwitchingEnabled, let endpoint = profile.localEndpoint {
            let currentSSID = await ssidProvider.currentSSID()
            if currentSSID == profile.preferredSSID ||
                (currentSSID == nil && allowSSIDlessLocalProbe)
            {
                candidates.append(.init(kind: .local, endpoint: endpoint))
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
