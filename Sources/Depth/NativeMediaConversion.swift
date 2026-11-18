import Foundation

// 2D-to-3D in the Spatial Player.
extension NativeMediaSession {
    /// Conversion needs a flat picture that holds a single eye.
    var supportsConversion: Bool { projection == .flat && arrangement == .mono && !detectedStereo }
    var canConvertTo3D: Bool { file != nil && error == nil && supportsConversion }

    func toggleConversion() {
        if conversion.isActive {
            conversion.stop()
        } else if canConvertTo3D {
            conversion.start()
        }
    }

    func stopConversionIfUnsupported() {
        if !supportsConversion {
            conversion.stop()
        }
    }

    /// Status shown on the phone and in the glasses while 3D is on.
    func conversionHint(stereo: Bool) -> String? {
        guard conversion.isActive else {
            return nil
        }
        if let failure = conversion.failure {
            return failure
        }
        if !stereo {
            return "Switch the glasses to 3D mode to see depth."
        }
        if conversion.phase == .preparing {
            return "Preparing 3D…"
        }
        return nil
    }
}
