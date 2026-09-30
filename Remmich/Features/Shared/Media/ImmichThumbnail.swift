import Nuke
import NukeUI
import SwiftUI

struct ImmichThumbnail: View {
    let descriptor: MediaRequestDescriptor
    let media: MediaLibraryController

    @State private var retryID = 0

    var body: some View {
        LazyImage(
            request: media.imageRequest(for: descriptor),
            transaction: .init(animation: .easeOut(duration: 0.18))
        ) { state in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
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
