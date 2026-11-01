import Combine
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Filmstrip viewport alignment", .serialized)
@MainActor
struct FilmstripAlignmentTests {
    @Test(arguments: [1, 3, 6], [402.0, 874.0])
    func fittingRowDoesNotAccumulateOffsetsAcrossSelection(count: Int, width: Double) async throws {
        let fixture = try await mount(count: count, width: width, selectedIndex: count - 1)
        defer { fixture.window.isHidden = true }
        try expectCentered(fixture)
        fixture.state.selectedID = "filmstrip-0"
        try await Task.sleep(for: .milliseconds(350))
        try expectCentered(fixture)
    }

    @Test func overflowingRowStillCentersTheSelectedAsset() async throws {
        let fixture = try await mount(count: 80, width: 402, selectedIndex: 70)
        defer { fixture.window.isHidden = true }
        let scroll = try #require(findScrollView(fixture.host.view))
        #expect(scroll.contentSize.width > scroll.bounds.width)
        #expect(abs(16 + 70 * 44 + 20 - scroll.contentOffset.x - scroll.bounds.width / 2) < 8)
        fixture.state.selectedID = "filmstrip-10"
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(16 + 10 * 44 + 20 - scroll.contentOffset.x - scroll.bounds.width / 2) < 8)
    }

    @Test func resizingBetweenOverflowingAndFittingKeepsTheCompleteRowCentered() async throws {
        let fixture = try await mount(count: 12, width: 402, selectedIndex: 11)
        defer { fixture.window.isHidden = true }
        fixture.window.frame.size.width = 874
        fixture.host.rootView = FilmstripFixture(count: 12, width: 874, state: fixture.state)
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        try expectCentered(fixture)
        fixture.state.selectedID = "filmstrip-0"
        try await Task.sleep(for: .milliseconds(350))
        try expectCentered(fixture)
        fixture.window.frame.size.width = 402
        fixture.host.rootView = FilmstripFixture(count: 12, width: 402, state: fixture.state)
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        let scroll = try #require(findScrollView(fixture.host.view))
        #expect(scroll.contentSize.width > scroll.bounds.width)
        #expect(abs(scroll.contentOffset.x) < 1)
    }

    private func expectCentered(_ fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let scroll = try #require(findScrollView(fixture.host.view))
        #expect(abs(scroll.contentSize.width - scroll.bounds.width) < 1, sourceLocation: sourceLocation)
        #expect(abs(scroll.contentOffset.x) < 1, sourceLocation: sourceLocation)
        #expect(abs(scroll.adjustedContentInset.left) < 1, sourceLocation: sourceLocation)
        #expect(abs(scroll.adjustedContentInset.right) < 1, sourceLocation: sourceLocation)
    }

    private func mount(count: Int, width: Double, selectedIndex: Int) async throws -> Fixture {
        for _ in 0 ..< 100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        let state = FilmstripSelection(selectedID: "filmstrip-\(selectedIndex)")
        let host = UIHostingController(rootView: FilmstripFixture(count: count, width: width, state: state))
        host.safeAreaRegions = []
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        return Fixture(window: window, host: host, state: state)
    }

    private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView {
            return scroll
        }
        return view.subviews.lazy.compactMap(findScrollView).first
    }

    private struct Fixture {
        let window: UIWindow
        let host: UIHostingController<FilmstripFixture>
        let state: FilmstripSelection
    }
}

@MainActor
private final class FilmstripSelection: ObservableObject {
    @Published var selectedID: String

    init(selectedID: String) {
        self.selectedID = selectedID
    }
}

private struct FilmstripFixture: View {
    let count: Int
    let width: Double
    @ObservedObject var state: FilmstripSelection
    private let media = MediaLibraryController()

    var body: some View {
        AssetViewerFilmstrip(assets: assets, selectedAssetID: state.selectedID, media: media,
                             select: { state.selectedID = $0 })
            .frame(width: width, height: 52)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var assets: [TimelineAssetSummary] {
        (0 ..< count).map { index in
            TimelineAssetSummary(id: "filmstrip-\(index)", ownerID: "owner", capturedAt: .distantPast,
                                 uploadedAt: .distantPast, localOffsetHours: 0, mediaKind: .image,
                                 durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline,
                                 livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil,
                                 thumbnailRevision: .distantPast)
        }
    }
}
