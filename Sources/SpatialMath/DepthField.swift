import Foundation

/// A coarse depth map sampled at mesh vertices, stored row by row from the top.
/// After `DepthFieldFilter`, values are nearness: 0 is the farthest part of the
/// picture and 1 the nearest.
public struct DepthGrid: Equatable {
    public let columns: Int
    public let rows: Int
    public var values: [Float]

    public init?(columns: Int, rows: Int, values: [Float]) {
        guard columns >= 2, rows >= 2, values.count == columns * rows else {
            return nil
        }
        self.columns = columns
        self.rows = rows
        self.values = values
    }

    public init(columns: Int, rows: Int, filling value: Float) {
        self.columns = max(columns, 2)
        self.rows = max(rows, 2)
        values = Array(repeating: value, count: self.columns * self.rows)
    }

    public subscript(column: Int, row: Int) -> Float {
        get {
            values[row * columns + column]
        }
        set {
            values[row * columns + column] = newValue
        }
    }

    /// Averages a full-size map around each vertex. `raw` holds `width * height`
    /// values row by row. Values that are not finite are skipped.
    public static func sampling(_ raw: [Float], width: Int, height: Int, columns: Int, rows: Int) -> DepthGrid? {
        guard width >= 2, height >= 2, raw.count == width * height, columns >= 2, rows >= 2 else {
            return nil
        }
        let reachX = max(1, width / (columns - 1) / 2)
        let reachY = max(1, height / (rows - 1) / 2)
        var values = [Float](repeating: 0, count: columns * rows)
        var previous: Float = 0
        for row in 0..<rows {
            let centerY = row * (height - 1) / (rows - 1)
            let ys = max(0, centerY - reachY)...min(height - 1, centerY + reachY)
            for column in 0..<columns {
                let centerX = column * (width - 1) / (columns - 1)
                let xs = max(0, centerX - reachX)...min(width - 1, centerX + reachX)
                var sum: Float = 0
                var count = 0
                for y in ys {
                    let start = y * width
                    for x in xs {
                        let value = raw[start + x]
                        if value.isFinite {
                            sum += value
                            count += 1
                        }
                    }
                }
                // A cell with no usable value repeats its neighbour, so it adds no false edge.
                if count > 0 {
                    previous = sum / Float(count)
                }
                values[row * columns + column] = previous
            }
        }
        return DepthGrid(columns: columns, rows: rows, values: values)
    }

    /// The grid as it looks after the picture is turned clockwise by `quarterTurns`.
    /// Matches the rotation the media shader applies to decoded frames.
    public func rotated(quarterTurns: UInt32) -> DepthGrid {
        let turns = quarterTurns % 4
        guard turns != 0 else {
            return self
        }
        let odd = turns % 2 == 1
        let outColumns = odd ? rows : columns
        let outRows = odd ? columns : rows
        var out = DepthGrid(columns: outColumns, rows: outRows, filling: 0)
        for row in 0..<outRows {
            for column in 0..<outColumns {
                let source: (column: Int, row: Int)
                switch turns {
                case 1:
                    source = (row, outColumns - 1 - column)
                case 2:
                    source = (columns - 1 - column, rows - 1 - row)
                default:
                    source = (outRows - 1 - row, column)
                }
                out[column, row] = self[source.column, source.row]
            }
        }
        return out
    }

    /// A light 3x3 blur. It keeps small errors in the model output from
    /// becoming sharp folds in the mesh.
    public func softened() -> DepthGrid {
        var out = self
        let weights: [Float] = [1, 2, 1]
        for row in 0..<rows {
            for column in 0..<columns {
                var sum: Float = 0
                var total: Float = 0
                for dy in -1...1 {
                    let y = min(max(row + dy, 0), rows - 1)
                    for dx in -1...1 {
                        let x = min(max(column + dx, 0), columns - 1)
                        let weight = weights[dx + 1] * weights[dy + 1]
                        sum += self[x, y] * weight
                        total += weight
                    }
                }
                out[column, row] = sum / total
            }
        }
        return out
    }
}

/// Turns raw model output into smoothed nearness from 0 to 1.
///
/// The model gives relative depth with no fixed scale, so each map is stretched
/// between its 2nd and 98th percentile. That range follows slowly, so the picture
/// does not breathe when something bright or close enters the frame.
public struct DepthFieldFilter {
    /// How much of each new map is used. The rest is the previous result.
    public var blend: Float = 0.5
    /// How quickly the stretch range follows a new map.
    public var rangeBlend: Float = 0.25
    public private(set) var current: DepthGrid?
    private var low: Float?
    private var high: Float?

    public init() {}

    public mutating func reset() {
        current = nil
        low = nil
        high = nil
    }

    /// Adds one raw map and returns the filtered nearness map. A scene cut
    /// starts over, so depth from the last shot does not linger.
    public mutating func add(_ raw: DepthGrid, sceneCut: Bool) -> DepthGrid {
        if sceneCut || current.map({ $0.columns != raw.columns || $0.rows != raw.rows }) == true {
            reset()
        }
        let sorted = raw.values.sorted()
        let newLow = Self.percentile(sorted, 0.02)
        let newHigh = Self.percentile(sorted, 0.98)
        let lowValue = low.map { $0 + (newLow - $0) * rangeBlend } ?? newLow
        let highValue = high.map { $0 + (newHigh - $0) * rangeBlend } ?? newHigh
        low = lowValue
        high = highValue
        var normalized = raw
        let span = highValue - lowValue
        for index in normalized.values.indices {
            if span > 1e-6 {
                normalized.values[index] = min(max((raw.values[index] - lowValue) / span, 0), 1)
            } else {
                // A picture with no depth sits in the middle of the range.
                normalized.values[index] = 0.5
            }
        }
        normalized = normalized.softened()
        if var previous = current {
            for index in previous.values.indices {
                previous.values[index] += (normalized.values[index] - previous.values[index]) * blend
            }
            current = previous
        } else {
            current = normalized
        }
        return current ?? normalized
    }

    static func percentile(_ sorted: [Float], _ fraction: Float) -> Float {
        guard !sorted.isEmpty else {
            return 0
        }
        let index = Int((Float(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

/// Detects a hard cut between two small grayscale thumbnails of the same size.
public enum SceneCut {
    /// Mean absolute difference, as a fraction of full scale, that counts as a cut.
    /// Ordinary motion and camera pans stay well below it.
    public static let threshold: Float = 0.14

    public static func isCut(previous: [UInt8], current: [UInt8]) -> Bool {
        guard !previous.isEmpty, previous.count == current.count else {
            return false
        }
        var total = 0
        for index in current.indices {
            total += abs(Int(current[index]) - Int(previous[index]))
        }
        return Float(total) / Float(current.count * 255) > threshold
    }
}
