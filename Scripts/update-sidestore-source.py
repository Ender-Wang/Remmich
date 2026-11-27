#!/usr/bin/env python3
"""Update the source from one published release and its actual unsigned IPA."""

import argparse
import json
import plistlib
import re
from pathlib import Path
import zipfile


def update_source(source, release, ipa):
    if release["draft"] or release["prerelease"]:
        raise ValueError("Only published releases in the regular channel belong in this source.")
    assets = [asset for asset in release["assets"] if asset["name"].endswith("-unsigned.ipa")]
    if len(assets) != 1:
        raise ValueError("Expected exactly one unsigned IPA asset.")
    asset = assets[0]
    if ipa.stat().st_size != asset["size"]:
        raise ValueError("Downloaded IPA size differs from the release asset.")
    with zipfile.ZipFile(ipa) as archive:
        names = [name for name in archive.namelist()
                 if name.startswith("Payload/") and name.count("/") == 2
                 and name.endswith(".app/Info.plist")]
        if len(names) != 1:
            raise ValueError("Expected one main application Info.plist.")
        info = plistlib.loads(archive.read(names[0]))
    app = source["apps"][0]
    if info["CFBundleIdentifier"] != app["bundleIdentifier"]:
        raise ValueError("IPA bundle identifier does not match the source.")
    version = info["CFBundleShortVersionString"]
    rc_identifier = info.get("RemmichPrereleaseIdentifier", "")
    if not isinstance(rc_identifier, str) or (rc_identifier and not re.fullmatch(r"rc\.[1-9][0-9]*", rc_identifier)):
        raise ValueError("Expected an RC identifier such as rc.1.")
    expected_tag = f"v{version}-{rc_identifier}" if rc_identifier else f"v{version}"
    if release["tag_name"] != expected_tag:
        raise ValueError("Release tag does not match the IPA version and RC identifier.")
    entry = {
        "version": version,
        "buildVersion": str(info["CFBundleVersion"]),
        "date": release["published_at"],
        "localizedDescription": release.get("body") or f"Remmich {version}",
        "downloadURL": asset["browser_download_url"],
        "size": asset["size"],
        "minOSVersion": info["MinimumOSVersion"],
    }
    versions = [item for item in app["versions"]
                if (item["version"], item["buildVersion"]) != (entry["version"], entry["buildVersion"])]
    versions.append(entry)
    # Re-running an older release must not downgrade the first/latest entry.
    app["versions"] = sorted(versions, key=lambda item: (
        tuple(int(part) for part in item["version"].split(".")),
        int(item["buildVersion"])), reverse=True)
    # Permissions describe the latest installable IPA, not an older rerun.
    if app["versions"][0] == entry:
        app["appPermissions"]["privacy"] = {
            key: value for key, value in info.items() if key.endswith("UsageDescription")
        }
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    args = parser.parse_args()
    source = update_source(json.loads(args.source.read_text()),
                           json.loads(args.release.read_text()), args.ipa)
    args.source.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
