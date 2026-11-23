#!/usr/bin/env python3
"""Prepare the schema used by Remmich's generated Swift client."""

import json
import sys


def prepare(document):
    # Remmich uses filter/orderBy/cursor, not the deprecated flat search fields.
    # Swift OpenAPI Generator otherwise warns inside its own memberwise init.
    schema = document["components"]["schemas"]["MetadataSearchDto"]
    properties = schema["properties"]
    for name in list(properties):
        if properties[name].get("deprecated"):
            if name in schema.get("required", []):
                raise ValueError(f"Cannot remove required search property: {name}")
            del properties[name]
    # Responses use nextCursor. The server's legacy nextPage key may still be
    # present on the wire; generated decoders can safely ignore that extra key.
    response = document["components"]["schemas"]["SearchAssetResponseDto"]
    if response["properties"].get("nextPage", {}).get("deprecated"):
        del response["properties"]["nextPage"]
        response["required"] = [name for name in response["required"] if name != "nextPage"]
    # Decode the settings the app consumes, independent of unrelated config
    # fields that vary between Immich server versions.
    schemas = document["components"]["schemas"]
    config = schemas["UserConfigDto"]
    config["properties"] = {name: config["properties"][name] for name in ("map", "server")}
    config["required"] = ["map"]
    server = schemas["UserConfigServerDto"]
    server["properties"] = {"externalDomain": server["properties"]["externalDomain"]}
    server.pop("required", None)
    return document


if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        document = prepare(json.load(source))
    with open(sys.argv[2], "w") as destination:
        json.dump(document, destination, indent=2, ensure_ascii=False)
        destination.write("\n")
