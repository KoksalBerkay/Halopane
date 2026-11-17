import AVFoundation
import Combine
import ImageIO
import MetalKit
import SpatialMath
#if canImport(UIKit)
    import UIKit
#endif

/// Owns one local file grant and one AVPlayer. Only the external display's
/// render loop asks for video frames; playback controls observe coarse progress.
final class NativeMediaSession: ObservableObject {
    @Published private(set) var file: LocalPanelFile?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var detectedStereo = false
    @Published private(set) var stereoFrameAvailable = false
    @Published private(set) var playing = false
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var scrubPreview: Double?
    @Published var stereoPresentation: StereoPresentationRoute = .image
    var usesFlatPhotoSurface: Bool {
        file?.kind == .image && projection == .flat && !roomScreen
            && (arrangement == .mono || arrangement == .separateEyes)
    }
    var usesLiveImagePresentation: Bool {
        detectedStereo && isMovie && projection == .flat && !roomScreen && arrangement == .separateEyes
            && stereoPresentation == .image
    }
    @Published private(set) var stereoDecoder: StereoDecoderChoice = .trackReader
    @Published private(set) var comparison: PausedMediaComparison?
    @Published private(set) var comparisonStatus = ""
    @Published var comparisonRoute: ComparisonGlassesRoute = .metal {
        didSet {
            if comparison != nil, oldValue != comparisonRoute {
                diagnostics.comparisonRoute(comparisonRoute, eye: comparisonEye)
            }
        }
    }
    @Published var comparisonEye: StereoEyePreview = .rightOnly {
        didSet {
            if comparison != nil, oldValue != comparisonEye {
                diagnostics.comparisonRoute(comparisonRoute, eye: comparisonEye)
            }
        }
    }
    private var comparisonRequest = UUID()
    @Published var stereoEyePreview: StereoEyePreview = .stereo
    @Published private(set) var diagnosticStatus = ""
    @Published private(set) var checkingFrame = false
    let diagnostics = NativeMediaDiagnostics()
    @Published var projection: MediaProjection = .flat {
        didSet {
            recenter()
        }
    }
    @Published var arrangement: MediaArrangement = .mono
    @Published var swapEyes = false
    @Published var roomScreen = false {
        didSet {
            recenter()
        }
    }

    private var player: AVPlayer?
    private var monoOutput: AVPlayerItemVideoOutput?
    private var stereoOutput: Any?
    private var alternateOutput: Any?
    private var waitingForSeek = false
    private var seekID = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: Any?
    private var endObservation: NSObjectProtocol?
    private var openedTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var recenterPending = true
    private var anchor = SceneMath.identity
    private var drag = SIMD2<Float>.zero
    private var pendingVideoPlay = false
    private(set) var decodedVideoFrames = 0
    private(set) var lastRun = "No native media opened."

    var summary: String {
        guard let file else {
            return lastRun
        }
        let kind = file.kind == .movie ? "video" : "photo"
        let status: String
        if let error {
            status = error
        } else if loading {
            status = "loading"
        } else {
            status = playing ? "playing" : "paused"
        }
        return "\(kind); \(projection.title), \(arrangement.title); "
            + "stereo source=\(detectedStereo), eye pair=\(stereoFrameAvailable); "
            + "video frames=\(decodedVideoFrames); \(status)"
    }

    private(set) var renderID = UUID()
    private(set) var photo: (CGImage, CGImage?)?
    private(set) var quarterTurns: UInt32 = 0
    var isMovie: Bool { file?.kind == .movie }
    var availableArrangements: [MediaArrangement] {
        MediaArrangement.allCases.filter { $0 != .separateEyes || detectedStereo }
    }

    init() {
        #if canImport(UIKit)
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.pause()
            }
        #endif
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func open(_ file: LocalPanelFile, autoplay: Bool = false) {
        close()
        guard file.kind != .document else {
            return
        }
        let format = MediaFormat.inferred(from: file.sourceName)
        projection = format.projection
        arrangement = format.layout
        loading = true
        self.file = file
        pendingVideoPlay = autoplay && isMovie
        renderID = UUID()
        diagnostics.start(file, decoder: stereoDecoder.rawValue)
        openedTask = Task { @MainActor [weak self] in
            if file.kind == .image {
                let decoded = await DecodedPhoto.decode(file, inferredProjection: format.projection)
                guard let self, self.file === file, !Task.isCancelled else {
                    return
                }
                self.showDecodedPhoto(decoded, inferredProjection: format.projection)
            } else {
                await self?.prepareVideo(file)
            }
        }
    }

    private func showDecodedPhoto(_ decoded: DecodedPhoto, inferredProjection: MediaProjection) {
        // Use the photo's own projection unless the user already picked another one.
        if projection == inferredProjection, projection != decoded.projection {
            projection = decoded.projection
        }
        photo = decoded.frames
        loading = false
        detectedStereo = decoded.frames?.1 != nil
        stereoFrameAvailable = detectedStereo
        if detectedStereo {
            arrangement = .separateEyes
        }
        if decoded.frames == nil {
            error = "This photo could not be read."
        }
    }

    private func prepareVideo(_ file: LocalPanelFile) async {
        let asset = AVURLAsset(url: file.url)
        do {
            let loaded = try await LoadedVideoTrack.load(from: asset)
            guard self.file === file, !Task.isCancelled else {
                return
            }
            quarterTurns = loaded.quarterTurns
            applyFormatMetadata(loaded.description)
            let item = AVPlayerItem(asset: asset)
            let componentBits = loaded.componentBits
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = false
            self.player = player
            let outputSummary = attachVideoOutput(
                for: loaded, file: file, asset: asset, item: item, player: player, componentBits: componentBits)
            logVideoFormat(loaded, componentBits: componentBits, outputSummary: outputSummary)
            observePlayback(of: item, player: player)
        } catch {
            if self.file === file {
                loading = false
                self.error = "No supported video track was found."
            }
        }
    }

    /// Uses projection and layout metadata from the file when the system can read it.
    private func applyFormatMetadata(_ description: CMFormatDescription?) {
        guard #available(iOS 18.0, macOS 15.0, *), let description else {
            return
        }
        var format = MediaFormat(projection: projection, layout: arrangement)
        format.applyVideoMetadata(description)
        if projection != format.projection {
            projection = format.projection
        }
        arrangement = format.layout
    }

    /// Connects the output that feeds decoded frames to the renderer.
    /// Returns a short description of the chosen output for diagnostics.
    private func attachVideoOutput(
        for loaded: LoadedVideoTrack, file: LocalPanelFile, asset: AVURLAsset, item: AVPlayerItem,
        player: AVPlayer, componentBits: Int?
    ) -> String {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard loaded.isStereo, #available(iOS 17.2, *) else {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(output)
            monoOutput = output
            return "mono player output · BGRA"
        }
        detectedStereo = true
        arrangement = .separateEyes
        let layers = loaded.videoLayerIDs
        if stereoDecoder == .trackReader, layers.count >= 2 {
            let reader = StereoTrackReader(
                file: file, asset: asset, track: loaded.track, layers: layers, duration: loaded.duration,
                bits: componentBits ?? 10)
            alternateOutput = reader
            let summary = "track reader \(MediaLuma.fourCC(reader.pixelFormat)), layers=\(layers)"
            reader.seek(to: .zero)
            return summary
        }
        var stereoAttributes = attributes
        let usesNativeFormat = stereoDecoder != .playerBGRA
        if usesNativeFormat {
            stereoAttributes.removeValue(forKey: kCVPixelBufferPixelFormatTypeKey as String)
        }
        stereoOutput = NativeStereoOutput(player: player, attributes: stereoAttributes)
        var summary = usesNativeFormat ? "player output · native format" : "player output · BGRA"
        if stereoDecoder == .trackReader {
            summary += " (track did not advertise two layer IDs)"
        }
        return summary
    }

    private func logVideoFormat(_ loaded: LoadedVideoTrack, componentBits: Int?, outputSummary: String) {
        let codec = loaded.description.map { MediaLuma.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "-"
        let depth = componentBits.map(String.init) ?? "not declared"
        diagnostics.videoFormat(
            "codec=\(codec), component bits=\(depth), nominal fps=\(loaded.nominalFrameRate), "
                + "MV-HEVC stereo track=\(loaded.isStereo); effective=\(outputSummary)")
    }

    private func observePlayback(of item: AVPlayerItem, player: AVPlayer) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item else {
                    return
                }
                self.handleStatusChange(of: item)
            }
        }
        timeObservation = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            self?.updateTime()
        }
        endObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.playing = false
            self?.updateTime()
        }
    }

    private func handleStatusChange(of item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            loading = false
            updateTime()
            if pendingVideoPlay {
                pendingVideoPlay = false
                play()
            }
        case .failed:
            loading = false
            playing = false
            error = "The system couldn’t decode this video."
        default:
            break
        }
    }

    static func timeLabel(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds.isFinite ? min(seconds, 1_000_000) : 0))
        return "\(whole/60):" + String(format: "%02d", whole % 60)
    }

    func showScrubPreview(_ seconds: Double?) {
        scrubPreview = seconds.map { min(duration, max(0, $0)) }
    }

    func presentationHint(stereo: Bool, rendererUnavailable: Bool) -> String? {
        guard file != nil, comparison == nil else {
            return nil
        }
        if let error {
            return error
        }
        if loading {
            return "Opening media…"
        }
        if rendererUnavailable && !usesFlatPhotoSurface && !usesLiveImagePresentation {
            return "Media rendering is unavailable."
        }
        if let scrubPreview {
            return Self.timeLabel(scrubPreview) + " / " + Self.timeLabel(duration)
        }
        if arrangement != .mono && !stereo {
            return "Switch the glasses to 3D mode for both eyes."
        }
        if isMovie && !playing {
            return "Paused · Tap the phone surface to play"
        }
        return nil
    }

    private func updateTime() {
        guard let player else {
            return
        }
        let seconds = player.currentTime().seconds
        let total = player.currentItem?.duration.seconds ?? 0
        if total.isFinite, total > 0, duration != total {
            duration = total
        }
        if seconds.isFinite, position != seconds {
            position = seconds
        }
    }

    func play() {
        if comparison != nil || !comparisonStatus.isEmpty {
            endComparison()
        }
        guard let player, player.currentItem?.status == .readyToPlay else {
            pendingVideoPlay = isMovie
            return
        }
        if duration > 0, position >= duration - 0.1 {
            seek(to: 0)
        }
        player.play()
        playing = true
    }

    func pause() {
        pendingVideoPlay = false
        player?.pause()
        if playing {
            playing = false
        }
    }

    func seek(to seconds: Double) {
        guard let player, duration > 0, seconds.isFinite else {
            return
        }
        position = min(duration, max(0, seconds))
        renderID = UUID()
        let time = CMTime(seconds: position, preferredTimescale: 60_000)
        if #available(iOS 17.2, *), let reader = alternateOutput as? StereoTrackReader {
            let id = UUID()
            seekID = id
            waitingForSeek = true
            // Clear old frames before AVPlayer changes clocks.
            reader.seek(to: time)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.seekID == id else {
                        return
                    }
                    self.waitingForSeek = false
                }
            }
        } else {
            player.seek(to: time)
        }
    }

    func sample(hostTime: CFTimeInterval, after previous: CMTime) -> (CVPixelBuffer, CVPixelBuffer?, CMTime)? {
        if #available(iOS 17.2, *), let reader = alternateOutput as? StereoTrackReader {
            guard !waitingForSeek, let player else {
                return nil
            }
            if let failure = reader.failure, error == nil {
                diagnostics.videoFormat("Track reader: " + failure)
                error = "The stereo track reader could not continue. Try another decoder in Media diagnostics."
                pause()
            }
            guard let frame = reader.frame(at: player.currentTime()), frame.time != previous else {
                return nil
            }
            if !stereoFrameAvailable {
                stereoFrameAvailable = true
            }
            decodedVideoFrames += 1
            return (frame.left, frame.right, frame.time)
        }
        if #available(iOS 17.2, *), let output = stereoOutput as? NativeStereoOutput {
            guard let sample = output.sample(time: hostTime), sample.2 != previous else {
                return nil
            }
            if stereoFrameAvailable != (sample.1 != nil) {
                stereoFrameAvailable = sample.1 != nil
            }
            decodedVideoFrames += 1
            return sample
        }
        guard let output = monoOutput else {
            return nil
        }
        let time = output.itemTime(forHostTime: hostTime)
        var timestamp = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: time) || !previous.isValid,
            let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &timestamp)
        else {
            return nil
        }
        decodedVideoFrames += 1
        return (buffer, nil, timestamp)
    }

    func setStereoDecoder(_ choice: StereoDecoderChoice) {
        guard stereoDecoder != choice else {
            return
        }
        stereoDecoder = choice
        if detectedStereo, isMovie, let file {
            open(file)
        }
    }

    func checkPausedFrame() {
        guard let file, !playing, !checkingFrame else {
            return
        }
        checkingFrame = true
        diagnosticStatus = "Checking the paused frame…"
        diagnostics.check(file: file) { [weak self] text in
            guard let self, self.file === file else {
                return
            }
            self.diagnosticStatus = text
            self.checkingFrame = false
        }
    }

    func comparePausedFrame() {
        guard let file, isMovie, !playing else {
            return
        }
        let request = UUID()
        comparisonRequest = request
        comparisonStatus = "Preparing the paused frame…"
        diagnostics.compare(turns: quarterTurns) { [weak self] comparison in
            guard let self, self.file === file, self.comparisonRequest == request else {
                return
            }
            if let comparison {
                self.comparisonRoute = .metal
                self.comparisonEye = comparison.right != nil ? .rightOnly : .leftOnly
                self.comparison = comparison
                self.diagnostics.comparisonRoute(self.comparisonRoute, eye: self.comparisonEye)
                self.comparisonStatus = ""
            } else {
                self.comparisonStatus = "Play until a picture appears, then pause and try again."
            }
        }
    }

    func endComparison() {
        comparisonRequest = UUID()
        comparison = nil
        comparisonStatus = ""
    }

    func recenter() {
        recenterPending = true
        drag = .zero
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        guard projection != .flat || roomScreen else {
            return
        }
        drag.x = (drag.x + Float(dx) * 0.005).truncatingRemainder(dividingBy: 2 * .pi)
        drag.y = min(.pi / 2, max(-.pi / 2, drag.y + Float(dy) * 0.005))
    }

    func orientation(_ frame: RenderFrame) -> simd_quatf {
        guard projection != .flat || roomScreen else {
            return SceneMath.identity
        }
        if recenterPending, frame.live {
            anchor = WebPanelMath.levelAnchor(lookingWith: frame.orientation)
            recenterPending = false
        }
        let relative = recenterPending ? SceneMath.identity : anchor.inverse * frame.orientation
        return simd_quatf(angle: drag.x, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: drag.y, axis: SIMD3(1, 0, 0))
            * relative
    }

    func close() {
        if file != nil {
            lastRun = summary
        }
        diagnostics.finish()
        endComparison()
        checkingFrame = false
        diagnosticStatus = ""
        decodedVideoFrames = 0
        openedTask?.cancel()
        openedTask = nil
        pause()
        if let token = timeObservation {
            player?.removeTimeObserver(token)
        }
        if let token = endObservation {
            NotificationCenter.default.removeObserver(token)
        }
        timeObservation = nil
        endObservation = nil
        statusObservation = nil
        if #available(iOS 17.2, *) {
            player?.videoOutput = nil
            (alternateOutput as? StereoTrackReader)?.stop()
        }
        alternateOutput = nil
        seekID = UUID()
        waitingForSeek = false
        player?.replaceCurrentItem(with: nil)
        player = nil
        monoOutput = nil
        stereoOutput = nil
        photo = nil
        file = nil
        loading = false
        error = nil
        position = 0
        duration = 0
        quarterTurns = 0
        scrubPreview = nil
        detectedStereo = false
        stereoFrameAvailable = false
        swapEyes = false
        roomScreen = false
        stereoEyePreview = .stereo
        recenter()
    }

    enum MediaError: Error { case noVideo }
}
