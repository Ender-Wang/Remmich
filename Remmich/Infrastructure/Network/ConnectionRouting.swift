import Foundation

actor NetworkRouteCoordinator {
    typealias Validator = @Sendable (URL) async -> Bool

    private let validate: Validator
    private var generation = 0
    private(set) var activeRoute: ActiveConnectionRoute?

    init(
        validate: @escaping Validator
    ) {
        self.validate = validate
    }

    func evaluate(
        _ profile: ConnectionProfile
    ) async -> ActiveConnectionRoute? {
        generation += 1
        let evaluation = generation
        for candidate in profile.routes {
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
