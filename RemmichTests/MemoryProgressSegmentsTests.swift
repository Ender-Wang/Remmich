import Testing
@testable import Remmich

struct MemoryProgressSegmentsTests {
    @Test func keepsSeparateSegmentsAcrossFormerThreshold() {
        #expect(MemoryProgressSegments.visibleRange(count: 12, selectedIndex: 0, width: 362) == 0 ..< 12)
        #expect(MemoryProgressSegments.visibleRange(count: 13, selectedIndex: 0, width: 362) == 0 ..< 13)
    }

    @Test func largeMemoriesKeepSelectionVisibleWithoutSubpixelSegments() {
        for width in [120.0, 362, 912] {
            for selection in [0, 1, 39, 500, 999] {
                let range = MemoryProgressSegments.visibleRange(count: 1000, selectedIndex: selection, width: width)
                #expect(range.contains(selection))
                #expect(range.lowerBound >= 0 && range.upperBound <= 1000)
                let segmentWidth = (width - Double(range.count - 1) * MemoryProgressSegments.spacing) / Double(range.count)
                #expect(segmentWidth >= MemoryProgressSegments.minimumWidth)
            }
        }
    }

    @Test func handlesEmptyAndNarrowLayouts() {
        #expect(MemoryProgressSegments.visibleRange(count: 0, selectedIndex: 0, width: 362).isEmpty)
        #expect(MemoryProgressSegments.visibleRange(count: 100, selectedIndex: 99, width: 0) == 99 ..< 100)
        #expect(MemoryProgressSegments.visibleRange(count: 1, selectedIndex: 0, width: 362) == 0 ..< 1)
    }
}
