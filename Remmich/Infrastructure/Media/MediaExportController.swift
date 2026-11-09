import AVFoundation
import Foundation
import Observation
import OSLog
import Photos
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class MediaExportController: NSObject {
    private(set) var journal = MediaExportJournal()
    private(set) var ready = false
    private(set) var message: String?
    private(set) var verifiedReceiptKeys = Set<String>()
    private(set) var savedAssetRevisions = Set<String>()
    @ObservationIgnored private var deletedReceiptKeys = Set<String>()
    var detailReader: (any AssetDetailReading)?
    @ObservationIgnored private(set) weak var media: MediaLibraryController?
    @ObservationIgnored private var scope: MediaAccountScope?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let files = MediaExportFiles()
    @ObservationIgnored private let photos: any MediaPhotosWriting
    @ObservationIgnored private let transfers: LibraryTransferQueue
    @ObservationIgnored private var foregroundWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var foregroundAvailable = UIApplication.shared.applicationState == .active
    @ObservationIgnored private var cancellationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var submission: Task<Void, Never>?
    @ObservationIgnored private var permissionIntents = Set<UUID>()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var configuring: Task<Void, Never>?
    @ObservationIgnored private var retiringWorkers: [Task<Void, Never>] = []
    @ObservationIgnored private var writing: Task<Void, Error>?
    private var runningID: UUID?
    @ObservationIgnored private var observingPhotos = false
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "MediaExport")

    init(store: SQLiteLibraryIndexStore = .init(), photos: any MediaPhotosWriting = MediaPhotosWriter(),
         transfers: LibraryTransferQueue = .exports)
    {
        self.store = store
        self.photos = photos
        self.transfers = transfers
        super.init()
    }

    var activeCount: Int {
        journal.jobs.filter(\.stage.isActive).count
    }

    var jobs: [MediaExportJob] {
        journal.jobs
    }

    func configure(media: MediaLibraryController, scope: MediaAccountScope) {
        self.media = media
        guard self.scope != scope else { return }
        reset()
        self.media = media
        self.scope = scope
        let owner = generation
        let previousWrites = writing
        let previousWorkers = retiringWorkers
        configuring = Task { [self] in
            do {
                for task in previousWorkers {
                    await task.value
                }
                _ = try? await previousWrites?.value
                guard generation == owner else { return }
                retiringWorkers.removeAll()
                var loaded = try await store.loadMediaExports(scope: scope)
                guard generation == owner else { return }
                for index in loaded.jobs.indices where loaded.jobs[index].stage.isActive {
                    let committing = loaded.jobs[index].stage == .saving
                    loaded.jobs[index].stage = committing ? .uncertain : .queued
                    loaded.jobs[index].error = committing
                        ? "The app closed during a Photos save. Check the Remmich album before starting another save."
                        : nil
                }
                journal = loaded
                try await persist()
                guard generation == owner else { return }
                ready = true
                await transfers.retainExports(operationIDs: Set(loaded.jobs.filter { $0.stage != .completed && $0.stage != .cancelled }.map(\.id)), namespace: scope.cacheNamespace)
                guard generation == owner else { return }
                await transfers.setExportHandler { [weak self] update in
                    Task { @MainActor in self?.applyTransferUpdate(update, owner: owner) }
                }
                await scheduleTransfers().value
                guard generation == owner else { return }
                pump()
                await files.prune(namespace: scope.cacheNamespace, keeping: Set(loaded.jobs.filter { $0.stage == .uncertain }.map(\.id)))
                guard generation == owner else { return }
                await reconcile()
                Self.logger.info("Export restored jobs=\(loaded.jobs.count) receipts=\(loaded.receipts.count)")
            } catch {
                guard generation == owner else { return }
                message = "Download history could not be opened: \(error.localizedDescription)"
                Self.logger.error("Export restore failed code=\((error as NSError).code) detail=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func reset() {
        let oldScope = scope
        generation = UUID()
        configuring?.cancel()
        if let worker {
            if journal.jobs.first(where: { $0.id == runningID })?.stage != .saving {
                worker.cancel()
            }
            retiringWorkers.append(worker)
        }
        worker = nil
        if let submission {
            submission.cancel()
            retiringWorkers.append(submission)
        }
        submission = nil
        retiringWorkers.append(contentsOf: cancellationTasks.values)
        cancellationTasks.removeAll()
        permissionIntents.removeAll()
        let waiting = foregroundWaiters.values
        foregroundWaiters.removeAll()
        for waiter in waiting {
            waiter.resume(throwing: CancellationError())
        }
        if let oldScope {
            let transfers = transfers
            retiringWorkers.append(Task { await transfers.invalidate(namespace: oldScope.cacheNamespace) })
        }
        runningID = nil
        scope = nil
        media = nil
        ready = false
        journal = .init()
        verifiedReceiptKeys = []
        savedAssetRevisions = []
        deletedReceiptKeys = []
        message = nil
        detailReader = nil
        if observingPhotos {
            PHPhotoLibrary.shared().unregisterChangeObserver(self); observingPhotos = false
        }
    }

    func retryLoading() {
        guard let media, let scope else { return }
        self.scope = nil
        configure(media: media, scope: scope)
    }

    func saved(_ asset: TimelineAssetSummary) -> Bool {
        savedAssetRevisions.contains("\(asset.id)|\(asset.thumbnailRevision.timeIntervalSince1970)")
    }

    func activeJob(assetID: String) -> MediaExportJob? {
        journal.jobs.first { $0.assetID == assetID && $0.stage.isActive }
    }

    func isSaved(asset: TimelineAssetSummary, tier: MediaExportTier) -> Bool {
        journal.receipts.contains { $0.assetID == asset.id && $0.revision == asset.thumbnailRevision && $0.tier == tier && verifiedReceiptKeys.contains($0.key) }
    }

    func savedReceipt(assetID: String, revision: Date, tier: MediaExportTier) -> MediaPhotosReceipt? {
        guard ready else { return nil }
        // A receipt locates the resource; PhotoKit verifies current readability.
        // Album membership governs the saved badge, not local-file reuse.
        return journal.receipts.first {
            $0.assetID == assetID && $0.revision == revision && $0.tier == tier
        }
    }

    func localImageData(assetID: String, revision: Date, tier: MediaExportTier) async throws -> Data? {
        guard let receipt = savedReceipt(assetID: assetID, revision: revision, tier: tier) else { return nil }
        let owner = generation
        let data = try await photos.localImageData(receipt: receipt)
        guard owner == generation else { throw CancellationError() }
        return data
    }

    func localVideoAsset(assetID: String, revision: Date, tier: MediaExportTier) async throws -> AVURLAsset? {
        guard let receipt = savedReceipt(assetID: assetID, revision: revision, tier: tier) else { return nil }
        let owner = generation
        let asset = try await photos.localVideoAsset(receipt: receipt)
        guard owner == generation else { throw CancellationError() }
        return asset
    }

    func enqueue(asset: TimelineAssetSummary, tier: MediaExportTier, detail: AssetDetail? = nil, expectedNamespace: String? = nil) {
        if let expectedNamespace, scope?.cacheNamespace != expectedNamespace {
            return
        }
        guard ready else { message = "Downloads are still loading. Try again shortly."; return }
        guard MediaExportTier.choices(video: asset.mediaKind == .video, live: asset.livePhotoVideoID != nil).contains(tier) else { return }
        let job = MediaExportJob(id: UUID(), assetID: asset.id, revision: asset.thumbnailRevision, capturedAt: asset.capturedAt,
                                 localOffsetHours: asset.localOffsetHours, video: asset.mediaKind == .video,
                                 motionID: asset.livePhotoVideoID, tier: tier, metadata: .init(assetID: asset.id, detail: detail))
        guard !journal.jobs.contains(where: { $0.key == job.key && ($0.stage.isActive || $0.stage == .uncertain) }) else {
            message = "This save is already tracked in Downloads."
            return
        }
        // An inaccessible Photos receipt is unknown, not a reason to reimport.
        if journal.receipts.contains(where: { $0.key == job.key }) {
            if deletedReceiptKeys.contains(job.key) {
                journal.receipts.removeAll { $0.key == job.key }
                deletedReceiptKeys.remove(job.key)
            } else {
                message = verifiedReceiptKeys.contains(job.key) ? nil : "This quality was saved before. Check Photos and full library access. If you removed it only from Remmich, add it back to that album in Photos."
                return
            }
        }
        journal.jobs.insert(job, at: 0)
        permissionIntents.insert(job.id)
        Self.logger.info("Export job=\(job.id.uuidString, privacy: .public) enqueue tier=\(tier.rawValue, privacy: .public) video=\(job.video) live=\(job.motionID != nil)")
        message = nil
        let owner = generation
        let pending = writeSnapshot()
        Task {
            do {
                try await pending.value; if generation == owner {
                    await scheduleTransfers().value
                    pump()
                }
            } catch {
                if generation == owner {
                    message = error.localizedDescription
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let index = journal.jobs.firstIndex(where: { $0.id == id }), journal.jobs[index].canCancel else { return }
        journal.jobs[index].stage = .cancelled
        journal.jobs[index].finishedAt = Date()
        if runningID == id {
            worker?.cancel()
        }
        if let scope {
            let transfers = transfers
            cancellationTasks[id] = Task { await transfers.finishExport(operationID: id, namespace: scope.cacheNamespace) }
        }
        scheduleSaveOrReport()
    }

    func retry(_ id: UUID) {
        guard ready, runningID != id, let index = journal.jobs.firstIndex(where: { $0.id == id }), journal.jobs[index].canRetry else { return }
        journal.jobs[index].stage = .queued
        journal.jobs[index].startedAt = Date()
        journal.jobs[index].finishedAt = nil
        journal.jobs[index].error = nil
        journal.jobs[index].received = 0
        journal.jobs[index].expected = 0
        journal.jobs[index].transferAttempt = UUID()
        permissionIntents.insert(id)
        let owner = generation
        let pending = writeSnapshot()
        let cancellation = cancellationTasks.removeValue(forKey: id)
        let transfers = transfers
        let namespace = scope?.cacheNamespace
        let cleanup = Task {
            await cancellation?.value
            if let namespace {
                await transfers.finishExport(operationID: id, namespace: namespace)
            }
        }
        cancellationTasks[id] = cleanup
        Task {
            do {
                await cleanup.value
                try await pending.value; if generation == owner {
                    await scheduleTransfers().value
                    pump()
                }
            } catch {
                if generation == owner {
                    message = error.localizedDescription
                }
            }
        }
    }

    func canRetry(_ job: MediaExportJob) -> Bool {
        job.canRetry && runningID != job.id
    }

    func clearHistory() {
        guard ready else { return }
        let removed = journal.jobs.filter { canRemoveHistory($0) }
        let ids = Set(removed.map(\.id))
        journal.jobs.removeAll { ids.contains($0.id) }
        if let scope {
            let transfers = transfers
            for job in removed {
                cancellationTasks[job.id] = Task { await transfers.finishExport(operationID: job.id, namespace: scope.cacheNamespace) }
            }
        }
        scheduleSaveOrReport()
    }

    func canRemoveHistory(_ job: MediaExportJob) -> Bool {
        !job.stage.isActive && job.stage != .uncertain && runningID != job.id
    }

    func removeHistory(_ id: UUID) {
        guard ready, let index = journal.jobs.firstIndex(where: { $0.id == id }), canRemoveHistory(journal.jobs[index]) else { return }
        journal.jobs.remove(at: index)
        if let scope {
            let transfers = transfers
            cancellationTasks[id] = Task { await transfers.finishExport(operationID: id, namespace: scope.cacheNamespace) }
        }
        // Receipts remain authoritative for saved badges and duplicate imports.
        scheduleSaveOrReport()
    }

    func acknowledgeUncertain(_ id: UUID) {
        guard let index = journal.jobs.firstIndex(where: { $0.id == id }), journal.jobs[index].stage == .uncertain else { return }
        journal.jobs[index].stage = .failed
        journal.jobs[index].error = "Photos was checked manually. Retry only if this item is absent."
        scheduleSaveOrReport()
    }

    func clearMessage() {
        message = nil
    }

    func sceneActivityChanged(active: Bool) {
        foregroundAvailable = active
        guard active else { return }
        let waiting = foregroundWaiters.values
        foregroundWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }

    private func waitForForeground() async throws {
        try Task.checkCancellation()
        guard photos is MediaPhotosWriter, !foregroundAvailable else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { foregroundWaiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.foregroundWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    func reconcile() async {
        guard ready, scope != nil else { return }
        observePhotosIfAuthorized()
        let owner = generation
        let receipts = journal.receipts
        let verified = await photos.verifiedKeys(receipts)
        guard generation == owner,
              Set(receipts.map(\.photosID)) == Set(journal.receipts.map(\.photosID)) else { return }
        verifiedReceiptKeys = verified.verified
        deletedReceiptKeys = verified.deleted
        savedAssetRevisions = Set(receipts.filter { verified.verified.contains($0.key) }.map { "\($0.assetID)|\($0.revision.timeIntervalSince1970)" })
    }

    private func observePhotosIfAuthorized() {
        guard !observingPhotos, photos is MediaPhotosWriter,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        PHPhotoLibrary.shared().register(self)
        observingPhotos = true
    }

    private func writeSnapshot() -> Task<Void, Error> {
        guard let scope else { return Task { throw CancellationError() } }
        let snapshot = journal
        let previous = writing
        let store = store
        let next = Task {
            _ = try? await previous?.value
            try await store.saveMediaExports(snapshot, scope: scope)
        }
        writing = next
        return next
    }

    private func persist() async throws {
        try await writeSnapshot().value
    }

    private func scheduleSaveOrReport() {
        let owner = generation
        let pending = writeSnapshot()
        Task {
            do { try await pending.value }
            catch {
                if generation == owner {
                    message = "Download history could not be saved: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveOrReport() async {
        let owner = generation
        do { try await persist() }
        catch {
            guard generation == owner else { return }
            message = "Download history could not be saved: \(error.localizedDescription)"
            Self.logger.error("Export journal failed code=\((error as NSError).code) detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func pump() {
        guard ready, worker == nil, let job = journal.jobs.last(where: { [.queued, .downloading, .awaitingPhotos].contains($0.stage) }), let scope, let media else { return }
        let owner = generation
        runningID = job.id
        worker = Task {
            await run(job, scope: scope, media: media, owner: owner)
            guard generation == owner else { return }
            worker = nil
            runningID = nil
            pump()
        }
    }

    private func scheduleTransfers() -> Task<Void, Never> {
        let previous = submission
        let owner = generation
        let next = Task {
            await previous?.value
            guard generation == owner, !Task.isCancelled, photos is MediaPhotosWriter,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                  let media else { return }
            do {
                let transferOwner = try await media.exportTransferOwner(using: transfers)
                guard generation == owner, !Task.isCancelled else { return }
                for job in journal.jobs.reversed() where [.queued, .preparing, .downloading, .awaitingPhotos].contains(job.stage) {
                    var components: [(assetID: String, tier: MediaExportTier, name: String)] = [(job.assetID, job.tier, "media")]
                    if let motion = job.motionID {
                        components.append((motion, .original, "motion"))
                    }
                    for component in components {
                        if let data = await media.exportCachedData(assetID: component.assetID, revision: job.revision, tier: component.tier),
                           component.tier != .full || MediaExportFiles.isFullSize(data, width: job.metadata.width, height: job.metadata.height)
                        {
                            continue
                        }
                        guard generation == owner, !Task.isCancelled,
                              journal.jobs.contains(where: { $0.id == job.id && $0.transferAttempt == job.transferAttempt && $0.stage.isActive && $0.stage != .saving }) else { break }
                        guard let url = media.downloadURL(assetID: component.assetID, derivative: component.tier.derivative, endpoint: transferOwner.endpoint) else { continue }
                        try await transfers.enqueueExport(url: url, operationID: job.id,
                                                          component: "\((job.transferAttempt ?? job.id).uuidString)|\(component.name)", owner: transferOwner)
                        if generation != owner || Task.isCancelled || !journal.jobs.contains(where: { $0.id == job.id && $0.transferAttempt == job.transferAttempt && $0.stage.isActive }) {
                            await transfers.finishExport(operationID: job.id, namespace: transferOwner.namespace, attemptID: job.transferAttempt ?? job.id)
                            return
                        }
                    }
                }
                guard generation == owner, !Task.isCancelled else { return }
                await transfers.startExports()
            } catch {
                // The serial importer exposes connection/preparation failures;
                // lack of a route must not block cached saves or lose the queue.
                Self.logger.notice("Export submission deferred code=\((error as NSError).code)")
            }
        }
        submission = next
        return next
    }

    private func applyTransferUpdate(_ update: LibraryTransferQueue.ExportUpdate, owner: UUID) {
        guard generation == owner, let index = journal.jobs.firstIndex(where: { $0.id == update.operationID }),
              update.attemptID == (journal.jobs[index].transferAttempt ?? journal.jobs[index].id),
              [.queued, .downloading, .awaitingPhotos].contains(journal.jobs[index].stage) else { return }
        journal.jobs[index].received = update.received
        journal.jobs[index].expected = update.expected
        if let code = update.errorCode {
            journal.jobs[index].stage = .failed
            journal.jobs[index].error = URLError(URLError.Code(rawValue: code)).localizedDescription
            journal.jobs[index].finishedAt = Date()
            scheduleSaveOrReport()
        } else if update.complete {
            journal.jobs[index].stage = .awaitingPhotos
            scheduleSaveOrReport()
        } else if update.started {
            journal.jobs[index].stage = .downloading
        }
    }

    private func transition(_ id: UUID, to stage: MediaExportStage, owner: UUID) async throws {
        try Task.checkCancellation()
        guard generation == owner, let index = journal.jobs.firstIndex(where: { $0.id == id }), journal.jobs[index].stage != .cancelled else { throw CancellationError() }
        journal.jobs[index].stage = stage
        try await persist()
    }

    private func run(_ initial: MediaExportJob, scope: MediaAccountScope, media: MediaLibraryController, owner: UUID) async {
        var job = initial
        var directory: URL?
        var committing = false
        var savedInPhotos = false
        do {
            try await transition(job.id, to: .preparing, owner: owner)
            if photos is MediaPhotosWriter, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized,
               !permissionIntents.contains(job.id)
            {
                throw MediaExportFailure.message("Photos access is needed to resume this save. Tap Retry to allow access.")
            }
            try await waitForForeground()
            try await photos.authorize()
            permissionIntents.remove(job.id)
            observePhotosIfAuthorized()
            try Task.checkCancellation()
            guard generation == owner else { throw CancellationError() }
            let album = try await photos.album(savedID: journal.albumID)
            guard generation == owner else { throw CancellationError() }
            journal.albumID = album
            await scheduleTransfers().value
            guard generation == owner else { throw CancellationError() }
            if let reader = detailReader {
                if let detail = await reader.cachedAssetDetail(id: job.assetID) {
                    job.metadata = .init(assetID: job.assetID, detail: detail)
                } else if media.activeAPIURL != nil {
                    do { job.metadata = try await .init(assetID: job.assetID, detail: reader.assetDetail(id: job.assetID)) }
                    catch {
                        try Task.checkCancellation()
                        Self.logger.notice("Export job=\(job.id.uuidString, privacy: .public) using available metadata after detail lookup failure")
                    }
                }
            }
            guard generation == owner else { throw CancellationError() }
            if let index = journal.jobs.firstIndex(where: { $0.id == job.id }) {
                journal.jobs[index].metadata = job.metadata
            }
            directory = try await files.directory(namespace: scope.cacheNamespace, job: job.id)
            let root = directory!
            let input = try await resolve(job, assetID: job.assetID, tier: job.tier, name: "media", root: root, media: media, owner: owner)
            try await transition(job.id, to: .preparing, owner: owner)
            let file: URL
            if job.video {
                let asset = AVURLAsset(url: input)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !tracks.isEmpty else { throw MediaExportFailure.message("The playback response is not a complete video file. Choose Original instead.") }
                let ext = input.pathExtension.isEmpty ? "mov" : input.pathExtension
                file = try await files.copy(input, directory: root, name: job.tier.filename(source: job.metadata.filename, extension: ext))
            } else {
                file = try await files.prepareImage(input, job: job)
            }
            var motion: URL?
            if let motionID = job.motionID {
                motion = try await resolve(job, assetID: motionID, tier: .original, name: "motion", root: root, media: media, owner: owner)
                try await photos.validateLivePhoto(still: file, motion: motion!)
            }
            let finalBytes = await files.byteCount([file] + (motion.map { [$0] } ?? []))
            guard generation == owner else { throw CancellationError() }
            if let index = journal.jobs.firstIndex(where: { $0.id == job.id }) {
                journal.jobs[index].received = finalBytes
                journal.jobs[index].expected = finalBytes
            }
            try await transition(job.id, to: .awaitingPhotos, owner: owner)
            try await waitForForeground()
            try await transition(job.id, to: .saving, owner: owner)
            try Task.checkCancellation()
            guard generation == owner else { throw CancellationError() }
            committing = true
            let receipt = try await photos.save(job: job, file: file, motion: motion, albumID: album)
            savedInPhotos = true
            // Even if the user signed out while Photos was committing, finish
            // the receipt for the old scope without publishing into the new UI.
            if self.scope == scope, ready, let index = journal.jobs.firstIndex(where: { $0.id == job.id }) {
                journal.receipts.removeAll { $0.key == receipt.key }
                journal.receipts.append(receipt)
                journal.jobs[index].stage = .completed
                journal.jobs[index].metadata = job.metadata
                journal.jobs[index].exportedFilename = file.lastPathComponent
                journal.jobs[index].finishedAt = Date()
                verifiedReceiptKeys.insert(receipt.key)
                savedAssetRevisions.insert("\(receipt.assetID)|\(receipt.revision.timeIntervalSince1970)")
            }
            let previous = writing
            let store = store
            let completedJobID = job.id
            let filename = file.lastPathComponent
            let record = Task {
                _ = try? await previous?.value
                try await store.recordMediaReceipt(receipt, jobID: completedJobID, filename: filename, byteCount: finalBytes, scope: scope)
            }
            writing = record
            try await record.value
            await transfers.finishExport(operationID: job.id, namespace: scope.cacheNamespace)
            if generation == owner {
                message = nil
            }
            Self.logger.info("Export job=\(job.id.uuidString, privacy: .public) saved tier=\(job.tier.rawValue, privacy: .public) live=\(job.motionID != nil) bytes=\(finalBytes) elapsedMs=\(Int(Date().timeIntervalSince(job.startedAt) * 1000))")
        } catch {
            if case MediaExportFailure.photosRejected = error {
                committing = false
            }
            if generation == owner, let index = journal.jobs.firstIndex(where: { $0.id == job.id }) {
                let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                let code = (error as NSError).code
                var offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(code)
                if case MediaExportFailure.connectionRequired = error {
                    offline = true
                }
                journal.jobs[index].stage = committing ? .uncertain : (cancelled ? .cancelled : (offline ? .waiting : .failed))
                journal.jobs[index].error = committing
                    ? (savedInPhotos ? "Saved to Photos, but the history could not be recorded. Avoid saving again. " : "Photos may have saved this item. Check the Remmich album before saving again. ") + error.localizedDescription
                    : error.localizedDescription
                journal.jobs[index].finishedAt = Date()
                await saveOrReport()
            }
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                Self.logger.info("Export job=\(job.id.uuidString, privacy: .public) stopped savedInPhotos=\(savedInPhotos)")
            } else {
                Self.logger.error("Export job=\(job.id.uuidString, privacy: .public) failed code=\((error as NSError).code) detail=\(error.localizedDescription, privacy: .private)")
            }
        }
        if let directory {
            await files.remove(directory)
        }
    }

    private func resolve(_ job: MediaExportJob, assetID: String, tier: MediaExportTier, name: String,
                         root: URL, media: MediaLibraryController, owner: UUID) async throws -> URL
    {
        guard generation == owner else { throw CancellationError() }
        if let data = await media.exportCachedData(assetID: assetID, revision: job.revision, tier: tier),
           tier != .full || MediaExportFiles.isFullSize(data, width: job.metadata.width, height: job.metadata.height)
        {
            try Task.checkCancellation()
            guard generation == owner else { throw CancellationError() }
            return try await files.stage(data: data, directory: root, name: "\(name).data")
        }
        let transferOwner = try await media.exportTransferOwner(using: transfers)
        guard generation == owner,
              let url = media.downloadURL(assetID: assetID, derivative: tier.derivative, endpoint: transferOwner.endpoint) else { throw CancellationError() }
        try await transition(job.id, to: .downloading, owner: owner)
        let downloaded = try await transfers.exportFile(url: url, operationID: job.id,
                                                        component: "\((job.transferAttempt ?? job.id).uuidString)|\(name)", owner: transferOwner) { _, _ in }
        guard 200 ..< 300 ~= downloaded.response.statusCode else {
            await transfers.finishExport(operationID: job.id, namespace: transferOwner.namespace)
            throw MediaDownloadService.DownloadError.httpStatus(downloaded.response.statusCode)
        }
        if job.video, downloaded.response.mimeType?.contains("mpegurl") == true || downloaded.response.mimeType?.contains("dash+xml") == true {
            throw MediaExportFailure.message("This playback source is a streaming playlist. Choose Original to save a complete video.")
        }
        if tier == .full, let finalURL = downloaded.response.url,
           URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "size" && $0.value == "preview" }) == true
        {
            throw MediaExportFailure.message("Full quality is not available on this server. Choose Preview instead.")
        }
        try Task.checkCancellation()
        guard generation == owner else { throw CancellationError() }
        let mimeExtension = downloaded.response.mimeType.flatMap { mime -> String? in
            guard let type = UTType(mimeType: mime), type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { return nil }
            return type.preferredFilenameExtension
        }
        let suggestedExtension = ((downloaded.response.suggestedFilename ?? "") as NSString).pathExtension
        let ext = mimeExtension ?? (suggestedExtension.isEmpty
            ? (job.video || name == "motion" ? "mov" : (job.metadata.filename as NSString).pathExtension)
            : suggestedExtension)
        return try await files.copy(downloaded.fileURL, directory: root, name: "\(name).\(ext.isEmpty ? "data" : ext)")
    }
}

extension MediaExportController: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_: PHChange) {
        Task { @MainActor [weak self] in await self?.reconcile() }
    }
}
