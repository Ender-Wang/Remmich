import Foundation
import SQLite3

actor SQLiteLibraryIndexStore: LibraryIndexStoring {
    static let currentSchemaVersion = 8

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
        try prepareSchema(database)
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
            try pruneUnusedPlaces(scope: scope, database: database)
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

    func derivativeRecords(scope: MediaAccountScope) async throws -> [LibraryIndexDerivativeRecord] {
        try readDerivatives(scope: scope, database: preparedDatabase(scope: scope))
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

    func syncState(scope: MediaAccountScope) async throws -> LibraryIndexSyncState {
        try readSyncState(scope: scope, database: preparedDatabase(scope: scope))
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
            try reconcilePlaceAsset(detail.id, coordinate: PlaceCoordinate(latitude: detail.latitude, longitude: detail.longitude), scope: scope, database: database)
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
            try pruneUnusedPlaces(scope: scope, database: database)
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

    /// Place enrichment shares metadata ownership and never stores Immich credentials.
    func configurePlaces(scope: MediaAccountScope, preferences: MapsPlacesPreferences, sessionID: String) async throws {
        let database = try preparedDatabase(scope: scope)
        let encoded = try Self.encode(preferences)
        try database.transaction {
            let prior = try database.scalarText("SELECT preferences FROM place_accounts WHERE scope = ?", [.text(scope.cacheNamespace)])
            let priorSession = try database.scalarText("SELECT session_id FROM place_accounts WHERE scope = ?", [.text(scope.cacheNamespace)])
            let priorVersion = try database.scalarInt64("SELECT selection_version FROM place_accounts WHERE scope = ?", [.text(scope.cacheNamespace)])
            try database.execute("""
            INSERT INTO place_accounts(scope, preferences, session_id, selection_version) VALUES(?, ?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET preferences=excluded.preferences, session_id=excluded.session_id, selection_version=excluded.selection_version
            """, [.text(scope.cacheNamespace), .text(encoded), .text(sessionID), .int(PlaceCacheKey.selectionVersion)])
            if priorSession != sessionID {
                try database.execute("UPDATE place_lookups SET work_state='pending', attempts=MAX(0,attempts-1), lease=NULL WHERE scope=? AND work_state='running'", [.text(scope.cacheNamespace)])
            }
            if try prior.map({ try Self.decode(MapsPlacesPreferences.self, from: $0) }) != preferences || priorVersion != Int64(PlaceCacheKey.selectionVersion) {
                let assets = try database.query("SELECT asset_id, latitude, longitude FROM asset_details WHERE scope=?", [.text(scope.cacheNamespace)]) {
                    ($0.text(0), PlaceCoordinate(latitude: $0.optionalDouble(1), longitude: $0.optionalDouble(2)))
                }
                for (id, coordinate) in assets {
                    try reconcilePlaceAsset(id, coordinate: coordinate, scope: scope, database: database)
                }
            }
            try pruneUnusedPlaces(scope: scope, database: database)
        }
    }

    func deactivatePlaces(scope: MediaAccountScope, sessionID: String) async throws {
        let database = try preparedDatabase()
        try database.transaction {
            guard try database.scalarText("SELECT session_id FROM place_accounts WHERE scope=?", [.text(scope.cacheNamespace)]) == sessionID else { return }
            try database.execute("UPDATE place_accounts SET session_id=NULL WHERE scope=?", [.text(scope.cacheNamespace)])
            try database.execute("UPDATE place_lookups SET work_state='pending', attempts=MAX(0,attempts-1), lease=NULL WHERE scope=? AND work_state='running'", [.text(scope.cacheNamespace)])
        }
    }

    func cachedAssetMetadata(id: String, scope: MediaAccountScope) async throws -> AssetDetail? {
        guard var detail = try await cachedAssetDetail(id: id, scope: scope) else { return nil }
        let desired = try await desiredPlace(assetID: id, scope: scope)
        if let desired, desired.isFresh(at: .now) {
            detail.cachedPlace = desired.location
        } else if let coordinate = PlaceCoordinate(latitude: detail.latitude, longitude: detail.longitude) {
            let database = try preparedDatabase(scope: scope)
            detail.cachedPlace = try database.queryOne("""
            SELECT p.location_json FROM place_lookups p
            JOIN asset_places a ON a.scope=p.scope AND a.lookup_id=p.lookup_id
            WHERE a.scope=? AND a.asset_id=? AND p.latitude=? AND p.longitude=? AND p.location_json IS NOT NULL
            ORDER BY p.fetched_at DESC LIMIT 1
            """, [.text(scope.cacheNamespace), .text(id), .double(coordinate.latitude), .double(coordinate.longitude)]) {
                try Self.decode(PlaceLocation.self, from: $0.text(0))
            }
        }
        return detail
    }

    func desiredPlace(assetID: String, scope: MediaAccountScope) async throws -> CachedPlaceLookup? {
        let database = try preparedDatabase()
        return try database.queryOne("""
        SELECT \(Self.placeColumns) FROM place_lookups p
        JOIN asset_places a ON a.scope=p.scope AND a.lookup_id=p.lookup_id
        WHERE a.scope=? AND a.asset_id=? AND a.desired=1
        """, [.text(scope.cacheNamespace), .text(assetID)], map: Self.readPlace)
    }

    func cachedPlace(_ key: PlaceCacheKey, scope: MediaAccountScope) async throws -> CachedPlaceLookup? {
        let database = try preparedDatabase()
        return try database.queryOne("SELECT \(Self.placeColumns) FROM place_lookups p WHERE scope=? AND lookup_id=?",
                                     [.text(scope.cacheNamespace), .text(key.id)], map: Self.readPlace)
    }

    func beginPlace(_ key: PlaceCacheKey, scope: MediaAccountScope, sessionID: String, automatic: Bool, now: Date) async throws -> String? {
        let database = try preparedDatabase()
        var lease: String?
        try database.transaction {
            guard try placeIsOwned(key, scope: scope, sessionID: sessionID, database: database),
                  let record = try database.queryOne("SELECT \(Self.placeColumns) FROM place_lookups p WHERE scope=? AND lookup_id=?",
                                                     [.text(scope.cacheNamespace), .text(key.id)], map: Self.readPlace),
                  !record.isFresh(at: now), record.work != .running,
                  !automatic || (!PlaceCacheKey.isPublicService(key.endpoint) && record.work != .onDemand),
                  (!automatic && record.work == .onDemand) || (record.retryAfter.map { $0 <= now } ?? true),
                  (!automatic && record.work == .onDemand) || record.attempts < 5 else { return }
            let token = UUID().uuidString
            try database.execute("""
            UPDATE place_lookups SET work_state='running', attempts=attempts+1, lease=?
            WHERE scope=? AND lookup_id=?
            """, [.text(token), .text(scope.cacheNamespace), .text(key.id)])
            lease = token
        }
        return lease
    }

    func finishPlace(_ key: PlaceCacheKey, scope: MediaAccountScope, sessionID: String, lease: String,
                     location: PlaceLocation?, error: String?, onDemandOnly: Bool,
                     retryDelay: TimeInterval?, now: Date) async throws -> Bool
    {
        let database = try preparedDatabase()
        var accepted = false
        try database.transaction {
            guard try database.scalarText("SELECT lease FROM place_lookups WHERE scope=? AND lookup_id=?",
                                          [.text(scope.cacheNamespace), .text(key.id)]) == lease else { return }
            guard try placeIsOwned(key, scope: scope, sessionID: sessionID, database: database) else {
                try database.execute("UPDATE place_lookups SET work_state='pending', attempts=MAX(0,attempts-1), lease=NULL WHERE scope=? AND lookup_id=? AND lease=?",
                                     [.text(scope.cacheNamespace), .text(key.id), .text(lease)])
                return
            }
            let attempts = try database.scalarInt64("SELECT attempts FROM place_lookups WHERE scope=? AND lookup_id=?",
                                                    [.text(scope.cacheNamespace), .text(key.id)]) ?? 1
            if let error {
                let delay = max(retryDelay ?? 0, min(86400, 60 * pow(2, Double(attempts - 1))))
                if let location {
                    try database.execute("""
                    UPDATE place_lookups SET location_json=?, outcome='found', fetched_at=?, expires_at=NULL
                    WHERE scope=? AND lookup_id=?
                    """, [.text(Self.encode(location)), .date(now), .text(scope.cacheNamespace), .text(key.id)])
                }
                try database.execute("""
                UPDATE place_lookups SET work_state=?, retry_after=?, last_error=?, lease=NULL
                WHERE scope=? AND lookup_id=?
                """, [.text(onDemandOnly ? "onDemand" : "failed"), .date(now.addingTimeInterval(delay)), .text(error),
                      .text(scope.cacheNamespace), .text(key.id)])
            } else {
                try database.execute("""
                UPDATE place_lookups SET location_json=?, outcome=?, work_state='idle',
                fetched_at=?, expires_at=?, retry_after=NULL, last_error=NULL, attempts=0, lease=NULL
                WHERE scope=? AND lookup_id=?
                """, [.optionalText(location.map { try Self.encode($0) }), .text(location == nil ? "noResult" : "found"),
                      .date(now), .optionalDate(location == nil ? now.addingTimeInterval(86400) : nil),
                      .text(scope.cacheNamespace), .text(key.id)])
                // Country discovery may select a Local variant for all sharing assets.
                let ids = try database.query("SELECT asset_id FROM asset_places WHERE scope=? AND lookup_id=? AND desired=1",
                                             [.text(scope.cacheNamespace), .text(key.id)]) { $0.text(0) }
                for id in ids {
                    try reconcilePlaceAsset(id, coordinate: key.coordinate, scope: scope, database: database)
                }
            }
            accepted = true
        }
        return accepted
    }

    func cancelPlace(_ key: PlaceCacheKey, scope: MediaAccountScope, lease: String) async throws {
        let database = try preparedDatabase()
        try database.execute("UPDATE place_lookups SET work_state='pending', attempts=MAX(0,attempts-1), lease=NULL WHERE scope=? AND lookup_id=? AND lease=?",
                             [.text(scope.cacheNamespace), .text(key.id), .text(lease)])
    }

    func pendingPlaces(scope: MediaAccountScope, retryFailed: Bool, now: Date) async throws -> [CachedPlaceLookup] {
        let database = try preparedDatabase()
        if retryFailed {
            try database.execute("""
                                 UPDATE place_lookups SET attempts=0, retry_after=NULL WHERE scope=? AND work_state='failed'
                                 AND EXISTS(SELECT 1 FROM asset_places a WHERE a.scope=place_lookups.scope AND a.lookup_id=place_lookups.lookup_id AND a.desired=1)
                                 """,
                                 [.text(scope.cacheNamespace)])
        }
        let records = try database.query("""
        SELECT \(Self.placeColumns) FROM place_lookups p WHERE scope=?
        AND EXISTS(SELECT 1 FROM asset_places a WHERE a.scope=p.scope AND a.lookup_id=p.lookup_id AND a.desired=1)
        AND (outcome='unresolved' OR work_state='failed'
             OR (outcome='noResult' AND (expires_at IS NULL OR expires_at <= ?))
             OR (outcome='found' AND work_state!='idle'))
        AND work_state NOT IN ('running','onDemand') AND attempts < 5
        AND (retry_after IS NULL OR retry_after <= ?)
        ORDER BY fetched_at ASC LIMIT 128
        """, [.text(scope.cacheNamespace), .date(now), .date(now)], map: Self.readPlace)
        return records.filter { !PlaceCacheKey.isPublicService($0.key.endpoint) }
    }

    func placeProgress(scope: MediaAccountScope, now: Date) async throws -> PlaceCacheProgress {
        let database = try preparedDatabase()
        let records = try database.query("""
        SELECT p.outcome, p.work_state, p.expires_at, p.endpoint, p.key_json, p.attempts, p.retry_after, p.last_error,
               (SELECT COUNT(*) FROM asset_places a WHERE a.scope=p.scope AND a.lookup_id=p.lookup_id AND a.desired=1),
               (SELECT GROUP_CONCAT(a.asset_id) FROM asset_places a WHERE a.scope=p.scope AND a.lookup_id=p.lookup_id AND a.desired=1)
        FROM place_lookups p WHERE scope=?
        AND EXISTS(SELECT 1 FROM asset_places a WHERE a.scope=p.scope AND a.lookup_id=p.lookup_id AND a.desired=1)
        """, [.text(scope.cacheNamespace)]) { row in
            (row.text(0), row.text(1), row.optionalDate(2), row.text(3), row.text(4), row.int(5), row.optionalDate(6), row.optionalText(7), row.int(8), row.text(9))
        }
        var progress = PlaceCacheProgress()
        for (outcome, work, expiry, endpoint, keyJSON, attempts, retry, error, count, ids) in records {
            progress.eligible += count
            if work == "idle", outcome == "found" || (outcome == "noResult" && expiry.map { $0 > now } == true) {
                progress.resolved += count
            } else if work == "failed" {
                progress.failed += count
                let key = try Self.decode(PlaceCacheKey.self, from: keyJSON)
                progress.diagnostics.append("Stage: Photon places\nAssets: \(ids)\nEndpoint: \(endpoint)\nLanguage: \(key.language.rawValue)\nAttempts: \(attempts)\nRetry after: \(retry?.ISO8601Format() ?? "manual retry")\nFailure: \(error ?? "unknown")")
            } else if work == "onDemand" {
                progress.demandOnly += count
            } else {
                progress.pending += count
            }
        }
        return progress
    }

    func nextPlaceRetry(scope: MediaAccountScope) async throws -> Date? {
        let database = try preparedDatabase()
        return try database.queryOne("""
        SELECT MIN(retry_after) FROM place_lookups p WHERE scope=? AND work_state='failed' AND attempts<5
        AND EXISTS(SELECT 1 FROM asset_places a WHERE a.scope=p.scope AND a.lookup_id=p.lookup_id AND a.desired=1)
        """, [.text(scope.cacheNamespace)]) { $0.optionalDate(0) } ?? nil
    }

    private static let placeColumns = "p.key_json, p.location_json, p.outcome, p.work_state, p.fetched_at, p.expires_at, p.attempts, p.retry_after, p.last_error"

    private static func readPlace(_ row: SQLiteRow) throws -> CachedPlaceLookup {
        try .init(key: decode(PlaceCacheKey.self, from: row.text(0)),
                  location: row.optionalText(1).map { try decode(PlaceLocation.self, from: $0) },
                  outcome: CachedPlaceLookup.Outcome(rawValue: row.text(2)) ?? .unresolved,
                  work: CachedPlaceLookup.WorkState(rawValue: row.text(3)) ?? .pending,
                  fetchedAt: row.optionalDate(4), expiresAt: row.optionalDate(5),
                  attempts: row.int(6), retryAfter: row.optionalDate(7), error: row.optionalText(8))
    }

    private func placeIsOwned(_ key: PlaceCacheKey, scope: MediaAccountScope, sessionID: String, database: SQLiteConnection) throws -> Bool {
        guard try database.scalarText("SELECT session_id FROM place_accounts WHERE scope=?", [.text(scope.cacheNamespace)]) == sessionID else { return false }
        return try (database.scalarInt64("""
        SELECT COUNT(*) FROM asset_places a JOIN asset_details d ON a.scope=d.scope AND a.asset_id=d.asset_id
        WHERE a.scope=? AND a.lookup_id=? AND a.desired=1 AND d.latitude=? AND d.longitude=?
        """, [.text(scope.cacheNamespace), .text(key.id), .double(key.coordinate.latitude), .double(key.coordinate.longitude)]) ?? 0) > 0
    }

    private func reconcilePlaceAsset(_ assetID: String, coordinate: PlaceCoordinate?, scope: MediaAccountScope, database: SQLiteConnection) throws {
        let namespace = scope.cacheNamespace
        let priorKeys = try database.query("SELECT lookup_id FROM asset_places WHERE scope=? AND asset_id=?", [.text(namespace), .text(assetID)]) { $0.text(0) }
        // Variants remain reusable, but no association may survive a GPS change.
        if let coordinate {
            try database.execute("""
            DELETE FROM asset_places WHERE scope=? AND asset_id=? AND lookup_id NOT IN
            (SELECT lookup_id FROM place_lookups WHERE scope=? AND latitude=? AND longitude=?)
            """, [.text(namespace), .text(assetID), .text(namespace), .double(coordinate.latitude), .double(coordinate.longitude)])
        } else {
            try database.execute("DELETE FROM asset_places WHERE scope=? AND asset_id=?", [.text(namespace), .text(assetID)])
            try pruneDetachedPlaces(priorKeys, scope: scope, database: database)
            return
        }
        try pruneDetachedPlaces(priorKeys, scope: scope, database: database)
        guard let coordinate,
              let json = try database.scalarText("SELECT preferences FROM place_accounts WHERE scope=?", [.text(namespace)]) else { return }
        let preferences = try Self.decode(MapsPlacesPreferences.self, from: json)
        let endpoint = try MapsPlacesPreferences.endpointURL(preferences.endpoint)
        let known = try database.queryOne("""
        SELECT location_json FROM place_lookups WHERE scope=? AND latitude=? AND longitude=? AND endpoint=? AND location_json IS NOT NULL
        ORDER BY fetched_at DESC LIMIT 1
        """, [.text(namespace), .double(coordinate.latitude), .double(coordinate.longitude), .text(PlaceCacheKey(endpoint: endpoint, coordinate: coordinate, language: .english).endpoint.absoluteString)]) {
            try Self.decode(PlaceLocation.self, from: $0.text(0)).countryCode
        }
        let key = try PlaceCacheKey(endpoint: endpoint, coordinate: coordinate, language: preferences.language(countryCode: known ?? ""))
        try database.execute("""
        INSERT OR IGNORE INTO place_lookups(scope,lookup_id,key_json,latitude,longitude,endpoint)
        VALUES(?,?,?,?,?,?)
        """, [.text(namespace), .text(key.id), .text(Self.encode(key)), .double(coordinate.latitude),
              .double(coordinate.longitude), .text(key.endpoint.absoluteString)])
        try database.execute("UPDATE asset_places SET desired=0 WHERE scope=? AND asset_id=?", [.text(namespace), .text(assetID)])
        try database.execute("""
        INSERT INTO asset_places(scope,asset_id,lookup_id,desired) VALUES(?,?,?,1)
        ON CONFLICT(scope,asset_id,lookup_id) DO UPDATE SET desired=1
        """, [.text(namespace), .text(assetID), .text(key.id)])
    }

    private func pruneUnusedPlaces(scope: MediaAccountScope, database: SQLiteConnection) throws {
        try database.execute("""
        DELETE FROM asset_places WHERE scope=? AND desired=0 AND lookup_id IN
        (SELECT lookup_id FROM place_lookups WHERE scope=?
         AND NOT(outcome='found' AND work_state='idle') AND (expires_at IS NULL OR expires_at <= ?))
        """, [.text(scope.cacheNamespace), .text(scope.cacheNamespace), .date(Date())])
        try database.execute("""
        DELETE FROM place_lookups WHERE scope=? AND NOT EXISTS(
            SELECT 1 FROM asset_places a WHERE a.scope=place_lookups.scope AND a.lookup_id=place_lookups.lookup_id)
        """, [.text(scope.cacheNamespace)])
    }

    private func pruneDetachedPlaces(_ keys: [String], scope: MediaAccountScope, database: SQLiteConnection) throws {
        for key in keys {
            try database.execute("""
            DELETE FROM place_lookups WHERE scope=? AND lookup_id=? AND NOT EXISTS(
                SELECT 1 FROM asset_places a WHERE a.scope=place_lookups.scope AND a.lookup_id=place_lookups.lookup_id)
            """, [.text(scope.cacheNamespace), .text(key)])
        }
    }

    func storageReport(scope: MediaAccountScope) async throws -> LibraryIndexStorageReport {
        let database = try preparedDatabase(scope: scope)
        let metadataBytes = metadataFileBytes()
        // Reporting progress must not decode the entire asset/group catalog.
        return try database.queryOne(
            """
            SELECT COALESCE(SUM(CASE WHEN derivative IN ('thumbnail','preview','fullSize') THEN byte_count ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN derivative IN ('thumbnail','preview','fullSize') THEN 1 ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN derivative IN ('original','videoPlayback') THEN byte_count ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN derivative IN ('original','videoPlayback') THEN 1 ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN derivative = 'original' THEN byte_count ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN derivative = 'videoPlayback' THEN byte_count ELSE 0 END),0)
            FROM derivatives WHERE scope = ?
            """,
            [.text(scope.cacheNamespace)]
        ) { row in
            LibraryIndexStorageReport(metadataBytes: metadataBytes, derivativeBytes: row.int64(0),
                                      derivativeCount: row.int(1), downloadBytes: row.int64(2), downloadCount: row.int(3),
                                      originalBytes: row.int64(4), playbackBytes: row.int64(5))
        } ?? storageReport(snapshot: nil)
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
        try prepareSchema(database)
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
                   scopes.created_at,
                   state.expected_asset_count, COALESCE(state.is_paused, 0),
                   (SELECT COUNT(DISTINCT d.asset_id) FROM derivatives AS d
                    WHERE d.scope = scopes.scope AND d.derivative = 'thumbnail' AND d.is_verified = 1
                      AND EXISTS (SELECT 1 FROM assets AS a WHERE a.scope = d.scope AND a.asset_id = d.asset_id
                                  AND a.generation = state.accepted_generation AND a.tombstone = 0
                                  AND d.source_revision = strftime('%Y-%m-%dT%H:%M:%SZ', a.updated_at, 'unixepoch'))),
                   (SELECT COUNT(*) FROM asset_details AS m
                    WHERE m.scope = scopes.scope
                      AND EXISTS (SELECT 1 FROM assets AS a WHERE a.scope = m.scope AND a.asset_id = m.asset_id
                                  AND a.generation = state.accepted_generation AND a.tombstone = 0)),
                   (SELECT COUNT(*) FROM asset_details AS m
                    WHERE m.scope = scopes.scope
                      AND EXISTS (SELECT 1 FROM assets AS a WHERE a.scope = m.scope AND a.asset_id = m.asset_id
                                  AND a.generation = state.accepted_generation AND a.tombstone = 0
                                  AND EXISTS (SELECT 1 FROM derivatives AS d WHERE d.scope = a.scope AND d.asset_id = a.asset_id
                                              AND d.derivative = 'thumbnail' AND d.is_verified = 1
                                              AND d.source_revision = strftime('%Y-%m-%dT%H:%M:%SZ', a.updated_at, 'unixepoch')))),
                   COALESCE((SELECT SUM(d.byte_count) FROM derivatives AS d
                    WHERE d.scope = scopes.scope AND d.derivative = 'thumbnail' AND d.is_verified = 1
                      AND EXISTS (SELECT 1 FROM assets AS a WHERE a.scope = d.scope AND a.asset_id = d.asset_id
                                  AND a.generation = state.accepted_generation AND a.tombstone = 0
                                  AND d.source_revision = strftime('%Y-%m-%dT%H:%M:%SZ', a.updated_at, 'unixepoch'))), 0),
                   state.last_index_sync_at, state.last_cache_sync_at,
                   scopes.account_name, scopes.account_email
            FROM scopes
            LEFT JOIN sync_state AS state ON state.scope = scopes.scope
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
                createdAt: row.date(6),
                expectedAssetCount: row.optionalInt(7),
                isIndexPaused: row.bool(8),
                thumbnailCount: row.int(9), metadataCount: row.int(10),
                cachedAssetCount: row.int(11), thumbnailBytes: row.int64(12),
                lastIndexSyncAt: row.optionalDate(13), lastCacheSyncAt: row.optionalDate(14),
                accountName: row.optionalText(15), accountEmail: row.optionalText(16)
            )
        }
    }

    func removeAccount(namespace: String) async throws {
        let database = try database()
        try prepareSchema(database)
        try database.transaction {
            for table in [
                "asset_places", "place_lookups", "place_accounts", "account_endpoint_aliases", "asset_details", "asset_detail_strings", "derivatives", "grouped_catalogs",
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
        try prepareSchema(database)
        return try Int(database.scalarInt64("PRAGMA user_version") ?? 0)
    }

    /// Call only after successful authentication at the incoming endpoint.
    /// An unrelated endpoint or user ID cannot select another account's scope.
    func sessionReusingRetainedAccount(_ authenticated: AccountSession) async throws -> AccountSession {
        let database = try database()
        try prepareSchema(database)
        let endpoint = MediaAccountScope.canonicalServerIdentity(authenticated.apiURL)
        let exact = try database.queryOne(
            "SELECT server_identity FROM scopes WHERE server_identity = ? AND user_id = ?",
            [.text(endpoint), .text(authenticated.userID)]
        ) { $0.text(0) }
        let aliases = try database.query(
            """
            SELECT DISTINCT scopes.server_identity FROM account_endpoint_aliases aliases
            JOIN scopes ON scopes.scope = aliases.scope
            WHERE aliases.endpoint = ? AND scopes.user_id = ?
            """, [.text(endpoint), .text(authenticated.userID)]
        ) { $0.text(0) }
        var session = authenticated
        let identity = exact ?? (aliases.count == 1 ? aliases.first : nil)
        session.cacheServerIdentity = identity == endpoint ? nil : identity
        return session
    }

    /// The caller has authenticated this endpoint as the current session's user.
    func recordVerifiedEndpoint(_ endpoint: URL, session: AccountSession) async throws {
        let scope = MediaAccountScope(session: session)
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            "INSERT OR IGNORE INTO account_endpoint_aliases(scope, endpoint) VALUES(?, ?)",
            [.text(scope.cacheNamespace), .text(MediaAccountScope.canonicalServerIdentity(endpoint))]
        )
    }

    /// Display metadata survives credential revocation when local data is kept.
    /// Only an authenticated/restored session supplies these values, never email matching.
    func recordAccountIdentity(_ session: AccountSession) async throws {
        let scope = MediaAccountScope(session: session)
        let database = try preparedDatabase(scope: scope)
        try database.execute(
            "UPDATE scopes SET account_name = ?, account_email = ? WHERE scope = ?",
            [.text(session.name), .text(session.userEmail), .text(scope.cacheNamespace)]
        )
    }

    private func preparedDatabase(scope: MediaAccountScope) throws -> SQLiteConnection {
        let database = try preparedDatabase()
        try ensureScope(scope, database: database)
        return database
    }

    private func preparedDatabase() throws -> SQLiteConnection {
        let database = try database()
        try prepareSchema(database)
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

    private func prepareSchema(_ database: SQLiteConnection) throws {
        let version = try Int(database.scalarInt64("PRAGMA user_version") ?? 0)
        if version == Self.currentSchemaVersion {
            return
        }
        if version == 7 {
            try database.transaction {
                try createPlaceSchema(database)
                try database.execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
            }
            return
        }
        guard version == 0 else {
            throw LibraryIndexStoreError.unsupportedSchema(version)
        }
        try database.transaction {
            try database.execute("""
            CREATE TABLE IF NOT EXISTS scopes(
                scope TEXT PRIMARY KEY,
                server_identity TEXT NOT NULL,
                user_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                account_name TEXT,
                account_email TEXT
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
                local_offset_hours REAL NOT NULL DEFAULT 0,
                stack_id TEXT,
                stack_asset_count INTEGER,
                projection_type TEXT,
                thumbhash TEXT,
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
                last_error TEXT,
                last_index_sync_at REAL,
                last_cache_sync_at REAL
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
            try database.execute("""
            CREATE TABLE IF NOT EXISTS account_endpoint_aliases(
                scope TEXT NOT NULL,
                endpoint TEXT NOT NULL,
                PRIMARY KEY(scope, endpoint),
                FOREIGN KEY(scope) REFERENCES scopes(scope) ON DELETE CASCADE
            )
            """)
            try createPlaceSchema(database)
            try database.execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    private func createPlaceSchema(_ database: SQLiteConnection) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS place_accounts(
            scope TEXT PRIMARY KEY REFERENCES scopes(scope) ON DELETE CASCADE,
            preferences TEXT NOT NULL, session_id TEXT, selection_version INTEGER NOT NULL
        )
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS place_lookups(
            scope TEXT NOT NULL REFERENCES scopes(scope) ON DELETE CASCADE,
            lookup_id TEXT NOT NULL, key_json TEXT NOT NULL,
            latitude REAL NOT NULL, longitude REAL NOT NULL, endpoint TEXT NOT NULL,
            location_json TEXT, outcome TEXT NOT NULL DEFAULT 'unresolved',
            work_state TEXT NOT NULL DEFAULT 'pending', fetched_at REAL, expires_at REAL,
            attempts INTEGER NOT NULL DEFAULT 0, retry_after REAL, last_error TEXT, lease TEXT,
            PRIMARY KEY(scope, lookup_id)
        )
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS asset_places(
            scope TEXT NOT NULL, asset_id TEXT NOT NULL, lookup_id TEXT NOT NULL,
            desired INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY(scope, asset_id, lookup_id),
            FOREIGN KEY(scope, asset_id) REFERENCES asset_details(scope, asset_id) ON DELETE CASCADE,
            FOREIGN KEY(scope, lookup_id) REFERENCES place_lookups(scope, lookup_id) ON DELETE CASCADE
        )
        """)
        try database.execute("CREATE UNIQUE INDEX IF NOT EXISTS asset_places_desired ON asset_places(scope, asset_id) WHERE desired = 1")
        try database.execute("CREATE INDEX IF NOT EXISTS asset_places_lookup ON asset_places(scope, lookup_id, desired)")
        try database.execute("CREATE INDEX IF NOT EXISTS place_work ON place_lookups(scope, work_state, retry_after)")
        try database.execute("CREATE INDEX IF NOT EXISTS place_coordinates ON place_lookups(scope, latitude, longitude, endpoint, fetched_at)")
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
        case let .unsupportedSchema(version): "Local library schema \(version) is unsupported by this test build. Reset local app data before using this build."
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
