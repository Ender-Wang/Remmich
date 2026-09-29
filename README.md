<b><font>Remmich</font></b>

A native, read-only Immich client for iPhone and iPad. Your library, with the platform feel Apple intended.

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-orange?logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/iOS-26.6%2B-black?logo=apple" alt="iOS 26.6+" />
  <img src=".github/assets/immich-read-only-badge.svg" alt="Read-only Immich" />
  <a href="https://github.com/Ender-Wang/Remmich/actions/workflows/build-and-test.yml"><img src="https://github.com/Ender-Wang/Remmich/actions/workflows/build-and-test.yml/badge.svg" alt="Build &amp; Test" /></a>
</p>

**Why Remmich exists:** Immich is an excellent self-hosted photo library, but its official mobile app is built with Flutter. Remmich explores a focused alternative: native SwiftUI navigation, adaptive iPad layouts, system materials, and Apple-platform interaction patterns while keeping the Immich library strictly read-only.

Remmich never creates, edits, archives, favorites, or deletes server content. Save to Photos, Share, and Download are allowed because they act on the Apple device, not the Immich server.

# Milestones

Each milestone is a small, testable step toward a native, read-only Immich client. The detailed execution plan is maintained alongside this repository in `immich-docs`.

| Milestone | Status | What it delivers |
| --- | --- | --- |
| M0 | ✅ Done | Reproducible Xcode project, formatting, and baseline configuration |
| M1 | ✅ Done | Adaptive native Photos, Albums, Library, and Search shell using fixtures |
| M2 | 🧪 Post-M2 fixes implemented — device verification pending | Secure login, Keychain restoration, connection routing, and typed read-only API boundary |
| M3 | ⏳ Pending | Shared image loading, memory management, prefetching, and download infrastructure |
| M4 | Planned | Real server-backed Photos timeline |
| M5 | Planned | Native viewer with Save to Photos, Share, and Download |
| M6 | Planned | Read-only Albums browsing |
| M7 | Planned | Read-only Library collections |
| M8 | Planned | Search with native filters |
| M9 | Planned | iPad, Liquid Glass, accessibility, resilience, and performance polish |
| M10 | Planned | Real-device verification and AltStore release candidate |

# Current state — post-M2 fixes awaiting device verification

This is the single living state diagram for the implemented app. It is updated when each milestone finishes.

```mermaid
flowchart TD
    Launch([Launch]) --> Session{Readable saved session?}
    Session -->|No| Onboarding[Native onboarding]
    Session -->|Corrupt| Purge[Clear credentials and active route]
    Session -->|Keychain unavailable| StorageError[Show recoverable storage error]
    Onboarding --> Login[Immich login]
    Session -->|Yes| Restore[Restore identity from Keychain]
    Login --> Save[Save account session in Keychain]
    Save --> Direct[Use authenticated login endpoint as Direct route]
    Restore --> Profile{Configured routes?}

    Profile -->|No| RestoreDirect[Authenticate saved API endpoint]
    Profile -->|Yes| Route{Authenticate configured routes}
    Direct --> Configure[User enters Local and External endpoints]
    Configure --> Normalize[Canonicalize with shared /api URL rules]
    Normalize --> Route
    RestoreDirect --> Active
    Route -->|Exact SSID| LAN[Configured LAN endpoint]
    Route -->|Personal Team| Probe[2-second authenticated LAN probe]
    Probe -->|Same user after bounded transient retries| LAN
    Probe -->|Unavailable or wrong user| External[Ordered external endpoints with bounded transient retries]
    Route -->|SSID mismatch| External
    Route -->|Transiently unreachable| Offline[Retain session and retry]
    Route -->|All routes reject credential| Purge
    RestoreDirect -->|Credential rejected| Purge

    Direct --> Active[Server displays active endpoint]
    LAN --> Active
    External --> Active
    Active -->|Path change or app activation| Profile
    Offline -->|Path change or app activation| Profile

    Active -->|Logout cancels in-flight routing| Purge
    Purge --> Onboarding
```

# Development

Refresh the pinned schema from a sibling Immich checkout without embedding a developer path:

```bash
Scripts/update-immich-schema.sh
```

Or pass a schema path explicitly:

```bash
Scripts/update-immich-schema.sh path/to/immich-openapi-specs.json
```

The updater prints a repository-relative checksum target. Schema provenance and the pinned upstream revision live in `Packages/ImmichAPI/SCHEMA-PROVENANCE.md`.

The project uses SwiftFormat as a pre-build check. Xcode may ask you once to trust the pinned Swift OpenAPI Generator build-tool plugin.

GitHub Actions runs formatting, package tests, app unit tests, and simulator UI tests for every pushed commit and pull request. It can also be started manually from the Actions tab.

True SSID matching requires the `com.apple.developer.networking.wifi-info` entitlement, which Apple does not provision for personal development teams. `Remmich/Remmich.entitlements` records the paid-team capability, but the personal-signing target intentionally does not attach it. After a connection profile is saved, Personal Team builds therefore perform a short authenticated probe of the configured local endpoint on every route evaluation, verify the same saved Immich user, and otherwise try the ordered external endpoints. Remmich never substitutes `localhost`.
