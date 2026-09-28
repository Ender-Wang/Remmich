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
| M2 | ✅ Done | Secure login, Keychain restoration, connection routing, and typed read-only API boundary |
| M3 | Planned | Shared image loading, memory management, prefetching, and download infrastructure |
| M4 | Planned | Real server-backed Photos timeline |
| M5 | Planned | Native viewer with Save to Photos, Share, and Download |
| M6 | Planned | Read-only Albums browsing |
| M7 | Planned | Read-only Library collections |
| M8 | Planned | Search with native filters |
| M9 | Planned | iPad, Liquid Glass, accessibility, resilience, and performance polish |
| M10 | Planned | Real-device verification and AltStore release candidate |

# Current state — M2

This is the single living state diagram for the implemented app. It is updated when each milestone finishes.

```mermaid
stateDiagram-v2
    [*] --> Loading
    Loading --> SignedOut: no saved session
    Loading --> SignedIn: Keychain session validates
    Loading --> Failed: restore or validation fails
    SignedOut --> Checking: submit server address
    Checking --> Credentials: discovery + server checks pass
    Checking --> Failed: invalid URL / offline / incompatible server
    Credentials --> SigningIn: submit email + password
    SigningIn --> SignedIn: token saved to Keychain
    SigningIn --> Failed: authentication fails
    Failed --> SignedOut: retry connection
    Failed --> Credentials: retry sign-in
    SignedIn --> SignedOut: logout + Keychain clear
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

True SSID matching requires the `com.apple.developer.networking.wifi-info` entitlement, which Apple does not provision for personal development teams. `Remmich/Remmich.entitlements` records the paid-team capability, but the personal-signing target intentionally does not attach it. When SSID details are unavailable, Remmich only considers the configured LAN endpoint while iOS reports an active Wi-Fi path: it performs a short authenticated probe, verifies the same saved Immich user, and otherwise falls back to the ordered external endpoints. Cellular paths never probe LAN, and Remmich never substitutes `localhost`.
