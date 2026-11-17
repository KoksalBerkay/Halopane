import Foundation
import simd

/// One vertex of a line in the 3D scene.
public struct LineVertex {
    public var position: SIMD3<Float>
    public var color: SIMD4<Float>
    public init(_ position: SIMD3<Float>, _ color: SIMD4<Float>) {
        self.position = position
        self.color = color
    }
}

/// Builds the floor grid and horizon for the 3D scene.
public enum SceneGeometry {
    public static func world() -> [LineVertex] {
        var vertices = [LineVertex]()
        func line(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ color: SIMD4<Float>) {
            vertices.append(LineVertex(start, color))
            vertices.append(LineVertex(end, color))
        }
        let grid = SIMD4<Float>(0.08, 0.25, 0.3, 1)
        // Fixed eye position at (0,0,0); ground 1.5 m below it. This is 3DoF.
        for step in -24...24 {
            let coordinate = Float(step) * 0.5
            line(SIMD3(coordinate, -1.5, -12), SIMD3(coordinate, -1.5, 12), grid)
            line(SIMD3(-12, -1.5, coordinate), SIMD3(12, -1.5, coordinate), grid)
        }
        // Distant horizontal ring approximates an infinite horizon.
        for step in 0..<360 {
            let startAngle = Float(step) * .pi / 180
            let endAngle = Float(step + 1) * .pi / 180
            line(
                SIMD3(sin(startAngle) * 1000, 0, -cos(startAngle) * 1000),
                SIMD3(sin(endAngle) * 1000, 0, -cos(endAngle) * 1000), SIMD4(0.9, 0.65, 0.2, 1))
        }
        // Eye-height markers on a 1.5 m radius, spaced every 15 degrees of yaw.
        for degrees in stride(from: -180, to: 180, by: 15) {
            let angle = Float(degrees) * .pi / 180
            let direction = SIMD3<Float>(sin(angle), 0, -cos(angle))
            let right = SIMD3<Float>(cos(angle), 0, sin(angle))
            let center = direction * 1.5
            let color = degrees == 0 ? SIMD4<Float>(0, 1, 1, 1) : SIMD4<Float>(0.8, 0.9, 1, 1)
            line(center - right * 0.025, center + right * 0.025, color)
            line(center - SIMD3(0, 0.035, 0), center + SIMD3(0, 0.035, 0), color)
            let label = degrees > 0 ? "+\(degrees)" : "\(degrees)"
            vertices += text(
                label, center: center + SIMD3(0, 0.095, 0), right: right,
                up: SIMD3(0, 1, 0), height: 0.045, color: color)
        }
        // Forward square is at 1.5 m, with visible stereo disparity.
        let cyan = SIMD4<Float>(0, 0.8, 0.8, 1)
        let corners: [SIMD3<Float>] = [
            SIMD3(-0.18, -0.18, -1.5), SIMD3(0.18, -0.18, -1.5),
            SIMD3(0.18, 0.18, -1.5), SIMD3(-0.18, 0.18, -1.5)
        ]
        for i in corners.indices {
            line(corners[i], corners[(i + 1) % 4], cyan)
        }
        return vertices
    }

    // Constant clip-space overlay: crosshair stays at each eye's screen center.
    public static func overlay(live: Bool, aspect: Float) -> [LineVertex] {
        let color = live ? SIMD4<Float>(1, 1, 1, 1) : SIMD4<Float>(1, 0.4, 0.1, 1)
        let x: Float = 0.012
        let y = x * aspect
        return [
            LineVertex(SIMD3(-x, 0, 0), color), LineVertex(SIMD3(x, 0, 0), color),
            LineVertex(SIMD3(0, -y, 0), color), LineVertex(SIMD3(0, y, 0), color)
        ]
    }

    public static func text(
        _ string: String, center: SIMD3<Float>, right: SIMD3<Float>,
        up: SIMD3<Float>, height: Float, color: SIMD4<Float>
    ) -> [LineVertex] {
        // Seven-segment vector labels need no font textures or per-frame CPU drawing.
        let segments: [(start: SIMD2<Float>, end: SIMD2<Float>)] = [
            (SIMD2(0, 1), SIMD2(0.5, 1)), (SIMD2(0.5, 1), SIMD2(0.5, 0.5)),
            (SIMD2(0.5, 0.5), SIMD2(0.5, 0)), (SIMD2(0.5, 0), SIMD2(0, 0)),
            (SIMD2(0, 0), SIMD2(0, 0.5)), (SIMD2(0, 0.5), SIMD2(0, 1)),
            (SIMD2(0, 0.5), SIMD2(0.5, 0.5)), (SIMD2(0.25, 0.25), SIMD2(0.25, 0.75))
        ]
        let digits: [Character: [Int]] = [
            "0": [0, 1, 2, 3, 4, 5], "1": [1, 2], "2": [0, 1, 6, 4, 3], "3": [0, 1, 6, 2, 3],
            "4": [5, 6, 1, 2], "5": [0, 5, 6, 2, 3], "6": [0, 5, 6, 4, 2, 3],
            "7": [0, 1, 2], "8": [0, 1, 2, 3, 4, 5, 6], "9": [0, 1, 2, 3, 5, 6], "-": [6], "+": [6, 7]
        ]
        let width = (Float(string.count) * 0.75 - 0.25) * height
        var result = [LineVertex]()
        for (index, character) in string.enumerated() {
            for segment in digits[character] ?? [] {
                for point in [segments[segment].start, segments[segment].end] {
                    let position =
                        center + right * (Float(index) * 0.75 * height + point.x * height - width / 2)
                        + up * ((point.y - 0.5) * height)
                    result.append(LineVertex(position, color))
                }
            }
        }
        return result
    }
}
