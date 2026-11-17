import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

extension BrowserScreen {
    func beginWorkspaceScroll() {
        guard active, !selectedSession.panelWarming, selectedSession.popup == nil, signInSession == nil else {
            return
        }
        let number = workspace.inputRoute.beginDrag()
        guard let panel = session(number) else {
            return
        }
        recordInput("Scroll → Panel \(number)")
        panel.beginScroll()
    }
    func scrollWorkspace(_ delta: Float) {
        guard let number = workspace.inputRoute.dragPanel, number == selectedPanel else {
            return
        }
        session(number)?.scroll(delta)
    }
    func endWorkspaceScroll(_ velocity: CGFloat) {
        guard let number = workspace.inputRoute.finishDrag(), number == selectedPanel else {
            return
        }
        session(number)?.endScroll(velocity)
    }
    func cancelWorkspaceScroll() {
        let number = workspace.inputRoute.dragPanel ?? selectedPanel
        workspace.inputRoute.cancelDrag()
        session(number)?.cancelScroll()
    }
    private var isShortsPage: Bool {
        guard let url = web.url,
            ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(url.host?.lowercased() ?? "")
        else {
            return false
        }
        return url.path == "/shorts" || url.path.hasPrefix("/shorts/")
    }
    func traceShorts(_ step: String) {
        scroll.shortsTrace.append(step)
        if scroll.shortsTrace.count > 24 {
            scroll.shortsTrace.removeFirst()
        }
    }
    func cancelScroll() {
        if scroll.shortsDrag != .none {
            traceShorts("Gesture cancelled before dispatch")
        }
        scroll.generation = UUID()
        scroll.ready = false
        scroll.inFlight = false
        scroll.catalogGesture = false
        scroll.catalogTouchSwipe = false
        scroll.catalogScroll = false
        scroll.pendingScroll = 0
        scroll.nativeScroll = false
        scroll.hasScrolledNatively = false
        scroll.origin = nil
        scroll.shortsDrag = .none
        scroll.shortsEnded = false
        scroll.releaseVelocity = nil
        native.stopPhoneScroll()
    }

    func noteCatalogScroll(_ state: String) {
        guard scroll.catalogScrollTrace.last != state else {
            return
        }
        scroll.catalogScrollTrace.append(state)
        if scroll.catalogScrollTrace.count > 12 {
            scroll.catalogScrollTrace.removeFirst()
        }
    }

    /// Starts a scroll drag. Routes, in order: Shorts swipe, GeForce NOW touch swipe,
    /// direct scroll view offsets, then JavaScript.
    func beginScroll() {
        cancelScroll()
        let useCatalog = CloudGamingService.page(web.url) == .geforceNow
        if useCatalog {
            noteCatalogScroll("swipe")
        }
        if isShortsPage {
            scroll.shortsTraceID = UUID()
            scroll.shortsStartURL = web.url
            scroll.shortsStartPath = web.url?.path
            traceShorts("Gesture began on Shorts")
        }
        clearWebSelection()
        guard receivesInput, !isCinema, !phonePageActive,
            let point = effectiveInput == .trackpad ? cursor : effectiveCursor,
            point.y >= 0, !bookmarksOpen, !historyOpen, !moreOpen
        else {
            if isShortsPage {
                traceShorts("No eligible scroll target (cursor, panel or menu)")
            }
            if useCatalog {
                noteCatalogScroll("no eligible cursor or panel")
            }
            return
        }
        if let top = fullChromeY, owner.showsFullChrome(at: CACurrentMediaTime()), point.y < top + chromeInset {
            if useCatalog {
                noteCatalogScroll("over toolbar")
            }
            return
        }
        scroll.origin = point
        scroll.catalogGesture = useCatalog
        if isShortsPage {
            beginShortsScroll(at: point)
            return
        }
        if useCatalog, workspace.scrollEngine == .native, beginCatalogTouchSwipe(at: point) {
            return
        }
        beginOffsetOrScriptScroll(at: point, useCatalog: useCatalog)
    }

    // Ask the page whether the cursor is over a Short or over a scrollable panel such as comments.
    private func beginShortsScroll(at point: SIMD2<Float>) {
        scroll.shortsDrag = .probing
        let generation = scroll.generation
        web.callAsyncJavaScript(
            "return globalThis.vxrShortsRoute(x,y);",
            arguments: ["x": Double(point.x) / 1000, "y": Double(point.y) / 625], in: nil, in: scrollWorld
        ) { [weak self] result in
            guard let self, self.scroll.generation == generation else {
                return
            }
            let route = (try? result.get()) as? String ?? "probe-error"
            self.traceShorts("Route: " + route)
            if route == "reel" {
                self.scroll.shortsDrag = .step
                if self.scroll.shortsEnded {
                    self.finishShortsSwipe()
                }
            } else {
                self.scroll.shortsDrag = .none
                self.beginScriptScroll(at: point)
            }
        }
    }

    /// Returns true when this GeForce NOW drag will be sent as a synthetic touch swipe.
    private func beginCatalogTouchSwipe(at point: SIMD2<Float>) -> Bool {
        let page = web.scrollView
        let fromTop = page.contentOffset.y + page.adjustedContentInset.top
        // The top of the catalog fights direct offsets. Let WebKit handle
        // the drag there, and keep ordinary continuous scrolling below it.
        guard page.bounds.height > 0, fromTop < page.bounds.height * 0.85 else {
            return false
        }
        scroll.catalogTouchSwipe = true
        // The catalogue's mandatory scroll snap pulls the page back after a swipe.
        web.callAsyncJavaScript(
            "return globalThis.vxrUnsnapCatalog(x,y);",
            arguments: ["x": Double(point.x) / 1000, "y": Double(point.y) / 625], in: nil,
            in: scrollWorld, completionHandler: nil)
        scroll.lastRoute = "GeForce NOW touch swipe"
        noteCatalogScroll("touch route (page offset \(String(format:"%.0f",fromTop)) pt)")
        return true
    }

    // Prefer moving the scroll view directly. Fall back to JavaScript when there is no native target.
    private func beginOffsetOrScriptScroll(at point: SIMD2<Float>, useCatalog: Bool) {
        if workspace.scrollEngine == .native, let sourcePoint = native.sourcePoint(point),
            native.beginPhoneScroll(at: sourcePoint)
        {
            scroll.nativeScroll = true
            scroll.lastRoute = useCatalog ? "GeForce NOW native offset" : "Native offset"
            if useCatalog {
                noteCatalogScroll("native ready")
            }
        } else {
            if useCatalog {
                noteCatalogScroll(workspace.scrollEngine == .native ? "no native target" : "script preferred")
            }
            beginScriptScroll(at: point, useCatalog: useCatalog)
        }
    }

    private func beginScriptScroll(at point: SIMD2<Float>, useCatalog: Bool = false) {
        scroll.catalogScroll = useCatalog
        if useCatalog {
            scroll.lastRoute = "GeForce NOW catalog"
        } else if workspace.scrollEngine == .native {
            scroll.lastRoute = "JavaScript fallback"
        } else {
            scroll.lastRoute = "JavaScript"
        }
        let generation = scroll.generation
        web.callAsyncJavaScript(
            """
            globalThis.vxrScrollStart(x,y,catalog);
            return true;
            """, arguments: ["x": Double(point.x) / 1000, "y": Double(point.y) / 625, "catalog": useCatalog], in: nil,
            in: scrollWorld
        ) { [weak self] result in
            guard let self, self.scroll.generation == generation else {
                return
            }
            if case .success = result {
                self.scroll.ready = true
                if self.scroll.catalogScroll {
                    self.noteCatalogScroll("ready")
                } else {
                    self.flushScroll()
                }
            } else if case .failure(let error) = result {
                if self.scroll.catalogScroll {
                    self.noteCatalogScroll("start failed")
                }
                self.inputStatus = "Scroll target unavailable: " + error.localizedDescription
                self.showNotice("Could not scroll this region.")
                self.cancelScroll()
            }
        }
    }

    func scroll(_ delta: Float) {
        guard delta.isFinite, scroll.origin != nil else {
            return
        }
        scroll.pendingScroll = min(max(scroll.pendingScroll - Double(delta) * Double(scrollGain), -2400), 2400)
        if !scroll.nativeScroll, !scroll.catalogScroll, !scroll.catalogTouchSwipe, scroll.shortsDrag == .none {
            flushScroll()
        }
    }

    func endScroll(_ velocity: CGFloat) {
        if isShortsPage {
            traceShorts("Gesture ended")
        }
        if scroll.shortsDrag != .none {
            scroll.shortsEnded = true
            if scroll.shortsDrag == .step {
                finishShortsSwipe()
            }
            return
        }
        if scroll.catalogTouchSwipe {
            finishCatalogTouchSwipe()
            return
        }
        guard scroll.nativeScroll, scroll.origin != nil else {
            return
        }
        scroll.releaseVelocity = velocity.isFinite ? -velocity * scrollGain : 0
    }

    private func finishCatalogTouchSwipe() {
        let point = scroll.origin.flatMap { native.sourcePoint($0) }
        let delta = scroll.pendingScroll
        cancelScroll()
        guard let point, let page = web.url, let window = web.window,
            let swipe = WebPanelMath.verticalTouchSwipe(from: point, in: web.bounds, scrollDelta: delta)
        else {
            noteCatalogScroll("touch skipped (short drag or invalid source)")
            return
        }
        guard window.bounds.contains(web.convert(swipe.start, to: window)),
            window.bounds.contains(web.convert(swipe.end, to: window))
        else {
            noteCatalogScroll("touch outside display")
            return
        }
        // Deliver accepted catalogue swipes in order. WebKit should finish the
        // current touch before receiving one that may go the other way.
        let request = QueuedTap(
            session: self, point: swipe.start, generation: tapGeneration,
            useApplicationRoute: native.engine == .application,
            swipeEnd: swipe.end, catalogPage: page)
        if Self.tapQueue.enqueue(request) {
            noteCatalogScroll(delta > 0 ? "touch queued down" : "touch queued up")
            drainTaps()
        } else {
            noteCatalogScroll("touch queue full")
        }
    }

    private func finishShortsSwipe() {
        let delta = scroll.pendingScroll
        let point = scroll.origin
        scroll.shortsDrag = .none
        cancelScroll()
        traceShorts("Accumulated scroll delta: \(Int(delta)) pt")
        guard abs(delta) >= 45, let point else {
            traceShorts("Below swipe threshold or no target")
            return
        }
        let direction = delta > 0 ? 1 : -1
        let generation = scroll.generation
        let traceID = scroll.shortsTraceID
        scroll.lastRoute = "Shorts step"
        web.callAsyncJavaScript(
            """
            globalThis.vxrMarkShort();
            return globalThis.vxrStepShort(direction);
            """, arguments: ["direction": direction], in: nil, in: scrollWorld
        ) { [weak self] result in
            guard let self, self.scroll.shortsTraceID == traceID else {
                return
            }
            let action = (try? result.get()) as? String ?? "script-error"
            self.traceShorts("DOM action: " + action)
            switch action {
            case "arrow", "adjacent-item":
                self.observeShortsOutcome(traceID)
            case "no-control", "script-error":
                guard self.scroll.generation == generation else {
                    return
                }
                self.sendShortsSwipe(direction: direction, point: point, generation: generation)
            default:
                break
            }
        }
    }

    func observeShortsOutcome(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.scroll.shortsTraceID == id else {
                return
            }
            if self.web.url?.path != self.scroll.shortsStartPath {
                self.traceShorts("Outcome: URL path changed")
                return
            }
            self.web.callAsyncJavaScript(
                "return globalThis.vxrShortChanged();",
                arguments: [:], in: nil, in: self.scrollWorld
            ) { [weak self] result in
                guard let self, self.scroll.shortsTraceID == id else {
                    return
                }
                let outcome = (try? result.get()) as? String ?? "unavailable"
                self.traceShorts(
                    "Outcome: \(outcome); URL \(self.web.url == self.scroll.shortsStartURL ? "unchanged" : "changed")")
                if outcome == "unchanged" && self.web.url == self.scroll.shortsStartURL {
                    self.showNotice("Short did not advance. The report records the swipe route.")
                }
            }
        }
    }

    private func sendShortsSwipe(direction: Int, point: SIMD2<Float>, generation: UUID) {
        guard receivesInput, isShortsPage, let window = web.window,
            let source = native.sourcePoint(point)
        else {
            traceShorts("Synthetic swipe unavailable: page or window changed")
            return
        }
        let bounds = web.bounds
        let x = min(max(source.x, bounds.width * 0.15), bounds.width * 0.85)
        let length = bounds.height * 0.62
        let low = min(max(source.y - length / 2, bounds.height * 0.08), bounds.height * 0.30)
        let upper = CGPoint(x: x, y: low)
        let lower = CGPoint(x: x, y: low + length)
        let start = direction > 0 ? lower : upper
        let end = direction > 0 ? upper : lower
        guard window.bounds.contains(web.convert(start, to: window)),
            window.bounds.contains(web.convert(end, to: window))
        else {
            traceShorts("Synthetic swipe rejected: projected endpoints outside display")
            showNotice("Center the Shorts screen and swipe again.")
            return
        }
        scroll.lastRoute = "Shorts swipe fallback"
        traceShorts("Queued one synthetic swipe")
        let request = QueuedTap(
            session: self, point: start, generation: tapGeneration,
            useApplicationRoute: native.engine == .application,
            swipeEnd: end, scrollToken: generation, trace: scroll.shortsTraceID)
        if Self.tapQueue.enqueue(request) {
            drainTaps()
        } else {
            traceShorts("Input queue full")
        }
    }

    func flushNativeScroll() {
        guard scroll.nativeScroll else {
            return
        }
        guard receivesInput else {
            cancelScroll()
            return
        }
        if abs(scroll.pendingScroll) >= 0.25 {
            let delta = min(max(scroll.pendingScroll, -150), 150)
            if native.drivePhoneScroll(CGFloat(delta)) {
                scroll.pendingScroll -= delta
                if scroll.catalogGesture {
                    noteCatalogScroll("native moved")
                }
                scroll.hasScrolledNatively = true
            } else if !scroll.hasScrolledNatively, let point = scroll.origin {
                native.stopPhoneScroll()
                scroll.nativeScroll = false
                scroll.releaseVelocity = nil
                if scroll.catalogGesture {
                    noteCatalogScroll("native did not move; trying script")
                }
                beginScriptScroll(at: point, useCatalog: scroll.catalogGesture)
                return
            } else {
                if scroll.catalogGesture {
                    noteCatalogScroll("native stopped moving")
                }
                scroll.pendingScroll = 0
            }
        }
        if let velocity = scroll.releaseVelocity, abs(scroll.pendingScroll) < 0.25 {
            scroll.nativeScroll = false
            scroll.releaseVelocity = nil
            scroll.origin = nil
            native.endPhoneScroll(velocity: velocity)
        }
    }

    func flushScroll() {
        guard receivesInput, scroll.ready, !scroll.inFlight, abs(scroll.pendingScroll) >= 1 else {
            return
        }
        let wholeDelta = scroll.pendingScroll.rounded(.towardZero)
        let delta = scroll.catalogScroll ? min(max(wholeDelta, -96), 96) : wholeDelta
        scroll.pendingScroll -= delta
        scroll.inFlight = true
        let generation = scroll.generation
        let script =
            scroll.catalogScroll
            ? "globalThis.vxrScrollBy(delta); return globalThis.vxrCatalogScrollState();"
            : "return globalThis.vxrScrollBy(delta);"
        web.callAsyncJavaScript(script, arguments: ["delta": delta], in: nil, in: scrollWorld) { [weak self] result in
            guard let self, self.scroll.generation == generation else {
                return
            }
            self.scroll.inFlight = false
            if case .failure(let error) = result {
                if self.scroll.catalogScroll {
                    self.noteCatalogScroll("update failed")
                }
                self.inputStatus = "Scroll failed: " + error.localizedDescription
                self.showNotice("Could not scroll this region.")
                self.cancelScroll()
                return
            }
            if self.scroll.catalogScroll {
                if let state = (try? result.get()) as? String {
                    self.noteCatalogScroll(state)
                }
            } else {
                self.flushScroll()
            }
        }
    }
}
