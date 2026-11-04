import Foundation

nonisolated enum MemoryProgressSegments {
    static let spacing = 3.0
    static let minimumWidth = 6.0

    static func visibleRange(count: Int, selectedIndex: Int, width: Double) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        let capacity = max(1, Int((max(0, width) + spacing) / (minimumWidth + spacing)))
        let visibleCount = min(count, capacity)
        let selection = min(count - 1, max(0, selectedIndex))
        let lower = min(max(0, selection - visibleCount / 2), count - visibleCount)
        return lower ..< lower + visibleCount
    }
}
