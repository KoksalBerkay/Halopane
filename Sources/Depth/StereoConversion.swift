import Combine
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import SpatialMath

/// Turns 2D frames into a stereo depth mesh for one player or browser screen.
/// Frames can be offered every display frame; at most one depth estimate runs
/// at a time, and the mesh eases between estimates.
final class StereoConversion: ObservableObject {
    enum Phase: Equatable {
        /// 2D. Nothing is converted.
        case off
        /// Turned on and waiting for the model or the first depth map.
        case preparing
        /// Showing depth.
        case on
    }

    /// Numbers for the diagnostics report.
    struct Stats {
        var estimates = 0
        var sceneCuts = 0
        var failures = 0
        var milliseconds: [Double] = []

        var summary: String {
            let recent = milliseconds.suffix(30)
            let mean = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
            return String(
                format: "%d depth maps, %.0f ms model time, %d scene cuts, %d failed", estimates, mean, sceneCuts,
                failures)
        }
    }

    static let settingsKey = "viture.depth3d.settings"
    /// Video depth updates per second. The mesh eases in between, so more adds
    /// little but costs battery.
    static let videoRate: CFTimeInterval = 15
    /// Vertices along the longer side of the picture.
    static let meshDetail = 64

    @Published private(set) var phase = Phase.off
    @Published var settings: StereoDepthSettings {
        didSet {
            saveSettings()
            if let depth = filter.current {
                let shown = depth.rotated(quarterTurns: quarterTurns)
                animator.setTarget(StereoDepthMesh(depth: shown, settings: settings), sceneCut: false)
            }
        }
    }
    private(set) var stats = Stats()
    let estimator: DepthEstimator
    private var filter = DepthFieldFilter()
    private var animator = StereoDepthAnimator()
    private var thumbnail: [UInt8] = []
    private var pending = false
    private var lastRequest: CFTimeInterval = 0
    private var lastAdvance: CFTimeInterval?
    private var generation = UUID()
    private var hasDepth = false
    private var quarterTurns: UInt32 = 0
    private var estimatorChanges: AnyCancellable?

    init(estimator: DepthEstimator = .shared) {
        self.estimator = estimator
        settings = Self.savedSettings()
        // The model's loading state is part of what this object shows.
        estimatorChanges = estimator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isActive: Bool { phase != .off }
    /// True while depth is on or still fading out.
    var isShowing: Bool { isActive || !animator.finished }
    /// True once a depth map has arrived since the last start.
    var hasDepthMap: Bool { hasDepth }
    var failure: String? {
        if case .failed(let message) = estimator.state {
            return message
        }
        return nil
    }

    func start() {
        guard phase == .off else {
            return
        }
        generation = UUID()
        filter.reset()
        thumbnail = []
        hasDepth = false
        pending = false
        lastRequest = 0
        animator.reset()
        animator.setEnabled(true)
        phase = .preparing
        estimator.prepare()
    }

    /// Turns depth off. The effect fades out over the next frames.
    func stop() {
        guard phase != .off else {
            return
        }
        generation = UUID()
        animator.setEnabled(false)
        phase = .off
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    /// True when a new frame would be used now. A still picture needs one depth map.
    func wantsFrame(now: CFTimeInterval, still: Bool) -> Bool {
        guard isActive, !pending, !estimator.state.isFailure else {
            return false
        }
        if still {
            return !hasDepth
        }
        return now - lastRequest >= 1 / Self.videoRate
    }

    /// Offers a decoded video frame. `quarterTurns` is how far the picture is
    /// turned when shown, so depth lines up with what the viewer sees.
    func submit(_ frame: CVPixelBuffer, quarterTurns: UInt32, now: CFTimeInterval) {
        let aspect = Double(CVPixelBufferGetWidth(frame)) / Double(max(CVPixelBufferGetHeight(frame), 1))
        begin(now: now) { completion in
            self.estimator.estimate(frame, completion: completion)
        } finish: { estimate in
            self.accept(estimate, sourceAspect: aspect, quarterTurns: quarterTurns)
        }
    }

    /// Offers a still image, a page snapshot or a captured video frame.
    func submit(_ image: CGImage, quarterTurns: UInt32, now: CFTimeInterval) {
        let aspect = Double(image.width) / Double(max(image.height, 1))
        begin(now: now) { completion in
            self.estimator.estimate(image, completion: completion)
        } finish: { estimate in
            self.accept(estimate, sourceAspect: aspect, quarterTurns: quarterTurns)
        }
    }

    /// The mesh to draw this frame, or nil to draw the picture in 2D.
    func mesh(now: CFTimeInterval) -> StereoDepthMesh? {
        let seconds = lastAdvance.map { Float(now - $0) } ?? 0
        lastAdvance = now
        return animator.advance(seconds: seconds)
    }

    // MARK: Depth results

    private func begin(
        now: CFTimeInterval, run: (@escaping (DepthEstimate?) -> Void) -> Void,
        finish: @escaping (DepthEstimate) -> Void
    ) {
        guard isActive, !pending else {
            return
        }
        pending = true
        lastRequest = now
        let request = generation
        run { [weak self] estimate in
            guard let self else {
                return
            }
            self.pending = false
            guard self.generation == request else {
                return
            }
            guard let estimate else {
                self.stats.failures += 1
                return
            }
            finish(estimate)
        }
    }

    private func accept(_ estimate: DepthEstimate, sourceAspect: Double, quarterTurns: UInt32) {
        let size = Self.gridSize(aspect: sourceAspect)
        guard
            let raw = DepthGrid.sampling(
                estimate.raw, width: estimate.width, height: estimate.height, columns: size.columns, rows: size.rows)
        else {
            stats.failures += 1
            return
        }
        let cut = SceneCut.isCut(previous: thumbnail, current: estimate.thumbnail)
        thumbnail = estimate.thumbnail
        self.quarterTurns = quarterTurns
        let depth = filter.add(raw, sceneCut: cut).rotated(quarterTurns: quarterTurns)
        animator.setTarget(StereoDepthMesh(depth: depth, settings: settings), sceneCut: cut)
        hasDepth = true
        stats.estimates += 1
        stats.sceneCuts += cut ? 1 : 0
        stats.milliseconds.append(estimate.milliseconds)
        if stats.milliseconds.count > 120 {
            stats.milliseconds.removeFirst(60)
        }
        if phase == .preparing {
            phase = .on
        }
    }

    /// Mesh size in the source picture's own orientation, keeping cells square.
    static func gridSize(aspect: Double) -> (columns: Int, rows: Int) {
        let detail = Double(meshDetail)
        let safe = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        if safe >= 1 {
            return (meshDetail, max(12, Int((detail / safe).rounded())))
        }
        return (max(12, Int((detail * safe).rounded())), meshDetail)
    }

    // MARK: Settings

    private static func savedSettings() -> StereoDepthSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
            let saved = try? JSONDecoder().decode(StereoDepthSettings.self, from: data)
        else {
            return StereoDepthSettings()
        }
        return saved
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}
