import Foundation
import SQLite3

actor SQLiteLibraryIndexStore: LibraryIndexStoring {
    static let currentSchemaVersion = 4

    private let databaseURL: URL
    private var connection: SQLiteConnection?

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.databaseURL = base
                .appending(path: "Remmich", directoryHint: .isDirectory)
                .appending(path: "LibraryIndex", directoryHint: .isDirectory)
                .appending(path: "library-index.sqlite3")
        }
    }

    func prepare(scope: MediaAccountScope) async throws {
        let database = try database()
        try migrate(database)
        try ensureScope(scope, database: database)
    }

    func beginGeneration(scope: MediaAccountScope) async throws -> Int64 {
        try beginGeneration(scope: scope, copiesAcceptedGeneration: true)
    }

    func beginReconciliation(scope: MediaAccountScope) async throws -> Int64 {
        try beginGeneration(scope: scope, copiesAcceptedGeneration: false)
    }

    private func beginGeneration(
        scope: MediaAccountScope,
        copiesAcceptedGeneration: Bool
    ) throws -> Int64 {
        let database = try preparedDatabase(scope: scope)
        let generation = try (database.scalarInt64(
            "SELECT COALESCE(MAX(generation), 0) + 1 FROM generations WHERE scope = ?",
            [.text(scope.cacheNamespace)]
        )) ?? 1
        try database.execute(
            "INSERT INTO generations(scope, generation, state, started_at) VALUES(?, ?, 'building', ?)",
            [.text(scope.cacheNamespace), .int64(generation), .double(Date().timeIntervalSince1970)]
        )
        if copiesAcceptedGeneration,
           let accepted = try database.scalarInt64(
               "SELECT accepted_generation FROM sync_state WHERE scope = ?",
               [.text(scope.cacheNamespace)]
           )
        {
            try database.transaction {
                try database.execute(
                    """
                    INSERT INTO assets(
                        scope, asset_id, owner_id, kind, live_photo_video_id,
                        captured_at, uploaded_at, updated_at, checksum, width, height,
                        aspect_ratio, duration_ms, is_favorite, visibility, is_trashed,
                        is_offline, bucket_key, day_key, week_key, month_key, year_key,
                        local_offset_hours, stack_id, stack_asset_count, projection_type, thumbhash,
                        generation, tombstone
                    )
                    SELECT scope, asset_id, owner_id, kind, live_photo_video_id,
                           captured_at, uploaded_at, updated_at, checksum, width, height,
                           aspect_ratio, duration_ms, is_favorite, visibility, is_trashed,
                           is_offline, bucket_key, day_key, week_key, month_key, year_key,
                           local_offset_hours, stack_id, stack_asset_count, projection_type, thumbhash,
                           ?, tombstone
                    FROM assets WHERE scope = ? AND generation = ?
                    """,
                    [.int64(generation), .text(scope.cacheNamespace), .int64(accepted)]
                )
                try database.execute(
                    """
                    INSERT INTO grouped_catalogs(
                        scope, generation, media_scope, level, group_key,
                        interval_start, interval_end, asset_count, owning_buckets,
                        cover_asset_ids, mosaic_seed
                    )
                    SELECT scope, ?, media_scope, level, group_key,
                           interval_start, interval_end, asset_count, owning_buckets,
                           cover_asset_ids, mosaic_seed
                    FROM grouped_catalogs WHERE scope = ? AND generation = ?
                    """,
                    [.int64(generation), .text(scope.cacheNamespace), .int64(accepted)]
                )
            }
        }
        return generation
    }

    func upsert(
        assets: [LibraryIndexAssetRecord],
        generation: Int64,
        scope: MediaAccountScope
    ) async throws {
        guard !assets.isEmpty else { return }
        let database = try preparedDatabase(scope: scope)
        try requireBuildingGeneration(generation, scope: scope, database: database)
        try database.transaction {
            for asset in assets {
                try database.execute(
                    """
                    INSERT INTO assets(
                        scope, asset_id, owner_id, kind, live_photo_video_id,
                        captured_at, uploaded_at, updated_at, checksum, width, height,
                        aspect_ratio, duration_ms, is_favorite, visibility, is_trashed,
                        is_offline, bucket_key, day_key, week_key, month_key, year_key,
                        local_offset_hours, stack_id, stack_asset_count, projection_type, thumbhash,
                        generation, tombstone
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(scope, generation, asset_id) DO UPDATE SET
                        owner_id = excluded.owner_id,
                        kind = excluded.kind,
                        live_photo_video_id = excluded.live_photo_video_id,
                        captured_at = excluded.captured_at,
                        uploaded_at = excluded.uploaded_at,
                        updated_at = excluded.updated_at,
                        checksum = excluded.checksum,
                        width = excluded.width,
                        height = excluded.height,
                        aspect_ratio = excluded.aspect_ratio,
                        duration_ms = excluded.duration_ms,
                        is_favorite = excluded.is_favorite,
                        visibility = excluded.visibility,
                        is_trashed = excluded.is_trashed,
                        is_offline = excluded.is_offline,
                        bucket_key = excluded.bucket_key,
                        day_key = excluded.day_key,
                        week_key = excluded.week_key,
                        month_key = excluded.month_key,
                        year_key = excluded.year_key,
                        local_offset_hours = excluded.local_offset_hours,
                        stack_id = excluded.stack_id,
                        stack_asset_count = excluded.stack_asset_count,
                        projection_type = excluded.projection_type,
                        thumbhash = excluded.thumbhash,
                        tombstone = 0
                    """,
                    [
                        .text(scope.cacheNamespace), .text(asset.id), .text(asset.ownerID),
                        .text(asset.kind.rawValue), .optionalText(asset.livePhotoVideoID),
                        .date(asset.capturedAt), .date(asset.uploadedAt), .date(asset.updatedAt),
                        .optionalText(asset.checksum), .optionalInt(asset.width), .optionalInt(asset.height),
                        .double(asset.aspectRatio), .optionalInt(asset.durationMilliseconds),
                        .bool(asset.isFavorite), .text(asset.visibility), .bool(asset.isTrashed),
                        .bool(asset.isOffline), .text(asset.bucketKey), .text(asset.dayKey),
                        .text(asset.weekKey), .text(asset.monthKey), .text(asset.yearKey),
                        .double(asset.localOffsetHours), .optionalText(asset.stackID),
                        .optionalInt(asset.stackAssetCount), .optionalText(asset.projectionType),
                        .optionalText(asset.thumbhash),
                        .int64(generation),
                    ]
                )
            }
        }
    }

    func replace(
        groups: [LibraryIndexGroupRecord],
        generation: Int64,
        scope: MediaAccountScope
    ) async throws {
        let database = try preparedDatabase(scope: scope)
        try requireBuildingGeneration(generation, scope: scope, database: database)
        try database.transaction {
            try database.execute(
                "DELETE FROM grouped_catalogs WHERE scope = ? AND generation = ?",
                [.text(scope.cacheNamespace), .int64(generation)]
            )
            for group in groups {
                let buckets = try Self.encode(group.owningBucketKeys)
                let covers = try Self.encode(group.coverAssetIDs)
                try database.execute(
                    """
                    INSERT INTO grouped_catalogs(
                        scope, generation, media_scope, level, group_key,
                        interval_start, interval_end, asset_count, owning_buckets,
                        cover_asset_ids, mosaic_seed
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(scope.cacheNamespace), .int64(generation),
                        .text(group.mediaScope.rawValue), .text(group.level), .text(group.key),
                        .date(group.intervalStart), .date(group.intervalEnd), .int(group.assetCount),
                        .text(buckets), .text(covers), .text(String(group.mosaicSeed)),
                    ]
                )
            }
        }
    }

    func removeAssets(
        in bucketKeys: Set<String>,
        generation: Int64,
        scope: MediaAccountScope
    ) async throws {
        guard !bucketKeys.isEmpty else { return }
        let database = try preparedDatabase(scope: scope)
        try requireBuildingGeneration(generation, scope: scope, database: database)
        try database.transaction {
            for bucketKey in bucketKeys {
                try database.execute(
                    "DELETE FROM assets WHERE scope = ? AND generation = ? AND bucket_key = ?",
                    [.text(scope.cacheNamespace), .int64(generation), .text(bucketKey)]
                )
            }
        }
    }

    func acceptGeneration(
        _ generation: Int64,
        watermark: Date?,
        historicalCursor: String?,
        expectedAssetCount: Int?,
        scope: MediaAccountScope
    ) async throws -> LibraryIndexGenerationCleanup {
        let database = try preparedDatabase(scope: scope)
        try requireBuildingGeneration(generation, scope: scope, database: database)
        let removedGenerations = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM generations WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(generation)]
        ) ?? 0)
        let removedAssetRows = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM assets WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(generation)]
        ) ?? 0)
        let removedGroupRows = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM grouped_catalogs WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(generation)]
        ) ?? 0)
        try database.transaction {
            try database.execute(
                "UPDATE generations SET state = 'accepted', completed_at = ? WHERE scope = ? AND generation = ?",
                [.date(Date()), .text(scope.cacheNamespace), .int64(generation)]
            )
            try database.execute(
                "UPDATE generations SET state = 'superseded' WHERE scope = ? AND generation <> ? AND state = 'accepted'",
                [.text(scope.cacheNamespace), .int64(generation)]
            )
            try database.execute(
                """
                INSERT INTO sync_state(
                    scope, accepted_generation, last_watermark, historical_cursor,
                    is_paused, expected_asset_count, last_error
                ) VALUES(?, ?, ?, ?, 0, ?, NULL)
                ON CONFLICT(scope) DO UPDATE SET
                    accepted_generation = excluded.accepted_generation,
                    last_watermark = excluded.last_watermark,
                    historical_cursor = excluded.historical_cursor,
                    expected_asset_count = excluded.expected_asset_count,
                    last_error = NULL
                """,
                [
                    .text(scope.cacheNamespace), .int64(generation), .optionalDate(watermark),
                    .optionalText(historicalCursor), .optionalInt(expectedAssetCount),
                ]
            )
            try database.execute(
                "DELETE FROM assets WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(generation)]
            )
            try database.execute(
                "DELETE FROM grouped_catalogs WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(generation)]
            )
            try database.execute(
                "DELETE FROM generations WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(generation)]
            )
            try database.execute(
                """
                DELETE FROM asset_details
                WHERE scope = ? AND asset_id NOT IN (
                    SELECT asset_id FROM assets WHERE scope = ? AND generation = ? AND tombstone = 0
                )
                """,
                [.text(scope.cacheNamespace), .text(scope.cacheNamespace), .int64(generation)]
            )
            try pruneUnusedDetailStrings(scope: scope, database: database)
        }
        return .init(
            generation: generation,
            removedGenerations: removedGenerations,
            removedAssetRows: removedAssetRows,
            removedGroupRows: removedGroupRows
        )
    }

    func finishMaintenance(
        scope: MediaAccountScope,
        compact: Bool
    ) async throws -> LibraryIndexMaintenanceReport {
        let database = try preparedDatabase(scope: scope)
        let before = metadataFileBytes()
        guard let accepted = try database.scalarInt64(
            "SELECT accepted_generation FROM sync_state WHERE scope = ?",
            [.text(scope.cacheNamespace)]
        ) else {
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            return .init(
                removedGenerations: 0,
                removedAssetRows: 0,
                removedGroupRows: 0,
                metadataBytesBefore: before,
                metadataBytesAfter: metadataFileBytes(),
                didCompact: false
            )
        }
        let removedGenerations = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM generations WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(accepted)]
        ) ?? 0)
        let removedAssetRows = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM assets WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(accepted)]
        ) ?? 0)
        let removedGroupRows = try Int(database.scalarInt64(
            "SELECT COUNT(*) FROM grouped_catalogs WHERE scope = ? AND generation <> ?",
            [.text(scope.cacheNamespace), .int64(accepted)]
        ) ?? 0)
        try database.transaction {
            try database.execute(
                "DELETE FROM assets WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(accepted)]
            )
            try database.execute(
                "DELETE FROM grouped_catalogs WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(accepted)]
            )
            try database.execute(
                "DELETE FROM generations WHERE scope = ? AND generation <> ?",
                [.text(scope.cacheNamespace), .int64(accepted)]
            )
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if compact {
            try database.execute("VACUUM")
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        return .init(
            removedGenerations: removedGenerations,
            removedAssetRows: removedAssetRows,
            removedGroupRows: removedGroupRows,
            metadataBytesBefore: before,
            metadataBytesAfter: metadataFileBytes(),
            didCompact: compact
        )
    }

    func finishMaintenanceIfNeeded(
        scope: MediaAccountScope
    ) async throws -> LibraryIndexMaintenanceReport? {
        let database = try preparedDatabase(scope: scope)
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        guard let accepted = try database.scalarInt64(
            "SELECT accepted_generation FROM sync_state WHERE scope = ?",
            [.text(scope.cacheNamespace)]
        ) else { return nil }
        let hasAbandonedGeneration = try database.scalarInt64(
            "SELECT EXISTS(SELECT 1 FROM generations WHERE scope = ? AND generation <> ? LIMIT 1)",
            [.text(scope.cacheNamespace), .int64(accepted)]
        ) == 1
        let pageSize = try database.scalarInt64("PRAGMA page_size") ?? 0
        let pageCount = try database.scalarInt64("PRAGMA page_count") ?? 0
        let freePageCount = try database.scalarInt64("PRAGMA freelist_count") ?? 0
        let reclaimableBytes = pageSize * freePageCount
        let hasMaterialAmplification = reclaimableBytes >= 4_000_000
            && freePageCount * 5 >= pageCount
        guard hasAbandonedGeneration || hasMaterialAmplification else { return nil }
        return try await finishMaintenance(scope: scope, compact: true)
    }

    func snapshot(scope: MediaAccountScope) async throws -> LibraryIndexSnapshot? {
        let database = try preparedDatabase(scope: scope)
        guard let generation = try database.scalarInt64(
            "SELECT accepted_generation FROM sync_state WHERE scope = ?",
            [.text(scope.cacheNamespace)]
        ) else { return nil }
        return try LibraryIndexSnapshot(
            generation: generation,
            assets: readAssets(scope: scope, generation: generation, database: database),
            groups: readGroups(scope: scope, generation: generation, database: database),
            derivatives: readDerivatives(scope: scope, database: database),
            syncState: readSyncState(scope: scope, database: database)
        )
    }

    func setPaused(_ paused: Bool, scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            """
            INSERT INTO sync_state(scope, is_paused) VALUES(?, ?)
            ON CONFLICT(scope) DO UPDATE SET is_paused = excluded.is_paused
            """,
            [.text(scope.cacheNamespace), .bool(paused)]
        )
    }

    func setLastError(_ message: String?, scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            """
            INSERT INTO sync_state(scope, last_error) VALUES(?, ?)
            ON CONFLICT(scope) DO UPDATE SET last_error = excluded.last_error
            """,
            [.text(scope.cacheNamespace), .optionalText(message)]
        )
    }

    func setLastIndexSyncAt(_ date: Date?, scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            """
            INSERT INTO sync_state(scope, last_index_sync_at) VALUES(?, ?)
            ON CONFLICT(scope) DO UPDATE SET last_index_sync_at = excluded.last_index_sync_at
            """,
            [.text(scope.cacheNamespace), .optionalDate(date)]
        )
    }

    func setLastCacheSyncAt(_ date: Date?, scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            """
            INSERT INTO sync_state(scope, last_cache_sync_at) VALUES(?, ?)
            ON CONFLICT(scope) DO UPDATE SET last_cache_sync_at = excluded.last_cache_sync_at
            """,
            [.text(scope.cacheNamespace), .optionalDate(date)]
        )
    }

    func upsert(derivatives: [LibraryIndexDerivativeRecord], scope: MediaAccountScope) async throws {
        guard !derivatives.isEmpty else { return }
        let database = try preparedDatabase(scope: scope)
        try database.transaction {
            for derivative in derivatives {
                try upsert(derivative: derivative, scope: scope, database: database)
            }
        }
    }

    func clearDerivatives(scope: MediaAccountScope, kinds: Set<MediaDerivative>) async throws {
        guard !kinds.isEmpty else { return }
        let database = try preparedDatabase(scope: scope)
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        try database.execute(
            "DELETE FROM derivatives WHERE scope = ? AND derivative IN (\(placeholders))",
            [.text(scope.cacheNamespace)] + kinds.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        )
    }

    func cachedAssetDetail(id: String, scope: MediaAccountScope) async throws -> AssetDetail? {
        let database = try preparedDatabase(scope: scope)
        return try database.queryOne(
            """
            SELECT details.asset_id, details.captured_at, details.original_file_name,
                   mime.value, details.width, details.height, details.description,
                   camera_make.value, camera_model.value, lens.value,
                   details.file_size_bytes, details.iso, details.focal_length,
                   details.aperture, exposure.value, details.latitude, details.longitude,
                   city.value, state.value, country.value
            FROM asset_details AS details
            LEFT JOIN asset_detail_strings AS mime ON mime.id = details.mime_type_id
            LEFT JOIN asset_detail_strings AS camera_make ON camera_make.id = details.camera_make_id
            LEFT JOIN asset_detail_strings AS camera_model ON camera_model.id = details.camera_model_id
            LEFT JOIN asset_detail_strings AS lens ON lens.id = details.lens_model_id
            LEFT JOIN asset_detail_strings AS exposure ON exposure.id = details.exposure_time_id
            LEFT JOIN asset_detail_strings AS city ON city.id = details.city_id
            LEFT JOIN asset_detail_strings AS state ON state.id = details.state_id
            LEFT JOIN asset_detail_strings AS country ON country.id = details.country_id
            WHERE details.scope = ? AND details.asset_id = ?
            """,
            [.text(scope.cacheNamespace), .text(id)]
        ) { row in
            AssetDetail(
                id: row.text(0), capturedAt: row.date(1), originalFileName: row.text(2),
                originalMimeType: row.optionalText(3), width: row.optionalInt(4),
                height: row.optionalInt(5), description: row.optionalText(6),
                cameraMake: row.optionalText(7), cameraModel: row.optionalText(8),
                lensModel: row.optionalText(9), fileSizeBytes: row.optionalInt(10),
                iso: row.optionalInt(11), focalLength: row.optionalDouble(12),
                aperture: row.optionalDouble(13), exposureTime: row.optionalText(14),
                latitude: row.optionalDouble(15), longitude: row.optionalDouble(16),
                city: row.optionalText(17), state: row.optionalText(18),
                country: row.optionalText(19)
            )
        }
    }

    func cachedAssetDetailIDs(scope: MediaAccountScope) async throws -> Set<String> {
        let database = try preparedDatabase(scope: scope)
        return try Set(database.query(
            "SELECT asset_id FROM asset_details WHERE scope = ?",
            [.text(scope.cacheNamespace)]
        ) { row in
            row.text(0)
        })
    }

    func upsert(assetDetail detail: AssetDetail, scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.transaction {
            let mimeTypeID = try intern(
                detail.originalMimeType, kind: "mime", scope: scope, database: database
            )
            let cameraMakeID = try intern(
                detail.cameraMake, kind: "camera-make", scope: scope, database: database
            )
            let cameraModelID = try intern(
                detail.cameraModel, kind: "camera-model", scope: scope, database: database
            )
            let lensModelID = try intern(
                detail.lensModel, kind: "lens-model", scope: scope, database: database
            )
            let exposureTimeID = try intern(
                detail.exposureTime, kind: "exposure-time", scope: scope, database: database
            )
            let cityID = try intern(detail.city, kind: "city", scope: scope, database: database)
            let stateID = try intern(detail.state, kind: "state", scope: scope, database: database)
            let countryID = try intern(
                detail.country, kind: "country", scope: scope, database: database
            )
            try database.execute(
                """
                INSERT INTO asset_details(
                    scope, asset_id, captured_at, original_file_name, mime_type_id,
                    width, height, description, camera_make_id, camera_model_id,
                    lens_model_id, file_size_bytes, iso, focal_length, aperture,
                    exposure_time_id, latitude, longitude, city_id, state_id, country_id,
                    cached_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope, asset_id) DO UPDATE SET
                    captured_at = excluded.captured_at,
                    original_file_name = excluded.original_file_name,
                    mime_type_id = excluded.mime_type_id,
                    width = excluded.width,
                    height = excluded.height,
                    description = excluded.description,
                    camera_make_id = excluded.camera_make_id,
                    camera_model_id = excluded.camera_model_id,
                    lens_model_id = excluded.lens_model_id,
                    file_size_bytes = excluded.file_size_bytes,
                    iso = excluded.iso,
                    focal_length = excluded.focal_length,
                    aperture = excluded.aperture,
                    exposure_time_id = excluded.exposure_time_id,
                    latitude = excluded.latitude,
                    longitude = excluded.longitude,
                    city_id = excluded.city_id,
                    state_id = excluded.state_id,
                    country_id = excluded.country_id,
                    cached_at = excluded.cached_at
                """,
                [
                    .text(scope.cacheNamespace), .text(detail.id), .date(detail.capturedAt),
                    .text(detail.originalFileName), .optionalInt64(mimeTypeID),
                    .optionalInt(detail.width), .optionalInt(detail.height),
                    .optionalText(detail.description), .optionalInt64(cameraMakeID),
                    .optionalInt64(cameraModelID), .optionalInt64(lensModelID),
                    .optionalInt(detail.fileSizeBytes), .optionalInt(detail.iso),
                    .optionalDouble(detail.focalLength), .optionalDouble(detail.aperture),
                    .optionalInt64(exposureTimeID), .optionalDouble(detail.latitude),
                    .optionalDouble(detail.longitude), .optionalInt64(cityID),
                    .optionalInt64(stateID), .optionalInt64(countryID), .date(Date()),
                ]
            )
            try pruneUnusedDetailStrings(scope: scope, database: database)
        }
    }

    func clearAssetDetails(scope: MediaAccountScope) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.transaction {
            try database.execute(
                "DELETE FROM asset_details WHERE scope = ?",
                [.text(scope.cacheNamespace)]
            )
            try pruneUnusedDetailStrings(scope: scope, database: database)
        }
    }

    func replace(
        derivatives: [LibraryIndexDerivativeRecord],
        kind: MediaDerivative,
        scope: MediaAccountScope
    ) async throws {
        let database = try preparedDatabase(scope: scope)
        try database.transaction {
            try database.execute(
                "DELETE FROM derivatives WHERE scope = ? AND derivative = ?",
                [.text(scope.cacheNamespace), .text(kind.rawValue)]
            )
            for derivative in derivatives {
                try upsert(derivative: derivative, scope: scope, database: database)
            }
        }
    }

    func storageReport(scope: MediaAccountScope) async throws -> LibraryIndexStorageReport {
        let snapshot = try await snapshot(scope: scope)
        return storageReport(snapshot: snapshot)
    }

    func storageReport(snapshot: LibraryIndexSnapshot) -> LibraryIndexStorageReport {
        storageReport(snapshot: Optional(snapshot))
    }

    private func storageReport(snapshot: LibraryIndexSnapshot?) -> LibraryIndexStorageReport {
        let metadataBytes = metadataFileBytes()
        return .init(
            metadataBytes: metadataBytes,
            derivativeBytes: snapshot?.derivatives
                .filter { [.thumbnail, .preview, .fullSize].contains($0.derivative) }
                .reduce(0) { $0 + $1.byteCount } ?? 0,
            derivativeCount: snapshot?.derivatives
                .filter { [.thumbnail, .preview, .fullSize].contains($0.derivative) }.count ?? 0,
            downloadBytes: snapshot?.derivatives
                .filter { [.original, .videoPlayback].contains($0.derivative) }
                .reduce(0) { $0 + $1.byteCount } ?? 0,
            downloadCount: snapshot?.derivatives
                .filter { [.original, .videoPlayback].contains($0.derivative) }.count ?? 0,
            originalBytes: snapshot?.derivatives
                .filter { $0.derivative == .original }
                .reduce(0) { $0 + $1.byteCount } ?? 0,
            playbackBytes: snapshot?.derivatives
                .filter { $0.derivative == .videoPlayback }
                .reduce(0) { $0 + $1.byteCount } ?? 0
        )
    }

    private func upsert(
        derivative: LibraryIndexDerivativeRecord,
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws {
        try database.execute(
            """
            INSERT INTO derivatives(
                scope, asset_id, derivative, pixel_width, pixel_height,
                source_revision, relative_file_key, byte_count, digest,
                is_verified, last_accessed_at, completed_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(scope, asset_id, derivative, pixel_width, pixel_height) DO UPDATE SET
                source_revision = excluded.source_revision,
                relative_file_key = excluded.relative_file_key,
                byte_count = excluded.byte_count,
                digest = excluded.digest,
                is_verified = excluded.is_verified,
                last_accessed_at = excluded.last_accessed_at,
                completed_at = excluded.completed_at
            """,
            [
                .text(scope.cacheNamespace), .text(derivative.assetID),
                .text(derivative.derivative.rawValue),
                .int(derivative.pixelSize?.width ?? 0), .int(derivative.pixelSize?.height ?? 0),
                .text(derivative.sourceRevision), .text(derivative.relativeFileKey),
                .int64(derivative.byteCount), .text(derivative.digest),
                .bool(derivative.isVerified), .date(derivative.lastAccessedAt),
                .date(derivative.completedAt),
            ]
        )
    }

    func storedAccounts() async throws -> [StoredLibraryAccount] {
        let database = try database()
        try migrate(database)
        return try database.query(
            """
            SELECT scopes.scope, scopes.server_identity, scopes.user_id,
                   COALESCE((
                       SELECT COUNT(*) FROM assets
                       WHERE assets.scope = scopes.scope
                         AND assets.generation = (
                             SELECT accepted_generation FROM sync_state
                             WHERE sync_state.scope = scopes.scope
                         )
                         AND assets.tombstone = 0
                   ), 0),
                   COALESCE((
                       SELECT SUM(byte_count) FROM derivatives
                       WHERE derivatives.scope = scopes.scope
                   ), 0),
                   COALESCE((
                       SELECT COUNT(*) FROM derivatives
                       WHERE derivatives.scope = scopes.scope
                   ), 0),
                   scopes.created_at
            FROM scopes
            ORDER BY scopes.created_at DESC
            """
        ) { row in
            StoredLibraryAccount(
                namespace: row.text(0),
                serverIdentity: row.text(1),
                userID: row.text(2),
                indexedAssetCount: row.int(3),
                derivativeBytes: row.int64(4),
                derivativeCount: row.int(5),
                createdAt: row.date(6)
            )
        }
    }

    func removeAccount(namespace: String) async throws {
        let database = try database()
        try migrate(database)
        try database.transaction {
            for table in [
                "asset_details", "asset_detail_strings", "derivatives", "grouped_catalogs",
                "assets", "generations", "sync_state", "scopes",
            ] {
                try database.execute(
                    "DELETE FROM \(table) WHERE scope = ?",
                    [.text(namespace)]
                )
            }
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try database.execute("VACUUM")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func schemaVersion() async throws -> Int {
        let database = try database()
        try migrate(database)
        return try Int(database.scalarInt64("PRAGMA user_version") ?? 0)
    }

    private func preparedDatabase(scope: MediaAccountScope) throws -> SQLiteConnection {
        let database = try database()
        try migrate(database)
        try ensureScope(scope, database: database)
        return database
    }

    private func metadataFileBytes() -> Int64 {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
            .reduce(Int64(0)) { total, url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
    }

    private func database() throws -> SQLiteConnection {
        if let connection {
            return connection
        }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = try SQLiteConnection(url: databaseURL)
        connection = opened
        return opened
    }

    private func migrate(_ database: SQLiteConnection) throws {
        var version = try Int(database.scalarInt64("PRAGMA user_version") ?? 0)
        guard version <= Self.currentSchemaVersion else {
            throw LibraryIndexStoreError.unsupportedSchema(version)
        }
        if version < 1 {
            try database.transaction {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS scopes(
                    scope TEXT PRIMARY KEY,
                    server_identity TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """)
                try database.execute("""
                CREATE TABLE IF NOT EXISTS generations(
                    scope TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    PRIMARY KEY(scope, generation)
                )
                """)
                try database.execute("""
                CREATE TABLE IF NOT EXISTS assets(
                    scope TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    owner_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    live_photo_video_id TEXT,
                    captured_at REAL NOT NULL,
                    uploaded_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    checksum TEXT,
                    width INTEGER,
                    height INTEGER,
                    aspect_ratio REAL NOT NULL,
                    duration_ms INTEGER,
                    is_favorite INTEGER NOT NULL,
                    visibility TEXT NOT NULL,
                    is_trashed INTEGER NOT NULL,
                    is_offline INTEGER NOT NULL,
                    bucket_key TEXT NOT NULL,
                    day_key TEXT NOT NULL,
                    week_key TEXT NOT NULL,
                    month_key TEXT NOT NULL,
                    year_key TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    tombstone INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(scope, generation, asset_id)
                )
                """)
                try database.execute("CREATE INDEX IF NOT EXISTS assets_scope_day ON assets(scope, day_key, captured_at)")
                try database.execute("CREATE INDEX IF NOT EXISTS assets_scope_week ON assets(scope, week_key, captured_at)")
                try database.execute("CREATE INDEX IF NOT EXISTS assets_scope_month ON assets(scope, month_key, captured_at)")
                try database.execute("CREATE INDEX IF NOT EXISTS assets_scope_updated ON assets(scope, updated_at, asset_id)")
                try database.execute("""
                CREATE TABLE IF NOT EXISTS grouped_catalogs(
                    scope TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    media_scope TEXT NOT NULL,
                    level TEXT NOT NULL,
                    group_key TEXT NOT NULL,
                    interval_start REAL NOT NULL,
                    interval_end REAL NOT NULL,
                    asset_count INTEGER NOT NULL,
                    owning_buckets TEXT NOT NULL,
                    cover_asset_ids TEXT NOT NULL,
                    mosaic_seed TEXT NOT NULL,
                    PRIMARY KEY(scope, generation, media_scope, level, group_key)
                )
                """)
                try database.execute("""
                CREATE TABLE IF NOT EXISTS sync_state(
                    scope TEXT PRIMARY KEY,
                    accepted_generation INTEGER,
                    last_watermark REAL,
                    historical_cursor TEXT,
                    is_paused INTEGER NOT NULL DEFAULT 0,
                    expected_asset_count INTEGER,
                    last_error TEXT
                )
                """)
                try database.execute("""
                CREATE TABLE IF NOT EXISTS derivatives(
                    scope TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    derivative TEXT NOT NULL,
                    pixel_width INTEGER NOT NULL DEFAULT 0,
                    pixel_height INTEGER NOT NULL DEFAULT 0,
                    source_revision TEXT NOT NULL,
                    relative_file_key TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    digest TEXT NOT NULL,
                    is_verified INTEGER NOT NULL,
                    last_accessed_at REAL NOT NULL,
                    completed_at REAL NOT NULL,
                    PRIMARY KEY(scope, asset_id, derivative, pixel_width, pixel_height)
                )
                """)
                try database.execute("PRAGMA user_version = 1")
            }
            version = 1
        }
        if version < 2 {
            try database.transaction {
                try database.execute(
                    "ALTER TABLE assets ADD COLUMN local_offset_hours REAL NOT NULL DEFAULT 0"
                )
                try database.execute("ALTER TABLE assets ADD COLUMN stack_id TEXT")
                try database.execute("ALTER TABLE assets ADD COLUMN stack_asset_count INTEGER")
                try database.execute("ALTER TABLE assets ADD COLUMN projection_type TEXT")
                try database.execute("ALTER TABLE assets ADD COLUMN thumbhash TEXT")
                try database.execute("PRAGMA user_version = 2")
            }
            version = 2
        }
        if version < 3 {
            try database.transaction {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS asset_detail_strings(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scope TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL,
                    UNIQUE(scope, kind, value),
                    FOREIGN KEY(scope) REFERENCES scopes(scope) ON DELETE CASCADE
                )
                """)
                try database.execute("""
                CREATE TABLE IF NOT EXISTS asset_details(
                    scope TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    original_file_name TEXT NOT NULL,
                    mime_type_id INTEGER,
                    width INTEGER,
                    height INTEGER,
                    description TEXT,
                    camera_make_id INTEGER,
                    camera_model_id INTEGER,
                    lens_model_id INTEGER,
                    file_size_bytes INTEGER,
                    iso INTEGER,
                    focal_length REAL,
                    aperture REAL,
                    exposure_time_id INTEGER,
                    latitude REAL,
                    longitude REAL,
                    city_id INTEGER,
                    state_id INTEGER,
                    country_id INTEGER,
                    cached_at REAL NOT NULL,
                    PRIMARY KEY(scope, asset_id),
                    FOREIGN KEY(scope) REFERENCES scopes(scope) ON DELETE CASCADE,
                    FOREIGN KEY(mime_type_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(camera_make_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(camera_model_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(lens_model_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(exposure_time_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(city_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(state_id) REFERENCES asset_detail_strings(id),
                    FOREIGN KEY(country_id) REFERENCES asset_detail_strings(id)
                )
                """)
                try database.execute(
                    "CREATE INDEX IF NOT EXISTS asset_details_scope_cached ON asset_details(scope, cached_at)"
                )
                try database.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try database.transaction {
                try database.execute("ALTER TABLE sync_state ADD COLUMN last_index_sync_at REAL")
                try database.execute("ALTER TABLE sync_state ADD COLUMN last_cache_sync_at REAL")
                try database.execute("PRAGMA user_version = 4")
            }
        }
    }

    private func ensureScope(_ scope: MediaAccountScope, database: SQLiteConnection) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO scopes(scope, server_identity, user_id, created_at)
            VALUES(?, ?, ?, ?)
            """,
            [
                .text(scope.cacheNamespace), .text(scope.serverIdentity), .text(scope.userID),
                .date(Date()),
            ]
        )
        try database.execute(
            "INSERT OR IGNORE INTO sync_state(scope, is_paused) VALUES(?, 0)",
            [.text(scope.cacheNamespace)]
        )
    }

    private func requireBuildingGeneration(
        _ generation: Int64,
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws {
        let state = try database.scalarText(
            "SELECT state FROM generations WHERE scope = ? AND generation = ?",
            [.text(scope.cacheNamespace), .int64(generation)]
        )
        guard state == "building" else {
            throw LibraryIndexStoreError.invalidGeneration(generation)
        }
    }

    private func intern(
        _ value: String?,
        kind: String,
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws -> Int64? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        try database.execute(
            "INSERT OR IGNORE INTO asset_detail_strings(scope, kind, value) VALUES(?, ?, ?)",
            [.text(scope.cacheNamespace), .text(kind), .text(value)]
        )
        return try database.scalarInt64(
            "SELECT id FROM asset_detail_strings WHERE scope = ? AND kind = ? AND value = ?",
            [.text(scope.cacheNamespace), .text(kind), .text(value)]
        )
    }

    private func pruneUnusedDetailStrings(
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws {
        try database.execute(
            """
            DELETE FROM asset_detail_strings
            WHERE scope = ? AND id NOT IN (
                SELECT mime_type_id FROM asset_details WHERE scope = ?
                UNION SELECT camera_make_id FROM asset_details WHERE scope = ?
                UNION SELECT camera_model_id FROM asset_details WHERE scope = ?
                UNION SELECT lens_model_id FROM asset_details WHERE scope = ?
                UNION SELECT exposure_time_id FROM asset_details WHERE scope = ?
                UNION SELECT city_id FROM asset_details WHERE scope = ?
                UNION SELECT state_id FROM asset_details WHERE scope = ?
                UNION SELECT country_id FROM asset_details WHERE scope = ?
            )
            """,
            Array(repeating: .text(scope.cacheNamespace), count: 9)
        )
    }

    private func readAssets(
        scope: MediaAccountScope,
        generation: Int64,
        database: SQLiteConnection
    ) throws -> [LibraryIndexAssetRecord] {
        try database.query(
            """
            SELECT asset_id, owner_id, kind, live_photo_video_id, captured_at,
                   uploaded_at, updated_at, checksum, width, height, aspect_ratio,
                   duration_ms, is_favorite, visibility, is_trashed, is_offline,
                   bucket_key, day_key, week_key, month_key, year_key,
                   local_offset_hours, stack_id, stack_asset_count, projection_type, thumbhash
            FROM assets
            WHERE scope = ? AND generation = ? AND tombstone = 0
            ORDER BY captured_at ASC, asset_id ASC
            """,
            [.text(scope.cacheNamespace), .int64(generation)]
        ) { row in
            LibraryIndexAssetRecord(
                id: row.text(0), ownerID: row.text(1),
                kind: LibraryIndexAssetKind(rawValue: row.text(2)) ?? .other,
                livePhotoVideoID: row.optionalText(3), capturedAt: row.date(4),
                uploadedAt: row.date(5), updatedAt: row.date(6), checksum: row.optionalText(7),
                width: row.optionalInt(8), height: row.optionalInt(9), aspectRatio: row.double(10),
                durationMilliseconds: row.optionalInt(11), isFavorite: row.bool(12),
                visibility: row.text(13), isTrashed: row.bool(14), isOffline: row.bool(15),
                bucketKey: row.text(16), dayKey: row.text(17), weekKey: row.text(18),
                monthKey: row.text(19), yearKey: row.text(20),
                localOffsetHours: row.double(21), stackID: row.optionalText(22),
                stackAssetCount: row.optionalInt(23), projectionType: row.optionalText(24),
                thumbhash: row.optionalText(25)
            )
        }
    }

    private func readGroups(
        scope: MediaAccountScope,
        generation: Int64,
        database: SQLiteConnection
    ) throws -> [LibraryIndexGroupRecord] {
        try database.query(
            """
            SELECT media_scope, level, group_key, interval_start, interval_end,
                   asset_count, owning_buckets, cover_asset_ids, mosaic_seed
            FROM grouped_catalogs
            WHERE scope = ? AND generation = ?
            ORDER BY interval_start ASC, group_key ASC
            """,
            [.text(scope.cacheNamespace), .int64(generation)]
        ) { row in
            try LibraryIndexGroupRecord(
                mediaScope: LibraryIndexMediaScope(rawValue: row.text(0)) ?? .photos,
                level: row.text(1), key: row.text(2), intervalStart: row.date(3),
                intervalEnd: row.date(4), assetCount: row.int(5),
                owningBucketKeys: Self.decode([String].self, from: row.text(6)),
                coverAssetIDs: Self.decode([String].self, from: row.text(7)),
                mosaicSeed: UInt64(row.text(8)) ?? 0
            )
        }
    }

    private func readDerivatives(
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws -> [LibraryIndexDerivativeRecord] {
        try database.query(
            """
            SELECT asset_id, derivative, pixel_width, pixel_height, source_revision,
                   relative_file_key, byte_count, digest, is_verified,
                   last_accessed_at, completed_at
            FROM derivatives WHERE scope = ?
            ORDER BY asset_id, derivative, pixel_width, pixel_height
            """,
            [.text(scope.cacheNamespace)]
        ) { row in
            let width = row.int(2)
            let height = row.int(3)
            return LibraryIndexDerivativeRecord(
                assetID: row.text(0),
                derivative: MediaDerivative(rawValue: row.text(1)) ?? .thumbnail,
                pixelSize: width > 0 && height > 0 ? .init(width: width, height: height) : nil,
                sourceRevision: row.text(4), relativeFileKey: row.text(5),
                byteCount: row.int64(6), digest: row.text(7), isVerified: row.bool(8),
                lastAccessedAt: row.date(9), completedAt: row.date(10)
            )
        }
    }

    private func readSyncState(
        scope: MediaAccountScope,
        database: SQLiteConnection
    ) throws -> LibraryIndexSyncState {
        try database.queryOne(
            """
            SELECT accepted_generation, last_watermark, historical_cursor,
                   is_paused, expected_asset_count, last_error,
                   (SELECT COUNT(*) FROM assets
                    WHERE scope = ? AND generation = sync_state.accepted_generation AND tombstone = 0),
                   last_index_sync_at, last_cache_sync_at
            FROM sync_state WHERE scope = ?
            """,
            [.text(scope.cacheNamespace), .text(scope.cacheNamespace)]
        ) { row in
            LibraryIndexSyncState(
                acceptedGeneration: row.optionalInt64(0),
                lastSuccessfulWatermark: row.optionalDate(1),
                lastIndexSyncAt: row.optionalDate(7),
                lastCacheSyncAt: row.optionalDate(8),
                historicalCursor: row.optionalText(2), isPaused: row.bool(3),
                expectedAssetCount: row.optionalInt(4), indexedAssetCount: row.int(6),
                lastError: row.optionalText(5)
            )
        } ?? .init(
            acceptedGeneration: nil, lastSuccessfulWatermark: nil,
            lastIndexSyncAt: nil, lastCacheSyncAt: nil,
            historicalCursor: nil, isPaused: false, expectedAssetCount: nil,
            indexedAssetCount: 0, lastError: nil
        )
    }

    private static func encode(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }
}

nonisolated enum LibraryIndexStoreError: LocalizedError, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int)
    case invalidGeneration(Int64)

    var errorDescription: String? {
        switch self {
        case let .sqlite(code, message): "Library index database error \(code): \(message)"
        case let .unsupportedSchema(version): "Library index schema \(version) is newer than this app supports."
        case let .invalidGeneration(generation): "Library index generation \(generation) is not writable."
        }
    }
}

private final nonisolated class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let error = Self.error(handle)
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while true {
            switch sqlite3_step(statement.handle) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw Self.error(handle)
            }
        }
    }

    func scalarInt64(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        let matches: [Int64?] = try query(sql, values) { $0.optionalInt64(0) }
        return matches.first ?? nil
    }

    func scalarText(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        let matches: [String?] = try query(sql, values) { $0.optionalText(0) }
        return matches.first ?? nil
    }

    func query<T>(
        _ sql: String,
        _ values: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var output: [T] = []
        while true {
            switch sqlite3_step(statement.handle) {
            case SQLITE_ROW:
                try output.append(map(SQLiteRow(handle: statement.handle)))
            case SQLITE_DONE:
                return output
            default:
                throw Self.error(handle)
            }
        }
    }

    func queryOne<T>(
        _ sql: String,
        _ values: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> T? {
        try query(sql, values, map: map).first
    }

    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw Self.error(handle) }
        return SQLiteStatement(handle: statement, database: handle)
    }

    private static func error(_ handle: OpaquePointer?) -> LibraryIndexStoreError {
        let code = sqlite3_errcode(handle)
        let message = sqlite3_errmsg(handle).map(String.init(cString:)) ?? "Unknown SQLite error"
        return .sqlite(code: code, message: message)
    }
}

private final nonisolated class SQLiteStatement {
    let handle: OpaquePointer
    private let database: OpaquePointer?

    init(handle: OpaquePointer, database: OpaquePointer?) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null:
                sqlite3_bind_null(handle, index)
            case let .int64(value):
                sqlite3_bind_int64(handle, index, value)
            case let .double(value):
                sqlite3_bind_double(handle, index, value)
            case let .text(value):
                sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else {
                let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "Binding failed"
                throw LibraryIndexStoreError.sqlite(code: result, message: message)
            }
        }
    }
}

private nonisolated struct SQLiteRow {
    let handle: OpaquePointer

    func text(_ index: Int32) -> String {
        optionalText(index) ?? ""
    }

    func optionalText(_ index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(handle, index)
        else { return nil }
        return String(cString: pointer)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func optionalInt(_ index: Int32) -> Int? {
        optionalInt64(index).map(Int.init)
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func optionalInt64(_ index: Int32) -> Int64? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : int64(index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func bool(_ index: Int32) -> Bool {
        int(index) != 0
    }

    func date(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: double(index))
    }

    func optionalDate(_ index: Int32) -> Date? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : date(index)
    }

    func optionalDouble(_ index: Int32) -> Double? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : double(index)
    }
}

private nonisolated enum SQLiteValue {
    case null
    case int64(Int64)
    case double(Double)
    case text(String)

    static func int(_ value: Int) -> Self {
        .int64(Int64(value))
    }

    static func bool(_ value: Bool) -> Self {
        .int64(value ? 1 : 0)
    }

    static func date(_ value: Date) -> Self {
        .double(value.timeIntervalSince1970)
    }

    static func optionalDate(_ value: Date?) -> Self {
        value.map(date) ?? .null
    }

    static func optionalText(_ value: String?) -> Self {
        value.map(text) ?? .null
    }

    static func optionalInt(_ value: Int?) -> Self {
        value.map(int) ?? .null
    }

    static func optionalInt64(_ value: Int64?) -> Self {
        value.map(int64) ?? .null
    }

    static func optionalDouble(_ value: Double?) -> Self {
        value.map(double) ?? .null
    }
}

private nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
