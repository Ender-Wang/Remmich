import AVFoundation
import Foundation
import Observation
import OSLog
import Photos
import Synchronization
import UIKit

nonisolated enum SavedPhotosMediaError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This item is unavailable in Photos."
    }
}

nonisolated enum SavedPhotosDate {
    static func offsetHours(for date: Date?, timeZone: TimeZone = .autoupdatingCurrent) -> Double {
        date.map { Double(timeZone.secondsFromGMT(for: $0)) / 3600 } ?? 0
    }
}

/// Device-local Photos identity; never used as an Immich asset or request ID.
nonisolated struct SavedPhoto: Identifiable, Sendable {
    let asset: PHAsset
    let addedAt: Date?

    var id: String {
        asset.localIdentifier
    }

    var revision: Date? {
        asset.modificationDate
    }

    var isVideo: Bool {
        asset.mediaType == .video
    }

    var isLivePhoto: Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

    var timelineID: String {
        "photos-local|\(id)"
    }

    var captureLocalDate: Date {
        let captured = asset.creationDate
        return (captured ?? .distantPast).addingTimeInterval(SavedPhotosDate.offsetHours(for: captured) * 3600)
    }

    var timelineSummary: TimelineAssetSummary {
        let date = addedAt ?? .distantPast
        return .init(id: timelineID, ownerID: "", capturedAt: date, uploadedAt: date,
                     localOffsetHours: SavedPhotosDate.offsetHours(for: addedAt), mediaKind: isVideo ? .video : .image,
                     durationMilliseconds: isVideo ? Int((asset.duration * 1000).rounded()) : nil,
                     aspectRatio: Double(asset.pixelWidth) / Double(max(1, asset.pixelHeight)),
                     isFavorite: asset.isFavorite, visibility: .timeline,
                     livePhotoVideoID: isLivePhoto ? timelineID : nil, stack: nil,
                     projectionType: nil, thumbhash: nil, thumbnailRevision: revision ?? date)
    }
}

nonisolated struct SavedPhotosContext: Equatable, Sendable {
    let scope: MediaAccountScope
    let albumID: String?
    let saveDates: [String: Date]

    init(scope: MediaAccountScope, journal: MediaExportJournal?) {
        self.scope = scope
        albumID = journal?.albumID
        saveDates = (journal?.receipts ?? []).reduce(into: [:]) { result, receipt in
            result[receipt.photosID] = max(result[receipt.photosID] ?? .distantPast, receipt.savedAt)
        }
    }
}

@MainActor @Observable
final class SavedPhotosLibrary: NSObject {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "SavedPhotos")
    nonisolated enum State: Equatable, Sendable {
        case loading, permission, denied, limitedUnavailable, missing, ambiguous, ready
        case failed(String)
    }

    nonisolated struct CardCoverRequest: Equatable {
        let assetID: String
        let revision: Date?
        let pixels: CGSize

        init(item: SavedPhoto, pixels: CGSize) {
            assetID = item.id
            revision = item.revision
            self.pixels = pixels
        }
    }

    private struct CardCoverLoad {
        let request: CardCoverRequest
        let id = UUID()
        let task: Task<UIImage?, Never>
    }

    private(set) var state: State = .loading
    private(set) var items: [SavedPhoto] = []
    private(set) var limited = false
    private(set) var albumTitle = "Remmich"
    private(set) var catalogRevision = 0
    @ObservationIgnored private var itemsByTimelineID: [String: SavedPhoto] = [:]
    @ObservationIgnored private var context: SavedPhotosContext?
    @ObservationIgnored private var resolvedAlbumID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observers: Set<UUID> = []
    @ObservationIgnored private var pending: Task<Snapshot, Error>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private var cardCover: (request: CardCoverRequest, image: UIImage)?
    @ObservationIgnored private var cardCoverLoad: CardCoverLoad?

    var summary: String {
        switch state {
        case .ready: "\(items.count) \(limited ? "visible" : "saved")"
        case .permission: "Photos access"
        case .denied: "Access needed"
        case .limitedUnavailable: "Limited access"
        case .missing: "No saved items"
        case .ambiguous: "Choose in Photos"
        case .loading: "Loading…"
        case .failed: "Unavailable"
        }
    }

    func item(timelineID: String) -> SavedPhoto? {
        itemsByTimelineID[timelineID]
    }

    func cardCover(for request: CardCoverRequest) -> UIImage? {
        cardCover?.request == request ? cardCover?.image : nil
    }

    func prepareCardCover(_ request: CardCoverRequest) async {
        guard !Task.isCancelled, let cover = items.first,
              cover.id == request.assetID, cover.revision == request.revision,
              cardCover(for: request) == nil else { return }
        let load: CardCoverLoad
        if let pending = cardCoverLoad, pending.request == request {
            load = pending
        } else {
            cardCoverLoad?.task.cancel()
            load = CardCoverLoad(request: request, task: Task {
                try? await Self.image(cover, pixels: request.pixels)
            })
            cardCoverLoad = load
        }
        let image = await load.task.value
        guard cardCoverLoad?.id == load.id else { return }
        cardCoverLoad = nil
        if let image {
            cardCover = (request, image)
        }
    }

    private func publishItems(_ next: [SavedPhoto]) {
        guard next.count != items.count || !zip(next, items).allSatisfy({
            $0.id == $1.id && $0.revision == $1.revision && $0.addedAt == $1.addedAt && $0.asset.isFavorite == $1.asset.isFavorite
        }) else { return }
        if next.first?.id != items.first?.id || next.first?.revision != items.first?.revision {
            cardCoverLoad?.task.cancel()
            cardCoverLoad = nil
            cardCover = nil
        }
        itemsByTimelineID = Dictionary(uniqueKeysWithValues: next.map { ($0.timelineID, $0) })
        items = next
        catalogRevision &+= 1
    }

    func configure(_ next: SavedPhotosContext) {
        guard context != next else { return }
        pending?.cancel()
        pending = nil
        generation = UUID()
        if context?.scope != next.scope {
            resolvedAlbumID = nil
            publishItems([])
            state = .loading
            albumTitle = "Remmich"
        }
        context = next
    }

    func observe(owner: UUID) {
        if observers.isEmpty {
            PHPhotoLibrary.shared().register(self)
        }
        observers.insert(owner)
    }

    func stopObserving(owner: UUID) {
        observers.remove(owner)
        guard observers.isEmpty else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        pending?.cancel()
        pending = nil
        refreshTask?.cancel()
        refreshTask = nil
        generation = UUID()
    }

    func requestAccess() async {
        guard let owner = context?.scope else { return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard !Task.isCancelled, context?.scope == owner, !observers.isEmpty else { return }
        await refresh()
    }

    func refresh(reuseInFlight: Bool = false, priority: TaskPriority = .userInitiated) async {
        guard let context else { return }
        if reuseInFlight, let pending {
            _ = try? await pending.value
            return
        }
        pending?.cancel()
        pending = nil
        let owner = UUID()
        generation = owner
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        limited = status == .limited
        guard status == .authorized || status == .limited else {
            publishItems([])
            state = status == .notDetermined ? .permission : .denied
            return
        }
        let preferredAlbumID = context.albumID ?? resolvedAlbumID
        let startedAt = ContinuousClock.now
        let operation = Task.detached(priority: priority) { try Self.read(context, preferredAlbumID: preferredAlbumID) }
        pending = operation
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard !Task.isCancelled, generation == owner,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == status else { return }
            publishItems(snapshot.items)
            albumTitle = snapshot.title
            resolvedAlbumID = snapshot.albumID
            state = snapshot.state == .missing && limited ? .limitedUnavailable : snapshot.state
            if state == .ready {
                let duration = String(describing: ContinuousClock.now - startedAt)
                Self.logger.info("Timeline opening destination=downloads stage=inventory-ready assets=\(snapshot.items.count) elapsed=\(duration, privacy: .public)")
            }
        } catch is CancellationError {
            // A replacement query or departure owns the next result.
        } catch {
            guard generation == owner else { return }
            publishItems([])
            state = .failed(error.localizedDescription)
        }
        if generation == owner {
            pending = nil
        }
    }

    private nonisolated struct Snapshot: Sendable {
        let state: State
        var title = "Remmich"
        var albumID: String?
        var items: [SavedPhoto] = []
    }

    private nonisolated static func read(_ context: SavedPhotosContext, preferredAlbumID: String?) throws -> Snapshot {
        try Task.checkCancellation()
        // Read-only lookup: never use the export writer's album-creation path.
        let known = preferredAlbumID.flatMap {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
        }
        let album: PHAssetCollection
        if let known {
            album = known
        } else {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", "Remmich")
            let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            guard matches.count <= 1 else { return Snapshot(state: .ambiguous) }
            guard let match = matches.firstObject else { return Snapshot(state: .missing) }
            album = match
        }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var items: [SavedPhoto] = []
        assets.enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                stop.pointee = true; return
            }
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            // addedDate is library import time, not capture time or necessarily
            // the date an existing Photos item was moved into this album.
            items.append(SavedPhoto(asset: asset, addedAt: asset.addedDate ?? context.saveDates[asset.localIdentifier]))
        }
        try Task.checkCancellation()
        items.sort {
            let lhs = $0.addedAt ?? .distantPast, rhs = $1.addedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return Snapshot(state: .ready, title: album.localizedTitle ?? "Remmich", albumID: album.localIdentifier, items: items)
    }

    nonisolated static func image(_ item: SavedPhoto, pixels: CGSize, fit: Bool = false,
                                  network: Bool = false) async throws -> UIImage?
    {
        let request = PhotoResourceRead<UIImage>()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        let manager = PHImageManager.default()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let image: UIImage? = await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = manager.requestImage(for: item.asset, targetSize: pixels,
                                                      contentMode: fit ? .aspectFit : .aspectFill, options: options)
                { image, info in
                    guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                    request.finish(image)
                }
                request.install { manager.cancelImageRequest(identifier) }
            }
            try Task.checkCancellation()
            return image
        } onCancel: { request.cancel() }
    }

    nonisolated static func video(_ item: SavedPhoto, network: Bool) async throws -> AVPlayerItem? {
        let request = PhotoResourceRead<AVPlayerItem>()
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = network
        let manager = PHImageManager.default()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let video: AVPlayerItem? = await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = manager.requestPlayerItem(forVideo: item.asset, options: options) { video, _ in request.finish(video) }
                request.install { manager.cancelImageRequest(identifier) }
            }
            try Task.checkCancellation()
            return video
        } onCancel: { request.cancel() }
    }

    nonisolated static func primaryResource(for item: SavedPhoto) -> PHAssetResource? {
        PHAssetResource.assetResources(for: item.asset).first { $0.type == (item.isVideo ? .video : .photo) }
    }

    nonisolated static func resourceSize(_ resource: PHAssetResource) async throws -> Int? {
        try Task.checkCancellation()
        if #available(iOS 27.0, *), let size = resource.dataSize, size > 0 {
            return size
        }

        // Count local chunks without retaining the media or fetching it from iCloud.
        let request = PhotoResourceRead<Int>()
        let byteCount = Mutex(0)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return try await withTaskCancellationHandler {
            let size: Int? = await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = PHAssetResourceManager.default().requestData(for: resource, options: options) { @Sendable chunk in
                    byteCount.withLock { $0 += chunk.count }
                } completionHandler: { @Sendable error in
                    request.finish(error == nil ? byteCount.withLock { $0 } : nil)
                }
                request.install { PHAssetResourceManager.default().cancelDataRequest(identifier) }
            }
            try Task.checkCancellation()
            return size
        } onCancel: { request.cancel() }
    }

    nonisolated static func originalImageData(_ item: SavedPhoto) async throws -> Data {
        let request = PhotoResourceRead<Data>()
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let manager = PHImageManager.default()
        let data: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = manager.requestImageDataAndOrientation(for: item.asset, options: options) { data, _, _, _ in
                    request.finish(data)
                }
                request.install { manager.cancelImageRequest(identifier) }
            }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        guard let data else { throw SavedPhotosMediaError.unavailable }
        return data
    }

    nonisolated static func copyResource(_ resource: PHAssetResource, namespace: String, files: MediaExportFiles) async throws -> MediaShareFile {
        let directory = try await files.directory(namespace: namespace, job: UUID())
        let name = (resource.originalFilename as NSString).lastPathComponent
        let url = directory.appending(path: name.isEmpty || name == "." || name == ".." ? "Media" : name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let file = MediaShareFile(url: url, directory: directory, files: files)
        try Task.checkCancellation()
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        try Task.checkCancellation()
        return file
    }
}

extension SavedPhotosLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, !observers.isEmpty else { return }
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in await self?.refresh() }
        }
    }
}
