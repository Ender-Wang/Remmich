#!/bin/sh
set -eu

REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-"$REPOSITORY_ROOT/../immich/open-api/immich-openapi-specs.json"}
DESTINATION="$REPOSITORY_ROOT/Packages/ImmichAPI/Sources/ImmichAPI/openapi.json"

if [ ! -f "$SOURCE" ]; then
    echo "Immich OpenAPI schema not found: $SOURCE" >&2
    exit 1
fi

cp "$SOURCE" "$DESTINATION"
(
    cd "$REPOSITORY_ROOT"
    shasum -a 256 "Packages/ImmichAPI/Sources/ImmichAPI/openapi.json"
)
