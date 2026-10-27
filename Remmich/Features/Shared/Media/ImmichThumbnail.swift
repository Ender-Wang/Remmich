import Nuke
import NukeUI
import SwiftUI
import UIKit

struct ImmichThumbnail: View {
    let descriptor: MediaRequestDescriptor
    let media: MediaLibraryController
    var contentMode: ContentMode = .fill
    var showsBackground = true
    var backgroundOpacity = 1.0
    var imageCornerRadius: CGFloat = 0
    var imageScale: CGFloat = 1
    var priority: ImageRequest.Priority = .normal
    var placeholderImage: UIImage?
    var didLoad: (ImageResponse) -> Void = { _ in }

    @State private var retryID = 0

    var body: some View {
        LazyImage(
            request: media.imageRequest(for: descriptor, priority: priority),
            transaction: .init(animation: .easeOut(duration: 0.18))
        ) { state in
            ZStack {
                if showsBackground {
                    Rectangle()
                        .fill(.quaternary)
                        .opacity(backgroundOpacity)
                }
                if let image = state.image {
                    rendered(image)
                } else if let placeholderImage {
                    rendered(Image(uiImage: placeholderImage))
                } else if state.error != nil {
                    Button {
                        retryID += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry image")
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
        .transition(.opacity)
    }
}
