import Observation

@MainActor
@Observable
final class PhotosPresentationState {
    private(set) var preferences: PresentationPreferences
    @ObservationIgnored private let store: any PresentationPreferencesStoring

    init(store: any PresentationPreferencesStoring = UserDefaultsPresentationPreferencesStore()) {
        self.store = store
        preferences = store.load()
    }

    func setRootRange(_ range: PhotosRootRange) throws {
        guard range != preferences.rootRange else { return }
        var next = preferences
        next.rootRange = range
        try store.save(next)
        preferences = next
    }

    func setAssetLayout(_ layout: PhotosAssetLayout) throws {
        guard layout != preferences.assetLayout else { return }
        var next = preferences
        next.assetLayout = layout
        try store.save(next)
        preferences = next
    }
}
