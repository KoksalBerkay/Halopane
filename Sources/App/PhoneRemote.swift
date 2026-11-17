import Combine
import CoreMotion
import Foundation
import QuartzCore
import SpatialMath
import SwiftUI
import UIKit
import simd

/// Uses the iPhone's motion sensors to aim a pointer in the glasses.
final class PhoneRemote: ObservableObject {
    /// One motion reading from the phone.
    struct Sample {
        let orientation: simd_quatf
        let arrival: TimeInterval
        let sourceTime: TimeInterval
        let gravity: SIMD3<Float>
        let steadySince: TimeInterval?
    }
    @Published private(set) var enabled = false
    @Published private(set) var aimReady = false
    @Published private(set) var status = "Phone controller is off."
    @Published var invertOrientation = false {
        didSet {
            clearAim()
        }
    }
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Halopane.PhoneController"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var latest: Sample?
    private var generation = UUID()
    private var aim: PhoneAim?
    private var spatialAim: SpatialPhoneAim?
    private var observers = [NSObjectProtocol]()

    init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.enabled else {
                    return
                }
                self.stop(disable: false)
                self.status = "Motion paused."
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.enabled else {
                    return
                }
                self.start()
            })
    }

    deinit {
        motion.stopDeviceMotionUpdates()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        guard !motion.isDeviceMotionActive else {
            return
        }
        guard motion.isDeviceMotionAvailable else {
            status = "Phone motion is unavailable. Check LiveContainer's Motion & Fitness access."
            return
        }
        enabled = true
        clearAim()
        let session = UUID()
        lock.lock()
        generation = session
        latest = nil
        lock.unlock()
        status = "Reading phone motion."
        motion.deviceMotionUpdateInterval = 0.01
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, error in
            guard let self else {
                return
            }
            if let error {
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = self.generation == session
                    self.lock.unlock()
                    guard current else {
                        return
                    }
                    self.stop()
                    self.status = "Motion error: " + error.localizedDescription
                }
                return
            }
            guard let data else {
                return
            }
            let attitude = data.attitude.quaternion
            let rotation = simd_quatf(
                ix: Float(attitude.x), iy: Float(attitude.y), iz: Float(attitude.z), r: Float(attitude.w))
            guard rotation.length.isFinite, rotation.length > 0.001 else {
                return
            }
            let now = CACurrentMediaTime()
            let rate = data.rotationRate
            let slow = rate.x * rate.x + rate.y * rate.y + rate.z * rate.z < 0.12 * 0.12
            self.lock.lock()
            if self.generation == session {
                self.latest = Sample(
                    orientation: rotation.normalized, arrival: now, sourceTime: data.timestamp,
                    gravity: SIMD3(Float(data.gravity.x), Float(data.gravity.y), Float(data.gravity.z)),
                    steadySince: slow ? self.latest?.steadySince ?? now : nil)
            }
            self.lock.unlock()
        }
    }

    func stop(disable: Bool = true) {
        motion.stopDeviceMotionUpdates()
        lock.lock()
        generation = UUID()
        latest = nil
        lock.unlock()
        if disable {
            enabled = false
        }
        clearAim()
        status = "Phone controller is off."
    }

    func snapshot() -> Sample? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return latest
    }

    private func fresh() -> Sample? {
        guard let sample = snapshot(), CACurrentMediaTime() - sample.arrival < 0.25 else {
            return nil
        }
        return sample
    }

    private func orientation(_ sample: Sample) -> simd_quatf {
        invertOrientation ? sample.orientation.inverse : sample.orientation
    }

    @discardableResult
    func calibrate(camera: simd_quatf) -> Bool {
        guard let sample = fresh() else {
            status = "Waiting for phone motion. Allow Motion access, then tap Aim phone again."
            return false
        }
        aim = PhoneAim(reference: orientation(sample), camera: camera)
        aimReady = true
        status = "Ready. Move the phone to aim; tap to select and swipe to scroll."
        return true
    }

    var settledForSpatialAim: Bool {
        guard let sample = fresh(), let since = sample.steadySince else {
            return false
        }
        return sample.arrival - since >= 0.3
    }

    @discardableResult
    func calibrateSpatial(target: simd_quatf) -> Bool {
        guard let sample = fresh() else {
            return false
        }
        spatialAim = SpatialPhoneAim(reference: orientation(sample), target: target)
        aimReady = true
        status = "Phone aimed."
        return true
    }

    func spatialRay() -> PointerRay? {
        guard let sample = fresh() else {
            return nil
        }
        return spatialAim?.ray(orientation: orientation(sample))
    }

    func clearAim() {
        aim = nil
        spatialAim = nil
        aimReady = false
        if enabled {
            status = "Aim again to align the phone with the scene."
        }
    }

    func ray() -> PointerRay? {
        guard let sample = fresh(), let aim else {
            return nil
        }
        return aim.ray(orientation: orientation(sample))
    }

    var report: String {
        var text =
            "Phone controller enabled: \(enabled), calibrated: \(aimReady), inverted: \(invertOrientation)\n\(status)"
        if let sample = snapshot() {
            text += String(
                format: "\nPhone sample arrival age: %.1f ms", (CACurrentMediaTime() - sample.arrival) * 1000)
            let down = SIMD3<Float>(0, 0, -1)
            text += String(
                format: "\nGravity consistency raw/inverse: %.4f / %.4f",
                simd_length(sample.orientation.act(sample.gravity) - down),
                simd_length(sample.orientation.inverse.act(sample.gravity) - down))
        }
        return text
    }
}
