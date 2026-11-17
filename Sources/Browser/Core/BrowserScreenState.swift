import CoreGraphics
import Foundation
import WebKit
import simd

// Groups of per-screen state. Each BrowserScreen holds one of each.

/// Trackpad and Shorts scrolling for this screen.
struct ScrollState {
    var nativeScroll = false
    var lastRoute = "Not used"
    var hasScrolledNatively = false
    var origin: SIMD2<Float>?
    var shortsDrag = BrowserScreen.ShortsDrag.none
    var shortsEnded = false
    var shortsTraceID = UUID()
    var shortsTrace: [String] = []
    var shortsStartURL: URL?
    var shortsStartPath: String?
    var releaseVelocity: CGFloat?
    var generation = UUID()
    var pendingScroll: Double = 0
    var inFlight = false
    var catalogGesture = false
    var catalogTouchSwipe = false
    var catalogScroll = false
    var catalogScrollTrace: [String] = []
    var ready = false
}

/// The cloud gaming page open in this screen, and what it reported.
struct CloudPageState {
    var id = UUID()
    var service: CloudGamingService?
    var profile: CloudGamingProfile?
    var modeRequested = "not recorded"
    var navigation: [CloudGamingService: [String]] = [:]
    var signals: [CloudGamingService: [CloudGamingProfile: [String: String]]] = [:]
}

/// The web field mirrored to the phone editor, and a pending tap that may open it.
struct PhoneEditorState {
    var fieldFrame: WKFrameInfo?
    var tapStarted: CFTimeInterval?
    var tapFrame: WKFrameInfo?
    var request = UUID()
}

/// Snapshot and frame timing for the diagnostics report.
struct FrameStats {
    var lastTick: TimeInterval?
    var displayTicks = 0
    var snapshotCount = 0
    var requestCount = 0
    var snapshotMilliseconds = [Double]()
    var uploadMilliseconds = [Double]()
    var nextSnapshot: TimeInterval = 0
    var inFlight = false
    var lastPoll: TimeInterval = 0
    var sourceMetrics = "Not sampled"
    var layoutValid = false
    var surfaceSize = CGSize.zero
    var displayHz = 0.0
    var snapshotHz = 0.0
    var latestImageSize = CGSize.zero
    var physicalPixels = CGSize.zero
    var snapshotGPU = "Not active"
}

/// Notes collected for the diagnostics report.
struct DiagnosticNotes {
    var secondaryClickReport = "not tried"
    var fixtureHistory = [String]()
    var runStart: TimeInterval?
    var runEpoch = UUID()
    var samples = [String]()
    var videoEvidence = "Unencrypted local synthetic H.264 video; not a DRM test"
    var firstMountNote = "No external mount"
    var pageRasterNote = "Not sampled"
}
