import QuartzCore
import UIKit

// How the right eye gets its copy of the left eye in side-by-side mode.
extension GlassesSurface {
    /// The replicator draws the left eye's layers a second time for the right
    /// eye. On some pages, such as Pluto TV's catalogue, images go missing from
    /// that second drawing. A mesh draws the left eye once and shows the same
    /// picture in both halves, so the eyes cannot differ.
    func updateEyeCopy() {
        guard let replica, browser.backend == .replica else {
            return
        }
        let wide = bounds.width / max(1, bounds.height) > 2.5
        let useMesh = wide && browser.workspace.meshEyeCopy
        guard appliedMeshEyeCopy != useMesh else {
            return
        }
        let layer = replica.layer as! CAReplicatorLayer
        appliedMeshEyeCopy = useMesh
        if useMesh, let failure = applyEyeCopyMesh(to: layer) {
            browser.setEyeCopyStatus("Mesh unavailable (\(failure)); using the replicator")
            appliedMeshEyeCopy = false
            layer.instanceCount = 2
            return
        }
        if useMesh {
            layer.instanceCount = 1
            browser.setEyeCopyStatus("Mesh")
        } else {
            VXRClearLayerMesh(layer)
            layer.instanceCount = wide ? 2 : 1
            browser.setEyeCopyStatus("Replicator")
        }
    }

    // Two rectangles that both sample the left half: one drawn in place and one
    // moved into the right half. The layer itself must not clip; `left` clips inside it.
    private func applyEyeCopyMesh(to layer: CALayer) -> String? {
        let points: [VXRMeshPoint] = [0, 0.5].flatMap { offset in
            [
                VXRMeshPoint(fromX: 0, fromY: 0, toX: offset, toY: 0),
                VXRMeshPoint(fromX: 0.5, fromY: 0, toX: 0.5 + offset, toY: 0),
                VXRMeshPoint(fromX: 0.5, fromY: 1, toX: 0.5 + offset, toY: 1),
                VXRMeshPoint(fromX: 0, fromY: 1, toX: offset, toY: 1)
            ]
        }
        let quads: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 7]
        return points.withUnsafeBufferPointer { pointBuffer in
            quads.withUnsafeBufferPointer { quadBuffer in
                guard let pointBase = pointBuffer.baseAddress, let quadBase = quadBuffer.baseAddress else {
                    return "Empty mesh"
                }
                return VXRSetLayerMesh(layer, pointBase, pointBuffer.count, quadBase, 2)
            }
        }
    }
}
