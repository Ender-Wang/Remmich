# Immich OpenAPI snapshot

- Source: sibling checkout `../immich/open-api/immich-openapi-specs.json`
- Upstream commit: `520a70891b0e0fdb3f7d3fbca18232bfee322916`
- Upstream describe: `v3.1.0-447-g520a70891`
- OpenAPI document version: `3.2.0`
- Upstream SHA-256: `4e15b58113426d59ffb991a82875308b3eeb64e6c916395e5c923a0632fcc67f`
- Prepared SHA-256: `e76f6f1f02a5a5820183e50d21342b97dbcd5b301a59afd10511082f9b1ed2cc`
- Copied: 2026-09-27
- Transformations: `Scripts/prepare-immich-schema.py` removes deprecated flat fields from metadata and smart search and removes the unused `SearchAssetResponseDto.nextPage`. It also limits the authenticated user config decoder to map settings and the optional external domain used for shared links. This lets Remmich load maps from server responses that omit unrelated fields such as `theme`.

The generator configuration includes operations used by the wrapper and their dependencies. The metadata and smart search wrappers both use the nested Immich 3.2 filter. Metadata uses cursor pagination and smart search returns a ranked set. The preparation script strips legacy aliases before generation from the same upstream snapshot.

Album reads were enabled on 2026-11-11 using the same pinned snapshot: `getAllAlbums` and `getAlbumInfo` are in the operation filter, and the wrapper forwards `albumId` to `getTimeBuckets`/`getTimeBucket`. Album-scoped queries include stacked members and omit the root timeline visibility filter so archived album members remain readable. No album create/edit/delete or membership mutation operation is enabled. This expands the generated read surface; it does not refresh the schema snapshot or change the provenance hashes above. Regression coverage is in [AlbumReadTests](Tests/ImmichAPITests/AlbumReadTests.swift).

Map configuration uses authenticated `getUserConfig`. Pre-login validation still uses `getServerConfig` and `getServerFeatures` for initialization, onboarding, maintenance, and feature flags. Search also reads feature flags from `getServerFeatures`. The pinned public config omits the required server state and some feature flags. Swift 6.4 and later acknowledge deprecation at the two private compatibility readers with `@diagnose`. Earlier toolchains still report the warnings.

Migration was rechecked and deferred on 2026-11-08. Upstream `main`'s OpenAPI document version `3.4.0-rc.0` still exposes initialization/admin-onboarding state through `ServerConfigDto`, not `PublicConfigDto`; separate admin-onboarding reads require authentication. The [upstream web server-config manager](https://github.com/immich-app/immich/blob/main/web/src/lib/managers/server-config-manager.svelte.ts) also still calls `getServerConfig`. Keep the current calls until an appropriate replacement is available.

Run `Scripts/update-immich-schema.sh` from the Remmich repository root to refresh the snapshot deliberately. Review and update this provenance record in the same change.
