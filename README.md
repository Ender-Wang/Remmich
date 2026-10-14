<b><font>Remmich</font></b>

A native, read-only Immich client for iPhone and iPad. Your library, with the platform feel Apple intended.

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-orange?logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/iOS-26.6%2B-black?logo=apple" alt="iOS 26.6+" />
  <img src=".github/assets/immich-read-only-badge.svg" alt="Read-only Immich" />
  <a href="https://github.com/Ender-Wang/Remmich/actions/workflows/build.yml"><img src="https://github.com/Ender-Wang/Remmich/actions/workflows/build.yml/badge.svg" alt="Build" /></a>
  <a href="https://github.com/Ender-Wang/Remmich/actions/workflows/test.yml"><img src="https://github.com/Ender-Wang/Remmich/actions/workflows/test.yml/badge.svg" alt="Tests" /></a>
</p>

**Why Remmich exists:** Immich is an excellent self-hosted photo library, but its official mobile app is built with Flutter. Remmich explores a focused alternative: native SwiftUI navigation, adaptive iPad layouts, system materials, and Apple-platform interaction patterns while keeping the Immich library strictly read-only.

Remmich never creates, edits, archives, favorites, or deletes server content. Save to Photos, Share, and Download are allowed because they act on the Apple device, not the Immich server.

# Milestones

Each milestone is a small, testable step toward a native, read-only Immich client. The detailed execution plan is maintained alongside this repository in `immich-docs`.

| Milestone | Status | What it delivers |
| --- | --- | --- |
| M0 | ✅ Done | Reproducible Xcode project, formatting, and baseline configuration |
| M1 | ✅ Done | Adaptive native Photos, Albums, Library, and Search shell using fixtures |
| M2 | ✅ Done | Secure login, Keychain restoration, verified endpoint failover, and typed read-only API boundary |
| M3 | ✅ Done | Shared image loading, memory management, prefetching, and download infrastructure |
| M4 | ✅ Done | Real server-backed Photos timeline with bounded decoded-image residency |
| M5 | In progress | Timeline presentation, native media tabs, Videos, viewer, and local export |
| M6 | Planned | Read-only Albums browsing |
| M7 | Planned | Read-only Library collections |
| M8 | Planned | Search with native filters |
| M9 | Planned | iPad, Liquid Glass, accessibility, resilience, and performance polish |
| M10 | Planned | Real-device verification and AltStore release candidate |

# Current state — M5 in progress

This is the single living state diagram for the implemented app. It is updated when each milestone finishes.

```mermaid
flowchart TD
    Launch([Launch]) --> Session{Readable saved session?}
    Session -->|No| Onboarding[Native onboarding]
    Session -->|Corrupt| Purge[Clear credentials, routes, media caches, and temporary files]
    Session -->|Keychain unavailable| StorageError[Show recoverable storage error]
    Onboarding --> Login[Immich login]
    Session -->|Yes| Restore[Restore identity from Keychain]
    Login --> Save[Save account session in Keychain]
    Save --> Direct[Use authenticated login endpoint as Direct route]
    Restore --> Profile{Configured routes?}

    Profile -->|No| RestoreDirect[Authenticate saved Direct endpoint]
    Profile -->|Yes| Evaluate{Validate current endpoint first}
    Direct --> Configure[User enters Local and External endpoints]
    Configure --> Normalize[Canonicalize with shared /api URL rules]
    Normalize --> Persist[Persist syntactically valid route candidates]
    Persist -->|Current endpoint matches a candidate| Classify[Reclassify current connection without another request]
    Persist -->|Current endpoint is not a candidate| Keep[Keep the current working connection]
    Persist -->|No active connection| Evaluate
    Classify --> Active[Server displays active endpoint]
    Keep --> Active
    RestoreDirect --> Active
    Evaluate -->|Authenticated user ID matches| Activate[Atomically activate endpoint]
    Evaluate -->|Fails| Next{Other saved endpoints in profile order}
    Next -->|Authenticated user ID matches| Activate
    Next -->|None reachable| Offline[Retain current client and report unavailable]
    Evaluate -->|Credential rejected| Purge
    Next -->|All routes reject credential| Purge
    Activate --> Active
    RestoreDirect -->|Credential rejected| Purge

    Direct --> Active
    Active -->|Foreground activation| Evaluate
    Offline -->|Foreground activation| Evaluate
    Active -->|Path change| Debounce[Debounce bursty callbacks]
    Offline -->|Path change| Debounce
    Debounce --> Evaluate

    Active --> Media[Account-scoped media controller]
    Media --> Identity[Stable asset + derivative + update + target-size identity]
    Identity --> Nuke[Nuke 13 memory/disk cache, coalescing, and downsampling]
    Active --> Timeline[Route-aware photo timeline repository]
    Timeline --> Buckets[Read bucket summaries and load bounded asset windows]
    Buckets --> Pages[Stable bucket-local logical pages]
    Active --> VideoSearch[Read-only paginated video metadata search]
    VideoSearch --> VideoBuckets[Group video pages into month buckets]
    Pages --> PhotosState[Independent Photos timeline and range state]
    VideoBuckets --> VideosState[Independent Videos timeline and range state]
    PhotosState --> Browser[Shared bottom-up native media browser]
    VideosState --> Browser
    Browser --> TimelineActions[Jump, refresh, retry, and scroll-anchor restoration]
    Browser --> Ranges[All → Days → Weeks → Months → Years]
    Ranges --> RangeCards[Lazy grouped cards and tap drill-down]
    Browser --> NativeTabs[One native Liquid Glass tab bar]
    NativeTabs -->|Latest| RootTabs[Photos, Videos, Albums, Library, Search]
    NativeTabs -->|Browsing older Photos| PhotoRangeTabs[Photos, Weeks, Months, Years, Search]
    NativeTabs -->|Browsing older Videos| VideoRangeTabs[Videos, Weeks, Months, Years, Search]
    TimelineActions --> Residency[Newest, viewport, and 45-second warm decoded pins]
    Residency --> Nuke
    Timeline --> Memories[Optional independent memory lane]
    Active --> Preferences[Local presentation preferences]
    Preferences --> Browser
    Media --> Download[Authenticated streaming temporary-file downloads]
    Download --> Player[Local AVKit playback item]
    Media --> Lifecycle[Stop prefetching in background; purge decoded memory on warning]

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

GitHub Actions builds the app and test bundles once, then passes those products to a separate test workflow. Tests cover the API package, app logic, and iPhone simulator UI for every successful build; advisory iPad UI coverage runs without blocking the test result.

True SSID matching requires the `com.apple.developer.networking.wifi-info` entitlement, which Apple does not provision for personal development teams. `Remmich/Remmich.entitlements` records the paid-team capability, but the personal-signing target intentionally does not attach it. Correctness does not depend on SSID: Personal Team builds validate the endpoint currently in use first, then the other saved endpoints in profile order, using one bounded authenticated `/users/me` identity check per candidate. Bursty path changes are debounced, stale evaluations cannot publish route state, and Remmich never substitutes `localhost`.
