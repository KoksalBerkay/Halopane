import SpatialMath
import UIKit

/// Shows web video converted to 3D. The page stays live: a mesh on `meshHost`
/// draws the video once per eye, with each vertex moved sideways by its depth.
/// No video pixels are copied, so the picture keeps its quality and frame rate.
final class ConvertedVideoMount: UIView {
    private let meshHost = UIView()
    // Clips the page to the video. The meshed layer itself must not clip, or the
    // right eye's copy, which lies outside its bounds, would be cut off.
    private let videoClip = UIView()
    private weak var session: BrowserScreen?
    private var lastLayout: ConvertedVideoLayout?
    private var lastMesh: StereoDepthMesh?
    private var quads: [UInt32] = []
    private var quadGrid = (columns: 0, rows: 0)
    /// Why the last mesh could not be set, or nil when it was.
    private(set) var meshFailure: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        videoClip.clipsToBounds = true
        meshHost.addSubview(videoClip)
        addSubview(meshHost)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    func display(_ panel: BrowserScreen, layout: ConvertedVideoLayout, mesh: StereoDepthMesh) {
        let needsMount = session !== panel || panel.web.superview !== videoClip
        if needsMount {
            releaseVideo()
            session = panel
            videoClip.addSubview(panel.web)
        }
        isHidden = false
        if needsMount || layout != lastLayout {
            lastLayout = layout
            lastMesh = nil
            meshHost.frame = layout.fitted
            videoClip.frame = meshHost.bounds
            let web = panel.web
            web.transform = .identity
            web.bounds = CGRect(x: 0, y: 0, width: 1000, height: 625)
            web.transform = CGAffineTransform(scaleX: layout.scale, y: layout.scale)
            web.center = layout.pageCenter
        }
        guard mesh != lastMesh else {
            return
        }
        lastMesh = mesh
        applyMesh(mesh, rightEyeOffset: Float(layout.rightEyeOffset))
    }

    func releaseVideo() {
        guard session != nil || !isHidden else {
            return
        }
        if let session {
            if session.web.superview === videoClip {
                session.web.removeFromSuperview()
                session.web.transform = .identity
            }
            session.setDrawingStereoVideo(false)
        }
        VXRClearLayerMesh(meshHost.layer)
        session = nil
        isHidden = true
        lastLayout = nil
        lastMesh = nil
    }

    private func applyMesh(_ mesh: StereoDepthMesh, rightEyeOffset: Float) {
        if quadGrid != (mesh.columns, mesh.rows) {
            quads = mesh.layerQuads()
            quadGrid = (mesh.columns, mesh.rows)
        }
        let points = mesh.layerPoints(rightEyeOffset: rightEyeOffset).map {
            VXRMeshPoint(fromX: $0.x, fromY: $0.y, toX: $0.z, toY: $0.w)
        }
        meshFailure = points.withUnsafeBufferPointer { pointBuffer in
            quads.withUnsafeBufferPointer { quadBuffer in
                guard let pointBase = pointBuffer.baseAddress, let quadBase = quadBuffer.baseAddress else {
                    return "Empty mesh"
                }
                return VXRSetLayerMesh(meshHost.layer, pointBase, pointBuffer.count, quadBase, quadBuffer.count / 4)
            }
        }
    }
}
