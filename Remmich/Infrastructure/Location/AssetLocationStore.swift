import Foundation
import ImmichAPI
import Observation
import OSLog
import SwiftUI

@MainActor @Observable final class AssetLocationStore {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "PlaceCache")
    private(set) var namespace: String?
    private(set) var preferences = MapsPlacesPreferences()
    private(set) var revision = 0
    private(set) var mapStyles: AssetMapStyles?
    private(set) var mapEndpoint: URL?
    private(set) var progress = PlaceCacheProgress()
    private(set) var lastStorageError: String?
    @ObservationIgnored var preferencesDidChange: (() -> Void)?
    @ObservationIgnored private var mapSession: AccountSession?
    @ObservationIgnored private var validatedMapEndpoint: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: any PlaceLookingUp
    @ObservationIgnored private let store: any LibraryIndexStoring
    @ObservationIgnored private var scope: MediaAccountScope?
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private var configuration: Task<Void, Error>?
    @ObservationIgnored private var requests: [String: (id: UUID, task: Task<PlaceLocation?, Error>, consumers: Set<UUID>)] = [:]
    @ObservationIgnored private let requestInterval: Duration
    @ObservationIgnored private var activeRequest: UUID?
    @ObservationIgnored private var waitingRequests: [(id: UUID, automatic: Bool, continuation: CheckedContinuation<Void, Error>)] = []

    init(defaults: UserDefaults = .standard, client: any PlaceLookingUp = PhotonPlaceClient(),
         store: any LibraryIndexStoring = SQLiteLibraryIndexStore(), requestInterval: Duration = .seconds(1))
    {
        self.defaults = defaults
        self.client = client
        self.store = store
        self.requestInterval = requestInterval
    }

    var automaticCachingAllowed: Bool {
        guard let endpoint = try? MapsPlacesPreferences.endpointURL(preferences.endpoint) else { return false }
        return !PlaceCacheKey.isPublicService(endpoint)
    }

    func configure(scope: MediaAccountScope) {
        guard namespace != scope.cacheNamespace else { return }
        reset()
        self.scope = scope
        namespace = scope.cacheNamespace
        preferences = Self.read(MapsPlacesPreferences.self, defaults: defaults, key: "maps-places-preferences-\(scope.cacheNamespace)") ?? .init()
        mapStyles = Self.read(AssetMapStyles.self, defaults: defaults, key: "maps-places-styles-\(scope.cacheNamespace)")
        defaults.removeObject(forKey: "maps-places-cache-\(scope.cacheNamespace)")
        revision &+= 1
        persistConfiguration()
    }

    func reset() {
        let previous = configuration
        let oldScope = scope
        let oldSession = sessionID
        requests.values.forEach { $0.task.cancel() }
        requests = [:]
        configuration = Task { [store] in
            _ = try? await previous?.value
            if let oldScope {
                try await store.deactivatePlaces(scope: oldScope, sessionID: oldSession)
            }
        }
        scope = nil
        namespace = nil
        sessionID = UUID().uuidString
        preferences = .init()
        progress = .init()
        lastStorageError = nil
        mapStyles = nil
        mapEndpoint = nil
        mapSession = nil
        validatedMapEndpoint = nil
        revision &+= 1
    }

    func save(_ value: MapsPlacesPreferences) throws {
        var normalized = value
        normalized.endpoint = try MapsPlacesPreferences.endpointURL(value.endpoint).absoluteString
        guard let namespace, preferences != normalized else { return }
        preferences = normalized
        revision &+= 1
        try defaults.set(JSONEncoder().encode(normalized), forKey: "maps-places-preferences-\(namespace)")
        persistConfiguration()
    }

    private func persistConfiguration() {
        guard let scope else { return }
        let previous = configuration
        let settings = preferences
        let token = sessionID
        configuration = Task { [weak self, store] in
            _ = try? await previous?.value
            guard let self, sessionID == token else { throw CancellationError() }
            do {
                try await store.configurePlaces(scope: scope, preferences: settings, sessionID: token)
                guard sessionID == token else { throw CancellationError() }
                lastStorageError = nil
                if preferences == settings {
                    await reloadProgress()
                    let automatic = automaticCachingAllowed
                    let report = progress
                    Self.logger.info("Place cache configured automatic=\(automatic) eligible=\(report.eligible) resolved=\(report.resolved) pending=\(report.pending) failed=\(report.failed)")
                    preferencesDidChange?()
                }
            } catch {
                if !(error is CancellationError), sessionID == token {
                    lastStorageError = error.localizedDescription
                }
                throw error
            }
        }
    }

    func resolve(_ coordinate: PlaceCoordinate, assetID: String) async throws -> PlaceLocation? {
        try await configuration?.value
        guard let scope else { return nil }
        let token = sessionID
        // At most English country discovery followed by the selected Local variant.
        for _ in 0 ..< 2 {
            guard let record = try await store.desiredPlace(assetID: assetID, scope: scope),
                  record.key.coordinate == coordinate, sessionID == token else { return nil }
            if record.isFresh(at: .now) {
                return record.location
            }
            do {
                _ = try await fetch(record.key, scope: scope, token: token, automatic: false)
            } catch let error as LibraryIndexStoreError {
                if token == sessionID {
                    lastStorageError = error.localizedDescription
                }
                throw error
            }
            await reloadProgress()
            guard token == sessionID else { throw CancellationError() }
            if let updated = try await store.desiredPlace(assetID: assetID, scope: scope), updated.key == record.key {
                if updated.isFresh(at: .now) {
                    return updated.location
                }
                if let location = updated.location {
                    return location
                }
                return try await store.cachedAssetMetadata(id: assetID, scope: scope)?.cachedPlace
            }
        }
        return try await store.cachedAssetMetadata(id: assetID, scope: scope)?.cachedPlace
    }

    func prepareCacheRebuild() async {
        let token = sessionID
        do {
            try await configuration?.value
            guard let scope, token == sessionID, automaticCachingAllowed else { return }
            try await store.rebuildPlaces(scope: scope, sessionID: token)
            guard token == sessionID else { return }
            await reloadProgress()
        } catch {
            if token == sessionID {
                lastStorageError = error.localizedDescription
            }
        }
    }

    func refreshCachedPlaces(retryFailed: Bool, shouldContinue: @escaping @MainActor () -> Bool) async {
        let token = sessionID
        do {
            try await configuration?.value
            guard let scope, automaticCachingAllowed else {
                if retryFailed, let scope {
                    // Reset demand failures for the next view; never issue a public batch.
                    _ = try await store.pendingPlaces(scope: scope, retryFailed: true, now: .now)
                }
                await reloadProgress()
                return
            }
            Self.logger.info("Place cache pass started retryFailed=\(retryFailed)")
            var resetFailures = retryFailed
            while !Task.isCancelled, token == sessionID, shouldContinue() {
                let pending = try await store.pendingPlaces(scope: scope, retryFailed: resetFailures, now: .now)
                resetFailures = false
                if pending.isEmpty {
                    guard let retry = try await store.nextPlaceRetry(scope: scope) else { break }
                    await reloadProgress()
                    try await Task.sleep(for: .seconds(max(1, retry.timeIntervalSinceNow)))
                    continue
                }
                for record in pending {
                    guard !Task.isCancelled, token == sessionID, shouldContinue() else { break }
                    do { _ = try await fetch(record.key, scope: scope, token: token, automatic: true) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as LibraryIndexStoreError { throw error }
                    catch { /* Failure is durable; continue the next independent lookup. */ }
                    await reloadProgress()
                    try await Task.sleep(for: requestInterval)
                }
                await reloadProgress()
            }
        } catch {
            if !(error is CancellationError), token == sessionID {
                lastStorageError = error.localizedDescription
            }
        }
        if token == sessionID {
            await reloadProgress()
            let report = progress
            Self.logger.info("Place cache pass finished cancelled=\(Task.isCancelled) eligible=\(report.eligible) resolved=\(report.resolved) pending=\(report.pending) failed=\(report.failed)")
        }
    }

    private func fetch(_ key: PlaceCacheKey, scope: MediaAccountScope, token: String, automatic: Bool) async throws -> PlaceLocation? {
        let requestID = "\(scope.cacheNamespace)|\(key.id)"
        let consumer = UUID()
        if let shared = requests[requestID] {
            requests[requestID]?.consumers.insert(consumer)
            if !automatic, let index = waitingRequests.firstIndex(where: { $0.id == shared.id }) {
                var waiting = waitingRequests.remove(at: index)
                waiting.automatic = false
                waitingRequests.insert(waiting, at: waitingRequests.firstIndex(where: \.automatic) ?? waitingRequests.endIndex)
            }
            return try await consume(shared.task, requestID: requestID, id: shared.id, consumer: consumer)
        }
        let id = UUID()
        let task = Task { [weak self, client, store] () throws -> PlaceLocation? in
            guard let self, token == sessionID else { throw CancellationError() }
            try await acquireRequest(id: id, automatic: automatic)
            defer { releaseRequest(id: id) }
            try Task.checkCancellation()
            guard token == sessionID else { throw CancellationError() }
            guard let lease = try await store.beginPlace(key, scope: scope, sessionID: token, automatic: automatic, now: .now) else {
                return try await store.cachedPlace(key, scope: scope)?.location
            }
            do {
                let result = try await client.lookup(key.coordinate, endpoint: key.endpoint, language: key.language, automatic: automatic)
                try Task.checkCancellation()
                guard token == sessionID else { throw CancellationError() }
                let accepted = try await store.finishPlace(key, scope: scope, sessionID: token, lease: lease,
                                                           location: result, error: nil, onDemandOnly: false, retryDelay: nil, now: .now)
                return accepted ? result : nil
            } catch {
                if Task.isCancelled || error is CancellationError || token != sessionID {
                    try? await store.cancelPlace(key, scope: scope, lease: lease)
                    throw CancellationError()
                }
                let failure = error as? PlaceLookupError
                let partial: PlaceLocation? = if case let .contextFailed(location, _, _) = failure {
                    location
                } else {
                    nil
                }
                _ = try await store.finishPlace(key, scope: scope, sessionID: token, lease: lease,
                                                location: partial, error: error.localizedDescription,
                                                onDemandOnly: failure == .automaticPublicService, retryDelay: failure?.retryDelay, now: .now)
                Self.logger.warning("Place request failed automatic=\(automatic) category=\(String(describing: type(of: error)), privacy: .public)")
                await reloadProgress()
                if let partial {
                    return partial
                }
                throw error
            }
        }
        requests[requestID] = (id, task, [consumer])
        return try await consume(task, requestID: requestID, id: id, consumer: consumer)
    }

    private func consume(_ task: Task<PlaceLocation?, Error>, requestID: String, id: UUID, consumer: UUID) async throws -> PlaceLocation? {
        defer { releaseConsumer(requestID: requestID, id: id, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseConsumer(requestID: requestID, id: id, consumer: consumer) }
        }
    }

    /// One network lookup at a time; queued viewer work precedes queued bulk work.
    private func acquireRequest(id: UUID, automatic: Bool) async throws {
        try Task.checkCancellation()
        if activeRequest == nil {
            activeRequest = id
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let index = automatic ? waitingRequests.endIndex : waitingRequests.firstIndex(where: \.automatic) ?? waitingRequests.endIndex
                waitingRequests.insert((id, automatic, continuation), at: index)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = waitingRequests.firstIndex(where: { $0.id == id }) else { return }
                waitingRequests.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func releaseRequest(id: UUID) {
        guard activeRequest == id else { return }
        activeRequest = nil
        if !waitingRequests.isEmpty {
            let next = waitingRequests.removeFirst()
            activeRequest = next.id
            next.continuation.resume()
        }
    }

    private func releaseConsumer(requestID: String, id: UUID, consumer: UUID) {
        guard requests[requestID]?.id == id else { return }
        requests[requestID]?.consumers.remove(consumer)
        if requests[requestID]?.consumers.isEmpty == true {
            requests[requestID]?.task.cancel()
            requests[requestID] = nil
        }
    }

    func reloadProgress() async {
        guard let scope else { return }
        let token = sessionID
        do {
            let value = try await store.placeProgress(scope: scope, now: .now)
            guard token == sessionID else { return }
            progress = value
        } catch {
            guard token == sessionID else { return }
            lastStorageError = error.localizedDescription
        }
    }

    func test(endpoint: String) async throws -> Bool {
        let url = try MapsPlacesPreferences.endpointURL(endpoint)
        _ = try await client.lookup(PlaceCoordinate(latitude: 31.2167366667, longitude: 121.5484183333)!, endpoint: url, language: .english)
        return true
    }

    func configureMap(session: AccountSession, endpoint: URL?) {
        guard namespace == MediaAccountScope(session: session).cacheNamespace else { return }
        if mapEndpoint != endpoint || mapSession != session {
            validatedMapEndpoint = nil
        }
        mapSession = session
        mapEndpoint = endpoint
    }

    func loadMapStyles() async throws {
        guard let mapSession, let mapEndpoint, let namespace, validatedMapEndpoint != mapEndpoint else { return }
        let client = ImmichClient.routeCheckClient(apiURL: mapEndpoint, credential: .bearer(mapSession.accessToken))
        let response = try await client.mapStyles()
        let styles = AssetMapStyles(light: response.light, dark: response.dark, enabled: response.enabled)
        try Task.checkCancellation()
        guard self.namespace == namespace, self.mapEndpoint == mapEndpoint else { throw CancellationError() }
        mapStyles = styles
        validatedMapEndpoint = mapEndpoint
        if let data = try? JSONEncoder().encode(styles) {
            defaults.set(data, forKey: "maps-places-styles-\(namespace)")
        }
    }

    static func remove(defaults: UserDefaults, namespace: String) {
        for kind in ["preferences", "cache", "styles"] {
            defaults.removeObject(forKey: "maps-places-\(kind)-\(namespace)")
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension EnvironmentValues {
    @Entry var assetLocations: AssetLocationStore? = nil
}
