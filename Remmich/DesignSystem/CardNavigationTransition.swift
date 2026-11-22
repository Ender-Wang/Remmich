import SwiftUI

extension View {
    func cardNavigationSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat = DesignMetrics.defaultCornerRadius) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(.rect(cornerRadius: cornerRadius))
        }
    }

    func cardNavigationDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: id, in: namespace))
    }
}
