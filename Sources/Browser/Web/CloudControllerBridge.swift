import GameController
import QuartzCore
import WebKit

/// Reads the system's paired controllers. No Bluetooth scanning or pairing.
final class CloudControllerBridge {
    private struct State: Equatable {
        let buttons: [Double]
        let axes: [Double]

        init(_ pad: GCExtendedGamepad) {
            func value(_ input: GCControllerButtonInput?) -> Double {
                Double(input?.value ?? 0)
            }
            // W3C standard order. GameController uses positive Y upwards;
            // the browser's standard layout uses negative Y upwards.
            buttons = [
                value(pad.buttonA), value(pad.buttonB), value(pad.buttonX), value(pad.buttonY),
                value(pad.leftShoulder), value(pad.rightShoulder), value(pad.leftTrigger), value(pad.rightTrigger),
                value(pad.buttonOptions), value(pad.buttonMenu), value(pad.leftThumbstickButton),
                value(pad.rightThumbstickButton),
                value(pad.dpad.up), value(pad.dpad.down), value(pad.dpad.left), value(pad.dpad.right),
                value(pad.buttonHome)
            ]
            func axis(_ input: GCControllerAxisInput, invert: Bool = false) -> Double {
                let reading = Double(input.value)
                // Discard stick noise without imposing a noticeable dead zone.
                guard abs(reading) >= 0.025 else {
                    return 0
                }
                return ((invert ? -reading : reading) * 1000).rounded() / 1000
            }
            axes = [
                axis(pad.leftThumbstick.xAxis), axis(pad.leftThumbstick.yAxis, invert: true),
                axis(pad.rightThumbstick.xAxis), axis(pad.rightThumbstick.yAxis, invert: true)
            ]
        }
    }

    private var controller: GCController?
    private var lastState: State?
    private var lastSend: CFTimeInterval = -.infinity
    private var lastPoll: CFTimeInterval = -.infinity
    private var outstanding: UUID?
    private var knownCount = 0
    private var attempts = 0
    private var forwarded = 0
    private var outcome = "not sampled"

    func update(web: WKWebView, now: CFTimeInterval) {
        // At most one frame in flight. Do not build a queue during a slow page.
        guard outstanding == nil, now - lastPoll >= 1.0 / 120 else {
            return
        }
        lastPoll = now
        let eligible = GCController.controllers().filter { !$0.isSnapshot && $0.extendedGamepad != nil }
        knownCount = eligible.count
        if let live = controller, !eligible.contains(where: { $0 === live }) {
            stop(web: web)
        }
        if controller == nil {
            controller =
                eligible.first { $0.productCategory.localizedCaseInsensitiveContains("Xbox") } ?? eligible.first
        }
        guard let pad = controller?.extendedGamepad else {
            outcome = "no extended gamepad"
            return
        }
        let state = State(pad)
        // Refresh held input while idle, so the page can release it if delivery stops.
        guard state != lastState || now - lastSend >= 0.4 else {
            return
        }

        lastState = state
        lastSend = now
        attempts += 1
        let token = UUID()
        outstanding = token
        web.callAsyncJavaScript(
            """
            return globalThis.__vxrCloudControllerUpdate?.(buttons,axes) ?? 'page bridge not installed';
            """, arguments: ["buttons": state.buttons, "axes": state.axes], in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.outstanding == token else {
                return
            }
            self.outstanding = nil
            self.outcome = (try? result.get()) as? String ?? "page bridge error"
            if self.outcome == "Spatial bridge" {
                self.forwarded += 1
            }
        }
    }

    func stop(web: WKWebView) {
        guard controller != nil || lastState != nil || outstanding != nil else {
            return
        }
        controller = nil
        lastState = nil
        lastSend = -.infinity
        outstanding = nil
        web.callAsyncJavaScript(
            "globalThis.__vxrCloudControllerUpdate?.(null,null);",
            arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    var report: String {
        let routing = controller == nil ? "inactive" : "active"
        return
            """
            Cloud controller: \(knownCount) paired extended gamepad(s) seen; \(routing); last result: \(outcome); \
            delivered \(forwarded) of \(attempts) updates via Spatial
            """
    }
}
