# Immich OpenAPI snapshot

- Source: sibling checkout `../immich/open-api/immich-openapi-specs.json`
- Upstream commit: `520a70891b0e0fdb3f7d3fbca18232bfee322916`
- Upstream describe: `v3.1.0-447-g520a70891`
- OpenAPI document version: `3.2.0`
- Upstream SHA-256: `4e15b58113426d59ffb991a82875308b3eeb64e6c916395e5c923a0632fcc67f`
- Prepared SHA-256: `4ea300b7aa7e5305a6decd8a096e51c5739e6a96a469c6ace2fc8e15f1fcfbd7`
- Copied: 2026-09-27
- Transformations: `Scripts/prepare-immich-schema.py` removes the deprecated optional flat fields from `MetadataSearchDto` and the unused legacy `SearchAssetResponseDto.nextPage` response field (including its required entry). Remmich uses `filter`, `orderBy`, and cursor pagination instead. Other schema definitions and endpoint deprecations remain intact.

The generator configuration includes only operations used by the wrapper and their dependencies. This avoids generating unused legacy search DTOs and operations whose initializers reference deprecated properties. The preparation step removes the equivalent unused aliases from the search DTO that Remmich does use; it does not suppress compiler diagnostics or edit generated Swift files.

Map configuration uses authenticated `getUserConfig`. `getServerConfig` and `getServerFeatures` remain intentionally in use during pre-login validation. In this snapshot, `getPublicConfig` does not expose initialization/onboarding/maintenance state or the full feature set. `getUserConfig` requires authentication. Preserve the startup checks until a complete replacement is available; the two validation call-site deprecation warnings therefore remain visible.

Run `Scripts/update-immich-schema.sh` from the Remmich repository root to refresh the snapshot deliberately. Review and update this provenance record in the same change.
