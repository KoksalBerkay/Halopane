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
        guard wide, fullyExpanded, conversion.isShowing, active.stereoPacking == nil, !active.phonePageActive,
            active.popup == nil, !browser.workspace.calibratingVisibleArea,
            let crop = active.media.mapping?.crop,
            let layout = ConvertedVideoLayout(crop: crop, eyeSize: eye, visible: visible)
        else {
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
        if !active.depthCapture.meshShown {
            active.depthCapture.meshShown = true
            active.depthCapture.note("mesh shown")
        }
        return true
    }
}
