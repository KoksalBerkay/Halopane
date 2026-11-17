import Foundation
import simd

/// Lines and fill for the demo panel and its pointer.
public struct InteractionMesh {
    public let fill: [LineVertex]
    public let lines: [LineVertex]
}

/// Builds the demo panel mesh for the 3D scene.
public enum InteractionGeometry {
    public static func mesh(_ frame: InteractionFrame) -> InteractionMesh {
        let z: Float = -DemoPanel.depth
        let left: Float = -DemoPanel.width / 2
        let right = -left
        let top: Float = DemoPanel.height / 2
        let bottom = -top
        let dark = SIMD4<Float>(0.015, 0.025, 0.035, 1)
        let corners = [
            SIMD3<Float>(left, bottom, z), SIMD3<Float>(right, bottom, z),
            SIMD3<Float>(right, top, z), SIMD3<Float>(left, top, z)
        ]
        let fill = [0, 1, 2, 0, 2, 3].map { LineVertex(corners[$0], dark) }
        var lines = [LineVertex]()
        func line(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ color: SIMD4<Float>) {
            lines.append(LineVertex(start, color))
            lines.append(LineVertex(end, color))
        }
        func rect(x0: Float, x1: Float, y0: Float, y1: Float, color: SIMD4<Float>) {
            let points = [SIMD3(x0, y0, z), SIMD3(x1, y0, z), SIMD3(x1, y1, z), SIMD3(x0, y1, z)]
            for i in 0..<4 {
                line(points[i], points[(i + 1) % 4], color)
            }
        }
        let teal = SIMD4<Float>(0, 0.8, 0.85, 1)
        rect(x0: left, x1: right, y0: bottom, y1: top, color: teal)
        let hovered = frame.ray.flatMap { frame.panel.hit($0) }
        let first = Int(floor(frame.panel.scrollOffset))
        let header = "\(first + 1)-\(min(first + 3, DemoPanel.rowCount))"
        lines += SceneGeometry.text(
            header, center: SIMD3(0, 0.275, z), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), height: 0.035, color: teal)
        for index in first..<min(first + 4, DemoPanel.rowCount) {
            let rowTop = DemoPanel.contentTop - (Float(index) - frame.panel.scrollOffset) * DemoPanel.rowHeight
            let rowBottom = rowTop - DemoPanel.rowHeight
            let clippedTop = min(rowTop, DemoPanel.contentTop)
            let clippedBottom = max(rowBottom, DemoPanel.contentBottom)
            guard clippedTop > clippedBottom else {
                continue
            }
            let color: SIMD4<Float>
            if hovered == index {
                color = SIMD4(1, 0.85, 0.15, 1)
            } else if frame.panel.lastSelected == index {
                color = SIMD4(0.2, 1, 0.5, 1)
            } else {
                color = SIMD4(0.35, 0.55, 0.65, 1)
            }
            rect(x0: -0.4, x1: 0.4, y0: clippedBottom, y1: clippedTop, color: color)
            let centerY = (rowTop + rowBottom) / 2
            if centerY - 0.035 >= DemoPanel.contentBottom, centerY + 0.035 <= DemoPanel.contentTop {
                lines += SceneGeometry.text(
                    "\(index + 1)", center: SIMD3(-0.27, centerY, z), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                    height: 0.06, color: color)
                lines += SceneGeometry.text(
                    "\(frame.panel.counts[index])", center: SIMD3(0.25, centerY, z), right: SIMD3(1, 0, 0),
                    up: SIMD3(0, 1, 0), height: 0.06, color: color)
            }
        }
        // A proportional scroll indicator is independent of row label clipping.
        line(SIMD3(0.425, -0.26, z), SIMD3(0.425, 0.22, z), SIMD4(0.2, 0.4, 0.5, 1))
        let thumbTop = 0.22 - frame.panel.scrollOffset / Float(DemoPanel.rowCount) * 0.48
        line(SIMD3(0.425, thumbTop, z), SIMD3(0.425, thumbTop - 0.072, z), SIMD4(1, 1, 1, 1))
        if let ray = frame.ray {
            var center = DemoPanel.intersection(ray) ?? ray.direction * DemoPanel.depth
            if simd_length(center) > 10 {
                center = ray.direction * DemoPanel.depth
            }
            center.z += 0.005
            let color = hovered == nil ? SIMD4<Float>(0, 1, 1, 1) : SIMD4<Float>(1, 0.85, 0.15, 1)
            for step in 0..<24 {
                let startAngle = Float(step) * 2 * .pi / 24
                let endAngle = Float(step + 1) * 2 * .pi / 24
                line(
                    center + SIMD3(cos(startAngle) * 0.018, sin(startAngle) * 0.018, 0),
                    center + SIMD3(cos(endAngle) * 0.018, sin(endAngle) * 0.018, 0), color)
            }
        }
        return InteractionMesh(fill: fill, lines: lines)
    }
}
