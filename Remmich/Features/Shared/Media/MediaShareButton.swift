import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Preparation snapshots the input once; paging or sharper loads cannot change
/// an in-flight share. The native activity owns only a ready file-backed item.
struct MediaShareButton<Content: View>: View {
    let media: MediaLibraryController
    let selection: MediaShareSelection?
    @ViewBuilder let label: (Bool) -> Content
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var preparing = false
    @State private var percent: Int?
    @State private var attempt: MediaShareSelection?
    @State private var activity: MediaShareActivitySource?
    @State private var errorMessage: String?

    var body: some View {
        Button {
            if preparing {
                cancel()
            } else if let selection {
                start(selection)
            }
        } label: { label(preparing) }
            .buttonStyle(.plain)
            .disabled(selection == nil && !preparing)
            .accessibilityLabel(preparing ? "Cancel share preparation" : "Share")
            .accessibilityValue(percent.map { "\($0) percent" } ?? "")
            .sheet(item: $activity, onDismiss: {
                if errorMessage == nil {
                    attempt = nil
                }
            }) { source in
                MediaShareActivity(source: source) { message in
                    activity = nil
                    if let message {
                        errorMessage = message
                    }
                }
            }
            .alert("Unable to share", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                if let attempt, attempt.namespace == media.scope?.cacheNamespace {
                    Button("Retry") { start(attempt) }
                }
                Button("Cancel", role: .cancel) { attempt = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: media.scope?.cacheNamespace) { _, _ in
                cancel()
                attempt = nil
                activity = nil
                errorMessage = nil
            }
            .onDisappear {
                if preparing {
                    cancel()
                }
            }
    }

    private func start(_ snapshot: MediaShareSelection) {
        task?.cancel()
        let owner = UUID()
        operation = owner
        attempt = snapshot
        errorMessage = nil
        preparing = true
        percent = nil
        task = Task { @MainActor in
            do {
                let payload = try await media.exports.prepareShare(snapshot) { received, total in
                    guard operation == owner, preparing else { return }
                    let next = total > 0 ? Int(min(100, max(0, Double(received) / Double(total) * 100))) : nil
                    if percent != next {
                        percent = next
                    }
                }
                try Task.checkCancellation()
                guard operation == owner, media.scope?.cacheNamespace == snapshot.namespace else { return }
                let source = MediaShareActivitySource(file: payload, url: payload.url)
                preparing = false
                task = nil
                activity = source
            } catch is CancellationError {
                if operation == owner {
                    preparing = false
                    task = nil
                }
            } catch {
                guard operation == owner else { return }
                preparing = false
                task = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        operation = UUID()
        task?.cancel()
        task = nil
        preparing = false
        percent = nil
    }
}

private struct MediaShareActivity: UIViewControllerRepresentable {
    let source: MediaShareActivitySource
    let completed: (String?) -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let logger = Logger(subsystem: "Remmich", category: "Sharing")
        let shareID = source.file.id.uuidString
        let controller = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        controller.modalPresentationStyle = .pageSheet
        controller.completionWithItemsHandler = { activity, succeeded, _, error in
            logger.info("Share activity finished id=\(shareID, privacy: .public) type=\(activity?.rawValue ?? "none", privacy: .public) completed=\(succeeded) errorDomain=\((error as NSError?)?.domain ?? "none", privacy: .public) errorCode=\((error as NSError?)?.code ?? 0)")
            let message = error?.localizedDescription
            Task { @MainActor in completed(message) }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

/// ShareSheet's NSItemProvider invokes these callbacks on background queues.
/// Only immutable URLs and the file lease belong here; UI/state stay on MainActor.
final nonisolated class MediaShareActivitySource: NSObject, UIActivityItemSource, Identifiable, Sendable {
    var id: UUID {
        file.id
    }

    let file: MediaShareFile
    let url: URL

    init(file: MediaShareFile, url: URL) {
        self.file = file
        self.url = url
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_: UIActivityViewController, dataTypeIdentifierForActivityType _: UIActivity.ActivityType?) -> String {
        UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
    }
}
