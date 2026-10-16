import Foundation
import Observation

nonisolated enum AssetViewerOrigin: Hashable, Sendable {
    case timeline(bucketID: TimelineBucketID, contentName: String)
    case scoped(route: PhotosRangeRoute, contentName: String)
}

nonisolated struct AssetViewerRoute: Hashable, Identifiable, Sendable {
    let selectedAsset: TimelineAssetSummary
    let initialAssets: [TimelineAssetSummary]
    let origin: AssetViewerOrigin

    var id: String {
        "\(origin.idComponent)|\(selectedAsset.id)"
    }
}

private extension AssetViewerOrigin {
    nonisolated var idComponent: String {
        switch self {
        case let .timeline(bucketID, contentName):
            "timeline|\(contentName)|\(bucketID.rawValue)"
        case let .scoped(route, contentName):
            "scoped|\(contentName)|\(String(describing: route))"
        }
    }
}

@MainActor
@Observable
final class AssetViewerSession {
    typealias BucketLoader = @MainActor (TimelineBucketID) async -> [TimelineAssetSummary]

    private(set) var assets: [TimelineAssetSummary]
    private(set) var isLoadingNeighbor = false
    private(set) var unavailableMessage: String?
    var selectedAssetID: String

    let origin: AssetViewerOrigin

    private let bucketIDs: [TimelineBucketID]
    private let loadBucket: BucketLoader?
    private var loadedBucketIDs: Set<TimelineBucketID> = []
    private var bucketByAssetID: [String: TimelineBucketID] = [:]

    init(
        route: AssetViewerRoute,
        bucketIDs: [TimelineBucketID] = [],
        loadBucket: BucketLoader? = nil
    ) {
        origin = route.origin
        selectedAssetID = route.selectedAsset.id
        assets = Self.orderedUnique(route.initialAssets + [route.selectedAsset])
        self.bucketIDs = bucketIDs
        self.loadBucket = loadBucket

        if case let .timeline(bucketID, _) = route.origin {
            bucketByAssetID[route.selectedAsset.id] = bucketID
        }
    }

    var selectedAsset: TimelineAssetSummary? {
        assets.first { $0.id == selectedAssetID }
    }

    var selectedIndex: Int? {
        assets.firstIndex { $0.id == selectedAssetID }
    }

    func start() async {
        guard case let .timeline(bucketID, _) = origin else { return }
        await load(bucketID)
        await loadNeighborsIfNeeded()
    }

    func select(_ assetID: String) async {
        guard assets.contains(where: { $0.id == assetID }) else { return }
        selectedAssetID = assetID
        await loadNeighborsIfNeeded()
    }

    func loadNeighborsIfNeeded() async {
        guard case .timeline = origin,
              let selectedIndex,
              !assets.isEmpty
        else { return }

        if selectedIndex <= 1, let selectedBucket = bucketByAssetID[selectedAssetID] {
            await loadAdjacent(to: selectedBucket, offset: -1)
        }
        if selectedIndex >= max(0, assets.count - 2),
           let selectedBucket = bucketByAssetID[selectedAssetID]
        {
            await loadAdjacent(to: selectedBucket, offset: 1)
        }
    }

    private func loadAdjacent(to bucketID: TimelineBucketID, offset: Int) async {
        guard let index = bucketIDs.firstIndex(of: bucketID) else { return }
        let adjacentIndex = index + offset
        guard bucketIDs.indices.contains(adjacentIndex) else { return }
        await load(bucketIDs[adjacentIndex])
    }

    private func load(_ bucketID: TimelineBucketID) async {
        guard !loadedBucketIDs.contains(bucketID), let loadBucket else { return }
        loadedBucketIDs.insert(bucketID)
        isLoadingNeighbor = true
        defer { isLoadingNeighbor = false }
        let loaded = await loadBucket(bucketID)
        guard !Task.isCancelled else {
            loadedBucketIDs.remove(bucketID)
            return
        }

        if loaded.isEmpty {
            unavailableMessage = "Some nearby items could not be loaded."
        } else {
            unavailableMessage = nil
            for asset in loaded {
                bucketByAssetID[asset.id] = bucketID
            }
            assets = Self.orderedUnique(assets + loaded)
        }
    }

    nonisolated static func orderedUnique(
        _ values: [TimelineAssetSummary]
    ) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        return values
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt > $1.capturedAt
                }
                return $0.id > $1.id
            }
            .filter { seen.insert($0.id).inserted }
    }
}
