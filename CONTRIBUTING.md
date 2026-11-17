# Contributing to Remmich

The [README](README.md) describes available features, limitations and milestone progress. This guide covers building the app, architecture, tests and release workflows.

## Requirements

- Xcode 27 or later; the current source has been compiled with Xcode 27.2.
- The app uses Swift 6 language mode (`SWIFT_VERSION = 6.0`). The local API package requires Swift tools 6.2 or later; the verified Xcode 27.2 toolchain uses Swift 6.4.2.
- SwiftFormat is optional for local builds; the latest release is recommended, with no required version. The [build workflow](.github/workflows/build.yml) downloads the latest release for formatting checks.
- To run the app on a device, iOS/iPadOS 26.6 or later and an account on your Immich server.

Swift packages resolve through Xcode. The local API package's generator and runtime dependencies are pinned in [Package.swift](Packages/ImmichAPI/Package.swift); schema provenance is recorded [alongside the package](Packages/ImmichAPI/SCHEMA-PROVENANCE.md).

## Build and run

```bash
git clone https://github.com/Ender-Wang/Remmich.git
cd Remmich
open Remmich.xcodeproj
```

1. Optionally install SwiftFormat with `brew install swiftformat` and let Xcode resolve the packages. Xcode may ask you to trust the Swift OpenAPI Generator build-tool plugin.
2. Select the **Remmich** scheme and your device, choose your signing team, and use a unique bundle identifier if your team requires one.
3. Build and run. Sign in with your Immich server address and credentials, then configure a Primary address and optional Fallback addresses in **Profile → Connection** if needed.

Connection selection checks Primary first, then Fallback addresses in order, using authenticated user-ID validation. It does not require Wi-Fi-name access or a location permission. Connection displays omit the trailing `/api` while internal endpoints retain it. A separate unauthenticated `/server/ping` probe measures HTTP response time only while Connection is visible and the app is active; probe rounds do not overlap or switch routes. The initial label stays `Checking…` until a result arrives; state changes fade, and response digits roll independently of the steady `ms` suffix. Reduce Motion disables these animations.

Without saved connection settings, the authenticated login URL is the implicit Primary address. Saved profiles retain their ordered Primary/Fallback classification, including login through a known fallback URL. There is no separate Direct route type or validation path, and the implicit default does not overwrite saved settings.

Verified endpoint aliases share a stable account cache identity, independent of the current network URL. After successful login, SQLite resolves a retained identity through an exact endpoint/user-ID match or one unambiguous verified alias. Email alone is never an identity key. Saving a profile authenticates additional candidates before recording aliases; unreachable or different-account endpoints are not associated. Ordinary logout retains aliases and cached data; deleting an account's local data removes its aliases, SQL records, and thumbnail namespace. Old address-profile keys are not adopted. The current schema includes the account-scoped alias table.

Connection profiles, automatic-cache preferences, manual-cache intent, and Index/cache pause choices belong to the same account identity. Signing out while keeping data preserves those choices; another account loads only its own state. Session teardown clears runtime statistics, routing, metadata readers, and viewer state before adopting a new owner. Delayed metadata responses, exports and transfer configuration must still match the requesting owner and generation. Legacy global preferences are not adopted. Catalog/cache database sizes and feature statistics belong to the selected account's physical files.

Manage saved sessions and retained local data under **Profile → Account → Accounts**. The list joins Keychain credentials and SQL inventories by verified account namespace, including the current account and data-only accounts that need sign-in. The current row samples in-memory Index/cache progress once per second while visible; inactive rows use accepted-generation SQL aggregates and saved pause/manual-cache intent. Thumbnail inventory excludes unverified, orphaned, and stale-revision records; cache completion requires both a thumbnail and metadata. Storage labels show thumbnail bytes rather than assigning shared SQLite bytes to an account. Local-data deletion preserves saved credentials, with confirmation and live progress; current-account deletion remains a sign-out choice.

Current, Switch, and Sign in share the account row's trailing action column. Current is plain text in the Connection icon's green; Switch and Sign in use compact glass capsules. Inactive rows expose a trailing **Clear Data** glass button with red text for their index, thumbnails, and metadata. **Sign Out** is available only for the active account. Clearing another account's offline data retains its saved sign-in.

`KeychainSessionStore` keeps independent `saved-session-<namespace>` records alongside the existing `active-session` payload. Restoring an existing active session registers its scoped record. Corrupt records are isolated; protected-store access failures retain credentials. A switch pins the target credential and saves the active owner before clearing outgoing runtime readers and transfer ownership, then restores the incoming account through the normal guarded bootstrap and authenticated route evaluation. Switching never calls Immich logout. Route callbacks are invalidated before credential selection, and credential deletion identifies its intended namespace. Explicit sign-out revokes only the selected session using its own endpoint/token. Add account suspends the outgoing runtime while retaining a return session for Cancel; successful authentication refreshes a saved identity only through verified endpoint/user matches, never email.

The account catalog retains display name/email separately from Keychain credentials. Authentication and restoration refresh this metadata; keeping local data retains it, and deleting that account's data removes it. Catalog and cache schemas are independently versioned at 1; this is a new file layout, not a migration of the former shared schema. See [Local storage and 0.5.0 upgrades](#local-storage-and-050-upgrades). `AccountSignOutButton` attaches a SwiftUI confirmation popover to each actual button before row-wide layout modifiers; Cancel/outside dismissal changes only presentation state.

## Architecture

### Data flow

```mermaid
flowchart TD
    Keychain[Keychain session] --> Routing[Authenticated Primary / Fallback routing]
    Routing --> API[Typed read-only Immich API]
    API --> Index[Per-account catalog and Timeline Index]
    API --> Albums[Album discovery and Album Index]
    Albums --> Index
    Index --> Timeline[Photos, Videos and album timelines]
    API --> Cache[Per-account thumbnail, Info and place cache]
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

### Local storage and 0.5.0 upgrades

[AccountStorageLayout](Remmich/Infrastructure/LibraryIndex/AccountStorageLayout.swift) defines `LibraryIndex/Accounts/<namespace>/catalog.sqlite` and `cache.sqlite`. Catalog schema 1 owns canonical assets, Timeline/Album memberships, prepared groups, sync state, account metadata and Downloads records/Photos receipts. Cache schema 1 owns derivative inventory, cached asset details and Photon results. The cache is attached to the selected catalog connection; existing account-namespaced media files keep their paths. Features share canonical asset records and cached media rather than creating a database or media cache per album.

Timeline Rebuild, Album Rebuild, Clear Cache and account deletion have distinct ownership boundaries. Rebuilding one index must preserve the other index, cached media and Downloads history. Deleting one account removes its new-format directory and media ownership, invalidates late reads/exports, and must not recreate that directory through obsolete work or affect another account. [AccountStorageArchitectureTests](RemmichTests/AccountStorageArchitectureTests.swift) and [AccountLibraryIsolationTests](RemmichTests/AccountLibraryIsolationTests.swift) cover these contracts.

**Upgrading from 0.5.0:** the former shared `LibraryIndex/library-index.sqlite3` and its WAL/SHM files are neither imported nor automatically deleted. Current Rebuild and account-deletion operations target the new files; they do not clean up the obsolete shared database. Server-derived indexes can be rebuilt, but rebuilding cannot recreate historical Downloads records/Photos receipts or Photon results stored only in the old database. Existing media paths alone do not establish complete inventory reuse. No migration or legacy-deletion implementation is included.

### Asset Cache and Place Cache

**Profile → Cache & Storage** has separate Asset Cache and Place Cache sections, each with its own Sync/Pause/Resume, automatic-cache preference and card/page state. Settings and manual intent remain account-owned; existing shared cache preferences supply the initial values for both stages. Places consumes GPS metadata already stored by Assets. Pausing Assets lets Places finish known work; pausing Places lets Assets continue discovering metadata. Places reports waiting for metadata when discovery is incomplete. Rebuild and Clear remain shared maintenance actions for both caches, preserving the timeline index and server library.

Place progress counts assets whose required lookup is complete, including successful updates and valid no-result responses. A lookup shared by several assets completes each asset; an older display fallback does not complete newly required work. The shared cache database/WAL size appears once. Optional attached-cache DBSTAT attribution includes each feature's tables and indexes; these allocations are not additional file totals.

All four per-10K estimates use the same calculation: current sample bytes divided by the matching stored-item count, multiplied by 10,000. They update during sync and show **—** for missing attribution or nonpositive bytes/counts. Asset Cache uses matched thumbnail bytes/counts. Places uses its allocated table/index bytes and represented desired assets, including pending work and retained variants in the footprint. Timeline includes stored staging generations and counts distinct asset IDs; Album Index retains its album-membership unit, including an asset appearing in several albums. These are normalized current footprints and can change as data fills, rather than predicting a finished cache's size. Database attribution refreshes outside rendering every 15 seconds while the relevant page is visible/active, with explicit entry/lifecycle refreshes; ordinary stored-report reads do not measure again. Index refreshes coalesce in flight, preserve a forced follow-up and reject stale account ownership. Failed attempts are throttled too.

### Albums

Albums uses `AlbumReading` on `ImmichTimelineRepository` for authenticated list/detail GETs. `AlbumTimelineReader` scopes timeline requests with `albumId`, includes stacked members and omits root visibility filtering so archived members remain available. `AlbumIndexController` saves lists, complete memberships and prepared date-group catalogs in the account catalog through the existing sync lifecycle and durable GET queue. Canonical assets are shared between Timeline and Albums through membership relationships. Automatic album-list checks retain a 15-minute success window; matching catalog revisions reuse indexed contents regardless of age, while explicit Album Rebuild forces a contents refresh. Missing derived groups can be prepared locally. Timeline and Album Index have independent controls, counts, progress and storage measurements; swipes and the picker use the shared home-page gesture policy.

Album timelines restore prepared catalogs through the existing bootstrap path and reuse `PhotosTimelineStore`, `PhotosView`, previews, viewers and the account media cache. Discovery supports All/Shared, search, six sorts with explicit direction, Cards and List. Covers use canonical indexed revisions. Native cover zoom opens the album timeline, whose per-account/per-album session restores its asset bookmark even when the initial catalog is empty. Re-tapping Albums scrolls the current album timeline to its latest items without popping discovery. Long-press Back returns to the originating timeline with the visited asset as focus, or the pre-grouping viewport when no date/asset was visited; ordinary Back remains one level.

Sorting keeps the viewport fixed while albums move through it. Card/List changes transform around the visible album; pinch selects the album under its starting centroid, follows a reversible logarithmic progress path and can interrupt a settling transition. `AlbumReflowLayout` eagerly computes metadata geometry across the album list, interpolating exact item frames and content height in one stable identity tree. `AlbumCardReflowLayout` blends the fixed Card/List label endpoints so long names do not snap between wrapping layouts. Cover requests keep stable identities and media loading is visibility-gated. Each album's `geometryGroup()` resolves movement before drawing descendants, avoiding large per-item drawing surfaces during distant reorders; this is not a lazy or virtualized layout.

`AlbumPinchGesture` attaches the native recognizer to discovery without an input-blocking overlay. `AlbumPinchInteraction` rejects album activation through the remainder of the pinch touch sequence, while root page-swipe ownership separately blocks late/offscreen album activation. Header clearance, hit testing and independent scrolling remain shared timeline contracts.

Album discovery's initial placement and navbar retap target the padded content extent, preserving clearance below wrapped titles. Underfilled scopes use bottom alignment only; no persistent content-resize anchor changes the existing sorting or pinch policies. Entering a different scope requests its content bottom. These positioning rules are independent of the animation implementation.

All/Shared and main tabs reuse `NativePageSlideAnimation` in [NativeAppTabShell](Remmich/App/NativeAppTabShell.swift). The shared factory owns translation direction, duration, curve and preservation of input transforms; callers own transition completion and cleanup. Albums' stage host, captures and content-installation phases adapt discovery to that same animation path. Discovery keeps one bounded viewport capture per scope, invalidated by content/layout/account-view lifetime changes or memory pressure. Both stages are populated before motion. On a valid return capture, live collection construction waits until motion finishes; the final image covers installation until the new native extent, insets and bottom offset agree, with a generation-guarded timeout for cleanup. This defers eager layout work rather than eliminating it. The native stage host is declared below the entire live header; search and scope controls stay stationary above both pages.

Profile Index uses [IndexSectionPan](Remmich/Features/Settings/IndexSectionPan.swift) to reject vertical intent before recognition, allowing its outer ScrollView to scroll from indexing/status content. The existing section-direction and leading-edge rules still govern horizontal paging. Both sections place Sync/Pause/Resume and **Rebuild index** below their statistics; an absent album error reserves no blank row. Main-tab tap animation uses `NativeTabPageAnimationPolicy` independently of horizontal-drag ownership, so an expanded Library profile does not suppress animated tab taps. Viewer and Reduce Motion exclusions remain.

### Media loading, sharing and downloads

The timeline index and paired thumbnail/Info cache are local, account-scoped stores. Video playback uses [AuthenticatedVideoStreamSource](Remmich/Infrastructure/Media/AuthenticatedVideoStreamSource.swift) with one viewer-owned [VideoPlaybackSession](Remmich/Features/Shared/AssetViewer/VideoPlaybackSession.swift). Download uses [MediaExportController](Remmich/Infrastructure/Media/MediaExportController.swift) to save a selected tier into Photos → Remmich, reusing encoded caches and [LibraryTransferQueue](Remmich/Infrastructure/LibraryIndex/LibraryTransferQueue.swift). Exports use that queue implementation with a separate background session/journal so cache controls do not cancel user saves. Large responses remain file-backed; matching account/credential tasks reattach after relaunch, completed files replay, and progress/cancel/retry use the same Downloads jobs. With Photos access granted, pending resources are durably submitted and download serially even while earlier files await foreground Photos import. Force-quitting can cancel native transfers. Account-scoped jobs and separate import receipts live in the existing SQLite store. Library → Downloads History exposes progress, cancellation, retry and history. Removing history preserves saved Photos assets and import receipts. The quality sheet and History measure content at the allocated sheet width before choosing a detent, avoiding narrow-width transition measurements. Persistent private offline originals remain planned.

Timeline thumbnails can read both managed offline files and Nuke's account-scoped memory/disk cache before a connection route is validated. When no active route exists and no managed file matches, the saved account URL constructs a thumbnail request with `returnCacheDataDontLoad`; it cannot start a network fetch. Route activation removes that option, which NukeUI observes even when the URL and image identity stay unchanged, so cache misses retry automatically. A cache-only miss keeps the loading placeholder. Preview/original requests retain their existing route requirements. [MediaOfflineThumbnailTests](RemmichTests/MediaOfflineThumbnailTests.swift) covers cold disk-cache loading, zero-network misses followed by same-URL activation, and account isolation.

Saved Photos resources are reused only for the matching account, asset revision and requested tier, with normal loading as fallback when the local resource is unavailable. [MediaVideoMetadata](Remmich/Infrastructure/Media/MediaVideoMetadata.swift) restores missing Playback movie and camera-track tags by editing the header of an export-owned copy on a serial utility queue; compressed media data is not re-encoded. [MediaExportFiles](Remmich/Infrastructure/Media/MediaExportFiles.swift) retains the image metadata path and byte-preserving Originals, including Live Photo resources. Actual focal length is not assumed to be 35 mm equivalent. PhotoKit determines which Original formats can be imported and which embedded fields Photos displays.

Downloads History coordinates one revealed Remove action across its rows; tapping elsewhere or swiping back closes it with a short smooth animation. Row gestures retain their horizontal direction checks and full-swipe removal. [DownloadHistoryNavigationBoundary](Remmich/Features/Library/DownloadHistoryNavigationBoundary.swift) disables UIKit's content-area pop recognizer only while History is visible, restoring its prior enabled state on exit. The existing left-edge Back gesture and navigation buttons remain available; ordinary rightward row swipes do not navigate back.

Sharing uses [MediaShareSelection](Remmich/Infrastructure/Media/MediaShareSelection.swift) to capture account, revision, tier, bitmap/orientation and available Info metadata at tap time. Viewer and preview use [MediaShareButton](Remmich/Features/Shared/Media/MediaShareButton.swift) and the existing export controller, caches, transfer queue and metadata writers. Original bytes remain unchanged; cached stills preserve the selected tier's encoded source dimensions and compression while restoring supported metadata. Screen-size downsampling does not define a new share tier; an uncached bitmap is a fallback. Visible video shares complete Playback with audio; poster-only video shares its displayed still. Live Photos share the displayed still at the captured tier. Native motion sharing remains limited by the investigated Apple public APIs: the system picker requires user selection for its export provider, while direct automatic export is not supported by this implementation. Save to Photos still imports the unchanged Original pair as a Live Photo. Immutable, background-safe activity sources retain temporary files until released. The native file header shows the actual attachment thumbnail/name/size with normal tier naming and no location disclaimer. Location metadata remains preserved. No custom LinkPresentation header is used. Share never imports into Photos or creates download receipts/history. Cancellation/retry and account-generation guards are included.

### Landing and sign-in

[OnboardingView](Remmich/Features/Onboarding/OnboardingView.swift) uses the profile's animated branding, green connection and blue account accents, and a native glass form. An adaptive layout keeps branding above the form in portrait and beside it in landscape, with scrolling for the keyboard and larger text. [RootView](Remmich/App/RootView.swift) keeps a single onboarding view across server checking, credentials, sign-in progress, and failure so field values and logo motion survive those transitions. Checking uses that mounted branding rather than a second full-screen loader. Server validation, HTTP confirmation, credential storage, and successful library preparation remain owned by `AppSessionController`; OAuth remains unsupported.

An empty server-address field selects `https://demo.immich.app`. After validation, only that HTTPS origin's credential screen is prefilled with the public demo account; sign-in still requires a user action. The demo's login notice is omitted. Custom-server notices retain the limited native HTML text renderer for line breaks, emphasis, warning text, entities, lists, and HTTP(S) links. Script and embedded active content are omitted; JavaScript links become inactive labels. The renderer loads no web resources and does not extract credentials or submit sign-in.

Before Keychain restoration establishes an authenticated account, startup shows the system background and loading logo. Native tab placeholders are reserved for an authenticated library being prepared. Signed-out foreground entry does not wait for native transfer-session restoration.

After foreground restoration establishes the account and local media/timeline scope, local library bootstrap and authenticated route validation run concurrently. The existing owned foreground-preparation task publishes local readiness independently of network latency. Route-outcome application, activation, and automatic sync wait for that task; generation, cancellation, and account checks run again after the wait. Account invalidation cancels the local job, and restoration awaits and clears its captured task before returning. Background restoration retains its existing ordering. Session fixtures cover local readiness during suspended validation and rejection of a late validation result after sign-out.

### Timeline preview

Individual Photos/Videos timeline assets, including scoped date grids, expose an exclusive long-press preview gesture and an accessible Preview action. The preview is a centered overlay owned by `PhotosView`; the timeline and shell remain mounted with a clear backdrop. The viewer's controls and visible Back button stay hidden. Outside taps, the Back gesture, and accessibility escape dismiss preview before normal navigation. Image and action-panel geometry reserve their combined space before aspect-fitting with 22-point insets. Opening/return reuse the asset viewer's landing-transform and crop helpers, captured cell geometry, and `AssetViewerTransitionMotion` springs (0.30-second opening with 0.18 bounce; 0.24-second return without bounce). Handoffs wait for animation removal; Reduce Motion uses opacity only. The captured thumbnail remains through expansion before larger-image and motion loading begin. A full-content transparent hit plane handles outside taps separately from the clipped preview's playback taps.

`TimelineAssetPreviewSession` reuses `VideoPlaybackSession` and the authenticated, paced stream for ordinary videos and paired Live Photo motion. Its player is muted and receives a no-op audio-session implementation; it does not mount AVKit or PiP. Playback starts after opening completes, plays once, and explicitly pauses at item end without looping. Single tap pauses/resumes, including retaining a pause choice during opening; tapping after playback ends manually replays from the start. Dismissal blocks late preparation and pauses immediately, then closes and removes the overlay after the return animation so the last frame can remain visible. Account changes, tab changes, scene deactivation, and timeline disappearance tear down preview playback.

A compact glass action panel uses the same Download quality sheet and coordinator as the asset viewer; Share uses the same captured-resource preparation as the full viewer. Rows stack in portrait and at accessibility text sizes, and form a horizontal strip in landscape. The panel follows the preview transition and consumes its own taps. Focused fixtures cover grouped-panel fit, source-crop geometry, selected motion identity/mute/end action, early toggle intent, and late preparation after dismissal.

### Asset capture times

[TimelineAssetSummary](Remmich/Domain/Timeline/TimelineModels.swift) keeps the original capture instant separate from `captureLocalDate`, which applies Immich's per-asset `localOffsetHours`. Displays, accessibility labels, date groups, and date-only titles use the capture-local calendar. Ordering follows capture-local day, then the original instant within that day, preserving chronology when daylight saving repeats an hour. The offset is rounded to whole seconds when applied to avoid float representation noise at midnight boundaries.

Viewer details already contain Immich's `localDateTime`; they receive no second offset. Video-search fallback carries `fileCreatedAt` plus the offset derived from `localDateTime`, matching the timeline contract. Upload, update, sync, and thumbnail-revision timestamps retain their original meanings. GPS is optional: Remmich uses the server's capture metadata and does not guess a missing timezone from the phone's current location or offset.

New index writes persist capture-local day/week/month/year keys, including the ISO week year. Reopening the current schema preserves capture instants, accepted generations, pause state, cached details, derivative manifests, and thumbnail files. Historical database upgrades are intentionally unsupported during testing.

[TimelineCaptureDateFormattingTests](RemmichTests/TimelineCaptureDateFormattingTests.swift) and [CaptureTimePersistenceTests](RemmichTests/CaptureTimePersistenceTests.swift) cover offsets, DST, viewer consistency, new index writes, video fallback, and current-schema persistence.

### Scoped timeline entry and transitions

[PhotosRangeAssetsView](Remmich/Features/Photos/PhotosRangeViews.swift) opens date groups at the bottom, where the latest assets appear. It uses the native bottom anchor rather than scrolling to the card's rotating cover image. Removing the retained initial center-scroll request also prevents the underlying grid from shifting when the first viewer opens.

[ScopedAssetTransitionRuntime](Remmich/Features/Shared/AssetViewer/ScopedAssetTransitionRuntime.swift) keeps weak UIKit probes for visible thumbnail geometry and revision-checked source images. Opening captures the tapped rectangle and reuses the displayed thumbnail before presentation; returning resolves the selected asset's current rectangle and aspect ratio. Unavailable cells retain the existing fallback. [ScopedDayTransitionTests](RemmichTests/ScopedDayTransitionTests.swift) checks newest-asset entry and stable opening/return positions across Day, Week, Month, and Year layouts. [ScopedAssetTransitionTests](RemmichTests/ScopedAssetTransitionTests.swift) covers geometry, clipping, cell reuse, weak image ownership, and immediate image handoff.

### Memory selection and card rotation

[MemoryDaySearch](Remmich/Domain/Timeline/MemoryDaySearch.swift) requests today first, then up to three following calendar days only while no usable memories are found. Each date keeps the server's first twenty records. Photos and Videos select independently: video eligibility is evaluated before stopping the search. Cancellation and account/route generation checks apply at each request boundary. [MemoryDaySearchTests](RemmichTests/MemoryDaySearchTests.swift) covers the date bound, stopping order, empty results, media eligibility, calendar changes, errors, and cancellation.

The selected `availableOn` date passes through memory grouping and viewer context. Upcoming cards show Tomorrow or In N days, and relative-year titles use that display day across New Year. The row stays hidden when the entire bounded search is empty. Card rotation keeps the outgoing cover opaque beneath the incoming crossfade, waits for the next thumbnail through the existing Nuke pipeline, and retains only current/incoming image references. Zoom continues after promotion, and taps select the visually dominant cover.

### Timeline overlays during viewer transitions

Viewer swipes keep their first clear axis after a 16-point minimum component movement and a 1.2 direction-dominance ratio. A vertical Info/dismissal gesture disables horizontal asset paging; Info explicitly retains its own scrolling. A swipe starting below Info's top stays a scroll for its entire duration, with dismissal available on a new downward swipe from the top. Memory boundary navigation shares the axis policy; edge-back and map interactions retain their existing guards.

[TimelineAssetOverlay](Remmich/DesignSystem/TimelineAssetOverlay.swift) shares the Live Photo/360/stack badges and video-duration label between thumbnail cells and the viewer's opening surface. The opening overlay follows the image frame and fades with the expansion progress while retaining its text size. On return, both Live Photo badges and video durations participate in source visibility; a local value-bound fade survives the UIKit hosting boundary. Memory-panel opening retains its existing path.

Semantic pinch transitions carry the complete asset overlay, including plain-video durations. Overlay frames follow the interpolated image rectangle without applying a nonuniform transform to text or symbols; hosted layout updates only when bounds change. Transition date headers reuse the steady collection header's native labels, font metrics, material, and pinned opacity. Their settled endpoints match the installed collection's pixel-rounded header frames. At handoff, only the media child surface fades; transition headers remain above it while native header content stays hidden. Cleanup removes the transition and reveals native headers together, avoiding both duplicate antialiased text and image occlusion of pinned headers. Blur views and their ancestors retain alpha 1: a mask directly on each effect view supplies its subtle coverage, while visibility uses hidden header content and foreground fading affects only the labels. This follows [UIKit's visual-effect alpha and masking rules](https://developer.apple.com/documentation/uikit/uivisualeffectview). Canceled pinches settle back before that handoff. Group-card chrome retains its existing transform path. The focused controller fixtures cover header metric/endpoint parity, header ownership during the media fade, mask coverage/resize, cancellation, and persistent unscaled video/Live Photo overlays.

[TimelineAssetOverlayTests](RemmichTests/TimelineAssetOverlayTests.swift) checks opening opacity and hidden/revealed return states for Live Photos and videos, with an ordinary-photo control.

Grouped cards share an already-decoded native cover with an empty matching pinch-transition tile. The delivery checks the current node, asset, thumbnail revision, and installed target; it never replaces a tile that already has an image. Native and local decode completions use the same image crossfade and handoff image map, without new requests or waiting for image readiness before completing a pinch. The focused semantic-zoom fixture covers valid, stale, duplicate, and post-cleanup completions.

Unloaded date cards show a small static copy of the selected app logo over the timeline background. [RemmichCoverPlaceholder](Remmich/DesignSystem/RemmichCoverPlaceholder.swift) caches the existing brand artwork and shares logo sizing and opacity between hosted cards and native pinch tiles. The logo centers in the area above the padded title/count block, using the title's two-line cap, wrapping, featured/compact styles, and Dynamic Type metrics. The shared UIKit placeholder inherits the same font traits in both surfaces; pinch progress interpolates between source and destination caption layouts. Photo zoom applies only to image content. The native tile keeps its logo separate from decoded asset pixels, relayouts it without stretching during pinch, and retires it atomically when the real card becomes visible so two translucent logos cannot overlap during the media fade. Incoming covers crossfade over 0.18 seconds; existing readiness, revision, and cancellation guards remain in place. Focused fixtures cover logo geometry, caption exclusion, and decoded-image separation.

### Photo and Info animation ownership

[ZoomableStillImageView](Remmich/Features/Shared/AssetViewer/ZoomableStillImageView.swift) applies fit changes using the representable's SwiftUI transaction animation through `UIView.animate(Animation, changes:)`. Photo fit and Info panel geometry share that transaction, including metadata-driven panel-height changes. The bridge keeps both on SwiftUI's presentation-value animation path. Initial placement, direct dragging, Reduce Motion and disabled/nil animation transactions stay immediate; requested fits remain deferred while zooming.

### Filmstrip layout

`AssetViewerFilmstrip`, in [AssetViewerView](Remmich/Features/Shared/AssetViewer/AssetViewerView.swift), centers the complete thumbnail row when it fits the viewport. The row has at least the viewport's width, and fitting content skips selected-item scroll requests. Overflowing content scrolls to the selected stable ID; viewport width is part of the positioning request so resizing also updates the selection's position. [FilmstripAlignmentTests](RemmichTests/FilmstripAlignmentTests.swift) covers fitting rows, selection changes, overflowing content, and resizing using the hosted scroll view.

### Video opening and backgrounds

[AssetViewerView](Remmich/Features/Shared/AssetViewer/AssetViewerView.swift) keeps the selected video's media rectangle black in its shared page backdrop, outside the poster's opening crop and transform. The black stage and themed surround fade as one compositing group; Info and app chrome retain the app theme. AVKit stays deferred until the source expansion ends, so its own UIView background cannot supply the earlier transition frames. [VideoOpeningBackgroundTests](RemmichTests/VideoOpeningBackgroundTests.swift) checks the portrait player/surround split, landscape Info boundary, photo background, and opening-fade composition.

### Native Picture in Picture

[ViewerVideoSurface](Remmich/Features/Shared/AssetViewer/ViewerVideoSurface.swift) enables AVKit's automatic inline Picture in Picture, backed by the app's audio background mode. The same viewer, player, and stream stay mounted for restoration. AVKit owns the Home-screen handoff for playing video; the scene's inactive transition must not pause it. Unfinished preparation and seeks still suspend on background entry when PiP is not engaged, and audio interruptions retain their suspension behavior.

The session retains its playback audio configuration throughout PiP, including a pause from native controls, so those controls can resume playback in the background. Stopping PiP while the app is backgrounded pauses playback and releases audio; terminal viewer dismissal always closes the session. [VideoPictureInPictureTests](RemmichTests/VideoPictureInPictureTests.swift) exercises native configuration, delegate restoration, audio ownership, and cleanup. Test system gestures and PiP controls on a physical device; see [Apple's standard-player guidance](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player).

The host tracks its own scene's background entry and requests inline return when that scene becomes active again. It waits for PiP startup and the same open player to be attached to a parent/window, then disables `allowsPictureInPicturePlayback` until the stop/failure callback restores eligibility. This follows [Apple's AVKit guidance](https://developer.apple.com/videos/play/wwdc2019/503/) without replacing the player/item, seeking, or requesting play. Inactive-only interruptions do not trigger return, and activation without PiP clears the pending request. Attachment is rechecked on host updates and PiP-start completion. A single diagnostic marks the accepted foreground-return request. Focused fixtures cover startup/attachment races, paused playback intent, player/item identity, a second PiP cycle, a background visit without PiP, and closed-session rejection.

Only the ordinary-video `AVPlayerViewController` enables `updatesNowPlayingInfoCenter`, letting AVKit own system playback state and remote controls. Live Photo motion and muted previews use raw player layers and never mount this host. Do not add app-global Now Playing publication or cleanup to shared `VideoPlaybackSession`, which also serves previews.

Full-viewer video opts into `AVPlayerItem.externalMetadata` with `Remmich · <caption or filename>` (first nonempty description line, then original filename, then `Video`). The current Immich model has no distinct title field. Existing source pixels, the memory-cached viewer Preview, and the poster's completion supply artwork without another image request. JPEG artwork preserves aspect ratio and is bounded to 512 pixels. Metadata is installed before item attachment and refreshed in place; it does not replace the item, change playback intent, or publish timing manually. The opt-in fields do not participate in SwiftUI observation, remain unset for previews, survive a retry, and clear on session close. See [Apple's AVKit metadata guidance](https://developer.apple.com/videos/play/wwdc2022/110338/).

### Index generation reconciliation

[LibraryIndexSynchronizer](Remmich/Domain/LibraryIndex/LibraryIndexSynchronizer.swift) treats a successful complete bucket-summary response as authoritative for bucket presence. Previously indexed months absent from that response become empty replacements, including during recent-only and historical passes. The same replacement keys drive copied-generation row removal and in-memory merging, so counts and rebuilt grouped catalogs agree. All selected fetches must succeed before staging, and cancellation is checked again before acceptance. A failed/cancelled fetch leaves the prior accepted generation visible. Removal stays account-scoped and does not delete cached files, downloads, or server data.

Retired bucket keys and their removed asset count are logged once per accepted generation. A complete-generation count mismatch emits a separate diagnostic. [LibraryIndexSynchronizationTests](RemmichTests/LibraryIndexSynchronizationTests.swift) covers vanished recent/old months, all ordinary sync modes, an empty library, failure/cancellation, grouped catalogs, and another account remaining unchanged.

### Background library sync

[LibraryBackgroundSyncCoordinator](Remmich/App/LibraryBackgroundSyncCoordinator.swift) registers two native tasks through the app delegate before launch completes:

| Task | Identifier | Earliest requested start | Work |
| --- | --- | --- | --- |
| `BGAppRefreshTask` | `io.github.ender-wang.Remmich.library-refresh` | 5 minutes later | Refresh the newest two month buckets, with a 20-second budget including preparation. No historical catch-up, database compaction, cache reconciliation, or thumbnail/metadata warming. |
| `BGProcessingTask` | `io.github.ender-wang.Remmich.library-sync` | 15 minutes later | Index/history catch-up, maintenance, and enabled thumbnail/metadata caching. Requires network connectivity; external power is not required. |

`Info.plist` declares both identifiers and the `fetch` and `processing` background modes alongside the existing audio mode. These are minimum delays, not repeating timers; iOS decides when, or whether, to run either task. Existing pending requests retain their dates across foreground events. Each launch requests the next opportunity, including when another worker already owns execution; overlapping grants cede their time instead of creating a second index writer.

The scene and background handlers share one `AppSessionController` and `LibraryIndexController`. A cold background launch restores credentials, connection candidates, and persisted index/pause state without creating media prefetchers or projecting the photo/video UI. The short refresh also skips restoring cache inventory. Index and cache work reuse their existing account-scoped storage and cancellation paths. Processing awaits both indexing and caching, honors pauses and auto-cache settings, and observes Low Power Mode and thermal changes. Native expiration and the short-refresh deadline invalidate preparation and cancel unfinished work; completed generations and cache pairs remain reusable. A successful partial refresh leaves missing history and older changed buckets for processing and does not mark the complete index as fresh. Returning to the background under a refresh grant restores its cache restriction, even after foreground activity. Sign-out cancels both pending requests and invalidates in-flight restoration before clearing the account.

Foreground automatic checks have a five-minute success-only freshness window, persisted per account. A failed attempt never counts as fresh, and **Sync now** bypasses the window. Accepted timeline publication deferred by an open viewer survives suspension and can be applied when the viewer closes. Background entry stops the foreground Swift tasks while retaining their OS-owned transfers.

[LibraryTransferQueue](Remmich/Infrastructure/LibraryIndex/LibraryTransferQueue.swift) owns one logical queue for index responses, asset metadata, thumbnails and custom-Photon place responses. It selects a standard native URLSession in foreground and one native background URLSession for suspended execution. Lifecycle handoff requeues unfinished attempts while preserving completed responses and job-keyed waiting consumers. Both sessions use the same serial delegate queue. [LibraryTransferJournal](Remmich/Infrastructure/LibraryIndex/LibraryTransferJournal.swift) persists account/credential/route identities, request kinds, stable pass IDs, retry state, attempt UUIDs, transport, and completed-file references without writing bearer tokens into the journal. Attempt-scoped body filenames and callback guards reject late completions even when sessions reuse numeric task IDs. Legacy completed responses keep their original file identity; lost in-process attempts are requeued after relaunch. The dedicated sync repository uses [ImmichQueuedGETTransport](Packages/ImmichAPI/Sources/ImmichAPI/ImmichQueuedGETTransport.swift), preserving generated request authentication and response decoding. Photon requests never receive Immich credentials. Interactive browsing, authentication, and video playback keep their existing transports.

Cache look-ahead covers up to 128 unfinished candidates, alongside the two import tasks, with at most 256 tracked current native attempts. Ready journal records are separate from that attempt cap. The native sessions allow up to six HTTP/1.1 connections per host, with two cache-import workers. While the app is suspended it cannot replenish the queue; later execution windows import responses and enqueue more work. Completed files are moved into owned storage before delegates return. Normal cache responses are released after the thumbnail/metadata pair is stored; these records have separate SQL transactions, and interruption between them leaves a recoverable partial pair that is excluded from complete cached counts. Rebuild responses remain replayable until atomic promotion. New index runs discard completed responses at least five minutes old (and legacy responses without a completion date), preserving recent replay and pending transfers. A staging generation is created only after its selected responses arrive. Pause, sign-out, deletion, credential/route changes, and asset-revision changes invalidate the appropriate jobs. Transient failures have three quick attempts followed by a 60-second cooldown before another automatic retry burst. Retries become eligible on the next pump, request, or execution opportunity rather than a separate polling timer. Native task batches are journaled once before any task resumes.

Custom-Photon caching runs alongside asset caching through the same transfer lifecycle, with a bounded 32-key look-ahead and no fixed one-second request delay. Progress publication is coalesced rather than requests. English country discovery finishes its selected Local follow-up before advancing to another coordinate, so final-language asset completion does not wait behind the discovery backlog. Both stages retain durable ownership, retry/backoff and settings/session guards. Default/public Photon remains viewer-demand-only, including during Rebuild; no automatic bulk pass is submitted.

Both already-backgrounded receipts and OS background-session wakeups notify the existing sync coordinator. Transfer reconciliation uses a separate entry point from scheduled discovery: warm imports reuse the validated account/route, while cold restoration, path changes, authentication rejection, and connection failures retain route recovery. Receipt and committed-import revisions permit further windows when data arrives or imports advance; unchanged no-progress notifications do not restart the worker. Unfinished response files remain available to later deliveries, scheduled grants, or foreground continuation.

Normal cache imports select ready thumbnail/metadata pairs from the bounded unfinished look-ahead, preserving two import workers while bypassing earlier undelivered requests. Refills track unfinished asset IDs, so out-of-order delivery cannot skip a slow pair. Incremental index progress retains accepted bucket counts until replacement responses arrive; explicit rebuild progress starts at zero. The transfer-only software deadline is removed on foreground entry and re-armed on returning to background; native expiration keeps its authority.

Home-to-background migration holds a short native background assertion until unfinished foreground attempts have been handed off. The assertion is acquired before scheduling the asynchronous migration and released on completion or a stale-phase exit. Its expiration does not cancel another sync owner.

Receipt-driven reconciliation holds a native background-time assertion, ended on completion or expiration. Reconciliation has a 20-second window and shares the existing worker owner; it does not hold a system completion callback until a full library finishes. Real session completions attached to an existing transfer window are completed exactly once. Same-generation cache continuation skips filesystem preparation while refreshing committed SQLite manifest rows; fresh operations, changed generations, deletion, and account changes retain reconciliation. Low Power Mode and thermal restrictions gate cache scheduling/resumption. iOS still owns execution timing; a durable queue does not guarantee an uninterrupted full-library run. The journal stores a token digest, not the token itself; authenticated native tasks carry their authorization header in the OS-managed session. Receipt/metric logs identify both transport and attempt, independently of app state. Retired background attempts may still emit metrics after foreground return. Interrupted partial responses can be downloaded again during handoff; completed bodies and committed cache pairs are retained.

Index and asset-cache statistics treat interrupted background windows as continuations. They retain the operation's start time; cache inventory remains visible while the next snapshot loads, and its ETA work sample accumulates across those windows. Elapsed time is wall time across native-transfer waits and suspension within the same in-memory operation. An explicit new operation starts a new clock; deletion and account changes clear the relevant inventory. Live storage reporting uses account-scoped SQL aggregates, throttled to once every five seconds during asset-cache progress. Returning to the profile refreshes committed statistics and rebases its visible clock, without a background UI timer or counting unimported transfer bodies as cached assets.

[PlaceCacheRun](Remmich/Domain/LibraryIndex/PlaceCacheRun.swift) separately persists observed place-work intervals per account, merging overlapping consumer/native activity. Its elapsed time includes scheduling and response-delivery wait, not just network time; restoration does not count unobserved terminated-process time. Recent completed-asset samples supply ETA; pause and changed work reset the sample. Last synced is recorded only after a successful, stable drain with metadata discovery complete. A partial run or restored count alone cannot certify completion.

Profile Home's Index and Cache & Storage cards share percentage/status rows in the existing secondary text style. A view-owned task samples published in-memory progress and the Connection summary immediately on entry and once per second while Home is visible and active; it cancels on navigation, dismissal, or backgrounding. This presentation task does not query SQLite, recount storage, or request sync work. Percentages round down to one decimal place and use native rolling digits; all three cards share the same vertical-roll-and-fade status transition. Reduce Motion disables both transitions. Accepted index counts remain visible during update checks. Index/cache subpage clocks also stop while inactive. Immich Server/version is shown in Account → Server above Connection; the Profile footer shows only Remmich version/build/revision, and both orientation layouts measure its actual height.

Manual Pause freezes elapsed time on both Index and Cache & Storage. Resume continues the accumulated value, excluding time spent manually paused. It remains distinct from starting a new Sync/Rebuild operation.

Index and Cache share [SettingsSectionPager](Remmich/Features/Settings/SettingsSectionPager.swift) for section taps, swipes, measured heights and Reduce Motion. Clip each page before applying its slide offset; the outer viewport clip alone allows neighboring glass edges to appear. Sync/Pause/Resume buttons and cache toggles have 16-point horizontal insets so the active page's controls fit inside that clip. Hidden pages reject input and are excluded from accessibility; switch/slider interaction is excluded from the section pan recognizer.

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

These commands are development-only debugger operations; the app contains no private scheduler calls. Use these scenarios to check lifecycle behavior:

- Both task kinds are scheduled and logged with `kind=refresh` or `kind=processing`.
- A short refresh updates the recent index without starting thumbnail caching or maintenance. If preparation/indexing exceeds 20 seconds, it finishes with `refresh-budget-expired` and preserves accepted data.
- Processing discovers server-side changes, finishes missing history, and fills the enabled thumbnail/metadata cache.
- Paused indexing and disabled/paused auto-cache remain respected after a background launch.
- Expiration stops unfinished work without losing previously accepted index data or complete cache pairs. A later foreground pass resumes missing work.
- Returning during a run does not create a second index writer. Returning within five minutes after success avoids another automatic check; **Sync now** still runs immediately.
- Closing a viewer after a background refresh applies the deferred timeline update.
- Sign-out during preparation or caching prevents the old session from restarting work, and removes its pending background request.
- Low Power Mode, thermal deferral, an unreachable server, and disabled Background App Refresh leave a working foreground fallback.

[LibraryBackgroundSyncTests](RemmichTests/LibraryBackgroundSyncTests.swift), the focused background cases in [LibraryIndexSynchronizationTests](RemmichTests/LibraryIndexSynchronizationTests.swift), and the background-restoration cases in [RemmichTests](RemmichTests/RemmichTests.swift) cover policy, joining, pause persistence, caching completion/cancellation, and invalidation.

### Source layout

```text
Remmich/
├── App/                    # Entry point, session lifecycle, native tab shell
├── Domain/                 # Models, service protocols, timeline/index/navigation policies
├── Infrastructure/         # Immich adapters, networking, Keychain, storage, media
├── Features/
│   ├── Photos/             # Timeline store, semantic zoom, date cards and range browsing
│   ├── Albums/             # Discovery, album sessions, anchored reflow and interactive pinch
│   ├── Shared/AssetViewer/ # Photo, Live Photo, and memory viewers; video playback
│   ├── LibraryIndex/       # Index and offline-cache coordination
│   ├── Settings/           # Account, connection, index/cache UI and app-icon selection
│   └── ...                 # Onboarding, Videos, Library, Search
├── DesignSystem/           # Shared surfaces, loading states, branding and gestures
├── Assets.xcassets/        # Native images and generated branding layers
└── Resources/              # Icon Composer artwork and branding geometry
Packages/ImmichAPI/         # Pinned OpenAPI schema, generated client, package tests
RemmichTests/               # App logic and hosted UIKit regression tests
Scripts/                   # Schema/artwork generation and SideStore source updates
.github/workflows/         # Build → Tests → eligible Release and SideStore publication
```

### Key patterns

| Pattern | What to preserve |
| --- | --- |
| Read-only boundary | Feature services read Immich content. Upload, edit, archive, favorite, and delete operations stay outside the product scope. Sharing and Save to Photos operate on local copies. |
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

[TimelineWindowSafeAreaReader](Remmich/Features/Photos/TimelineWindowSafeAreaReader.swift) measures the timeline's attached window after UIKit lifecycle callbacks and passes a cached top inset into SwiftUI. Reading `UIWindow.safeAreaInsets` directly inside a SwiftUI layout closure can ask the hosting controller for status-bar preferences and re-enter the same view graph. Preserve the deferred, window-local measurement and cancellation on detach; [TimelineWindowSafeAreaTests](RemmichTests/TimelineWindowSafeAreaTests.swift) covers deferred reads, inset/window changes, and cancellation.

## Tests and formatting

The Albums/storage changes add [AlbumsTests](RemmichTests/AlbumsTests.swift), [AlbumCatalogPersistenceTests](RemmichTests/AlbumCatalogPersistenceTests.swift), [AlbumReflowLayoutTests](RemmichTests/AlbumReflowLayoutTests.swift), [AlbumPinchTests](RemmichTests/AlbumPinchTests.swift), [AccountStorageArchitectureTests](RemmichTests/AccountStorageArchitectureTests.swift) and API-package [AlbumReadTests](Packages/ImmichAPI/Tests/ImmichAPITests/AlbumReadTests.swift). [IndexSectionPanTests](RemmichTests/IndexSectionPanTests.swift) covers native direction rejection, [NativePageSlideAnimationTests](RemmichTests/NativePageSlideAnimationTests.swift) covers both directions and preserved transforms, and [RootPageSwipePolicyTests](RemmichTests/RootPageSwipePolicyTests.swift) distinguishes tap eligibility from profile drag ownership. Semantic timeline and Back-policy suites also cover shared navigation.

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

This compiles test products; it does not execute the tests. Run relevant app tests in Xcode, and verify media behavior, gestures, rotation, and accessibility on a physical device. The [Build workflow](.github/workflows/build.yml) produces one set of app/test products; [Tests](.github/workflows/test.yml) runs the package and app-logic tests against that build's revision. The separate [Release workflow](.github/workflows/release.yml) handles eligible archives and publication after Tests succeeds.

Run the API package tests with:

```bash
swift test --package-path Packages/ImmichAPI --jobs 2
```

The Xcode project checks formatting before compilation. For a focused formatting check, pass the changed Swift files explicitly:

```bash
swiftformat --lint --config .swiftformat path/to/ChangedFile.swift
```

### Release IPAs

The Actions sidebar separates **Build → Tests → Release**. After successful tests, Tests records the original Build run ID and tested SHA in a small release-context artifact. Release verifies both successful runs through GitHub's API and archives that exact revision. Only same-repository `push` or manual Build runs on `main`/`develop` qualify.

- A tested commit changing `Remmich.xcodeproj/project.pbxproj` checks for a release automatically. To check an unchanged project version, run the **Build** workflow manually on the intended branch.
- To retry only packaging/publication, choose **Actions → Release → Run workflow**, select the branch matching the successful Tests run, and enter its `tests_run_id` (the number in its Actions URL). This bypasses the project-file change check, but still requires successful Build/Tests and an unused tag. The 30-day release-context artifact must exist; runs from before this split or expired artifacts require a fresh Build/Tests run.
- `main` creates `v<version>`; an existing stable tag is left unchanged. `develop` creates the next unused `v<version>-beta.N` prerelease. Version and build are read from the project, and app/test targets must agree.
- Release notes use the body of the exact tested commit, excluding its subject, for both automatic and manual Build runs; no GitHub-generated changelog or fixed introductory text is added.
- Archive uses `Release`, a generic iOS device destination, Swift `-O` and whole-module compilation. Code signing is disabled; no signing certificate or provisioning-profile secrets are required.
- Package only the archived `Remmich.app` under `Payload/`, preserving its frameworks/resources. Publish `Remmich-v<version>-unsigned.ipa`, a separate dSYMs ZIP, and SHA-256 files. Verify the archived version/build, iOS platform and arm64 executable before upload.
- The publishing job verifies checksums, creates the GitHub release/tag at the tested SHA, and attaches the generated assets. An eligible successful run publishes automatically. Publishing and the subsequent SideStore source update have `contents: write`; build, tests and archive remain read-only.

### SideStore source

The repository's [source.json](source.json) uses the [AltStore source format](https://faq.altstore.io/developers/make-a-source), compatible with SideStore. Its permanent subscription URL is `https://raw.githubusercontent.com/Ender-Wang/Remmich/main/source.json`.

After publishing a stable release, Release downloads and checksum-verifies its IPA, then runs `Scripts/update-sidestore-source.py`. Version/build, minimum OS, privacy descriptions and byte size come from the actual IPA/release asset. Older versions remain available, ordered newest first; beta releases are excluded. Source branding and descriptions remain editable in the repository.

The source job updates only `source.json` on the default branch through GitHub's Contents API, creating a GitHub Actions bot commit. It uses the existing blob SHA to reject concurrent edits and does not alter the release commit or notes. If this step fails (for example, branch protection denies the bot), the published release remains available; resolve the failure and rerun the failed source job. No new IPA build is required. Token-authored source updates do not trigger another Build run.

These unsigned IPAs need re-signing with a compatible sideloading tool before installation; they are not App Store/TestFlight or directly installable distribution builds. Test the optimized build on a physical device before treating it as release-verified. The **Run workflow** button is on the selected workflow's Actions page, not inside an individual run, and appears after the workflow is present on the default branch.

## Schema and artwork updates

Refresh the pinned schema from a sibling Immich checkout, or provide a schema path:

```bash
Scripts/update-immich-schema.sh
Scripts/update-immich-schema.sh path/to/immich-openapi-specs.json
```

Review the schema change and update [its provenance record](Packages/ImmichAPI/SCHEMA-PROVENANCE.md) together. Let the pinned OpenAPI Generator plugin generate the client from that input.

The updater prepares the snapshot with `Scripts/prepare-immich-schema.py`, removing unused deprecated flat search fields and legacy response pagination. The generator configuration includes only operations used by the wrapper and their dependencies. When adding an operation, update that list too. Keep modern filters/cursor pagination intact and never edit DerivedData-generated Swift files.

Map settings use authenticated `/config`. Pre-login validation still uses deprecated `/server/config` and `/server/features`: the replacement public configuration does not provide all the existing startup checks. Their warnings remain visible until a supported migration can preserve those checks; see the provenance record for details.

Generate native branding layers from the committed Icon Composer SVGs:

```bash
python3 Scripts/generate-brand-artwork.py
```

Artwork generation requires librsvg's `rsvg-convert`. Review the generated layers and geometry alongside the SVG source. Logo credits appear below the logo in the [README header](README.md).

## Proposing a change

Use the [milestone table](README.md#milestones) to understand current scope. Keep changes focused, explain the user-visible behavior, and state the tests and device checks performed. Record remaining verification honestly. Update the README when available features, limitations, or milestone status change; update this guide when architecture or developer workflows change.
