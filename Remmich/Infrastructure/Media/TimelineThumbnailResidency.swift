import CoreGraphics
import Foundation
import Nuke
import UIKit

actor TimelineThumbnailResidency {
    static let maximumThumbnailDimension = 2048

    private let workingSet: TimelineWorkingSet<ImageContainer>
    private var newestAssetIDs = Set<String>()
    private var viewportAssetIDs = Set<String>()
    private var desiredRevisionByAssetID: [String: Date] = [:]
    private var trackedDescriptorByKey: [String: MediaRequestDescriptor] = [:]
    private var viewportGeneration = 0
    private var scopeGeneration = 0

    init(limits: TimelineWorkingSet<ImageContainer>.Limits = .default) {
        workingSet = TimelineWorkingSet(limits: limits)
    }

    func updatePlan(
        _ plan: TimelineResidencyPlan,
        scopeGeneration requestedScopeGeneration: Int = 0
    ) async {
        guard requestedScopeGeneration >= scopeGeneration else { return }
        if requestedScopeGeneration > scopeGeneration {
            await reset(for: requestedScopeGeneration)
        }
        newestAssetIDs = Set(plan.newestAssets.map(\.id))
        viewportAssetIDs = Set(plan.viewportAssets.map(\.id))
        desiredRevisionByAssetID = Dictionary(
            (plan.newestAssets + plan.viewportAssets).map { ($0.id, $0.thumbnailRevision) },
            uniquingKeysWith: { _, current in current }
        )
        viewportGeneration = await workingSet.beginViewportGeneration()

        var discardedKeys: [String] = []
        for (key, descriptor) in trackedDescriptorByKey {
            let tier = desiredTier(for: descriptor)
            await workingSet.setTier(tier, for: key)
            if tier == .cold {
                discardedKeys.append(key)
            }
        }
        for key in discardedKeys {
            trackedDescriptorByKey[key] = nil
        }
        await workingSet.expire()
    }

    @discardableResult
    func retain(
        _ container: ImageContainer,
        for descriptor: MediaRequestDescriptor,
        scopeGeneration requestedScopeGeneration: Int = 0
    ) async -> Bool {
        guard requestedScopeGeneration == scopeGeneration else { return false }
        guard descriptor.derivative == .thumbnail,
              let target = descriptor.targetPixels,
              target.width <= Self.maximumThumbnailDimension,
              target.height <= Self.maximumThumbnailDimension,
              !container.isPreview
        else { return false }

        let tier = desiredTier(for: descriptor)
        guard tier != .cold else { return false }
        let key = Self.key(for: descriptor)
        let byteCost = Self.decodedByteCost(of: container)
        await workingSet.insert(
            container,
            for: key,
            byteCost: byteCost,
            tier: tier,
            generation: tier == .viewport ? viewportGeneration : nil
        )
        guard await workingSet.value(for: key) != nil else { return false }
        trackedDescriptorByKey[key] = descriptor
        return true
    }

    func handleBackgroundTransition() async {
        trackedDescriptorByKey = [:]
        await workingSet.removeAll()
    }

    func handleMemoryPressure() async {
        await workingSet.handleMemoryPressure()
        trackedDescriptorByKey = trackedDescriptorByKey.filter {
            desiredTier(for: $0.value) == .viewport
        }
    }

    func removeAll() async {
        await reset(for: scopeGeneration)
    }

    func advance(to requestedScopeGeneration: Int) async {
        guard requestedScopeGeneration > scopeGeneration else { return }
        await reset(for: requestedScopeGeneration)
    }

    private func reset(for requestedScopeGeneration: Int) async {
        scopeGeneration = requestedScopeGeneration
        newestAssetIDs = []
        viewportAssetIDs = []
        desiredRevisionByAssetID = [:]
        trackedDescriptorByKey = [:]
        await workingSet.removeAll()
    }

    var count: Int {
        get async { await workingSet.count }
    }

    var isEmpty: Bool {
        get async { await workingSet.isEmpty }
    }

    var byteCount: Int {
        get async { await workingSet.byteCount }
    }

    private func desiredTier(
        for descriptor: MediaRequestDescriptor
    ) -> TimelineWorkingSet<ImageContainer>.Tier {
        guard desiredRevisionByAssetID[descriptor.assetID] == descriptor.updatedAt else {
            return .cold
        }
        if viewportAssetIDs.contains(descriptor.assetID) {
            return .viewport
        }
        if newestAssetIDs.contains(descriptor.assetID) {
            return .newest
        }
        return .cold
    }

    private static func key(for descriptor: MediaRequestDescriptor) -> String {
        let target = descriptor.targetPixels.map { "\($0.width)x\($0.height)" } ?? "source"
        return [
            descriptor.assetID,
            descriptor.updatedAt.ISO8601Format(),
            descriptor.derivative.rawValue,
            target,
        ].joined(separator: "|")
    }

    private static func decodedByteCost(of container: ImageContainer) -> Int {
        if let image = container.image.cgImage {
            return image.width * image.height * 4
        }
        let scale = container.image.scale
        let width = Int((container.image.size.width * scale).rounded(.up))
        let height = Int((container.image.size.height * scale).rounded(.up))
        return max(0, width * height * 4)
    }
}
