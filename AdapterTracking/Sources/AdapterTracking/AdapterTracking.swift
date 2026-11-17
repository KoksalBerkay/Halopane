import Combine
import CoreBluetooth
import Foundation
import QuartzCore

/// Connects to the glasses' Bluetooth adapter and streams head orientation.
public final class AdapterTracking: NSObject, ObservableObject {
    public struct Measurement {
        public let pose: AdapterPose
        public let receiveHz: Double
        public let packets: Int
        public let gapCount: Int
        public let lastInterval: UInt32?
        public let elapsed: TimeInterval
        public let recoveryAttempts: Int
        public let connection: Int
    }

    @Published public private(set) var status = "Disconnected"
    @Published public private(set) var measurement: Measurement?
    @Published public private(set) var active = false
    public let poses = PoseStore()

    private let queue = DispatchQueue(label: "Halopane.Bluetooth", qos: .userInteractive)
    private let service = CBUUID(string: "FFF0")
    private let notify = CBUUID(string: "FFF1")
    private let write = CBUUID(string: "FFF2")
    private let adapterName: String?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var pending: StartupCommand?
    private var writeAcknowledged = false
    private var expectedDataReceived = false
    private var deadline: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var monitor: DispatchSourceTimer?
    private var wantsConnection = false
    private var streaming = false
    private var retryDelay: Double = 1
    private var lastPoseAt: TimeInterval?
    private var firstArrival: TimeInterval?
    private var lastDisplay: TimeInterval = 0
    private var previousTick: UInt32?
    private var packets = 0
    private var gaps = 0
    private var recoveryAttempts = 0
    private var recoveryWrite: Int?
    private var restartAfterDisconnect = false
    private var restartDisconnectDeadline: DispatchWorkItem?
    private enum ManualReconnect { case idle, knownAdapter, scan }
    private var manualReconnect = ManualReconnect.idle
    private var knownAdapter: CBPeripheral?
    private var connection = 0
    private var publishedStatus = ""
    private var poseHandler: ((TimedPose) -> Void)?

    public override convenience init() {
        self.init(adapterName: nil)
    }

    public init(adapterName: String?) {
        self.adapterName = adapterName
        super.init()
    }

    static func matchesAdvertisement(_ name: String?, exact: String?) -> Bool {
        guard let name else {
            return false
        }
        if let exact {
            return name == exact
        }
        guard name.hasPrefix("R15_") else {
            return false
        }
        let suffix = name.utf8.dropFirst(4)
        return suffix.count == 6
            && suffix.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    public func setPoseHandler(_ handler: ((TimedPose) -> Void)?) {
        queue.async {
            self.poseHandler = handler
        }
    }

    public func connect() {
        queue.async {
            self.beginConnection()
        }
    }

    private func beginConnection(manual: Bool = false) {
        guard !wantsConnection, !restartAfterDisconnect else {
            return
        }
        wantsConnection = true
        retryDelay = 1
        reconnectWork?.cancel()
        resetCounters()
        DispatchQueue.main.async {
            self.measurement = nil
        }
        publish("Starting Bluetooth…", active: true)
        manualReconnect = manual ? .scan : .idle
        if manual, let central, central.state == .poweredOn, let knownAdapter, knownAdapter.state == .disconnected {
            manualReconnect = .knownAdapter
            poses.recordTrace("Manual Restart tracking: connecting to the known adapter")
            connectCandidate(knownAdapter, using: central)
        } else if let central {
            centralManagerDidUpdateState(central)
        } else {
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    public func restartTracking() {
        queue.async {
            guard !self.restartAfterDisconnect else {
                return
            }
            self.poses.recordTrace("Manual Restart tracking requested")
            self.wantsConnection = false
            self.reconnectWork?.cancel()
            self.clearSession()
            self.central?.stopScan()
            self.publish("Restarting tracking…", active: true)
            if let peripheral = self.peripheral, peripheral.state != .disconnected, let central = self.central {
                self.restartAfterDisconnect = true
                // A Bluetooth state change can delay or prevent the disconnect callback.
                // Keep the pending restart bounded even though no handshake is running.
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.restartAfterDisconnect else {
                        return
                    }
                    self.restartDisconnectDeadline = nil
                    self.restartAfterDisconnect = false
                    self.finishManualRecovery("Bluetooth did not confirm the disconnect")
                }
                self.restartDisconnectDeadline = timeout
                self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
                central.cancelPeripheralConnection(peripheral)
            } else {
                self.peripheral = nil
                self.beginConnection(manual: true)
            }
        }
    }

    public func disconnect() {
        queue.async {
            self.restartAfterDisconnect = false
            self.restartDisconnectDeadline?.cancel()
            self.restartDisconnectDeadline = nil
            self.manualReconnect = .idle
            self.wantsConnection = false
            self.reconnectWork?.cancel()
            self.clearSession()
            self.central?.stopScan()
            self.publish("Disconnected", active: false)
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func publish(_ message: String, active: Bool) {
        guard publishedStatus != message else {
            return
        }
        publishedStatus = message
        DispatchQueue.main.async {
            self.status = message
            self.active = active
        }
    }

    private func resetCounters() {
        packets = 0
        gaps = 0
        previousTick = nil
        firstArrival = nil
        lastDisplay = 0
        recoveryAttempts = 0
        poses.reset()
    }

    private func clearSession() {
        deadline?.cancel()
        deadline = nil
        monitor?.cancel()
        monitor = nil
        pending = nil
        recoveryWrite = nil
        streaming = false
        lastPoseAt = nil
        commandCharacteristic = nil
        poses.reset()
    }

    private func expectProgress(_ purpose: String, seconds: TimeInterval = 8) {
        deadline?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.retry("Timed out: \(purpose)")
        }
        deadline = task
        queue.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func retry(_ reason: String) {
        guard wantsConnection else {
            return
        }
        clearSession()
        central?.stopScan()
        publish("\(reason). Reconnecting…", active: true)
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        } else if manualReconnect != .idle {
            finishManualRecovery(reason)
        } else {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard wantsConnection else {
            return
        }
        reconnectWork?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, self.central?.state == .poweredOn else {
                return
            }
            self.startScan()
        }
        reconnectWork = task
        queue.asyncAfter(deadline: .now() + retryDelay, execute: task)
        retryDelay = min(retryDelay * 2, 8)
    }

    private func startScan() {
        guard let central, wantsConnection, peripheral == nil else {
            return
        }
        publish("Looking for a compatible adapter…", active: true)
        central.scanForPeripherals(withServices: nil)
        if manualReconnect == .scan {
            poses.recordTrace("Manual Restart tracking: waiting for adapter advertisement")
            expectProgress("restart adapter discovery", seconds: 12)
        } else {
            expectProgress("adapter discovery", seconds: 20)
        }
    }

    private func connectCandidate(_ candidate: CBPeripheral, using central: CBCentralManager) {
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        publish(manualReconnect == .knownAdapter ? "Reconnecting to adapter…" : "Connecting…", active: true)
        expectProgress(manualReconnect == .knownAdapter ? "direct restart connection" : "Bluetooth connection")
        central.connect(candidate)
    }

    private func finishManualRecovery(_ reason: String) {
        manualReconnect = .idle
        wantsConnection = false
        poses.recordTrace("Manual Restart tracking failed: " + reason)
        publish("Tracking unavailable. Unplug and reconnect the adapter, then tap Restart tracking.", active: false)
    }

    private func send(_ command: StartupCommand, to peripheral: CBPeripheral, recoveryAttempt: Int? = nil) {
        guard let characteristic = commandCharacteristic else {
            retry("FFF2 unavailable")
            return
        }
        let frame = command.encode()
        guard frame.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            wantsConnection = false
            clearSession()
            publish("Bluetooth write limit is below 64 bytes", active: false)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        pending = command
        writeAcknowledged = false
        expectedDataReceived = false
        publish(String(format: "Sent 0x%04X", command.rawValue), active: true)
        expectProgress("command response")
        recoveryWrite = recoveryAttempt
        if let recoveryAttempt {
            poses.recordTrace("Recovery write sent (attempt \(recoveryAttempt), connection \(connection))")
        }
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)
    }

    private func advanceIfReady(_ peripheral: CBPeripheral) {
        guard let pending, writeAcknowledged, expectedDataReceived else {
            return
        }
        switch pending {
        case .prepare:
            send(.identify, to: peripheral)
        case .identify:
            send(.startPose, to: peripheral)
        case .startPose:
            deadline?.cancel()
            deadline = nil
            self.pending = nil
            streaming = true
            if manualReconnect != .idle {
                poses.recordTrace("Manual Restart tracking: orientation stream started on connection \(connection)")
                manualReconnect = .idle
            }
            retryDelay = 1
            publish("Receiving orientation", active: true)
            startMonitor()
        }
    }

    private func startMonitor() {
        monitor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.streaming, self.pending == nil,
                let last = self.lastPoseAt, CACurrentMediaTime() - last > 1,
                let peripheral = self.peripheral, peripheral.state == .connected
            else {
                return
            }
            self.recoveryAttempts += 1
            if let sample = self.poses.snapshot() {
                let q = sample.pose.orientation.vector
                let raw = [q.x, q.y, q.z, q.w].map { String(format: "%.6f", $0) }.joined(separator: ",")
                self.poses.recordTrace(
                    """
                    Watchdog detected stall: connection \(self.connection), last pose at \
                    \(String(format:"%.3f",last)), tick \(sample.pose.deviceMilliseconds), q \(raw)
                    """
                )
            }
            self.send(.startPose, to: peripheral, recoveryAttempt: self.recoveryAttempts)
        }
        monitor = timer
        timer.resume()
    }

    private func record(_ pose: AdapterPose, arrival: TimeInterval) {
        lastPoseAt = arrival
        let sample = poses.update(pose, arrivalTime: arrival, connection: connection)
        poseHandler?(sample)
        if firstArrival == nil {
            firstArrival = arrival
        }
        let interval = previousTick.map { pose.deviceMilliseconds &- $0 }
        if let interval, interval > 24 {
            gaps += 1
        }
        previousTick = pose.deviceMilliseconds
        packets += 1
        guard arrival - lastDisplay >= 0.1 else {
            return
        }
        lastDisplay = arrival
        let elapsed = arrival - (firstArrival ?? arrival)
        let value = Measurement(
            pose: pose, receiveHz: elapsed > 0 ? Double(packets - 1) / elapsed : 0,
            packets: packets, gapCount: gaps, lastInterval: interval,
            elapsed: elapsed, recoveryAttempts: recoveryAttempts, connection: connection)
        DispatchQueue.main.async {
            self.measurement = value
        }
    }
}

extension AdapterTracking: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard wantsConnection else {
            return
        }
        switch central.state {
        case .poweredOn:
            if peripheral == nil {
                startScan()
            }
        case .unauthorized:
            wantsConnection = false
            clearSession()
            publish("Allow Bluetooth for LiveContainer in iPhone Settings", active: false)
        case .poweredOff, .resetting:
            clearSession()
            publish("Waiting for Bluetooth…", active: true)
        case .unknown:
            publish("Starting Bluetooth…", active: true)
        default:
            wantsConnection = false
            clearSession()
            publish("Bluetooth is unavailable", active: false)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard wantsConnection, self.peripheral == nil, Self.matchesAdvertisement(name, exact: adapterName) else {
            return
        }
        if manualReconnect == .scan {
            poses.recordTrace("Manual Restart tracking: adapter advertisement found")
        }
        connectCandidate(peripheral, using: central)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard wantsConnection, peripheral === self.peripheral else {
            return
        }
        knownAdapter = peripheral
        previousTick = nil
        connection += 1
        if manualReconnect != .idle {
            poses.recordTrace("Manual Restart tracking: Bluetooth connected; starting handshake")
        }
        publish("Discovering adapter service…", active: true)
        expectProgress("adapter service discovery")
        peripheral.discoverServices([service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishDisconnect(peripheral, error: error)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        finishDisconnect(peripheral, error: error)
    }

    private func finishDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else {
            return
        }
        self.peripheral = nil
        clearSession()
        if restartAfterDisconnect {
            restartAfterDisconnect = false
            restartDisconnectDeadline?.cancel()
            restartDisconnectDeadline = nil
            poses.recordTrace("Manual Restart tracking: disconnect completed")
            beginConnection(manual: true)
            return
        }
        guard wantsConnection else {
            return
        }
        switch manualReconnect {
        case .knownAdapter:
            poses.recordTrace("Manual Restart tracking: direct connection ended; trying a scan")
            manualReconnect = .scan
            if central?.state == .poweredOn {
                startScan()
            } else {
                finishManualRecovery("Bluetooth unavailable before fallback scan")
            }
            return
        case .scan:
            finishManualRecovery(error?.localizedDescription ?? "Scanned adapter disconnected during startup")
            return
        case .idle:
            break
        }
        publish("\(error?.localizedDescription ?? "Disconnected"). Reconnecting…", active: true)
        scheduleReconnect()
    }
}

extension AdapterTracking: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard wantsConnection, peripheral === self.peripheral else {
            return
        }
        guard error == nil, let adapterService = peripheral.services?.first(where: { $0.uuid == service }) else {
            retry(error?.localizedDescription ?? "FFF0 service missing")
            return
        }
        peripheral.discoverCharacteristics([notify, write], for: adapterService)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    {
        guard wantsConnection, peripheral === self.peripheral else {
            return
        }
        guard error == nil,
            let input = service.characteristics?.first(where: { $0.uuid == write && $0.properties.contains(.write) }),
            let output = service.characteristics?.first(where: { $0.uuid == notify && $0.properties.contains(.notify) })
        else {
            retry(error?.localizedDescription ?? "FFF1 or FFF2 unavailable")
            return
        }
        commandCharacteristic = input
        peripheral.setNotifyValue(true, for: output)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard wantsConnection, peripheral === self.peripheral, characteristic.uuid == notify else {
            return
        }
        guard error == nil, characteristic.isNotifying else {
            retry(error?.localizedDescription ?? "FFF1 subscription failed")
            return
        }
        send(.prepare, to: peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    {
        guard wantsConnection, peripheral === self.peripheral, characteristic.uuid == write, pending != nil else {
            return
        }
        if let attempt = recoveryWrite {
            let details = (error as NSError?).map { "\($0.domain)/\($0.code)" } ?? "ok"
            poses.recordTrace(
                "Recovery write acknowledgement (attempt \(attempt), connection \(connection)): " + details)
            recoveryWrite = nil
        }
        if let error {
            retry("FFF2 write failed: \(error.localizedDescription)")
            return
        }
        writeAcknowledged = true
        advanceIfReady(peripheral)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        let arrival = CACurrentMediaTime()
        guard wantsConnection, peripheral === self.peripheral, characteristic.uuid == notify else {
            return
        }
        if let error {
            retry("FFF1 update failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, let frame = AdapterFrame(data) else {
            return
        }
        if let pending, let expected = pending.expectedReply, frame.id == pending.rawValue {
            guard frame.payload == expected else {
                retry("Unexpected startup reply")
                return
            }
            expectedDataReceived = true
            advanceIfReady(peripheral)
        }
        if let pose = frame.pose, pending == .startPose || streaming {
            record(pose, arrival: arrival)
            if pending == .startPose {
                expectedDataReceived = true
                advanceIfReady(peripheral)
            }
        }
    }
}
