import Foundation

nonisolated struct TimelineBrowsingPosition: Codable, Equatable, Sendable {
    let assetID: String
    let bucketID: TimelineBucketID
    let viewportFraction: Double
}

nonisolated struct AlbumBrowsingPosition: Codable, Equatable, Sendable {
    let albumID: String
    let viewportFraction: Double
}

@MainActor
final class AccountBrowsingState {
    let navigation: NativeTabSelectionState
    let activation: NativeTabContentActivationState
    let photos = TimelineSemanticRuntime()
    let videos = TimelineSemanticRuntime()

    private let defaults: UserDefaults
    private var keyPrefix: String?

    init(scope: MediaAccountScope? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keyPrefix = scope.map { "browsing.\($0.cacheNamespace)." }
        let storedTab = keyPrefix.flatMap { defaults.string(forKey: $0 + "tab") }
            .flatMap(NativeTabDestination.init(rawValue:))
        let tab = storedTab.flatMap { NativeTabLayout.primaryDestinations.contains($0) ? $0 : nil } ?? .photos
        navigation = NativeTabSelectionState(selection: tab)
        activation = NativeTabContentActivationState(initialDestination: tab, preparedDestinations: [.library, .search])
        photos.pendingBrowsingPosition = readPosition(.photos)
        videos.pendingBrowsingPosition = readPosition(.videos)
        if keyPrefix != nil {
            photos.saveBrowsingPosition = { [weak self] in self?.savePosition($0, in: .photos) }
            videos.saveBrowsingPosition = { [weak self] in self?.savePosition($0, in: .videos) }
        }
    }

    func saveTab(_ tab: NativeTabDestination, groupedMediaOwner: NativeTabDestination) {
        guard let keyPrefix else { return }
        let destination = NativeTabLayout.primaryDestinations.contains(tab) ? tab : groupedMediaOwner
        defaults.set(destination.rawValue, forKey: keyPrefix + "tab")
    }

    var albumPosition: AlbumBrowsingPosition? {
        guard let keyPrefix, let data = defaults.data(forKey: keyPrefix + "albums.position"),
              let position = try? JSONDecoder().decode(AlbumBrowsingPosition.self, from: data),
              !position.albumID.isEmpty, (0 ... 1).contains(position.viewportFraction)
        else { return nil }
        return position
    }

    func saveAlbumPosition(_ position: AlbumBrowsingPosition?) {
        guard let keyPrefix else { return }
        savePosition(position, forKey: keyPrefix + "albums.position")
    }

    private func savePosition(_ position: TimelineBrowsingPosition?, in tab: NativeTabDestination) {
        guard let key = positionKey(tab) else { return }
        savePosition(position, forKey: key)
    }

    private func savePosition(_ position: (some Encodable)?, forKey key: String) {
        if let position, let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func detach(deleteLocalData: Bool) {
        guard let keyPrefix else { return }
        if deleteLocalData {
            defaults.removeObject(forKey: keyPrefix + "tab")
            savePosition(nil, in: .photos)
            savePosition(nil, in: .videos)
            saveAlbumPosition(nil)
        }
        self.keyPrefix = nil
    }

    private func positionKey(_ tab: NativeTabDestination) -> String? {
        guard tab == .photos || tab == .videos else { return nil }
        return keyPrefix.map { $0 + tab.rawValue + ".position" }
    }

    private func readPosition(_ tab: NativeTabDestination) -> TimelineBrowsingPosition? {
        guard let key = positionKey(tab), let data = defaults.data(forKey: key),
              let position = try? JSONDecoder().decode(TimelineBrowsingPosition.self, from: data),
              !position.assetID.isEmpty, (0 ... 1).contains(position.viewportFraction)
        else { return nil }
        return position
    }
}
