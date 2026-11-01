import Combine
import Nuke
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Viewer photo loading", .serialized)
@MainActor
struct ViewerPhotoLoadingTests {
    @Test(arguments: [true, false])
    func ordinaryViewingRequestsPreviewOnly(selected: Bool) async throws {
        let fixture = try await makeFixture(selected: selected)
        defer { fixture.close() }
        try await waitUntil { fixture.state.metadata.last?.source == .preview }
        #expect(fixture.loader.urls.map(\.query) == ["size=preview"])
        #expect(fixture.loader.urls.allSatisfy { $0.lastPathComponent == "thumbnail" })
    }

    @Test func originalRequiresExplicitRequestAndSurvivesTaskRestart() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await waitUntil { fixture.state.metadata.last?.source == .preview }
        fixture.state.requestID = 1
        try await waitUntil { fixture.state.metadata.last?.source == .original }
        #expect(fixture.loader.urls.map(\.lastPathComponent) == ["thumbnail", "original"])
        #expect(fixture.state.metadata.last?.pixelSize == .init(width: 64, height: 48))

        let previousCount = fixture.state.metadata.count
        fixture.state.selected = false
        try await waitUntil { fixture.state.metadata.count > previousCount }
        #expect(fixture.state.metadata.last?.source == .original)
        #expect(fixture.loader.urls.count == 2)
    }

    @Test func unavailablePreviewKeepsTheThumbnailWithoutFetchingOriginal() async throws {
        let fixture = try await makeFixture(failsPreview: true)
        defer { fixture.close() }
        try await waitUntil { fixture.loader.completedCount == 1 }
        #expect(fixture.loader.urls.map(\.query) == ["size=preview"])
        #expect(fixture.state.metadata.last?.source == .thumbnail)
        func containsThumbnail(_ view: UIView) -> Bool {
            (view as? UIImageView)?.image === fixture.thumbnail || view.subviews.contains(where: containsThumbnail)
        }
        #expect(try containsThumbnail(#require(fixture.window.rootViewController?.view)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Viewer did not reach the expected loading state")
    }

    private func makeFixture(selected: Bool = true, failsPreview: Bool = false) async throws -> PhotoFixture {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func image(width: CGFloat, height: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
                UIColor.red.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let thumbnail = image(width: 8, height: 6)
        let loader = try PhotoDataLoader(preview: #require(image(width: 24, height: 18).pngData()),
                                         original: #require(image(width: 64, height: 48).pngData()),
                                         failsPreview: failsPreview)
        let media = MediaLibraryController(imageDataLoader: loader)
        let session = AccountSession(apiURL: URL(string: "https://viewer.invalid/api")!, accessToken: "test",
                                     userID: UUID().uuidString, userEmail: "test@example.com", name: "Test",
                                     isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        media.configure(session: session, activeEndpoint: session.apiURL)
        let asset = TimelineAssetSummary(id: UUID().uuidString, ownerID: session.userID,
                                         capturedAt: .distantPast, uploadedAt: .distantPast, localOffsetHours: 0,
                                         mediaKind: .image, durationMilliseconds: nil, aspectRatio: 4.0 / 3,
                                         isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                                         projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
        let state = PhotoLoadingState(selected: selected)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = UIHostingController(rootView: PhotoLoadingView(
            asset: asset, media: media, thumbnail: thumbnail, state: state
        ))
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return PhotoFixture(window: window, media: media, loader: loader, state: state, thumbnail: thumbnail)
    }
}

@MainActor
private struct PhotoFixture {
    let window: UIWindow
    let media: MediaLibraryController
    let loader: PhotoDataLoader
    let state: PhotoLoadingState
    let thumbnail: UIImage

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        media.clearAll()
    }
}

@MainActor
private final class PhotoLoadingState: ObservableObject {
    @Published var selected: Bool
    @Published var requestID: Int?
    var metadata: [AssetViewerRenderedImageMetadata] = []

    init(selected: Bool) {
        self.selected = selected
    }
}

private struct PhotoLoadingView: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let thumbnail: UIImage
    @ObservedObject var state: PhotoLoadingState

    var body: some View {
        ZoomableStillImageView(
            asset: asset, media: media, isSelected: state.selected, sourceImage: thumbnail,
            targetPixels: .init(width: 20, height: 20), fitRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            animatesFitChanges: false, showsBackground: false, reportsRenderedImageMetadata: true,
            fullResolutionRequestID: state.requestID, renderedImageMetadataChanged: { state.metadata.append($0) },
            fullResolutionLoadFailed: { _ in }, zoomChanged: { _ in }, livePhotoPressChanged: { _ in }, toggleChrome: {}
        )
    }
}

private final class PhotoDataLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URL] = []
    private var completed = 0
    private let preview: Data
    private let original: Data
    private let failsPreview: Bool

    init(preview: Data, original: Data, failsPreview: Bool) {
        self.preview = preview
        self.original = original
        self.failsPreview = failsPreview
    }

    var urls: [URL] {
        lock.withLock { requests }
    }

    var completedCount: Int {
        lock.withLock { completed }
    }

    func loadData(with request: URLRequest,
                  didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Nuke.Cancellable
    {
        let url = request.url!
        lock.withLock { requests.append(url) }
        let work = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if failsPreview, url.query == "size=preview" {
                completion(URLError(.notConnectedToInternet))
            } else {
                let data = url.lastPathComponent == "original" ? original : preview
                didReceiveData(data, URLResponse(url: url, mimeType: "image/png",
                                                 expectedContentLength: data.count, textEncodingName: nil))
                completion(nil)
            }
            lock.withLock { completed += 1 }
        }
        return PhotoLoadCancellation(task: work)
    }
}

private final class PhotoLoadCancellation: Nuke.Cancellable, @unchecked Sendable {
    let task: Task<Void, Never>
    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
