import Foundation

/// Invalidates work queued by a fullscreen request when the user exits.
public struct VideoPresentationGate {
    public private(set) var revision = 0
    private var resumeAt: TimeInterval = -.infinity

    public init() {}

    public mutating func dismiss(at now: TimeInterval) {
        revision &+= 1
        resumeAt = now + 0.8
    }

    public mutating func reset() {
        revision &+= 1
        resumeAt = -.infinity
    }

    public func accepts(at now: TimeInterval, revision request: Int? = nil) -> Bool {
        now >= resumeAt && (request == nil || request == revision)
    }
}
