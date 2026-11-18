import XCTest
import SpatialMath

final class DepthGridTests: XCTestCase {
    func testSamplingAveragesAroundEachVertex() throws {
        // Left half 0, right half 10.
        let width = 20
        let height = 10
        let raw = (0..<height).flatMap { _ in (0..<width).map { $0 < 10 ? Float(0) : Float(10) } }
        let grid = try XCTUnwrap(DepthGrid.sampling(raw, width: width, height: height, columns: 3, rows: 2))
        XCTAssertEqual(grid[0, 0], 0)
        XCTAssertEqual(grid[2, 1], 10)
        // The middle vertex straddles the edge.
        XCTAssertGreaterThan(grid[1, 0], 0)
        XCTAssertLessThan(grid[1, 0], 10)
    }

    func testSamplingSkipsValuesThatAreNotFinite() throws {
        let raw: [Float] = [1, .nan, 1, 1, .infinity, 1, 1, 1, 1]
        let grid = try XCTUnwrap(DepthGrid.sampling(raw, width: 3, height: 3, columns: 2, rows: 2))
        XCTAssertTrue(grid.values.allSatisfy { $0 == 1 })
    }

    func testSamplingRejectsMismatchedSizes() {
        XCTAssertNil(DepthGrid.sampling([1, 2, 3], width: 2, height: 2, columns: 2, rows: 2))
        XCTAssertNil(DepthGrid(columns: 2, rows: 2, values: [1]))
    }

    // Values mark their source position, so each turn can be checked against the shader's mapping.
    func testRotationMatchesTheMediaShader() throws {
        let grid = try XCTUnwrap(DepthGrid(columns: 3, rows: 2, values: [0, 1, 2, 10, 11, 12]))
        XCTAssertEqual(grid.rotated(quarterTurns: 0), grid)
        let quarter = grid.rotated(quarterTurns: 1)
        XCTAssertEqual(quarter.columns, 2)
        XCTAssertEqual(quarter.rows, 3)
        // Shader turn 1: display (u, v) samples source (v, 1 - u).
        XCTAssertEqual(quarter[0, 0], grid[0, 1])
        XCTAssertEqual(quarter[1, 0], grid[0, 0])
        XCTAssertEqual(quarter[0, 2], grid[2, 1])
        let half = grid.rotated(quarterTurns: 2)
        XCTAssertEqual(half[0, 0], grid[2, 1])
        let three = grid.rotated(quarterTurns: 3)
        // Shader turn 3: display (u, v) samples source (1 - v, u).
        XCTAssertEqual(three[0, 0], grid[2, 0])
        XCTAssertEqual(three[1, 0], grid[2, 1])
        XCTAssertEqual(grid.rotated(quarterTurns: 1).rotated(quarterTurns: 3), grid)
    }

    func testSoftenedKeepsAFlatMapFlat() {
        let grid = DepthGrid(columns: 4, rows: 3, filling: 0.3)
        XCTAssertEqual(grid.softened().values.map { ($0 * 1000).rounded() }, grid.values.map { ($0 * 1000).rounded() })
    }
}

final class DepthFieldFilterTests: XCTestCase {
    private func ramp(_ scale: Float, offset: Float = 0) -> DepthGrid {
        let values = (0..<6).flatMap { _ in (0..<8).map { Float($0) * scale + offset } }
        return DepthGrid(columns: 8, rows: 6, values: values)!
    }

    func testOutputIsNearnessFromZeroToOne() {
        var filter = DepthFieldFilter()
        let out = filter.add(ramp(5, offset: 100), sceneCut: false)
        XCTAssertTrue(out.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertLessThan(out[0, 2], 0.2)
        XCTAssertGreaterThan(out[7, 2], 0.8)
    }

    // Raw scale does not matter, only the order of depths.
    func testScaleOfTheRawOutputDoesNotChangeTheResult() {
        var small = DepthFieldFilter()
        var large = DepthFieldFilter()
        let a = small.add(ramp(1), sceneCut: false)
        let b = large.add(ramp(40, offset: -7), sceneCut: false)
        for index in a.values.indices {
            XCTAssertEqual(a.values[index], b.values[index], accuracy: 0.001)
        }
    }

    func testNewMapsBlendInUnlessTheSceneCuts() {
        var filter = DepthFieldFilter()
        let first = filter.add(ramp(1), sceneCut: false)
        let flipped = DepthGrid(columns: 8, rows: 6, values: ramp(1).values.reversed())!
        let blended = filter.add(flipped, sceneCut: false)
        XCTAssertGreaterThan(blended[7, 3], 0.3)
        XCTAssertLessThan(blended[7, 3], first[7, 3])
        var cutFilter = DepthFieldFilter()
        _ = cutFilter.add(ramp(1), sceneCut: false)
        let cut = cutFilter.add(flipped, sceneCut: true)
        XCTAssertLessThan(cut[7, 3], 0.2)
    }

    func testFlatPictureSitsInTheMiddle() {
        var filter = DepthFieldFilter()
        let out = filter.add(DepthGrid(columns: 4, rows: 4, filling: 3), sceneCut: false)
        XCTAssertTrue(out.values.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }
}

final class SceneCutTests: XCTestCase {
    func testSmallChangesAreNotCuts() {
        let a = [UInt8](repeating: 100, count: 64)
        let b = [UInt8](repeating: 110, count: 64)
        XCTAssertFalse(SceneCut.isCut(previous: a, current: b))
    }

    func testLargeChangesAreCuts() {
        let a = [UInt8](repeating: 20, count: 64)
        let b = [UInt8](repeating: 200, count: 64)
        XCTAssertTrue(SceneCut.isCut(previous: a, current: b))
        XCTAssertFalse(SceneCut.isCut(previous: [], current: b))
    }
}

final class StereoDepthMeshTests: XCTestCase {
    private func depth(_ value: (Int, Int) -> Float, columns: Int = 33, rows: Int = 9) -> DepthGrid {
        let values = (0..<rows).flatMap { row in (0..<columns).map { value($0, row) } }
        return DepthGrid(columns: columns, rows: rows, values: values)!
    }

    func testFarPointsGoBehindAndNearPointsComeForwardWithPopOut() {
        let far = StereoDepthMesh(depth: depth { _, _ in 0 }, settings: StereoDepthSettings(strength: 1))
        XCTAssertGreaterThan(far[16, 4], 0)
        let near = StereoDepthMesh(
            depth: depth { _, _ in 1 }, settings: StereoDepthSettings(strength: 1, popOut: true))
        XCTAssertLessThan(near[16, 4], 0)
        let left = far.eyePoint(column: 16, row: 4, eye: 0)
        let right = far.eyePoint(column: 16, row: 4, eye: 1)
        XCTAssertGreaterThan(right.x, left.x)
        XCTAssertEqual(left.y, right.y)
    }

    func testParallaxStaysInsideTheComfortBudget() {
        let settings = StereoDepthSettings(strength: 1, popOut: true)
        let mesh = StereoDepthMesh(depth: depth { column, _ in column % 2 == 0 ? 0 : 1 }, settings: settings)
        let largest = mesh.parallax.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(largest, StereoDepthSettings.strongestParallax + 0.0001)
    }

    func testZeroStrengthIsFlat() {
        let mesh = StereoDepthMesh(depth: depth { column, _ in Float(column) / 32 }, settings: .init(strength: 0))
        XCTAssertTrue(mesh.parallax.allSatisfy { $0 == 0 })
    }

    func testFrameEdgesStayOnTheScreenPlane() {
        let mesh = StereoDepthMesh(depth: depth { _, _ in 0 }, settings: StereoDepthSettings(strength: 1))
        for row in 0..<mesh.rows {
            XCTAssertEqual(mesh[0, row], 0, accuracy: 0.0001)
            XCTAssertEqual(mesh[mesh.columns - 1, row], 0, accuracy: 0.0001)
        }
    }

    // A hard depth edge must not fold the picture: vertices stay in order in both eyes.
    func testVerticesStayInOrderInBothEyes() {
        let mesh = StereoDepthMesh(
            depth: depth({ column, _ in column < 6 ? 1 : 0 }, columns: 12, rows: 4),
            settings: StereoDepthSettings(strength: 1, popOut: true))
        let cell = 1 / Float(mesh.columns - 1)
        for eye in 0..<2 {
            for row in 0..<mesh.rows {
                for column in 1..<mesh.columns {
                    let gap =
                        mesh.eyePoint(column: column, row: row, eye: eye).x
                        - mesh.eyePoint(column: column - 1, row: row, eye: eye).x
                    XCTAssertGreaterThanOrEqual(gap, cell * StereoDepthMesh.minimumCellWidth - 0.0001)
                }
            }
        }
    }
}

final class StereoDepthAnimatorTests: XCTestCase {
    private let mesh = StereoDepthMesh(
        depth: DepthGrid(columns: 9, rows: 3, filling: 0), settings: StereoDepthSettings(strength: 1))

    func testFadesInAndOut() throws {
        var animator = StereoDepthAnimator()
        animator.setEnabled(true)
        animator.setTarget(mesh, sceneCut: false)
        let start = try XCTUnwrap(animator.advance(seconds: 0.05))
        XCTAssertLessThan(abs(start[4, 1]), abs(mesh[4, 1]))
        for _ in 0..<20 {
            _ = animator.advance(seconds: 0.05)
        }
        let full = try XCTUnwrap(animator.advance(seconds: 0.05))
        XCTAssertEqual(full[4, 1], mesh[4, 1], accuracy: 0.0001)
        animator.setEnabled(false)
        XCTAssertFalse(animator.finished)
        for _ in 0..<10 {
            _ = animator.advance(seconds: 0.05)
        }
        XCTAssertTrue(animator.finished)
        XCTAssertNil(animator.advance(seconds: 0.05))
    }

    func testEasesTowardNewDepthButJumpsOnACut() throws {
        var animator = StereoDepthAnimator()
        animator.setEnabled(true)
        animator.setTarget(StereoDepthMesh.flat(columns: 9, rows: 3), sceneCut: false)
        for _ in 0..<20 {
            _ = animator.advance(seconds: 0.05)
        }
        animator.setTarget(mesh, sceneCut: false)
        let eased = try XCTUnwrap(animator.advance(seconds: 0.016))
        XCTAssertGreaterThan(eased[4, 1], 0)
        XCTAssertLessThan(eased[4, 1], mesh[4, 1] * 0.5)
        animator.setTarget(StereoDepthMesh.flat(columns: 9, rows: 3), sceneCut: true)
        let jumped = try XCTUnwrap(animator.advance(seconds: 0.016))
        XCTAssertEqual(jumped[4, 1], 0, accuracy: 0.0001)
    }
}
