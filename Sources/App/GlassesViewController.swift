import AdapterTracking
import Combine
import SwiftUI
import MetalKit
import SpatialMath
import simd
import UIKit

/// Hosts everything drawn in the glasses and runs the per-frame display loop.
final class GlassesViewController: UIViewController {
    private var link: CADisplayLink?
    private let pattern = PatternView()
    private let webSurface = GlassesSurface()
    private var metalView: MTKView?
    private var renderer: WorldRenderer?
    private var nativeView: MTKView?
    private var nativeRenderer: NativeMediaRenderer?
    private let comparisonSurface = MediaComparisonImageSurface()
    private let liveStereoImages = LiveStereoImageOutput()
    private let mediaHUD = ExternalMediaHUD()
    private var lastReport: CFTimeInterval = 0
    private var resumeObserver: NSObjectProtocol?
    private var lastResume: CFTimeInterval = 0

    // Views from back to front: test pattern, 3D scene, browser screens, media player, overlays.
    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        pattern.frame = view.bounds
        pattern.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pattern)
        addSceneRenderer()
        webSurface.frame = view.bounds
        webSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webSurface.isHidden = true
        view.addSubview(webSurface)
        addMediaRenderer()
        addMediaOverlays()
        resumeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeDisplay()
        }
    }

    // The head-tracked 3D scene shown when the browser is closed.
    private func addSceneRenderer() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            GlassesDisplay.shared.event("Metal device unavailable")
            return
        }
        do {
            let renderer = try WorldRenderer(device: device)
            let metal = MTKView(frame: view.bounds, device: device)
            metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            metal.colorPixelFormat = .bgra8Unorm
            metal.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            metal.isPaused = true
            metal.enableSetNeedsDisplay = false
            metal.delegate = renderer
            view.addSubview(metal)
            self.renderer = renderer
            metalView = metal
        } catch {
            GlassesDisplay.shared.event("Metal setup failed: " + error.localizedDescription)
        }
    }

    // The Spatial Player's Metal view. Hidden until a local file is open.
    private func addMediaRenderer() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            GlassesDisplay.shared.nativeMediaRendererUnavailable = true
            return
        }
        do {
            let renderer = try NativeMediaRenderer(device: device)
            let metal = MTKView(frame: view.bounds, device: device)
            metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            metal.colorPixelFormat = .bgra8Unorm
            metal.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            metal.isPaused = true
            metal.enableSetNeedsDisplay = false
            metal.backgroundColor = .black
            metal.isOpaque = true
            metal.isHidden = true
            view.addSubview(metal)
            nativeRenderer = renderer
            nativeView = metal
            GlassesDisplay.shared.nativeMediaRendererUnavailable = false
        } catch {
            GlassesDisplay.shared.nativeMediaRendererUnavailable = true
            GlassesDisplay.shared.event("Native media setup failed: " + error.localizedDescription)
        }
    }

    // Photo and comparison images, and the media status text, drawn above everything else.
    private func addMediaOverlays() {
        comparisonSurface.frame = view.bounds
        comparisonSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(comparisonSurface)
        mediaHUD.frame = view.bounds
        mediaHUD.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mediaHUD)
    }

    deinit {
        if let resumeObserver {
            NotificationCenter.default.removeObserver(resumeObserver)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    func resumeDisplay() {
        guard isViewLoaded, view.window != nil else {
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastResume > 0.25 else {
            return
        }
        lastResume = now
        webSurface.stop()
        startDisplayLink()
    }

    private func startDisplayLink() {
        link?.invalidate()
        link = nil
        guard let scene = view.window?.windowScene else {
            return
        }
        let displayLink: CADisplayLink?
        if #available(iOS 27.0, *) {
            displayLink = scene.displayLink(target: self, selector: #selector(frame(_:)))
        } else {
            displayLink = scene.screen.displayLink(withTarget: self, selector: #selector(frame(_:)))
        }
        guard let link = displayLink else {
            return
        }
        let maximum = Float(max(1, scene.screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    func stop() {
        webSurface.stop()
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let display = GlassesDisplay.shared
        display.tick(link)
        if BrowserScreen.shared.active {
            drawBrowserFrame(link, display: display)
            return
        }
        drawSceneFrame(link, display: display)
    }

    // Web panels, plus the media player when a local file is open.
    private func drawBrowserFrame(_ link: CADisplayLink, display: GlassesDisplay) {
        webSurface.isHidden = display.nativeMedia.file != nil
        pattern.isHidden = true
        metalView?.isHidden = true
        let stereo = view.bounds.width / max(1, view.bounds.height) > 2.5
        let render = display.makeRenderFrame(link, stereo: stereo)
        webSurface.update(link, frame: render)
        drawNativeMedia(link, render: render, stereo: stereo, display: display)
    }

    // The test pattern or the tracked 3D scene, shown when the browser is closed.
    private func drawSceneFrame(_ link: CADisplayLink, display: GlassesDisplay) {
        if !webSurface.isHidden {
            webSurface.isHidden = true
            webSurface.stop()
        }
        liveStereoImages.clear()
        comparisonSurface.hideImages()
        nativeView?.isHidden = true
        mediaHUD.isHidden = true
        let useScene = display.showTrackedScene && metalView != nil
        pattern.isHidden = useScene
        metalView?.isHidden = !useScene
        if useScene, let metal = metalView, let renderer {
            let stereo = metal.drawableSize.width / max(1, metal.drawableSize.height) > 2.5
            renderer.frame = display.makeRenderFrame(link, stereo: stereo)
            metal.draw()
            if link.timestamp - lastReport >= 1 {
                display.updateRenderReport(
                    renderer, size: metal.drawableSize, stereo: stereo, live: renderer.frame.live)
                lastReport = link.timestamp
            }
        } else {
            pattern.split = display.splitPattern
            pattern.seconds = link.timestamp
            pattern.setNeedsDisplay()
        }
    }

    // Media is drawn one of four ways: a paused-frame comparison, a flat photo,
    // live 3D video as images, or the Metal renderer for everything else.
    private func drawNativeMedia(
        _ link: CADisplayLink, render: RenderFrame, stereo: Bool, display: GlassesDisplay
    ) {
        let media = display.nativeMedia
        if let comparison = media.comparison, media.comparisonRoute == .image {
            liveStereoImages.clear()
            nativeView?.isHidden = true
            comparisonSurface.show(
                comparison, eye: media.comparisonEye, stereo: stereo,
                visible: BrowserScreen.shared.workspace.visibleArea)
        } else if media.usesFlatPhotoSurface {
            showFlatPhoto(media, stereo: stereo)
        } else if media.usesLiveImagePresentation, media.comparison == nil {
            showLiveStereoVideo(media, link: link, stereo: stereo)
        } else {
            liveStereoImages.clear()
            comparisonSurface.hideImages()
            if media.file != nil, let nativeView, let nativeRenderer {
                nativeView.isHidden = false
                nativeRenderer.draw(
                    in: nativeView, session: media, render: render,
                    safeArea: BrowserScreen.shared.workspace.visibleArea, hostTime: link.targetTimestamp)
            } else if nativeView?.isHidden == false {
                nativeView?.isHidden = true
                nativeRenderer?.clear()
            }
        }
        mediaHUD.show(
            media.presentationHint(stereo: stereo, rendererUnavailable: display.nativeMediaRendererUnavailable),
            stereo: stereo, visibleArea: BrowserScreen.shared.workspace.visibleArea)
    }

    private func showFlatPhoto(_ media: NativeMediaSession, stereo: Bool) {
        liveStereoImages.clear()
        if nativeView?.isHidden == false {
            nativeRenderer?.clear()
        }
        nativeView?.isHidden = true
        guard let photo = media.photo else {
            comparisonSurface.hideImages()
            return
        }
        let eye: StereoEyePreview = media.arrangement == .mono ? .leftOnly : media.stereoEyePreview
        let size = view.window?.windowScene?.screen.currentMode?.size ?? view.bounds.size
        media.diagnostics.screen(size, stereo: stereo, eyes: eye, route: "Flat photo image surface")
        comparisonSurface.showPhoto(
            left: photo.0, right: photo.1, id: media.renderID, eye: eye,
            swapped: media.swapEyes, stereo: stereo, visible: BrowserScreen.shared.workspace.visibleArea)
    }

    private func showLiveStereoVideo(_ media: NativeMediaSession, link: CADisplayLink, stereo: Bool) {
        if nativeView?.isHidden == false {
            nativeRenderer?.clear()
        }
        nativeView?.isHidden = true
        let size = view.window?.windowScene?.screen.currentMode?.size ?? view.bounds.size
        media.diagnostics.screen(
            size, stereo: stereo, eyes: media.stereoEyePreview, route: "Live image surface")
        liveStereoImages.update(session: media, hostTime: link.targetTimestamp)
        if let frame = liveStereoImages.frame {
            comparisonSurface.show(
                frame, eye: media.stereoEyePreview, swapped: media.swapEyes,
                stereo: stereo, visible: BrowserScreen.shared.workspace.visibleArea)
        } else {
            comparisonSurface.hideImages()
        }
    }
}

/// Test pattern shown in the glasses when nothing else is open.
private final class PatternView: UIView {
    var split = false
    var seconds: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(bounds)
        let regions =
            split
            ? [
                CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height),
                CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
            ] : [bounds]
        for (index, region) in regions.enumerated() {
            context.saveGState()
            context.clip(to: region)
            context.setStrokeColor(UIColor(white: 0.25, alpha: 1).cgColor)
            context.setLineWidth(1)
            for step in 0...12 {
                let x = region.minX + CGFloat(step) / 12 * region.width
                let y = region.minY + CGFloat(step) / 12 * region.height
                context.move(to: CGPoint(x: x, y: region.minY))
                context.addLine(to: CGPoint(x: x, y: region.maxY))
                context.move(to: CGPoint(x: region.minX, y: y))
                context.addLine(to: CGPoint(x: region.maxX, y: y))
            }
            context.strokePath()
            context.setStrokeColor(UIColor.cyan.cgColor)
            context.setLineWidth(3)
            context.stroke(region.insetBy(dx: 6, dy: 6))
            let label = split ? (index == 0 ? "LEFT" : "RIGHT") : "EXTERNAL DISPLAY"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            (label as NSString).draw(at: CGPoint(x: region.minX + 24, y: region.minY + 24), withAttributes: attributes)
            context.setFillColor(UIColor.cyan.cgColor)
            let x = region.midX + sin(seconds * 2) * region.width * 0.25
            context.fillEllipse(in: CGRect(x: x - 10, y: region.midY - 10, width: 20, height: 20))
            context.restoreGState()
        }
    }
}
