import Foundation
import simd

/// The three commands sent to the adapter to start pose streaming.
enum StartupCommand: UInt16, CaseIterable {
    case prepare = 0x0212
    case identify = 0x0211
    case startPose = 0x0015

    var expectedReply: [UInt8]? {
        switch self {
        case .prepare:
            [0]
        case .identify:
            [0, 4, 0x11]
        case .startPose:
            nil
        }
    }

    func encode(timestamp: UInt64 = clock_gettime_nsec_np(CLOCK_REALTIME)) -> Data {
        let payload: [UInt8] = self == .startPose ? [1] : []
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0...1] = [0xff, 0xfe]
        bytes[4] = UInt8(12 + payload.count)
        for byte in 0..<8 {
            bytes[6 + byte] = UInt8(truncatingIfNeeded: timestamp >> (8 * byte))
        }
        bytes[14] = UInt8(truncatingIfNeeded: rawValue)
        bytes[15] = UInt8(rawValue >> 8)
        bytes.replaceSubrange(18..<(18 + payload.count), with: payload)
        let crc = AdapterFrame.checksum(bytes[4..<(18 + payload.count)])
        bytes[2] = UInt8(truncatingIfNeeded: crc)
        bytes[3] = UInt8(crc >> 8)
        return Data(bytes)
    }
}

/// One framed message from the adapter.
struct AdapterFrame {
    let id: UInt16
    let payload: [UInt8]
    private let bytes: [UInt8]

    init?(_ data: Data) {
        guard data.count == 64 else {
            return nil
        }
        let bytes = Array(data)
        let length = Int(bytes[4]) | Int(bytes[5]) << 8
        let crc = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        guard bytes[0] == 0xff, bytes[1] == 0xfd, (12...58).contains(length),
            Self.checksum(bytes[4..<(6 + length)]) == crc
        else {
            return nil
        }
        self.bytes = bytes
        id = UInt16(bytes[14]) | UInt16(bytes[15]) << 8
        payload = Array(bytes[18..<(6 + length)])
    }

    var pose: AdapterPose? {
        guard id == 0x0308, payload.count == 32 else {
            return nil
        }
        func bits(at offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func float(at offset: Int) -> Float {
            Float(bitPattern: bits(at: offset))
        }
        let orientation = simd_quatf(
            ix: -float(at: 46), iy: float(at: 34),
            iz: float(at: 38), r: -float(at: 42))
        guard orientation.length.isFinite, abs(orientation.length - 1) < 0.01 else {
            return nil
        }
        let tick = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[10 + $1]) << (8 * $1) }
        return AdapterPose(
            orientation: orientation.normalized, deviceMilliseconds: tick,
            packetEuler: SIMD3(float(at: 18), float(at: 22), float(at: 26)),
            packetQuaternion: SIMD4(bits(at: 46) ^ 0x80000000, bits(at: 34), bits(at: 38), bits(at: 42) ^ 0x80000000))
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc << 1) ^ (crc & 0x8000 == 0 ? 0 : 0x1021)
            }
        }
        return crc
    }
}

/// A decoded head orientation from the adapter.
public struct AdapterPose {
    public let orientation: simd_quatf
    public let deviceMilliseconds: UInt32
    /// The packet's original a0/a1/a2 values, in degrees. Used for diagnostics only.
    public var packetEuler: SIMD3<Float>? = nil

    var packetQuaternion: SIMD4<UInt32>? = nil
    var quaternionBits: SIMD4<UInt32> {
        if let packetQuaternion {
            return packetQuaternion
        }
        let components = orientation.vector
        return SIMD4(components.x.bitPattern, components.y.bitPattern, components.z.bitPattern, components.w.bitPattern)
    }
    func sameQuaternion(as previous: AdapterPose) -> Bool {
        quaternionBits == previous.quaternionBits
            || quaternionBits == (previous.quaternionBits ^ SIMD4(repeating: 0x80000000))
    }
    func sameOrientationPayload(as previous: AdapterPose) -> Bool {
        guard quaternionBits == previous.quaternionBits else {
            return false
        }
        switch (packetEuler, previous.packetEuler) {
        case (nil, nil):
            return true
        case let (current?, prior?):
            return current.x.bitPattern == prior.x.bitPattern && current.y.bitPattern == prior.y.bitPattern
                && current.z.bitPattern == prior.z.bitPattern
        default:
            return false
        }
    }

    // Decompose Rz(yaw) * Rx(a0) * Ry(a1). Physical pitch and roll are provisional.
    public static func angles(for orientation: simd_quatf) -> SIMD3<Float> {
        let matrix = simd_float3x3(orientation)
        let sine = max(-1, min(1, matrix.columns.1.z))
        let a0 = asin(sine)
        let a1: Float
        let yaw: Float
        if 1 - abs(sine) < 0.000001 {
            a1 = 0
            yaw = atan2(matrix.columns.0.y, matrix.columns.0.x)
        } else {
            a1 = atan2(-matrix.columns.0.z, matrix.columns.2.z)
            yaw = atan2(-matrix.columns.1.x, matrix.columns.1.y)
        }
        return SIMD3(yaw, a1, a0) * (180 / .pi)
    }
}
