import Nuke
import NukeUI
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var thumbnailRevealsActive = true
}

struct ImmichThumbnail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let descriptor: MediaRequestDescriptor
    let media: MediaLibraryController
    var contentMode: ContentMode = .fill
    var showsBackground = true
    var backgroundOpacity = 1.0
    var imageCornerRadius: CGFloat = 0
    var imageScale: CGFloat = 1
    var priority: ImageRequest.Priority = .normal
    var preparedImage: UIImage?
    var placeholderImage: UIImage?
    var logoPlaceholderCaption: RemmichCoverPlaceholder.Caption?
    var revealsImageOnLoad = false
    var didLoad: (ImageResponse) -> Void = { _ in }

    @State private var retryID = 0

    var body: some View {
        let request = preparedImage == nil ? media.imageRequest(for: descriptor, priority: priority) : nil
        let isCacheOnly = request?.options.contains(.returnCacheDataDontLoad) == true
        let animatesTransition = !revealsImageOnLoad && !reduceMotion
        LazyImage(
            request: request,
            transaction: .init(animation: animatesTransition ? ThumbnailImageReveal.animation : nil)
        ) { state in
            ZStack {
                if showsBackground {
                    Rectangle()
                        .fill(.quaternary)
                        .opacity(backgroundOpacity)
                }
                if let image = preparedImage.map({ Image(uiImage: $0) }) ?? state.image ?? placeholderImage.map({ Image(uiImage: $0) }) {
                    rendered(image)
                        .modifier(ThumbnailImageReveal(enabled: revealsImageOnLoad && placeholderImage == nil))
                        .transition(animatesTransition ? .opacity : .identity)
                } else if state.error != nil, !isCacheOnly {
                    Button {
                        retryID += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry image")
                } else if let logoPlaceholderCaption {
                    RemmichCoverLoadingView(caption: logoPlaceholderCaption)
                        .transition(.opacity)
                } else if isCacheOnly {
                    ProgressView()
                } else if state.isLoading {
                    ProgressView(value: Double(state.progress.fraction))
                        .progressViewStyle(.circular)
                }
            }
            .clipped()
        }
        .pipeline(media.pipeline ?? .shared)
        .priority(priority)
        .onCompletion { result in
            if case let .success(response) = result {
                didLoad(response)
            }
        }
        .onDisappear(.cancel)
        .id("\(descriptor.assetID)-\(descriptor.updatedAt.timeIntervalSinceReferenceDate)-\(retryID)")
    }

    private func rendered(_ image: Image) -> some View {
        GeometryReader { geometry in
            image
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: imageCornerRadius,
                        style: .continuous
                    )
                )
                .scaleEffect(imageScale)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .center
                )
                .clipped()
        }
    }
}

/// Reveal the pixels on their first mount, including synchronous memory hits.
/// Keep placeholder geometry and interaction outside the opacity animation.
struct ThumbnailImageReveal: ViewModifier {
    static let animation = Animation.easeOut(duration: 0.28)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.thumbnailRevealsActive) private var revealsActive
    var enabled = true
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(enabled && !reduceMotion && !revealed ? 0 : 1)
            .onChange(of: revealsActive, initial: true) { _, active in
                guard active, !revealed else { return }
                withAnimation(enabled && !reduceMotion ? Self.animation : nil) {
                    revealed = true
                }
            }
    }
}
