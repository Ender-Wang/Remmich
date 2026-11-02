# Contributing to Remmich

The [README](README.md) describes the available features, current limitations, and milestone progress. This guide covers how to build the app and how the project is organized.

## Requirements

- Xcode 27 or later; the current source has been compiled with Xcode 27.2.
- The app uses Swift 6 language mode (`SWIFT_VERSION = 6.0`). The local API package requires Swift tools 6.2 or later; the verified Xcode 27.2 toolchain uses Swift 6.4.2.
- SwiftFormat matching [.swiftformat-version](.swiftformat-version). The [build workflow](.github/workflows/build.yml) contains the pinned download and checksum-verification steps.
- To run the app on a device, iOS/iPadOS 26.6 or later and an account on your Immich server.

Swift packages resolve through Xcode. The local API package's generator and runtime dependencies are pinned in [Package.swift](Packages/ImmichAPI/Package.swift); schema provenance is recorded [alongside the package](Packages/ImmichAPI/SCHEMA-PROVENANCE.md).

## Build and run

```bash
git clone https://github.com/Ender-Wang/Remmich.git
cd Remmich
open Remmich.xcodeproj
```

1. Install the pinned SwiftFormat version and let Xcode resolve the packages. Xcode may ask you to trust the Swift OpenAPI Generator build-tool plugin.
2. Select the **Remmich** scheme and your device, choose your signing team, and use a unique bundle identifier if your team requires one.
3. Build and run. Sign in with your Immich server address and credentials, then configure a Primary address and optional Fallback addresses in **Profile → Connection** if needed.

Connection selection checks Primary first, then Fallback addresses in order, using authenticated user-ID validation. It does not require Wi-Fi-name access or a location permission. Connection displays omit the trailing `/api` while internal endpoints retain it. A separate unauthenticated `/server/ping` probe measures HTTP response time only while Connection is visible and the app is active; probe rounds do not overlap or switch routes.

Verified endpoint aliases share a stable account cache identity, independent of the current network URL. After successful login, SQLite resolves a retained identity through an exact endpoint/user-ID match or one unambiguous verified alias. Email alone is never an identity key. Saving a profile authenticates additional candidates before recording aliases; unreachable or different-account endpoints are not associated. Ordinary logout retains aliases and cached data; deleting an account's local data removes its aliases, SQL records, and thumbnail namespace. Old address-profile keys are not migrated. Schema 6 adds the account-scoped alias table without moving or merging existing caches.

## Architecture

### Data flow

```mermaid
flowchart TD
    Keychain[Keychain session] --> Routing[Authenticated Primary / Fallback routing]
    Routing --> API[Typed read-only Immich API]
    API --> Index[Local timeline index and incremental sync]
    Index --> Timeline[Photos and Videos timelines]
    API --> Cache[Account-scoped thumbnail and Info cache]
    Cache --> Timeline
    Timeline --> Browsing[Semantic zoom and date cards]
    Browsing --> Viewer[Photo, Live Photo, and memory viewer]
    Cache --> Viewer
    Browsing --> Stream[Authenticated video byte-range stream]
    Routing --> Stream
    Stream --> AVKit[AVPlayer and AVKit playback]
    Timeline --> Profile[Account, Connection, Index, Cache and Storage]
```

The generated API client is wrapped by [ImmichServiceAdapter](Remmich/Infrastructure/Immich/ImmichServiceAdapter.swift) and the feature-facing [read-only service protocols](Remmich/Domain/Protocols/ReadOnlyServices.swift). Account restoration and route changes are coordinated from [AppSessionController](Remmich/App/AppSessionController.swift).

The timeline index and paired thumbnail/Info cache are local, account-scoped stores. Video playback uses [AuthenticatedVideoStreamSource](Remmich/Infrastructure/Media/AuthenticatedVideoStreamSource.swift) with one viewer-owned [VideoPlaybackSession](Remmich/Features/Shared/AssetViewer/VideoPlaybackSession.swift). It streams the selected video; persistent original downloads and export actions remain planned work.

### Landing and sign-in

[OnboardingView](Remmich/Features/Onboarding/OnboardingView.swift) uses the profile's animated branding, green connection and blue account accents, and a native glass form. An adaptive layout keeps branding above the form in portrait and beside it in landscape, with scrolling for the keyboard and larger text. [RootView](Remmich/App/RootView.swift) keeps a single onboarding view across server checking, credentials, sign-in progress, and failure so field values and logo motion survive those transitions. Checking uses that mounted branding rather than a second full-screen loader. Server validation, HTTP confirmation, credential storage, and successful library preparation remain owned by `AppSessionController`; OAuth remains unsupported.

### Asset capture times

[TimelineAssetSummary](Remmich/Domain/Timeline/TimelineModels.swift) keeps the original capture instant separate from `captureLocalDate`, which applies Immich's per-asset `localOffsetHours`. Displays, accessibility labels, date groups, and date-only titles use the capture-local calendar. Ordering follows capture-local day, then the original instant within that day, preserving chronology when daylight saving repeats an hour. The offset is rounded to whole seconds when applied to avoid float representation noise at midnight boundaries.

Viewer details already contain Immich's `localDateTime`; they receive no second offset. Video-search fallback carries `fileCreatedAt` plus the offset derived from `localDateTime`, matching the timeline contract. Upload, update, sync, and thumbnail-revision timestamps retain their original meanings. GPS is optional: Remmich uses the server's capture metadata and does not guess a missing timezone from the phone's current location or offset.

SQLite schema 5 repairs persisted day/week/month/year keys, including the ISO week year, and invalidates grouped projections for offline rebuilding from accepted assets. It preserves capture instants, accepted generations, pause state, cached details, derivative manifests, and thumbnail files. This repair requires neither a cache clear nor a server refetch.

[TimelineCaptureDateFormattingTests](RemmichTests/TimelineCaptureDateFormattingTests.swift) and [CaptureTimePersistenceTests](RemmichTests/CaptureTimePersistenceTests.swift) cover offsets, DST, viewer consistency, new index writes, video fallback, and migration. Ten focused tests, including 12 offset cases, passed using unchanged production sources in a temporary macOS harness under `America/Los_Angeles` and `Asia/Shanghai` timezone settings. The iOS app and test bundle compiled successfully. Portable logic ran in the macOS harness; the UIKit semantic-group case is included in the iOS test target.

Device checks are performed by the maintainer during normal use. Reported issues are fixed and amended into the relevant change; device checks are regression references rather than unfinished implementation items.

### Scoped timeline entry and transitions

[PhotosRangeAssetsView](Remmich/Features/Photos/PhotosRangeViews.swift) opens date groups at the bottom, where the latest assets appear. It uses the native bottom anchor rather than scrolling to the card's rotating cover image. Removing the retained initial center-scroll request also prevents the underlying grid from shifting when the first viewer opens.

[ScopedAssetTransitionRuntime](Remmich/Features/Shared/AssetViewer/ScopedAssetTransitionRuntime.swift) keeps weak UIKit probes for visible thumbnail geometry and revision-checked source images. Opening captures the tapped rectangle and reuses the displayed thumbnail before presentation; returning resolves the selected asset's current rectangle and aspect ratio. Unavailable cells retain the existing fallback. [ScopedDayTransitionTests](RemmichTests/ScopedDayTransitionTests.swift) checks newest-asset entry and stable opening/return positions across Day, Week, Month, and Year layouts. [ScopedAssetTransitionTests](RemmichTests/ScopedAssetTransitionTests.swift) covers geometry, clipping, cell reuse, weak image ownership, and immediate image handoff.

### Timeline overlays during viewer transitions

[TimelineAssetOverlay](Remmich/DesignSystem/TimelineAssetOverlay.swift) shares the Live Photo/360/stack badges and video-duration label between thumbnail cells and the viewer's opening surface. The opening overlay follows the image frame and fades with the expansion progress while retaining its text size. On return, both Live Photo badges and video durations participate in source visibility; a local value-bound fade survives the UIKit hosting boundary. Semantic-pinch transitions and memory-panel opening retain their existing paths.

[TimelineAssetOverlayTests](RemmichTests/TimelineAssetOverlayTests.swift) checks opening opacity and hidden/revealed return states for Live Photos and videos, with an ordinary-photo control. All five rendering cases passed in the macOS harness, and the iOS app/test bundle compiled. The maintainer confirmed the reported opening/return regression resolved on device.

### Filmstrip layout

`AssetViewerFilmstrip`, in [AssetViewerView](Remmich/Features/Shared/AssetViewer/AssetViewerView.swift), centers the complete thumbnail row when it fits the viewport. The row has at least the viewport's width, and fitting content skips selected-item scroll requests. Overflowing content scrolls to the selected stable ID; viewport width is part of the positioning request so resizing also updates the selection's position. [FilmstripAlignmentTests](RemmichTests/FilmstripAlignmentTests.swift) covers fitting rows, selection changes, overflowing content, and resizing using the hosted scroll view.

### Video opening and backgrounds

[AssetViewerView](Remmich/Features/Shared/AssetViewer/AssetViewerView.swift) keeps the selected video's media rectangle black in its shared page backdrop, outside the poster's opening crop and transform. The black stage and themed surround fade as one compositing group; Info and app chrome retain the app theme. AVKit stays deferred until the source expansion ends, so its own UIView background cannot supply the earlier transition frames. [VideoOpeningBackgroundTests](RemmichTests/VideoOpeningBackgroundTests.swift) checks the portrait player/surround split, landscape Info boundary, photo background, and opening-fade composition.

### Native Picture in Picture

[ViewerVideoSurface](Remmich/Features/Shared/AssetViewer/ViewerVideoSurface.swift) enables AVKit's automatic inline Picture in Picture, backed by the app's audio background mode. The same viewer, player, and stream stay mounted for restoration. AVKit owns the Home-screen handoff for playing video; the scene's inactive transition must not pause it. Unfinished preparation and seeks still suspend on background entry when PiP is not engaged, and audio interruptions retain their suspension behavior.

The session retains its playback audio configuration throughout PiP, including a pause from native controls, so those controls can resume playback in the background. Stopping PiP while the app is backgrounded pauses playback and releases audio; terminal viewer dismissal always closes the session. [VideoPictureInPictureTests](RemmichTests/VideoPictureInPictureTests.swift) exercises native configuration, delegate restoration, audio ownership, and cleanup. The actual Home gesture, system PiP controls, and automatic-PiP setting require physical-device verification; see [Apple's standard-player guidance](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player).

### Background library sync

[LibraryBackgroundSyncCoordinator](Remmich/App/LibraryBackgroundSyncCoordinator.swift) registers two native tasks through the app delegate before launch completes:

| Task | Identifier | Earliest requested start | Work |
| --- | --- | --- | --- |
| `BGAppRefreshTask` | `io.github.ender-wang.Remmich.library-refresh` | 5 minutes later | Refresh the newest two month buckets, with a 20-second budget including preparation. No historical catch-up, database compaction, cache reconciliation, or thumbnail/metadata warming. |
| `BGProcessingTask` | `io.github.ender-wang.Remmich.library-sync` | 15 minutes later | Index/history catch-up, maintenance, and enabled thumbnail/metadata caching. Requires network connectivity; external power is not required. |

`Info.plist` declares both identifiers and the `fetch` and `processing` background modes alongside the existing audio mode. These are minimum delays, not repeating timers; iOS decides when, or whether, to run either task. Existing pending requests retain their dates across foreground events. Each launch requests the next opportunity, including when another worker already owns execution; overlapping grants cede their time instead of creating a second index writer.

The scene and background handlers share one `AppSessionController` and `LibraryIndexController`. A cold background launch restores credentials, connection candidates, and persisted index/pause state without creating media prefetchers or projecting the photo/video UI. The short refresh also skips restoring cache inventory. Index and cache work reuse their existing account-scoped storage and cancellation paths. Processing awaits both indexing and caching, honors pauses and auto-cache settings, and observes Low Power Mode and thermal changes. Native expiration and the short-refresh deadline invalidate preparation and cancel unfinished work; completed generations and cache pairs remain reusable. A successful partial refresh leaves missing history and older changed buckets for processing and does not mark the complete index as fresh. Returning to the background under a refresh grant restores its cache restriction, even after foreground activity. Sign-out cancels both pending requests and invalidates in-flight restoration before clearing the account.

Foreground automatic checks have a five-minute success-only freshness window, persisted per account. A failed attempt never counts as fresh, and **Sync now** bypasses the window. Accepted timeline publication deferred by an open viewer survives suspension and can be applied when the viewer closes. Background entry stops the foreground Swift tasks while retaining their OS-owned transfers.

[LibraryTransferQueue](Remmich/Infrastructure/LibraryIndex/LibraryTransferQueue.swift) owns one logical queue for index responses, asset metadata, and thumbnails. It selects a standard native URLSession in foreground and one native background URLSession for suspended execution. Lifecycle handoff requeues unfinished attempts while preserving completed responses and job-keyed waiting consumers. Both sessions use the same serial delegate queue. [LibraryTransferJournal](Remmich/Infrastructure/LibraryIndex/LibraryTransferJournal.swift) persists account/credential/route identities, request kinds, stable pass IDs, retry state, attempt UUIDs, transport, and completed-file references without writing bearer tokens into the journal. Attempt-scoped body filenames and callback guards reject late completions even when sessions reuse numeric task IDs. Legacy completed responses keep their original file identity; lost in-process attempts are requeued after relaunch. The dedicated sync repository uses [ImmichQueuedGETTransport](Packages/ImmichAPI/Sources/ImmichAPI/ImmichQueuedGETTransport.swift), preserving generated request authentication and response decoding. Interactive browsing, authentication, and video playback keep their existing transports.

Cache look-ahead covers up to 128 unfinished candidates, alongside the two import tasks, with at most 256 tracked current native attempts. Ready journal records are separate from that attempt cap. These bounds are a throughput-comparison candidate, increased from 32 assets/64 tasks while retaining six HTTP/1.1 connections per native session and two cache-import workers. While the app is suspended it cannot replenish the queue; later execution windows import responses and enqueue more work. Completed files are moved into owned storage before delegates return. Normal cache responses are released after the thumbnail/metadata pair is stored; these records have separate SQL transactions, and interruption between them leaves a recoverable partial pair that is excluded from complete cached counts. Rebuild responses remain replayable until atomic promotion. New index runs discard completed responses at least five minutes old (and legacy responses without a completion date), preserving recent replay and pending transfers. A staging generation is created only after its selected responses arrive. Pause, sign-out, deletion, credential/route changes, and asset-revision changes invalidate the appropriate jobs. Transient failures have three quick attempts followed by a 60-second cooldown before another automatic retry burst. Retries become eligible on the next pump, request, or execution opportunity rather than a separate polling timer. Native task batches are journaled once before any task resumes.

Both already-backgrounded receipts and OS background-session wakeups notify the existing sync coordinator. Transfer reconciliation uses a separate entry point from scheduled discovery: warm imports reuse the validated account/route, while cold restoration, path changes, authentication rejection, and connection failures retain route recovery. Receipt and committed-import revisions permit further windows when data arrives or imports advance; unchanged no-progress notifications do not restart the worker. Unfinished response files remain available to later deliveries, scheduled grants, or foreground continuation.

Normal cache imports select ready thumbnail/metadata pairs from the bounded unfinished look-ahead, preserving two import workers while bypassing earlier undelivered requests. Refills track unfinished asset IDs, so out-of-order delivery cannot skip a slow pair. Incremental index progress retains accepted bucket counts until replacement responses arrive; explicit rebuild progress starts at zero. The transfer-only software deadline is removed on foreground entry and re-armed on returning to background; native expiration keeps its authority.

Home-to-background migration holds a short native background assertion until unfinished foreground attempts have been handed off. The assertion is acquired before scheduling the asynchronous migration and released on completion or a stale-phase exit. Its expiration does not cancel another sync owner.

Receipt-driven reconciliation holds a native background-time assertion, ended on completion or expiration. Reconciliation has a 20-second window and shares the existing worker owner; it does not hold a system completion callback until a full library finishes. Real session completions attached to an existing transfer window are completed exactly once. Same-generation cache continuation skips filesystem preparation while refreshing committed SQLite manifest rows; fresh operations, changed generations, deletion, and account changes retain reconciliation. Low Power Mode and thermal restrictions gate cache scheduling/resumption. iOS still owns execution timing; a durable queue does not guarantee an uninterrupted full-library run. The journal stores a token digest, not the token itself; authenticated native tasks carry their authorization header in the OS-managed session. Receipt/metric logs identify both transport and attempt, independently of app state. Retired background attempts may still emit metrics after foreground return. Interrupted partial responses can be downloaded again during handoff; completed bodies and committed cache pairs are retained.

Index and cache statistics treat interrupted background windows as continuations. They retain the operation's start time; cache inventory remains visible while the next snapshot loads, and its ETA work sample accumulates across those windows. Elapsed time is wall time across native-transfer waits and suspension within the same in-memory operation. An explicit new operation starts a new clock; deletion and account changes clear the relevant inventory. Live storage reporting uses account-scoped SQL aggregates, throttled to once every five seconds during cache progress. Returning to the profile refreshes committed statistics and rebases its visible clock, without a background UI timer or counting unimported transfer bodies as cached assets.

Manual Pause freezes elapsed time on both Index and Cache & Storage. Resume continues the accumulated value, excluding time spent manually paused. It remains distinct from starting a new Sync/Rebuild operation.

Release retains sync lifecycle, handoff, recovery, pause/cancellation, warning, and error logs through unified logging. Per-response receipts, native request metrics, queue dumps/counters, and periodic cache-progress checkpoints are `DEBUG`-only, including their diagnostic calculations and queue-snapshot tasks. UI statistics and durable journal writes remain active in Release. No app-owned accumulating diagnostic log file is created.

Debug receipts, cache progress, index-generation publication, and foreground/background transitions include ISO 8601 timestamps with fractional seconds. Receipts and progress also include `appState=foreground/background/inactive`. Debug cache checkpoints are logged approximately every five seconds while progress callbacks run, in addition to percentage milestones. Compare paired-count/storage deltas across timestamped checkpoints for committed cache rates; sum receipt bytes separately for delivery rates. Background delegate delivery may be batched, so receipt timestamps measure app delivery rather than exact network transmission time.

The normal cache loop publishes UI progress approximately once per second and refills the unfinished request window after 16 processed assets, or earlier when no import task remains in flight. Each missing thumbnail or metadata half uses its own GET response; a refill batch is not a byte-range chunk or a bulk HTTP request. Request batching, UI publication, and diagnostic checkpoint cadence are distinct and can each produce a stepped appearance.

For transfer bottleneck investigations, queue snapshots expose queued/ready/native task states, waiter kinds, and process-lifetime submitted/received totals. Receipt task IDs join delegate-processing lag and journal/body processing duration with DEBUG native URLSession metrics when iOS supplies them. Missing native dates are logged as `-1`. These checkpoints are triggered by existing pump/window activity rather than a new timer; a native task in `running` state can still be waiting for system scheduling or connectivity.

Each native attempt persists `submittedAt`; receipt logs include that timestamp so creation before or after Home can be correlated with app-state transition logs, including after session restoration. Older journal entries without the field log `unknown`. The larger look-ahead gives the system more work before suspension, but cannot guarantee uninterrupted background execution or override native request scheduling.

The background session allows up to six HTTP/1.1 connections per host. The session-creation log records `maxConnectionsPerHost`, look-ahead, and native-task capacity so captures identify the configuration used. Native metrics include fetch-start delay, DNS, connection setup, TLS setup, and connection reuse (`1` reused, `0` new, `-1` unavailable). Connection setup can include TLS; do not add those durations together. iOS may use fewer connections than configured, and HTTP/2 or newer multiplexes requests independently of this HTTP/1.1 limit.

After a headless launch, the restoring shell remains visible until foreground media configuration and local timeline bootstrap finish. Cancelled index runs recheck their run ID, account scope, and cancellation after maintenance and cache reads before publishing results. On expiration, the coordinator retains ownership while cancellation drains, with a two-second cleanup limit before completing the native task; late completions cannot affect a newer grant. An unfinished refresh still reports failure when its 20-second budget expires.

#### Physical-device verification

Native scheduler delivery requires a physical device. Enable Background App Refresh for Remmich, sign in, then leave the app normally. Look for the `BackgroundLibrarySync` messages `scheduled`, `started`, and `finished`. Scheduling errors remain diagnostic messages; foreground sync remains available.

For deterministic Debug checks, schedule the requests, put the app in the background, pause in Xcode, and use Apple's [background-task testing commands](https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development), then continue execution. Test each kind separately:

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"io.github.ender-wang.Remmich.library-refresh"]
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"io.github.ender-wang.Remmich.library-sync"]
```

To test expiration, choose the identifier of the active task:

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"io.github.ender-wang.Remmich.library-refresh"]
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"io.github.ender-wang.Remmich.library-sync"]
```

These commands are development-only debugger operations; the app contains no private scheduler calls. Regression scenarios (recorded device outcomes follow the list):

- Both task kinds are scheduled and logged with `kind=refresh` or `kind=processing`.
- A short refresh updates the recent index without starting thumbnail caching or maintenance. If preparation/indexing exceeds 20 seconds, it finishes with `refresh-budget-expired` and preserves accepted data.
- Processing discovers server-side changes, finishes missing history, and fills the enabled thumbnail/metadata cache.
- Paused indexing and disabled/paused auto-cache remain respected after a background launch.
- Expiration stops unfinished work without losing previously accepted index data or complete cache pairs. A later foreground pass resumes missing work.
- Returning during a run does not create a second index writer. Returning within five minutes after success avoids another automatic check; **Sync now** still runs immediately.
- Closing a viewer after a background refresh applies the deferred timeline update.
- Sign-out during preparation or caching prevents the old session from restarting work, and removes its pending background request.
- Low Power Mode, thermal deferral, an unreachable server, and disabled Background App Refresh leave a working foreground fallback.

[LibraryBackgroundSyncTests](RemmichTests/LibraryBackgroundSyncTests.swift), the focused background cases in [LibraryIndexSynchronizationTests](RemmichTests/LibraryIndexSynchronizationTests.swift), and the background-restoration cases in [RemmichTests](RemmichTests/RemmichTests.swift) cover policy, joining, pause persistence, caching completion/cancellation, and invalidation. A local generic-device `build-for-testing` passed for the app and test bundle.

Physical iPhone checks on 2026-11-01 verified both native launch handlers using the debugger commands above. Refresh accepted a new index generation and completed successfully in 3.721 seconds, then scheduled its next request. Processing validated the route, scheduled its next request, and completed successfully using the fresh index and already-complete cache. This verifies native handler execution and successful completion; it does not establish a guaranteed automatic schedule or exercise downloads of missing cache items.

The regression scenarios above are references for diagnosing reported issues. Sign-out invalidation was reviewed in app logic and has compiled regression tests; manual sign-out is not required for this change.

### Source layout

```text
Remmich/
├── App/                    # Entry point, session lifecycle, native tab shell
├── Domain/                 # Models, service protocols, timeline/index/navigation policies
├── Infrastructure/         # Immich adapters, networking, Keychain, storage, media
├── Features/
│   ├── Photos/             # Timeline store, semantic zoom, date cards and range browsing
│   ├── Shared/AssetViewer/ # Photo, Live Photo, and memory viewers; video playback
│   ├── LibraryIndex/       # Index and offline-cache coordination
│   ├── Settings/           # Account, connection, index/cache UI and app-icon selection
│   └── ...                 # Onboarding, Videos, Albums, Library, Search
├── DesignSystem/           # Shared surfaces, loading states, branding and gestures
├── Assets.xcassets/        # Native images and generated branding layers
└── Resources/              # Icon Composer artwork and branding geometry
Packages/ImmichAPI/         # Pinned OpenAPI schema, generated client, package tests
RemmichTests/               # App logic and hosted UIKit regression tests
Scripts/                   # Schema update and artwork generation
.github/workflows/         # Build once, then test those products
```

### Key patterns

| Pattern | What to preserve |
| --- | --- |
| Read-only boundary | Feature services read Immich content. Upload, edit, archive, favorite, and delete operations stay outside the product scope. Future export actions operate on local copies. |
| Swift concurrency | The app uses Swift 6 with `MainActor` as the default isolation. Models, actors, and framework callbacks use explicit isolation where needed; preserve the actual executor and cancellation contract when changing asynchronous work. |
| Stable asset identity | Viewer selection, semantic-zoom focus, and scroll restoration use asset identity. Video playback owns the exact selected video rather than switching through the photo pager. |
| Gesture ownership | Root page swipes, left-edge Back, media paging, zoom, and video scrubbing have separate ownership rules. Preserve gesture cancellation and nested Back history. |
| Local storage ownership | Account-scoped index, thumbnail/Info cache, transient previews, and playback-session resources have distinct lifecycles. Clearing one cache must not erase unrelated local data. |
| Smooth semantic zoom | Metadata drives the transition between photos and date cards; network or image-decode completion does not gate the gesture. Preserve the focused asset and viewport position. The native scroll extent describes all known metadata, while collection cells and thumbnails stay windowed; moving that window must not change the extent or existing frames. |
| Logo rendering | Capture the changing elapsed phase and pose before constructing `Canvas` in each `TimelineView` update. Reading the clock only inside the `Canvas` renderer can leave its display list cached. Rendering pauses when hidden or in the background; Reduce Motion uses static artwork. |
| Product documentation | Keep the README feature and milestone summaries current, and describe implementation details here. Distinguish implemented work from pending device acceptance and unfinished features. |

### Timeline geometry and virtualization

[TimelineSemanticProjection](Remmich/Features/Photos/TimelineSemanticProjection.swift) measures the complete known timeline from metadata, then selects a bounded window of cells with their original full-timeline frames. [The collection controller](Remmich/Features/Photos/TimelineSemanticCollectionView.swift) reports the complete height to UIKit, so moving that window does not change the native scroll indicator's size. A distant indicator jump uses a binary search over the measured geometry to choose a new cell window while preserving the requested scroll offset.

The controller caches up to three scale measurements and invalidates them for catalog, viewport, appearance, or bottom-clearance changes. Scoped [asset grids](Remmich/DesignSystem/AssetGrid.swift) and [date-card stacks](Remmich/Features/Photos/PhotosRangeViews.swift) use explicit heights from their row/mosaic plans. Measurement does not request images or create every cell. Previously unknown history can still extend the catalog; rotation and zoom also legitimately recalculate its geometry. [TimelineScrollExtentTests](RemmichTests/TimelineScrollExtentTests.swift) covers extent stability, bounded windows, native jumps, and hosted SwiftUI grids; [TimelineSemanticZoomTests](RemmichTests/TimelineSemanticZoomTests.swift) covers shared focus, header, and cell-continuity behavior.

## Tests and formatting

Start with the tests affected by the change. Use two build jobs and run one CPU-intensive build/test command at a time.

Compile the app and test bundles for a generic iOS device:

```bash
xcodebuild build-for-testing \
  -project Remmich.xcodeproj \
  -scheme Remmich \
  -destination 'generic/platform=iOS' \
  -jobs 2 \
  -quiet \
  -parallel-testing-enabled NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGNING_ALLOWED=NO
```

This compiles test products; it does not execute the tests. Run relevant app tests in Xcode, and verify media behavior, gestures, rotation, and accessibility on a physical device. The [CI build workflow](.github/workflows/build.yml) produces one set of app/test products; the [test workflow](.github/workflows/test.yml) runs the package and app-logic tests against that build's revision.

Run the API package tests with:

```bash
swift test --package-path Packages/ImmichAPI --jobs 2
```

The Xcode project checks formatting before compilation. For a focused formatting check, pass the changed Swift files explicitly:

```bash
swiftformat --lint --config .swiftformat path/to/ChangedFile.swift
```

## Schema and artwork updates

Refresh the pinned schema from a sibling Immich checkout, or provide a schema path:

```bash
Scripts/update-immich-schema.sh
Scripts/update-immich-schema.sh path/to/immich-openapi-specs.json
```

Review the schema change and update [its provenance record](Packages/ImmichAPI/SCHEMA-PROVENANCE.md) together. Let the pinned OpenAPI Generator plugin generate the client from that input.

Generate native branding layers from the committed Icon Composer SVGs:

```bash
python3 Scripts/generate-brand-artwork.py
```

Artwork generation requires librsvg's `rsvg-convert`. Review the generated layers and geometry alongside the SVG source. Logo credits appear below the logo in the [README header](README.md).

## Proposing a change

Use the [milestone table](README.md#milestones) to understand current scope. Keep changes focused, explain the user-visible behavior, and state the tests and device checks performed. Record remaining verification honestly. Update the README when available features, limitations, or milestone status change; update this guide when architecture or developer workflows change.
