import SpatialMath
import UIKit

// Web video converted to 3D in the glasses.
extension GlassesSurface {
    /// Shows the active screen's converted video, or releases it. Returns true
    /// while it is shown, so the screen's own panel stays hidden.
    func showConvertedVideo(
        active: BrowserScreen, wide: Bool, fullyExpanded: Bool, eye: CGSize, visible: CGRect, now: CFTimeInterval
    ) -> Bool {
        let conversion = active.conversion
        guard conversion.isShowing else {
            convertedVideo.releaseVideo()
            return false
        }
        let crop = active.media.mapping?.crop
        let layout = crop.flatMap { ConvertedVideoLayout(crop: $0, eyeSize: eye, visible: visible) }
        let blocker = conversionBlocker(active: active, wide: wide, fullyExpanded: fullyExpanded, layout: layout)
        active.depthCapture.setDisplayState(blocker ?? "shown")
        guard blocker == nil, let layout else {
            convertedVideo.releaseVideo()
            return false
        }
        // Before the first depth map, a flat mesh still gives both eyes the picture.
        let mesh = conversion.mesh(now: now) ?? .flat(columns: 2, rows: 2)
        convertedVideo.display(active, layout: layout, mesh: mesh)
        if let failure = convertedVideo.meshFailure {
            convertedVideo.releaseVideo()
            active.conversionUnavailable("3D conversion isn't available for web video here.", detail: failure)
            return false
        }
        return true
    }

    /// Why converted video can't be shown this frame, or nil when it can.
    private func conversionBlocker(
        active: BrowserScreen, wide: Bool, fullyExpanded: Bool, layout: ConvertedVideoLayout?
    ) -> String? {
        if !wide {
            return "glasses in 2D mode"
        }
        if !fullyExpanded {
            return browser.workspace.fullScreen ? "full screen opening" : "not full screen"
        }
        if active.stereoPacking != nil {
            return "packed 3D on"
        }
        if active.phonePageActive {
            return "page shown on phone"
        }
        if active.popup != nil {
            return "popup open"
        }
        if browser.workspace.calibratingVisibleArea {
            return "adjusting visible area"
        }
        if active.media.mapping == nil {
            return active.media.cinema ? "video view has no visible video" : "video view closed"
        }
        if layout == nil {
            return "no room for the video"
        }
        return nil
    }
}
