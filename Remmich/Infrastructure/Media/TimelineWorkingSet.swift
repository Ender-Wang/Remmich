import Foundation

actor TimelineWorkingSet<Value: Sendable> {
    enum Tier: Int, Sendable {
        case cold
        case warm
        case newest
        case viewport
    }

    struct Limits: Sendable {
        let byteBudget: Int
        let hardByteCap: Int
        let warmLifetime: TimeInterval

        static var `default`: Self {
            let mebibyte = 1024 * 1024
            let physicalMemory = Int(clamping: ProcessInfo.processInfo.physicalMemory)
            let byteBudget = min(96 * mebibyte, max(48 * mebibyte, physicalMemory / 32))
            let hardByteCap = min(128 * mebibyte, max(byteBudget, physicalMemory / 24))
            return .init(
                byteBudget: byteBudget,
                hardByteCap: hardByteCap,
                warmLifetime: 45
            )
        }
    }

    private struct Entry: Sendable {
        var value: Value
        var byteCost: Int
        var tier: Tier
        var lastTouched: TimeInterval
    }

    private let limits: Limits
    private var entries: [String: Entry] = [:]
    private var generation = 0

    init(limits: Limits = .default) {
        self.limits = limits
    }

    @discardableResult
    func beginViewportGeneration() -> Int {
        generation += 1
        for key in entries.keys where entries[key]?.tier == .viewport {
            entries[key]?.tier = .warm
        }
        return generation
    }

    func insert(
        _ value: Value,
        for key: String,
        byteCost: Int,
        tier: Tier,
        generation requestedGeneration: Int? = nil,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard requestedGeneration == nil || requestedGeneration == generation else { return }
        guard tier != .cold else { return }
        entries[key] = Entry(
            value: value,
            byteCost: max(0, byteCost),
            tier: tier,
            lastTouched: now
        )
        trim(now: now, target: limits.hardByteCap)
    }

    func value(
        for key: String,
        promoteTo tier: Tier? = nil,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Value? {
        guard var entry = entries[key] else { return nil }
        entry.lastTouched = now
        if let tier, tier.rawValue > entry.tier.rawValue {
            entry.tier = tier
        }
        entries[key] = entry
        return entry.value
    }

    func setTier(
        _ tier: Tier,
        for key: String,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard var entry = entries[key] else { return }
        guard tier != .cold else {
            entries[key] = nil
            return
        }
        entry.tier = tier
        entry.lastTouched = now
        entries[key] = entry
    }

    func expire(now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        entries = entries.filter { _, entry in
            entry.tier == .viewport || entry.tier == .newest ||
                now - entry.lastTouched < limits.warmLifetime
        }
        trim(now: now, target: limits.byteBudget)
    }

    func handleMemoryPressure() {
        entries = entries.filter { $0.value.tier == .viewport }
    }

    func removeAll() {
        entries.removeAll()
    }

    var byteCount: Int {
        entries.values.reduce(0) { $0 + $1.byteCost }
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    private func trim(now _: TimeInterval, target: Int) {
        var total = byteCount
        guard total > target else { return }
        let victims = entries.sorted {
            if $0.value.tier != $1.value.tier {
                return $0.value.tier.rawValue < $1.value.tier.rawValue
            }
            return $0.value.lastTouched < $1.value.lastTouched
        }
        for (key, entry) in victims where total > target {
            entries.removeValue(forKey: key)
            total -= entry.byteCost
        }
    }
}
