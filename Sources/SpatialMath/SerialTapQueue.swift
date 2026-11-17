import Foundation

/// Keeps one gesture in flight even when its navigation context is invalidated.
public struct SerialTapQueue<Value> {
    private var pending: [Value] = []
    private var inFlight = false
    public let capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = capacity
    }
    public var count: Int { pending.count }
    public var isIdle: Bool { pending.isEmpty && !inFlight }
    @discardableResult
    public mutating func enqueue(_ value: Value) -> Bool {
        guard pending.count < capacity else {
            return false
        }
        pending.append(value)
        return true
    }
    public mutating func startNext() -> Value? {
        guard !inFlight, !pending.isEmpty else {
            return nil
        }
        inFlight = true
        return pending.removeFirst()
    }
    public mutating func didFinish() {
        inFlight = false
    }
    public mutating func removePending(where predicate: (Value) -> Bool) {
        pending.removeAll(where: predicate)
    }
    public mutating func discardPending() {
        pending.removeAll(keepingCapacity: true)
    }
}
