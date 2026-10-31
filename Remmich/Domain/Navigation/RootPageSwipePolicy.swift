nonisolated enum RootPageSwipePolicy {
    static func allowsPaging(
        viewerPresented: Bool,
        hasNavigationDestination: Bool,
        librarySelected: Bool,
        libraryAccountPresented: Bool
    ) -> Bool {
        // Library retains its expanded profile when another tab is selected.
        // Only that tab owns the profile's root-page swipe exclusion.
        !viewerPresented && !hasNavigationDestination
            && !(librarySelected && libraryAccountPresented)
    }
}
