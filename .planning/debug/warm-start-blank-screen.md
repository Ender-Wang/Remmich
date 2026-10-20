---
status: verifying
trigger: "Warm launch still shows an approximately three-second blank/loading screen despite a complete on-device index and warmed thumbnails."
created: 2026-10-20
updated: 2026-10-21
---

# Warm-start blank screen

## Symptoms

- Expected: a completed local index and warmed thumbnail cache should produce an effectively immediate, deterministic timeline first paint without a blank intermediate state.
- Actual: after `5d8022b`, warm startup improved from roughly 6–7 seconds to roughly 3 seconds, but the blank/loading interval remains visible.
- Errors: none correlated with the blank interval; timeline preload reports memory/disk hits and zero network loads.
- Timeline: observed after the persistent index/cache work; staged projection halved the delay but did not eliminate it.
- Reproduction: terminate Remmich, launch it with a complete accepted index and warmed thumbnails, and observe time until the first Photos thumbnails appear.

## Current Focus

- hypothesis: The structural first-Videos stall remains fixed. A single perceived pause while attached to Xcode is currently an unconfirmed debugger/runtime outlier; the supplied log does not contain an app-side control, layout, decode, disk, or network stall.
- test: Compare repeated unattached/device launches with the supplied debugger-attached run. Do not change behavior unless the pause reproduces or a trace attributes a missed frame.
- expecting: Normal first Videos selection publishes immediately, reaches the next run loop and geometry within one to four frames, and uses decoded-memory thumbnails without remote work.
- next_action: Observe rather than patch. If it recurs, capture Time Profiler/Hangs over the tap and scope the first-visible-thumbnail diagnostic by destination so inactive Photos requests cannot claim the Videos trace.
- reasoning_checkpoint: The 2026-10-21 debugger-attached outlier logged visual selection at 0 ms, the next run loop at 26 ms, Videos geometry at 64 ms, and 24/24 preload memory hits in 0 ms. The global content trace was then claimed by the same asset ID previously traced for Photos and emitted no Videos completion, so it cannot explain the perceived frame.

## Evidence

- timestamp: 2026-10-20
  observation: Accepted snapshot load took 333 ms; initial Photos/Videos projection took 60 ms; scanning 26,842 derivative records/files took 705 ms; bootstrap completed at 1,056 ms.
  implication: Full cache-directory reconciliation is the largest measured pre-shell stage and is currently awaited before `state = .signedIn`.
- timestamp: 2026-10-20
  observation: First timeline thumbnail rendered 769 ms after timeline presentation; preload later reported 21 memory hits, 3 disk hits, and zero network loads.
  implication: A second local UI/cache-presentation interval remains after shell publication; server latency is not required to reproduce it.
- timestamp: 2026-10-20
  observation: `AppSessionController.start()` awaits `bootstrapLocalLibrary`, and `LibraryIndexController.bootstrap()` awaits both initial projection and `availableThumbnails`, before publishing the signed-in shell.
  implication: Cache/index availability alone cannot make startup immediate while full thumbnail verification remains on the critical path.
- timestamp: 2026-10-20
  observation: Unified generation-141 trace reached profile restore at 168 ms, account session at 187 ms, media pipeline configuration at 988 ms, local bootstrap at 2,056 ms, shell appearance at 2,078 ms, timeline presentation at 2,104 ms, and first thumbnail at 2,842 ms.
  implication: The user-observed interval is fully accounted for. Media configuration (801 ms), manifest reconciliation (731 ms), and post-presentation first image (738 ms) are the three dominant local stages; route validation begins afterward and is not causal.
- timestamp: 2026-10-20
  observation: Generation-143 sub-stage trace measured `ImagePipeline` initialization at 815 ms, `ImageCache` at 0 ms, `DataCache` at 1 ms, prefetchers/download/profile setup at 1 ms total, manifest scan at 697 ms, deterministic layout at 43 ms, and first image at 825 ms after timeline presentation.
  implication: Nuke's default pipeline/configuration initialization—not disk-cache construction—is the media gate. Layout is eliminated as the explanation for the final image interval.
- timestamp: 2026-10-20
  observation: Generation-144 projected the indexed thumbnail manifest in 32 ms and built the initial projection in 57 ms, but concurrent pipeline construction took 1,364 ms, SQLite preparation took 583 ms, shell appeared at 1,946 ms, and first image arrived at 2,972 ms.
  implication: Removing directory enumeration is valid, but merely moving default pipeline construction off-main leaves expensive duplicate cache initialization and resource contention. The default network loader must be removed from the warm-start path rather than hidden on another executor.
- timestamp: 2026-10-20
  observation: In the same generation-144 run, first Videos selection published visually in 2 ms, activated content by 40 ms, built geometry by 67 ms, and subsequently preloaded 24 thumbnails with 24 memory hits, yet the user still perceived a long first Videos reveal.
  implication: The tab selection and deterministic layout are not the unmeasured interval. Add a per-content first-visible-thumbnail marker; the startup-only first-thumbnail marker cannot diagnose subsequent Videos presentation.
- timestamp: 2026-10-20
  observation: Generation-145 explicit-loader run measured 4,094 ms in `DataLoader`, 1 ms in `ImagePipeline`, SQLite preparation at 623 ms, shell at 4,841 ms, and first Photos asset 3,085 ms later at 7,944 ms total.
  implication: An ephemeral loader does not remove the process-level Foundation networking initialization cost and is a severe regression in this run.
- timestamp: 2026-10-20
  observation: First Videos selection in generation 145 published immediately, geometry completed in 72 ms, first visible asset arrived after 1,189 ms, and the next run-loop marker arrived after 1,223 ms; preload reported 24 memory hits and zero network loads.
  implication: The visible Videos delay is in local media publication/executor contention, not native tab selection, deterministic layout, or remote fetching.
- timestamp: 2026-10-20
  observation: Generation 148 isolated the optimistic manifest candidate with the synchronous default pipeline. Manifest projection took 29 ms and initial projection 57 ms, but pipeline construction took 3,089 ms; shell appeared at 4,173 ms; first Photos published 8,045 ms after activation; grouped catalogs took 9,602 ms; and first Videos publication plus its next-run-loop marker both waited about 9.1 seconds.
  implication: The candidate is rejected and must not be committed. The manifest micro-optimization does not establish an end-to-end win, synchronous pipeline construction remains a variable shell gate, and the missing image-publication interval must be traced below the current activation/publication markers.
- timestamp: 2026-10-20
  observation: Generation 149 measured 10,866 ms constructing the default Nuke pipeline. Photos request creation and local-source resolution completed at 56 ms; its data closure never ran; Nuke published the matching cached image at 3,770 ms. Persisted group rows existed, yet a redundant full grouped-catalog build consumed 8,807 ms. Videos selected after background work settled reached its next run loop in 66 ms and geometry in 93 ms.
  implication: Manifest/file I/O is eliminated as the missing interval. The correct candidate is a lazy network loader plus direct use of persisted grouped catalogs, not prewarming, sleeps, or additional image queues.
- timestamp: 2026-10-20
  observation: Generation 150 on physical iPhone configured the media pipeline in 3 ms, loaded the accepted snapshot in 306 ms, projected its indexed thumbnail manifest in 30 ms, built the initial projection in 113 ms, published the signed-in shell at 694 ms, and began timeline presentation at 724 ms. Both initial and refreshed snapshots reused persisted grouped catalogs. The first generic Photos thumbnail rendered at 1,956 ms total, and the traced active Photos asset published 1,348 ms after activation. Videos selection published immediately, reached its next run loop in 39 ms, built geometry in 71 ms, and preloaded 24 memory hits with zero disk or network loads.
  implication: The two structural startup regressions are fixed on device. Remaining latency is isolated to local cached-image processing/publication after the timeline is already visible; it is no longer caused by networking setup, index projection, grouped-catalog reconstruction, file lookup, or remote Immich access.
- timestamp: 2026-10-20
  observation: Warmed thumbnails existed in Remmich's managed persistent cache, but Nuke's separate `DataCache` satisfied the traced request before the managed-file closure ran. Nuke's disk read also updates access-date metadata, and the same thumbnail bytes can exist in both disk layers.
  implication: Use the managed thumbnail file as the sole disk source for warmed timeline requests while preserving Nuke's decoded memory cache. This removes redundant disk lookup/write work without changing decoder concurrency, request ordering, remote fallback, or viewer behavior.
- timestamp: 2026-10-20
  observation: Generation 151 with the disk-layer fine-tune reached shell in 647 ms and presentation in 677 ms. Existing markers improved only 49–57 ms versus generation 150, and no managed-file read markers fired. Videos selection still reached the next run loop in 39 ms and geometry in 71 ms.
  implication: The small timing change is noise, not evidence that bypassing the secondary disk cache improved first paint. The old completion marker is attached to a SwiftUI `.task`, can identify an overscan/coalesced request, and is not an exact image-pipeline completion marker. Replace it with Nuke's direct completion callback before further optimization.
- timestamp: 2026-10-20
  observation: Generation 152 using Nuke's direct completion callback reported the first Photos thumbnail as `cache=source` at 1,345 ms after presentation and the traced Photos asset at 1,445 ms. First Videos selection published at 0 ms, reached the next run loop in 37 ms, built geometry in 68 ms, and preloaded 24 decoded-memory hits in 1 ms, yet retained a slight perceived first-click pause.
  implication: Video decoding and network/disk loading are not the cause of the remaining first-click feel. The next bounded candidate reduces the initial SwiftUI virtualization burst: overscan changes from 1.5 viewport heights to 0.75, retaining scroll headroom without pacing rows with artificial delays.
- timestamp: 2026-10-20
  observation: Generation 153 with 0.75-screen overscan reached the first Videos next run loop in 24 ms and full geometry in 44 ms, improving from 37/68 ms. First Photos completion improved from 1,345/1,445 ms to 1,146/1,191 ms in this run. Videos preload completed in 12 ms with 21 memory hits and three originating-source loads; those source loads were managed files, not remote requests.
  implication: Reducing the initial virtualization burst improves the measured control/layout path without decode pacing. Correct the preload diagnostic so `cacheType == nil` with a data-backed request is reported as `managedFileLoads`, not `networkLoads`; final acceptance still requires the user's visual judgment and a short fast-scroll check.
- timestamp: 2026-10-20
  observation: Generation 154 retained a slight perceived Videos pause despite control/layout reaching 26/53 ms. Videos preload completed in 35 ms with 12 memory hits, 12 managed-file loads, and zero network loads. All mounted timeline cells still submitted direct image requests at `.veryHigh`, including virtualized overscan.
  implication: Do not insert sleeps between rows or lower decoder concurrency. Prioritize actual viewport cells over overscan so visible rows win the existing serial decode/publication queue naturally; keep inactive tabs at very-low priority.
- timestamp: 2026-10-21
  observation: Generation 155 with per-cell viewport visibility state regressed the first Videos next-run-loop marker to 588 ms even though selection published at 0 ms, request/source resolution took 3 ms, geometry took 77 ms, and the preload was 24 decoded-memory hits in 0 ms.
  implication: Visibility-state mutation itself created main-actor churn. The experiment was fully reverted; viewport and overscan cells again use the previous active/inactive priority behavior.
- timestamp: 2026-10-21
  observation: The user identified initial cell drawing/publication—not byte fetch or decode—as the remaining burst and explicitly requested a small delay between initial cells.
  implication: Test a bounded, one-time draw-publication queue rather than another cache/decode workaround: 12 ms per first-Videos cell, 180 ms maximum delay, disabled after 220 ms and never applied to scrolling or later activations.
- timestamp: 2026-10-21
  observation: Generation 157 showed the first pacing implementation still taking 599 ms to reach the next main run loop, essentially unchanged from generation 155's 588 ms. It delayed only image content inside cells that had already mounted their Button, overlays, GeometryReader, and LazyImage.
  implication: The first pacing boundary was incorrect and has been replaced. Preserve deterministic transparent cell slots, but defer mounting each complete initial cell subtree; this is the actual cell-level draw pacing requested by the user.
- timestamp: 2026-10-21
  observation: Generation 158 with whole-cell mounting improved first Videos next-run-loop latency from 599 ms to 449 ms while geometry completed in 36 ms. The tap still overlapped a startup refresh of the 2,583-asset October Photos bucket, which completed at 763 ms.
  implication: Cell mounting was one contributor but is not the remaining dominant blocker. Added bounded timings around repository DTO mapping and main-actor bucket deduplication, cross-bucket reconciliation, and grouped-catalog publication before changing pacing again.
- timestamp: 2026-10-21
  observation: Generation 159 measured repository mapping at 0 ms and main-actor publication of the 2,583-photo bucket at 77 ms: 34 ms cross-bucket reconciliation plus 42 ms grouped-catalog updates. When that work finished before the Videos tap, switching completed in 28 ms.
  implication: Photos was incorrectly configured with the legacy direct-reader refresh policy while Videos already used accepted-index publication. This produced redundant direct bucket refresh/publication around index synchronization.
- timestamp: 2026-10-21
  observation: Generation 160 after aligning Photos with accepted-index publication emitted two deferred-refresh markers, performed no direct Photos store bucket publication, and switched to Videos in 50 ms while index synchronization continued. The first Photos thumbnail still took 1,736 ms after presentation.
  implication: Remove the unproven cell-pacing workaround and retain the structural refresh-policy correction. First Videos contention and warm-start first-image latency are separate defects; the latter now requires stack profiling.
- timestamp: 2026-10-21
  observation: A single pause perceived while the app was attached to Xcode logged Videos selection at 0 ms, next-run-loop delivery at 26 ms, geometry at 64 ms, and a 24-item residency preload entirely from decoded memory in 0 ms. Repeated attempts did not reproduce it. The per-content thumbnail trace selected the same asset ID previously selected for Photos and never logged a Videos completion.
  implication: There is no measured app-side Videos stall in this run and no behavioral change is justified. Treat it as an unconfirmed debugger/runtime outlier. The destination-agnostic thumbnail trace is insufficient for future attribution and should be scoped before relying on it.

## Eliminated

- hypothesis: Initial remote timeline fetch causes the blank screen.
  evidence: The accepted local snapshot is published before route reevaluation, and the initial thumbnail preload has zero network loads.
- hypothesis: Complete Day/Week catalog construction is still blocking the shell.
  evidence: `5d8022b` stages those catalogs after initial timeline publication.

## Resolution

- root_cause: Warm startup constructs Nuke's default network loader/shared URL cache despite Remmich already owning a per-account data cache, and reconciles the full thumbnail directory before publishing the shell. The subsequent first-image interval is separate and is not caused by deterministic layout construction.
- fix: Corrected candidate uses a lazy network data loader, indexed thumbnail-manifest projection with on-demand file validation, and direct materialization of persisted grouped catalogs with a legacy fallback.
- verification: Generation 150 physical-device run confirms the structural gates are removed and the experience is better. Final visual acceptance of the remaining roughly 1.2–1.35 second first-Photos publication interval is pending.
- files_changed: `AppSessionController.swift`, `MediaLibraryController.swift`, `LibraryThumbnailCache.swift`, `LibraryIndexController.swift`, and focused tests.

