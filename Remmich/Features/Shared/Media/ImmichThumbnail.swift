import Nuke
import NukeUI
import SwiftUI

struct ImmichThumbnail: View {
    let descriptor: MediaRequestDescriptor
    let media: MediaLibraryController
    var contentMode: ContentMode = .fill
    var didLoad: (ImageContainer) -> Void = { _ in }

    @State private var retryID = 0

    var body: some View {
        LazyImage(
            request: media.imageRequest(for: descriptor),
            transaction: .init(animation: .easeOut(duration: 0.18))
        ) { state in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = state.image, let container = state.imageContainer {
                    GeometryReader { geometry in
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                            .clipped()
                    }
                    .transition(.opacity)
                    .task(id: ObjectIdentifier(container.image)) {
                        didLoad(container)
                    }
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
        .onDisappear(.cancel)
        .id("\(descriptor.assetID)-\(descriptor.updatedAt.timeIntervalSinceReferenceDate)-\(retryID)")
    }
}
