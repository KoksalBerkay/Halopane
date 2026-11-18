import Foundation

/// How strong 2D-to-3D depth is and where the screen plane sits.
public struct StereoDepthSettings: Equatable, Codable {
    /// 0 is flat and 1 is the strongest depth the comfort budget allows.
    public var strength: Float
    /// Lets the nearest objects come out in front of the screen instead of
    /// keeping almost everything behind it.
    public var popOut: Bool

    public init(strength: Float = 0.5, popOut: Bool = false) {
        self.strength = strength
        self.popOut = popOut
    }

    /// Largest parallax between the farthest and nearest point, as a fraction of
    /// one eye's picture width. About 4.5% keeps a 1920-pixel eye under 90 pixels
    /// of total spread, which stays comfortable in the glasses.
    public static let strongestParallax: Float = 0.045

    public var parallaxBudget: Float { Self.strongestParallax * min(max(strength, 0), 1) }

    /// Nearness that lands on the screen plane. Farther points sit behind it.
    public var convergence: Float { popOut ? 0.45 : 0.85 }
}

/// Horizontal parallax per vertex of a regular grid over the picture. Positive
/// values put a point behind the screen plane. Values are fractions of one eye's
/// picture width. The left eye moves each vertex by minus half its parallax and
/// the right eye by plus half.
public struct StereoDepthMesh: Equatable {
    public let columns: Int
    public let rows: Int
    public var parallax: [Float]

    /// Parallax fades to zero over this fraction of the width at the left and
    /// right edges. Objects cut by the frame edge then sit on the screen plane,
    /// and no gap opens at the border.
    public static let edgeTaper: Float = 0.04
    /// The smallest width a cell can shrink to, as a fraction of its rest width.
    /// Larger steps would fold the picture over itself.
    public static let minimumCellWidth: Float = 0.25

    public static func flat(columns: Int, rows: Int) -> StereoDepthMesh {
        StereoDepthMesh(columns: max(columns, 2), rows: max(rows, 2), parallax: [])
    }

    private init(columns: Int, rows: Int, parallax: [Float]) {
        self.columns = columns
        self.rows = rows
        self.parallax = parallax.count == columns * rows ? parallax : Array(repeating: 0, count: columns * rows)
    }

    public init(depth: DepthGrid, settings: StereoDepthSettings) {
        columns = depth.columns
        rows = depth.rows
        let budget = settings.parallaxBudget
        let convergence = settings.convergence
        var values = [Float](repeating: 0, count: columns * rows)
        let cell = 1 / Float(columns - 1)
        let step = 2 * (1 - Self.minimumCellWidth) * cell
        for row in 0..<rows {
            let start = row * columns
            for column in 0..<columns {
                let u = Float(column) * cell
                let taper = Self.smoothStep(u / Self.edgeTaper) * Self.smoothStep((1 - u) / Self.edgeTaper)
                values[start + column] = budget * (convergence - depth[column, row]) * taper
            }
            Self.limitSteps(&values, start: start, count: columns, step: step)
        }
        parallax = values
    }

    public subscript(column: Int, row: Int) -> Float { parallax[row * columns + column] }

    /// Where a vertex samples the source picture, from 0 to 1 on both axes.
    public func sourcePoint(column: Int, row: Int) -> SIMD2<Float> {
        SIMD2(Float(column) / Float(columns - 1), Float(row) / Float(rows - 1))
    }

    /// Where a vertex lands in one eye's picture. Eye 0 is the left eye.
    public func eyePoint(column: Int, row: Int, eye: Int) -> SIMD2<Float> {
        let half = self[column, row] / 2
        let source = sourcePoint(column: column, row: row)
        return SIMD2(source.x + (eye == 0 ? -half : half), source.y)
    }

    /// Moves part of the way toward another mesh of the same size.
    public func blended(toward target: StereoDepthMesh, fraction: Float) -> StereoDepthMesh {
        guard target.columns == columns, target.rows == rows else {
            return target
        }
        var out = self
        for index in out.parallax.indices {
            out.parallax[index] += (target.parallax[index] - out.parallax[index]) * fraction
        }
        return out
    }

    public func scaled(_ amount: Float) -> StereoDepthMesh {
        var out = self
        for index in out.parallax.indices {
            out.parallax[index] *= amount
        }
        return out
    }

    /// Limits the change between neighbours in one row, so no cell in either
    /// eye shrinks below `minimumCellWidth`. Both passes keep the result symmetric.
    static func limitSteps(_ values: inout [Float], start: Int, count: Int, step: Float) {
        guard count > 1 else {
            return
        }
        for index in (start + 1)..<(start + count) {
            values[index] = min(max(values[index], values[index - 1] - step), values[index - 1] + step)
        }
        for index in stride(from: start + count - 2, through: start, by: -1) {
            values[index] = min(max(values[index], values[index + 1] - step), values[index + 1] + step)
        }
    }

    static func smoothStep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Eases the shown mesh toward each new depth update and fades the effect in
/// and out, so depth never jumps on screen.
public struct StereoDepthAnimator {
    public static let fadeInSeconds: Float = 0.6
    public static let fadeOutSeconds: Float = 0.3
    /// Time constant for following a new depth map between model updates.
    public static let followSeconds: Float = 0.12

    public private(set) var amount: Float = 0
    public private(set) var enabled = false
    private var shown: StereoDepthMesh?
    private var target: StereoDepthMesh?

    public init() {}

    /// True once the effect has fully faded out after being turned off.
    public var finished: Bool { !enabled && amount <= 0 }

    public mutating func setEnabled(_ on: Bool) {
        enabled = on
    }

    /// A scene cut jumps straight to the new depth instead of easing into it.
    public mutating func setTarget(_ mesh: StereoDepthMesh, sceneCut: Bool) {
        target = mesh
        if sceneCut || shown == nil || shown?.columns != mesh.columns || shown?.rows != mesh.rows {
            shown = mesh
        }
    }

    public mutating func reset() {
        amount = 0
        enabled = false
        shown = nil
        target = nil
    }

    /// Advances by `seconds` and returns the mesh to draw, or nil when there is
    /// nothing to show yet or the effect has faded out.
    public mutating func advance(seconds: Float) -> StereoDepthMesh? {
        let dt = max(0, min(seconds, 0.25))
        if enabled {
            amount = min(1, amount + dt / Self.fadeInSeconds)
        } else {
            amount = max(0, amount - dt / Self.fadeOutSeconds)
        }
        if let current = shown, let target {
            shown = current.blended(toward: target, fraction: 1 - exp(-dt / Self.followSeconds))
        }
        guard let shown, amount > 0 else {
            return nil
        }
        return shown.scaled(StereoDepthMesh.smoothStep(amount))
    }
}
