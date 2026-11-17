import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Cursor, clicks and the queue of synthetic taps and swipes.
extension BrowserScreen {
    func moveCursor(_ delta: CGPoint) {
        guard receivesInput, effectiveInput == .trackpad else {
            return
        }
        cursor.x = min(max(cursor.x + Float(delta.x) * 2, 0), 999)
        let range = fullCursorBounds ?? (-chromeInset...624)
        cursor.y = min(max(cursor.y + Float(delta.y) * 2, range.lowerBound), range.upperBound)
        if let top = fullChromeY, abs(delta.y) > 0 {
            noteFullCursor(y: cursor.y, top: top)
        }
    }

    func click() {
        guard !panelWarming, receivesInput else {
            return
        }
        cancelScroll()
        if let point = effectiveCursor, chromeClick(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) {
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        if addressEditing {
            addressEditing = false
        }
        if effectiveCursor != nil, BrowserDestination.supportsDirectPhoneSignIn(web.url) {
            openSignInOnPhone()
            return
        }
        disableDoubleTapZoom()
        if native.engine == .dom {
            clickThroughDOM()
        } else {
            queueSyntheticTap()
        }
    }

    // Normal path: send a real touch to the page through the tap queue.
    private func queueSyntheticTap() {
        guard let point = effectiveCursor else {
            inputStatus = "Aim at the web screen first."
            return
        }
        let displayPoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        let source: CGPoint
        if let cinema = media.mapping {
            guard let mapped = cinema.sourcePoint(at: displayPoint) else {
                return
            }
            source = mapped
        } else {
            guard let normal = native.sourcePoint(point) else {
                return
            }
            source = normal
        }
        let request = QueuedTap(
            session: self, point: source, generation: tapGeneration,
            useApplicationRoute: native.engine == .application)
        if Self.tapQueue.enqueue(request) {
            UISelectionFeedbackGenerator().selectionChanged()
            drainTaps()
        } else {
            showNotice("Tap backlog full. Give it a moment.")
        }
    }

    // DOM fallback: remember a text field for typing, otherwise click the link or element.
    private func clickThroughDOM() {
        guard let point = effectiveCursor else {
            inputStatus = "Look at the screen before tapping."
            return
        }
        let js = """
            (() => {
                let element = document.elementFromPoint(\(point.x) * innerWidth / 1000, \(point.y) * innerHeight / 625);
                if (!element) {
                    return 'No element';
                }
                let field = element.closest('input,textarea,[contenteditable=true]');
                if (field) {
                    window.__vxrInputTarget = field;
                    return 'Text target: ' + field.tagName;
                }
                let target = element.closest('a,button') || element;
                target.click();
                return 'DOM click: ' + target.tagName + ' (untrusted)';
            })()
            """
        web.evaluateJavaScript(js) { [weak self] value, error in
            guard let self else {
                return
            }
            self.inputStatus = (value as? String) ?? error?.localizedDescription ?? "Click completed"
            if let source = self.native.sourcePoint(point) {
                self.offerPhoneEditor(at: source)
            }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func cancelTaps() {
        tapGeneration = UUID()
        Self.tapQueue.removePending { $0.session === self || $0.session == nil }
    }

    func drainTaps() {
        while let tap = Self.tapQueue.startNext() {
            if let session = tap.session {
                session.sendQueuedTap(tap)
                return
            }
            Self.tapQueue.didFinish()
        }
    }

    private func sendQueuedTap(_ tap: QueuedTap) {
        let valid: () -> Bool = { [weak self] in
            guard let self else {
                return false
            }
            return self.active && self.receivesInput && UIApplication.shared.applicationState == .active
                && !self.phonePageActive && self.popup == nil && self.tapGeneration == tap.generation
                && (tap.scrollToken == nil || self.scroll.generation == tap.scrollToken)
                && (tap.catalogPage == nil || self.web.url == tap.catalogPage)
        }
        let beforeSwipe = tap.catalogPage == nil ? nil : web.scrollView.contentOffset.y
        if tap.swipeEnd == nil {
            editorState.tapStarted = CACurrentMediaTime()
            editorState.tapFrame = nil
        }
        let completion: (String) -> Void = { [self] result in
            // These failures occur before .began was sent. Never replay a partially sent tap.
            let retryable =
                result.hasPrefix("Busy:")
                || (result.contains("Physical touch still active") && result.hasSuffix("phases=0"))
            if valid(), retryable, tap.retries < 8 {
                var retry = tap
                retry.retries += 1
                let next = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [self] in
                    self.sendQueuedTap(next)
                }
                return
            }
            Self.tapQueue.didFinish()
            if let trace = tap.trace, scroll.shortsTraceID == trace {
                reportShortsSwipe(result, trace: trace, valid: valid)
            } else if let beforeSwipe, tap.catalogPage != nil {
                reportCatalogSwipe(result, beforeSwipe: beforeSwipe, valid: valid)
            } else if valid(), tap.swipeEnd == nil {
                finishPageTap(result, tap: tap, valid: valid)
            }
            self.drainTaps()
        }
        if let end = tap.swipeEnd {
            // Catalogue swipes hold their end until physical fingers lift, so a
            // swipe interrupted by the next drag never leaves a touch down in WebKit.
            VXRInjectQueuedSwipe(
                web, tap.point, end, tap.useApplicationRoute, owner.visiblePanels.count > 1,
                tap.catalogPage != nil, valid, completion)
        } else {
            VXRInjectQueuedTap(
                web, tap.point, tap.useApplicationRoute, owner.visiblePanels.count > 1, valid, completion)
        }
    }

    private func reportShortsSwipe(_ result: String, trace: UUID, valid: () -> Bool) {
        traceShorts("Synthetic dispatch: " + result)
        observeShortsOutcome(trace)
        if !result.hasPrefix("Dispatch calls completed") && valid() {
            showNotice("Could not advance Shorts. Try the arrows on the page.")
        }
    }

    private func reportCatalogSwipe(_ result: String, beforeSwipe: CGFloat, valid: () -> Bool) {
        if result.hasPrefix("Dispatch calls completed") {
            let shift = String(format: "%.0f", web.scrollView.contentOffset.y - beforeSwipe)
            noteCatalogScroll("touch sent (page offset Δ \(shift) pt)")
        } else if valid() {
            noteCatalogScroll("touch rejected: " + String(result.prefix(140)))
        }
    }

    // After a delivered tap, offer the phone keyboard if the tap focused a text field.
    // After a rejected tap, tell the user and offer the keyboard as a fallback.
    private func finishPageTap(_ result: String, tap: QueuedTap, valid: @escaping () -> Bool) {
        if result.hasPrefix("Dispatch calls completed") {
            guard Self.tapQueue.count == 0 else {
                return
            }
            let began = editorState.tapStarted
            // Include trusted field taps delivered from a child frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self, valid(), Self.tapQueue.isIdle, self.editorState.tapStarted == began else {
                    return
                }
                let frame = self.editorState.tapFrame
                self.editorState.tapStarted = nil
                self.editorState.tapFrame = nil
                self.offerPhoneEditor(at: tap.point, frame: frame)
            }
        } else {
            inputStatus = result
            owner.recordInput("Panel \(panelNumber) dispatch rejected: " + String(result.prefix(160)))
            showNotice("Tap did not reach the page. Aim inside the screen or reset the view.")
            if Self.tapQueue.count == 0 {
                editorState.tapStarted = nil
                editorState.tapFrame = nil
                offerPhoneEditor(at: tap.point)
            }
        }
    }

    func clearWebSelection() {
        guard !native.phoneHosted else {
            return
        }
        func dismissMenus(in view: UIView) {
            for case let menu as UIEditMenuInteraction in view.interactions {
                menu.dismissMenu()
            }
            view.subviews.forEach(dismissMenus)
        }
        dismissMenus(in: web)
        // Clear page selection without blurring a focused editable field or closing its phone editor.
        web.evaluateJavaScript("window.getSelection()?.removeAllRanges();true", completionHandler: nil)
    }

    func disableDoubleTapZoom() {
        // Keep the change inside this pane. The CSS policy covers WebKit's tap-action
        // path; disable double-tap recognizers too, including on desktop-layout pages.
        func visit(_ view: UIView) {
            for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? []
            where tap.numberOfTapsRequired == 2 && tap.numberOfTouchesRequired == 1 {
                tap.isEnabled = false
            }
            view.subviews.forEach(visit)
        }
        visit(web)
    }

    func sendText() {
        let value = String(data: try! JSONSerialization.data(withJSONObject: [keyboardText]), encoding: .utf8)!
        web.evaluateJavaScript(
            """
            (() => {
                let field = window.__vxrInputTarget;
                if (!field || !field.isConnected) {
                    return 'Click a web text field first';
                }
                let text = \(value)[0];
                if (field.isContentEditable) {
                    field.textContent = text;
                } else {
                    // Use the native value setter so frameworks like React see the change.
                    let prototype = field.tagName === 'TEXTAREA'
                        ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, text);
                }
                field.dispatchEvent(new Event('input', {bubbles: true}));
                field.dispatchEvent(new Event('change', {bubbles: true}));
                return 'Text sent through DOM bridge';
            })()
            """
        ) { [weak self] result, error in
            self?.inputStatus = (result as? String) ?? error?.localizedDescription ?? "Text sent"
        }
    }
}
