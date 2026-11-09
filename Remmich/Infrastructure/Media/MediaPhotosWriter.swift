import AVFoundation
import CoreLocation
import Foundation
import Photos
import Synchronization

nonisolated protocol MediaPhotosWriting: Sendable {
    func authorize() async throws
    func album(savedID: String?) async throws -> String
    func validateLivePhoto(still: URL, motion: URL) async throws
    func save(job: MediaExportJob, file: URL, motion: URL?, albumID: String) async throws -> MediaPhotosReceipt
    func verifiedKeys(_ receipts: [MediaPhotosReceipt]) async -> MediaPhotosVerification
    func localImageData(receipt: MediaPhotosReceipt) async throws -> Data?
    func localVideoAsset(receipt: MediaPhotosReceipt) async throws -> AVURLAsset?
}

actor MediaPhotosWriter: MediaPhotosWriting {
    func localImageData(receipt: MediaPhotosReceipt) async throws -> Data? {
        guard let asset = readableAsset(receipt), asset.mediaType == .image,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else { return nil }
        let request = PhotoResourceRead<Data>()
        let data = Mutex(Data())
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Data? = await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = PHAssetResourceManager.default().requestData(for: resource, options: options) { @Sendable chunk in
                    data.withLock { $0.append(chunk) }
                } completionHandler: { @Sendable error in
                    request.finish(error == nil ? data.withLock { $0 } : nil)
                }
                request.install { PHAssetResourceManager.default().cancelDataRequest(identifier) }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { request.cancel() }
    }

    func localVideoAsset(receipt: MediaPhotosReceipt) async throws -> AVURLAsset? {
        guard let asset = readableAsset(receipt), asset.mediaType == .video else { return nil }
        let request = PhotoResourceRead<AVURLAsset>()
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .original
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: AVURLAsset? = await withCheckedContinuation { continuation in
                request.begin(continuation)
                let identifier = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { @Sendable video, _, _ in
                    let local = video as? AVURLAsset
                    request.finish(local?.url.isFileURL == true ? local : nil)
                }
                request.install { PHImageManager.default().cancelImageRequest(identifier) }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { request.cancel() }
    }

    private func readableAsset(_ receipt: MediaPhotosReceipt) -> PHAsset? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [receipt.photosID], options: nil).firstObject
    }

    func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw MediaExportFailure.message(status == .limited
                ? "Full Photos access is needed to create and reuse the Remmich album. You can change access in Settings."
                : "Allow Photos access in Settings to save into the Remmich album.")
        }
    }

    func album(savedID: String?) async throws -> String {
        if let savedID, PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [savedID], options: nil).firstObject?.localizedTitle == "Remmich" {
            return savedID
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", "Remmich")
        let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        guard matches.count <= 1 else { throw MediaExportFailure.message("There is more than one Remmich album in Photos. Rename the extra album before saving.") }
        if let album = matches.firstObject {
            return album.localIdentifier
        }
        let identifier = PhotoCreationIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            identifier.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Remmich").placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let value = identifier.value else { throw MediaExportFailure.message("Photos did not return the new album.") }
        return value
    }

    func validateLivePhoto(still: URL, motion: URL) async throws {
        let finished = Mutex(false)
        let valid: Bool = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [still, motion], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                let resume = finished.withLock { done in
                    if done {
                        return false
                    }
                    done = true
                    return true
                }
                if resume {
                    continuation.resume(returning: photo != nil)
                }
            }
        }
        guard valid else { throw MediaExportFailure.message("The original still and motion files do not form a valid Live Photo. Nothing was saved.") }
    }

    func save(job: MediaExportJob, file: URL, motion: URL?, albumID: String) async throws -> MediaPhotosReceipt {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            throw MediaExportFailure.message("The Remmich album is no longer available.")
        }
        let identifier = PhotoCreationIdentifier()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.lastPathComponent
                creation.addResource(with: job.video ? .video : .photo, fileURL: file, options: options)
                if let motion {
                    let motionOptions = PHAssetResourceCreationOptions()
                    motionOptions.originalFilename = job.tier.filename(source: job.metadata.filename, extension: motion.pathExtension)
                    creation.addResource(with: .pairedVideo, fileURL: motion, options: motionOptions)
                }
                creation.creationDate = job.capturedAt
                if let lat = job.metadata.latitude, let lon = job.metadata.longitude,
                   CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon))
                {
                    creation.location = CLLocation(latitude: lat, longitude: lon)
                }
                guard let placeholder = creation.placeholderForCreatedAsset,
                      let membership = PHAssetCollectionChangeRequest(for: album) else { return }
                identifier.value = placeholder.localIdentifier
                membership.addAssets([placeholder] as NSArray)
            }
        } catch {
            throw MediaExportFailure.photosRejected(error.localizedDescription)
        }
        guard let photosID = identifier.value else { throw MediaExportFailure.message("Photos completed without an import identifier. Check the album before retrying.") }
        return MediaPhotosReceipt(key: job.key, assetID: job.assetID, revision: job.revision, tier: job.tier,
                                  photosID: photosID, albumID: albumID, savedAt: Date())
    }

    func verifiedKeys(_ receipts: [MediaPhotosReceipt]) -> MediaPhotosVerification {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .init() }
        var result = MediaPhotosVerification()
        let existing = PHAsset.fetchAssets(withLocalIdentifiers: receipts.map(\.photosID), options: nil)
        var existingIDs = Set<String>()
        existing.enumerateObjects { asset, _, _ in existingIDs.insert(asset.localIdentifier) }
        result.deleted = Set(receipts.filter { !existingIDs.contains($0.photosID) }.map(\.key))
        for albumID in Set(receipts.map(\.albumID)) {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                  album.localizedTitle == "Remmich" else { continue }
            let candidates = receipts.filter { $0.albumID == albumID }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var identifiers = Set<String>()
            assets.enumerateObjects { asset, _, _ in identifiers.insert(asset.localIdentifier) }
            result.verified.formUnion(candidates.filter { identifiers.contains($0.photosID) }.map(\.key))
        }
        return result
    }
}

/// PhotoKit runs its change block on a private queue. This box has exactly one
/// writer, then is read only after performChanges completes.
private final nonisolated class PhotoCreationIdentifier: @unchecked Sendable {
    var value: String?
}

/// Covers cancellation before PhotoKit returns its request identifier as well
/// as cancellation while its local-only read is running.
final nonisolated class PhotoResourceRead<Value: Sendable>: Sendable {
    private struct State {
        var cancelled = false
        var finished = false
        var action: (@Sendable () -> Void)?
        var continuation: CheckedContinuation<Value?, Never>?
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<Value?, Never>) {
        let cancelled = state.withLock {
            if $0.cancelled {
                return true
            }
            $0.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(returning: nil)
        }
    }

    func finish(_ result: Value?) {
        let continuation = state.withLock {
            guard !$0.finished else { return CheckedContinuation<Value?, Never>?.none }
            $0.finished = true
            let continuation = $0.continuation
            $0.continuation = nil
            $0.action = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func install(_ action: @escaping @Sendable () -> Void) {
        let cancelNow = state.withLock {
            if $0.cancelled {
                return true
            }
            if !$0.finished {
                $0.action = action
            }
            return false
        }
        if cancelNow {
            action()
        }
    }

    func cancel() {
        let pending = state.withLock {
            $0.cancelled = true
            $0.finished = true
            let pending = ($0.action, $0.continuation)
            $0.action = nil
            $0.continuation = nil
            return pending
        }
        pending.1?.resume(returning: nil)
        pending.0?()
    }
}
