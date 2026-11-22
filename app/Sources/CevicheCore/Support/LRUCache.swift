import Foundation

/// A cache that drops what was used longest ago, once it holds more than `countLimit` entries or more than
/// `costLimit` in total cost (bytes, usually). Reading an entry counts as using it. Not thread-safe: keep it inside
/// an actor or under a lock.
public struct LRUCache<Key: Hashable, Value> {
    private struct Entry { var value: Value; var cost: Int; var used: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let countLimit: Int
    public let costLimit: Int
    public private(set) var totalCost = 0

    public init(countLimit: Int = .max, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit); self.costLimit = max(0, costLimit)
    }

    public var count: Int { entries.count }
    public var keys: Dictionary<Key, Value>.Keys { entries.mapValues(\.value).keys }

    /// The value for `key`, marked as just used.
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1; entry.used = clock; entries[key] = entry
        return entry.value
    }
    /// The value without counting as a use, for drawing code that must not mutate.
    public func peek(_ key: Key) -> Value? { entries[key]?.value }
    /// Marks `key` as just used.
    public mutating func touch(_ key: Key) { _ = value(for: key) }

    /// Stores `value` and returns the keys evicted to make room. The newest entry stays even when it alone is over
    /// the cost limit.
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key, cost: Int = 0) -> [Key] {
        clock += 1
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = Entry(value: value, cost: max(0, cost), used: clock); totalCost += max(0, cost)
        var evicted: [Key] = []
        while entries.count > 1, entries.count > countLimit || totalCost > costLimit,
              let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key, oldest != key {
            remove(oldest); evicted.append(oldest)
        }
        return evicted
    }
    public mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
    }
    public mutating func removeAll() { entries.removeAll(); totalCost = 0 }
}
