import Foundation

nonisolated enum LibraryIndexSyncMode: Sendable {
    case recent
    case historical
    case incremental
    case fullReconciliation
}

nonisolated struct LibraryIndexSyncResult: Sendable {
    let mode: LibraryIndexSyncMode
    let generation: Int64
    let indexedAssetCount: Int
    let indexedPhotoCount: Int
    let indexedVideoCount: Int
    let expectedAssetCount: Int
    let hasMoreHistory: Bool
    let cleanup: LibraryIndexGenerationCleanup
    var hasPendingBucketChanges = false

    var isComplete: Bool {
        !hasMoreHistory && !hasPendingBucketChanges
    }
}

nonisolated struct LibraryIndexProgress: Sendable {
    let indexedAssetCount: Int
    let indexedPhotoCount: Int
    let indexedVideoCount: Int
    let expectedAssetCount: Int
}

actor LibraryIndexSynchronizer {
    private let source: any TimelineReading
    private let store: any LibraryIndexStoring
    private let batchSize: Int

    init(source: any TimelineReading, store: any LibraryIndexStoring, batchSize: Int = 2) {
        self.source = source
        self.store = store
        self.batchSize = max(1, batchSize)
    }

    func synchronizeRecent(
        scope: MediaAccountScope,
        recentOnly: Bool = false,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        let snapshot = try await store.snapshot(scope: scope)
        return try await synchronize(
            scope: scope,
            mode: snapshot == nil ? .recent : .incremental,
            fullReconciliation: false,
            recentOnly: recentOnly,
            progress: progress
        )
    }

    func resumeHistorical(
        scope: MediaAccountScope,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        try await synchronize(
            scope: scope,
            mode: .historical,
            fullReconciliation: false,
            progress: progress
        )
    }

    func fullSyncAndVerify(
        scope: MediaAccountScope,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        try await synchronize(
            scope: scope,
            mode: .fullReconciliation,
            fullReconciliation: true,
            progress: progress
        )
    }

    private func synchronize(
        scope: MediaAccountScope,
        mode: LibraryIndexSyncMode,
        fullReconciliation: Bool,
        recentOnly: Bool = false,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)?
    ) async throws -> LibraryIndexSyncResult {
        try await store.prepare(scope: scope)
        let previous = try await store.snapshot(scope: scope)
        guard previous?.syncState.isPaused != true else {
            return .init(
                mode: mode,
                generation: previous?.generation ?? 0,
                indexedAssetCount: previous?.syncState.indexedAssetCount ?? 0,
                indexedPhotoCount: previous?.assets.count { $0.kind == .image } ?? 0,
                indexedVideoCount: previous?.assets.count { $0.kind == .video } ?? 0,
                expectedAssetCount: previous?.syncState.expectedAssetCount ?? 0,
                hasMoreHistory: previous?.syncState.historicalCursor != nil,
                cleanup: .init(
                    generation: previous?.generation ?? 0,
                    removedGenerations: 0,
                    removedAssetRows: 0,
                    removedGroupRows: 0
                )
            )
        }

        do {
            let summaries = try await source.bucketSummaries(query: .init())
                .sorted { $0.id.rawValue > $1.id.rawValue }
            let expectedCount = summaries.reduce(0) { $0 + $1.assetCount }
            let selected = bucketsToFetch(
                summaries: summaries,
                previous: previous,
                mode: mode,
                fullReconciliation: fullReconciliation,
                recentOnly: recentOnly
            )
            try Task.checkCancellation()

            let generation = if fullReconciliation {
                try await store.beginReconciliation(scope: scope)
            } else {
                try await store.beginGeneration(scope: scope)
            }
            // Refreshing a bucket does not remove its accepted local records.
            // Replace its contribution only after its new response arrives.
            let acceptedBuckets = Dictionary(grouping: fullReconciliation ? [] : previous?.assets ?? [], by: \.bucketKey)
            var progressCounts = Self.progress(from: fullReconciliation ? [] : previous?.assets ?? [], expectedAssetCount: expectedCount)
            var replacements: [String: [LibraryIndexAssetRecord]] = [:]
            for summary in selected {
                try Task.checkCancellation()
                let assets = try await source.assets(in: summary.id, query: .init())
                let records = assets.map {
                    LibraryIndexAssetRecord(asset: $0, bucketID: summary.id)
                }
                replacements[summary.id.rawValue] = records
                progressCounts = progressCounts.replacing(acceptedBuckets[summary.id.rawValue] ?? [], with: records)
                await progress?(progressCounts)
            }

            try await store.removeAssets(
                in: Set(selected.map(\.id.rawValue)),
                generation: generation,
                scope: scope
            )
            for records in replacements.values {
                try await store.upsert(assets: records, generation: generation, scope: scope)
            }
            let stagedAssets = mergedAssets(
                previous: fullReconciliation ? nil : previous,
                replacing: replacements
            )
            let stagedCounts = Dictionary(grouping: stagedAssets, by: \.bucketKey).mapValues(\.count)
            let hasPendingBucketChanges = recentOnly && summaries.contains {
                stagedCounts[$0.id.rawValue, default: 0] != $0.assetCount
            }
            try await store.replace(
                groups: LibraryIndexCatalogBuilder.build(from: stagedAssets),
                generation: generation,
                scope: scope
            )
            let nextCursor = fullReconciliation ? nil : summaries
                .first { !Set(stagedAssets.map(\.bucketKey)).contains($0.id.rawValue) }?
                .id.rawValue
            let cleanup = try await store.acceptGeneration(
                generation,
                watermark: stagedAssets.map(\.updatedAt).max(),
                historicalCursor: nextCursor,
                expectedAssetCount: expectedCount,
                scope: scope
            )
            try await store.setLastError(nil, scope: scope)
            return .init(
                mode: mode,
                generation: generation,
                indexedAssetCount: stagedAssets.count,
                indexedPhotoCount: stagedAssets.count { $0.kind == .image },
                indexedVideoCount: stagedAssets.count { $0.kind == .video },
                expectedAssetCount: expectedCount,
                hasMoreHistory: nextCursor != nil,
                cleanup: cleanup,
                hasPendingBucketChanges: hasPendingBucketChanges
            )
        } catch {
            if !(error is CancellationError) {
                try? await store.setLastError(Self.message(for: error), scope: scope)
            }
            throw error
        }
    }

    private func bucketsToFetch(
        summaries: [TimelineBucketSummary],
        previous: LibraryIndexSnapshot?,
        mode: LibraryIndexSyncMode,
        fullReconciliation: Bool,
        recentOnly: Bool
    ) -> [TimelineBucketSummary] {
        if recentOnly {
            return Array(summaries.prefix(batchSize))
        }
        guard !fullReconciliation else { return summaries }
        switch mode {
        case .recent:
            return Array(summaries.prefix(batchSize))
        case .historical:
            let indexed = Set(previous?.assets.map(\.bucketKey) ?? [])
            return Array(summaries.filter { !indexed.contains($0.id.rawValue) }.prefix(batchSize))
        case .incremental:
            let indexedCounts = Dictionary(grouping: previous?.assets ?? [], by: \.bucketKey)
                .mapValues(\.count)
            let suspect = summaries.filter { indexedCounts[$0.id.rawValue] != $0.assetCount }
            return Self.deduplicate(Array(summaries.prefix(batchSize)) + suspect)
        case .fullReconciliation:
            return summaries
        }
    }

    private func mergedAssets(
        previous: LibraryIndexSnapshot?,
        replacing replacements: [String: [LibraryIndexAssetRecord]]
    ) -> [LibraryIndexAssetRecord] {
        let replacedBuckets = Set(replacements.keys)
        let retained = previous?.assets.filter { !replacedBuckets.contains($0.bucketKey) } ?? []
        return (retained + replacements.values.flatMap(\.self))
            .sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt ? lhs.id < rhs.id : lhs.capturedAt < rhs.capturedAt
            }
    }

    private static func deduplicate(_ summaries: [TimelineBucketSummary]) -> [TimelineBucketSummary] {
        var seen = Set<TimelineBucketID>()
        return summaries.filter { seen.insert($0.id).inserted }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func progress(
        from assets: [LibraryIndexAssetRecord],
        expectedAssetCount: Int
    ) -> LibraryIndexProgress {
        .init(
            indexedAssetCount: assets.count,
            indexedPhotoCount: assets.count { $0.kind == .image },
            indexedVideoCount: assets.count { $0.kind == .video },
            expectedAssetCount: expectedAssetCount
        )
    }
}

private extension LibraryIndexProgress {
    nonisolated func replacing(_ previous: [LibraryIndexAssetRecord], with assets: [LibraryIndexAssetRecord]) -> LibraryIndexProgress {
        .init(
            indexedAssetCount: indexedAssetCount - previous.count + assets.count,
            indexedPhotoCount: indexedPhotoCount - previous.count { $0.kind == .image } + assets.count { $0.kind == .image },
            indexedVideoCount: indexedVideoCount - previous.count { $0.kind == .video } + assets.count { $0.kind == .video },
            expectedAssetCount: expectedAssetCount
        )
    }
}

private nonisolated enum LibraryIndexCatalogBuilder {
    static func build(from assets: [LibraryIndexAssetRecord]) -> [LibraryIndexGroupRecord] {
        LibraryIndexMediaScope.allCases.flatMap { scope in
            let scopedAssets = assets.filter { scope == .videos ? $0.kind == .video : $0.kind != .video }
            return ["day", "week", "month", "year"].flatMap { level in
                build(level: level, assets: scopedAssets, mediaScope: scope)
            }
        }
    }

    private static func build(
        level: String,
        assets: [LibraryIndexAssetRecord],
        mediaScope: LibraryIndexMediaScope
    ) -> [LibraryIndexGroupRecord] {
        let groups = Dictionary(grouping: assets) { asset in
            switch level {
            case "day": asset.dayKey
            case "week": asset.weekKey
            case "month": asset.monthKey
            default: asset.yearKey
            }
        }
        return groups.compactMap { key, members in
            let sorted = members.sorted { $0.capturedAt < $1.capturedAt }
            guard let start = members.map(\.captureLocalDate).min(),
                  let end = members.map(\.captureLocalDate).max() else { return nil }
            return LibraryIndexGroupRecord(
                mediaScope: mediaScope,
                level: level,
                key: key,
                intervalStart: start,
                intervalEnd: end.addingTimeInterval(0.001),
                assetCount: sorted.count,
                owningBucketKeys: Array(Set(sorted.map(\.bucketKey))).sorted(),
                coverAssetIDs: boundedIDs(from: sorted, limit: 12),
                mosaicSeed: stableSeed("\(mediaScope.rawValue):\(level):\(key):\(sorted.count)")
            )
        }
        .sorted { $0.intervalStart < $1.intervalStart }
    }

    private static func boundedIDs(from assets: [LibraryIndexAssetRecord], limit: Int) -> [String] {
        guard assets.count > limit else { return assets.map(\.id) }
        return (0 ..< limit).map { slot in
            assets[slot * (assets.count - 1) / (limit - 1)].id
        }
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private extension LibraryIndexAssetRecord {
    nonisolated init(asset: TimelineAssetSummary, bucketID: TimelineBucketID) {
        let keys = LibraryIndexCaptureDateKeys(localDate: asset.captureLocalDate)
        self.init(
            id: asset.id,
            ownerID: asset.ownerID,
            kind: asset.mediaKind.libraryIndexKind,
            livePhotoVideoID: asset.livePhotoVideoID,
            capturedAt: asset.capturedAt,
            uploadedAt: asset.uploadedAt,
            updatedAt: asset.thumbnailRevision,
            checksum: nil,
            width: nil,
            height: nil,
            aspectRatio: asset.aspectRatio,
            durationMilliseconds: asset.durationMilliseconds,
            isFavorite: asset.isFavorite,
            visibility: asset.visibility.libraryIndexValue,
            isTrashed: false,
            isOffline: false,
            bucketKey: bucketID.rawValue,
            dayKey: keys.day,
            weekKey: keys.week,
            monthKey: keys.month,
            yearKey: keys.year,
            localOffsetHours: asset.localOffsetHours,
            stackID: asset.stack?.id,
            stackAssetCount: asset.stack?.assetCount,
            projectionType: asset.projectionType,
            thumbhash: asset.thumbhash
        )
    }
}

private extension TimelineVisibility {
    nonisolated var libraryIndexValue: String {
        switch self {
        case .archive: "archive"
        case .timeline: "timeline"
        case .hidden: "hidden"
        case .locked: "locked"
        case let .unknown(value): value
        }
    }
}
