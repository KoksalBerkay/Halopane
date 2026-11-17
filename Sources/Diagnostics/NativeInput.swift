import Combine
import Darwin
import Foundation
import QuartzCore
import SwiftUI
import UIKit
import WebKit

// Observations only: no handler can ask the native bridge to execute an action.
final class NativeInput: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = NativeInput()
    enum Engine: String, CaseIterable, Identifiable {
        case dom = "DOM baseline", window = "Synthetic UIWindow", application = "Synthetic UIApplication"
        var id: String { rawValue }
    }
    @Published var engine: Engine = .window
    @Published var freezePanel = false
    @Published private(set) var phoneHosted = false
    @Published private(set) var keyboardVisible = false
    @Published private(set) var status = "Synthetic input has not been attempted."
    @Published private(set) var running = false
    @Published private(set) var eventSummary = "No page events recorded"
    static let phoneSourceSize = CGSize(width: 1280, height: 800)
    let phoneContent = UIView(frame: CGRect(origin: .zero, size: NativeInput.phoneSourceSize))
    weak var web: WKWebView?
    var onHostChange: ((Bool) -> Void)?
    private var observers = [NSObjectProtocol]()
    private var events = [[String: Any]]()
    private var totals = [String: Int]()
    private var logs = [String]()
    private var archives = [String]()
    private var attemptContext = "No automatic attempt"
    private var capabilities = "Not queried"
    private var token = UUID()
    private var priorFreeze: Bool?
    private var scrollDelta: Float = 0
    private var keyboardFrame = "Not observed"
    private var phoneScroll: UIScrollView?
    private var momentum: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var previousFrame: CFTimeInterval = 0
    private var holdActive = false
    private var holdAttempt: UUID?
    private var geometryBeforeRun = "Not sampled"
    private var geometryAfterFocus = "Not sampled"
    private var geometryBeforeFocus = "Not sampled"

    override init() {
        super.init()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.cancel("Input check interrupted by app deactivation.")
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] note in
                self?.keyboardVisible = true
                self?.keyboardFrame = String(
                    describing: (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.keyboardVisible else {
                        return
                    }
                    self.captureGeometry {
                        self.geometryAfterFocus = $0
                    }
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.keyboardVisible = false
            })
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func install(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.eventScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(self, name: "vxrInputProbe")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, kind.count < 50 else {
            return
        }
        // Whitelist metadata; never retain key values, text, initData or license payloads.
        var clean = [String: Any]()
        for field in [
            "kind", "trusted", "active", "tag", "inputType", "editable", "audioState", "playResult", "encryptedType"
        ] {
            if let value = body[field] as? String {
                clean[field] = String(value.prefix(100))
            } else if let value = body[field] as? Bool {
                clean[field] = value
            }
        }
        clean["receivedUptime"] = CACurrentMediaTime()
        clean["mainFrame"] = message.frameInfo.isMainFrame
        clean["host"] = ReportSite.label(message.frameInfo.request.url)
        let sourceWindow = message.webView?.window
        clean["hostWindow"] = sourceWindow?.windowScene?.session.role.rawValue ?? "unattached"
        clean["view"] = message.webView === web ? "main" : "popup"
        clean["selectedEngine"] = engine.rawValue
        let trust = (body["trusted"] as? Bool) == true ? "trusted" : "untrusted/unspecified"
        totals[kind + " · " + trust, default: 0] += 1
        events.append(clean)
        events = Array(events.suffix(100))
        eventSummary = totals.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
    func log(_ text: String) {
        logs.append("\(Date().ISO8601Format()) \(text)")
        logs = Array(logs.suffix(80))
        status = text
    }
    func setPhoneHost(_ enabled: Bool) {
        archive("Source host changing")
        cancel("Source host changed")
        guard phoneHosted != enabled else {
            return
        }
        phoneHosted = enabled
        if let web {
            web.removeFromSuperview()
            if enabled {
                phoneContent.addSubview(web)
                web.frame = phoneContent.bounds
                web.contentScaleFactor = 2
                web.layer.transform = CATransform3DIdentity
            }
        }
        onHostChange?(enabled)
        log(
            enabled
                ? "Source moved to interactive phone window; glasses now use portals for both eyes."
                : "Source returned to external window.")
    }
    func archive(_ reason: String) {
        guard !events.isEmpty || !logs.isEmpty else {
            return
        }
        archives.append("\(Date().ISO8601Format()) · \(reason)\n" + currentEvidence)
        archives = Array(archives.suffix(10))
        events = []
        totals = [:]
        logs = []
        eventSummary = "No events since the last context change"
    }
    func cancel(_ reason: String) {
        let wasRunning = running
        restoreRunState()
        if wasRunning {
            log(reason)
        }
    }
    private func restoreRunState() {
        token = UUID()
        if let priorFreeze {
            freezePanel = priorFreeze
        }
        priorFreeze = nil
        running = false
        scrollDelta = 0
        stopPhoneScroll()
        holdActive = false
        holdAttempt = nil
    }
    private func endRun(_ message: String) {
        restoreRunState()
        log(message)
    }
    func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    func injectTap(_ point: CGPoint, completion: (() -> Void)? = nil) {
        guard let web else {
            endRun("Web source detached")
            return
        }
        stopPhoneScroll()
        let attempt = token
        capabilities = VXRInputCapabilities()
        VXRInjectGesture(web, point, point, 0.065, false, engine == .application, false) { [weak self] result in
            guard let self, self.token == attempt else {
                return
            }
            guard result.hasPrefix("Dispatch calls completed") else {
                self.endRun(result)
                return
            }
            self.log(result)
            completion?()
        }
    }
    func run() {
        guard !running, let web, web.url?.isFileURL == true, web.url?.lastPathComponent == "web-probe.html" else {
            log("Load the bundled page for the automatic input check. Provider interaction is manual.")
            return
        }
        archive("New input attempt")
        capabilities = VXRInputCapabilities()
        if capabilities.hasPrefix("Unavailable") {
            log(capabilities)
            return
        }
        attemptContext =
            """
            Backend \(BrowserScreen.shared.backend.rawValue), source \(web.url?.lastPathComponent ?? "none"), host \
            \(phoneHosted ? "phone":"external")
            """
        dismissKeyboard()
        geometryBeforeRun = "Pending"
        geometryAfterFocus = "No keyboard geometry sampled yet"
        geometryBeforeFocus = "Pending"
        if engine == .dom {
            engine = .application
        }
        priorFreeze = freezePanel
        freezePanel = true
        running = true
        events = []
        totals = [:]
        eventSummary = "Starting controlled input check"
        let run = UUID()
        token = run
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.token == run, self.running else {
                return
            }
            self.endRun("Input check timed out; previous tracking mode restored.")
        }
        log(
            """
            Starting \(phoneHosted ? "phone-window":"external-window") check via \(engine.rawValue); panel \
            temporarily head-locked to keep targets in bounds.
            """
        )
        captureGeometry { [weak self] evidence in
            guard let self, self.token == run else {
                return
            }
            self.geometryBeforeRun = evidence
        }
        // DOM control uses the same activation handler, to expose permissive autoplay policy.
        web.evaluateJavaScript(
            "window.scrollTo(0,0);document.getElementById('activation').click()", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tapWidget("count", run: run) { [weak self] in
                self?.tapWidget("activation", run: run) { [weak self] in
                    self?.panThenFocus(run: run)
                }
            }
        }
    }
    private func tapWidget(_ id: String, run: UUID, completion: @escaping () -> Void) {
        guard token == run, running else {
            return
        }
        guard let web else {
            endRun("Web source detached")
            return
        }
        WebFixtureLocator.locate(id, in: web) { [weak self] result in
            guard let self, self.token == run else {
                return
            }
            guard case .success(let point) = result else {
                if case .failure(let error) = result {
                    self.endRun("Fixture lookup for \(id): \(error.localizedDescription)")
                }
                return
            }
            if id == "entry" {
                self.captureGeometry { [weak self] evidence in
                    guard let self, self.token == run else {
                        return
                    }
                    self.geometryBeforeFocus = evidence
                    self.tapLocatedWidget(point, run: run, completion: completion)
                }
            } else {
                self.tapLocatedWidget(point, run: run, completion: completion)
            }
        }
    }
    private func tapLocatedWidget(_ point: CGPoint, run: UUID, completion: @escaping () -> Void) {
        injectTap(point) { [weak self] in
            guard self?.token == run else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard self?.token == run else {
                    return
                }
                completion()
            }
        }
    }
    private func panThenFocus(run: UUID) {
        guard token == run else {
            return
        }
        guard let web else {
            endRun("Web source detached")
            return
        }
        let focus: () -> Void = { [weak self] in
            self?.tapWidget("entry", run: run) { [weak self] in
                guard let self, self.token == run else {
                    return
                }
                self.endRun("Input check finished. Tracking restored to its previous mode.")
                if !self.keyboardVisible {
                    BrowserScreen.shared.offerPhoneEditor()
                }
            }
        }
        // The phone-hosted path tests scrolling with a real two-finger drag afterwards.
        if phoneHosted {
            focus()
            return
        }
        let before = web.scrollView.contentOffset.y
        VXRInjectGesture(
            web, CGPoint(x: 650, y: 480), CGPoint(x: 650, y: 140), 0.32, true, engine == .application, false
        ) { [weak self] result in
            guard let self, self.token == run else {
                return
            }
            self.log(result)
            self.log("External pan offset: before=\(before), after end=\(web.scrollView.contentOffset.y)")
            focus()
        }
    }

    func sourcePoint(_ canonical: SIMD2<Float>) -> CGPoint? {
        guard let web else {
            return nil
        }
        return CGPoint(
            x: CGFloat(canonical.x) * web.bounds.width / 1000,
            y: CGFloat(canonical.y) * web.bounds.height / 625)
    }

    @discardableResult
    func beginPhoneScroll(at point: CGPoint) -> Bool {
        stopPhoneScroll()
        guard let web, web.window != nil, web.bounds.contains(point) else {
            return false
        }
        // Hit-test the source subtree, since the phone window correctly hits the opaque trackpad.
        var candidate = web.hitTest(point, with: nil)
        while let view = candidate {
            if let scroll = view as? UIScrollView, canScroll(scroll) {
                phoneScroll = scroll
                log(
                    "Direct scroll target: "
                        + (scroll === web.scrollView ? "page" : "inner " + NSStringFromClass(scroll.classForCoder)))
                return true
            }
            if view === web {
                break
            }
            candidate = view.superview
        }
        guard canScroll(web.scrollView) else {
            return false
        }
        phoneScroll = web.scrollView
        log("Direct scroll target: page")
        return true
    }

    private func limits(_ scroll: UIScrollView) -> ClosedRange<CGFloat> {
        let inset = scroll.adjustedContentInset
        let minimum = -inset.top
        return minimum...max(minimum, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
    }
    private func canScroll(_ scroll: UIScrollView) -> Bool {
        let range = limits(scroll)
        return range.upperBound - range.lowerBound > 1
    }
    @discardableResult
    func drivePhoneScroll(_ delta: CGFloat) -> Bool {
        guard let scroll = phoneScroll, let web, scroll.isDescendant(of: web), scroll.window === web.window,
            scroll.window != nil
        else {
            return false
        }
        let range = limits(scroll)
        let old = scroll.contentOffset
        let y = min(max(old.y + delta, range.lowerBound), range.upperBound)
        scroll.setContentOffset(CGPoint(x: old.x, y: y), animated: false)
        return abs(old.y - y) > 0.01
    }
    func endPhoneScroll(velocity: CGFloat) {
        guard phoneScroll != nil, momentum == nil, abs(velocity) > 40 else {
            stopPhoneScroll()
            return
        }
        momentumVelocity = min(max(velocity, -3600), 3600)
        previousFrame = 0
        let link = CADisplayLink(target: self, selector: #selector(scrollFrame(_:)))
        momentum = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func scrollFrame(_ link: CADisplayLink) {
        let elapsed = previousFrame == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - previousFrame
        previousFrame = link.timestamp
        let dt = min(max(elapsed, 0), 0.05)
        momentumVelocity *= exp(-5 * dt)
        if abs(momentumVelocity) < 15 || (dt > 0 && !drivePhoneScroll(momentumVelocity * dt)) {
            stopPhoneScroll()
        }
    }
    func stopPhoneScroll() {
        momentum?.invalidate()
        momentum = nil
        phoneScroll = nil
    }

    func startHoldControl() {
        guard phoneHosted, !running, holdAttempt == nil, let web,
            web.url?.isFileURL == true, web.url?.lastPathComponent == "web-probe.html"
        else {
            return
        }
        let attempt = UUID()
        holdAttempt = attempt
        holdActive = true
        WebFixtureLocator.locate("count", in: web) { [weak self] result in
            guard let self, self.holdAttempt == attempt, self.holdActive else {
                return
            }
            guard case .success(let point) = result else {
                self.holdAttempt = nil
                self.log("Hold control could not locate counter: \(result)")
                return
            }
            self.log("Testing a fresh event routed only to the phone window while the trackpad finger is held.")
            VXRInjectGesture(web, point, point, 0.065, false, false, true) { [weak self] result in
                guard let self, self.holdAttempt == attempt else {
                    return
                }
                self.holdAttempt = nil
                self.log(result + " | trackpad hold still active at completion: \(self.holdActive)")
            }
        }
    }
    func releaseHoldControl() {
        holdActive = false
    }

    private func captureGeometry(_ completion: @escaping (String) -> Void) {
        guard let web, let window = web.window else {
            completion("Source detached")
            return
        }
        let rect = web.convert(web.bounds, to: window)
        let screenRect = window.convert(rect, to: window.screen.coordinateSpace)
        let native = """
            source=\(web.bounds.size), frame in window=\(rect), frame on screen=\(screenRect), \
            requested scale=\(phoneHosted ? 2 : 1), view/layer scale=\(web.contentScaleFactor)/\(web.layer.contentsScale), \
            screen scale=\(window.screen.scale), process footprint=\(Self.footprint())
            """
        web.evaluateJavaScript(
            """
            JSON.stringify({
                visibility: document.visibilityState,
                dpr: devicePixelRatio,
                inner: [innerWidth, innerHeight],
                visual: visualViewport
                    ? [visualViewport.width, visualViewport.height, visualViewport.offsetTop, visualViewport.scale]
                    : null,
                scroll: [scrollX, scrollY],
                video: document.querySelector('video')?.currentTime
            })
            """
        ) { value, error in
            completion(native + "; " + ((value as? String) ?? error?.localizedDescription ?? "No page geometry"))
        }
    }
    private static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS
            ? String(format: "%.1f MiB (app process only)", Double(info.phys_footprint) / 1048576) : "Unavailable"
    }
    func popupObserved(_ url: URL?) {
        log(
            """
            WKUIDelegate popup request observed: \(ReportSite.label(url)); \
            intentionally no new window. This signal is compared against the DOM control.
            """
        )
    }
    var report: String { currentEvidence + "\nArchived input contexts\n" + archives.joined(separator: "\n\n") }
    private var currentEvidence: String {
        let eventJSON =
            (try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "[]"
        return """
            Native input experiment
            Attempt context: \(attemptContext)
            Engine: \(engine.rawValue); source host: \
            \(phoneHosted ? "interactive phone":"external non-interactive scene")
            Panel head-locked for input: \(freezePanel)
            Capabilities: \(capabilities)
            Last native bridge action: \(UserDefaults.standard.string(forKey:"viture.xr.input.lastAction.v1") ?? "None")
            Before input: \(geometryBeforeRun)
            Before field tap: \(geometryBeforeFocus)
            After keyboard opened: \(geometryAfterFocus)
            Keyboard notification visible: \(keyboardVisible); frame: \(keyboardFrame)
            No typed characters or DRM payloads are logged by this module.
            \(eventSummary)
            Recent page event metadata: \(eventJSON)
            Dispatch observations
            \(logs.joined(separator:"\n"))
            A returned dispatch call does not prove delivery. Focus events alone do not prove user activation.
            Public media baseline requires no playback gesture; unmuted play alone is not proof of activation.
            """
    }
    static var eventScript: String {
        guard let path = Bundle.main.url(forResource: "input-observer", withExtension: "js"),
            let script = try? String(contentsOf: path, encoding: .utf8)
        else {
            return ""
        }
        return script
    }
}
