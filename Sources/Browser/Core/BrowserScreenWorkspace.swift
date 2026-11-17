import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Panels in the workspace: adding, closing, selecting, full screen and the pointer.
extension BrowserScreen {
    var fullScreenRouting: Bool {
        owner.fullScreenAvailable && (workspace.fullScreen || workspace.expansion.blend(at: CACurrentMediaTime()) > 0)
    }

    func toggleFullScreen() {
        guard self === owner, fullScreenAvailable else {
            return
        }
        let now = CACurrentMediaTime()
        cancelWorkspaceScroll()
        selectedSession.cancelTaps()
        workspace.fullScreen.toggle()
        workspace.expansion.setExpanded(workspace.fullScreen, at: now)
        workspace.pendingRecenter = nil
        workspace.centerCountdown = 0
        workspace.centerMessage = ""
        workspace.toolbarUntil = 0
        workspace.previousFullPanel = nil
        if workspace.fullScreen {
            selectedSession.cursor.y = min(624, max(0, selectedSession.cursor.y))
        }
    }

    func fullBlend(at now: CFTimeInterval) -> Float {
        fullScreenAvailable ? workspace.expansion.blend(at: now) : 0
    }

    func fullFade(at now: CFTimeInterval) -> CGFloat {
        fullScreenAvailable ? workspace.expansion.otherOpacity(at: now) : 1
    }

    func fullCrossfade(panel: Int, at now: CFTimeInterval) -> CGFloat? {
        guard workspace.fullScreen, let old = workspace.previousFullPanel else {
            return nil
        }
        let progress = min(1, max(0, (now - old.time) / 0.2))
        if progress >= 1 {
            workspace.previousFullPanel = nil
            return nil
        }
        if old.id == panel {
            return CGFloat(1 - progress)
        }
        if selectedPanel == panel {
            return CGFloat(progress)
        }
        return nil
    }

    func showsFullChrome(at now: CFTimeInterval) -> Bool {
        let session = selectedSession
        return now < workspace.toolbarUntil || session.addressEditing || session.bookmarksOpen || session.historyOpen
            || session.moreOpen
    }

    func noteFullCursor(y: Float, top: Float) {
        if workspace.fullScreen, y <= top + 14 {
            workspace.toolbarUntil = CACurrentMediaTime() + 3
        }
    }

    var visiblePanels: [BrowserScreen] {
        backend == .replica && !native.phoneHosted ? allPanels : [self]
    }

    var canAddWebPanel: Bool {
        self === owner && backend == .replica && !native.phoneHosted && signInSession == nil
            && selectedSession.popup == nil && !native.running
    }

    func addPanel(selectNewScreen: Bool = false) {
        guard canAddWebPanel else {
            return
        }
        guard let slot = (1...3).first(where: { candidate in !workspace.panels.contains { $0.slot == candidate } })
        else {
            selectedSession.showNotice("Close a screen to add another.")
            return
        }
        let panel = BrowserScreen(panelNumber: workspace.nextPanelID, slot: slot, owner: self)
        workspace.nextPanelID += 1
        panel.offset = .slot(slot)
        panel.open()
        workspace.panels.append(panel)
        if selectNewScreen {
            selectPanel(panel.panelNumber)
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    func closePanel(_ panel: BrowserScreen) {
        guard self === owner, !panel.phonePageActive, panel.popup == nil, signInSession == nil else {
            return
        }
        if panel === self {
            // Keep the anchor panel as the diagnostic source.
            panel.loadHome()
            return
        }
        guard workspace.panels.contains(where: { $0 === panel }) else {
            return
        }
        if selectedSession === panel {
            let direction = panel.panelAnchor.act(SIMD3<Float>(0, 0, -1))
            let neighbor = allPanels.filter { $0 !== panel }.max {
                simd_dot($0.panelAnchor.act(SIMD3<Float>(0, 0, -1)), direction)
                    < simd_dot($1.panelAnchor.act(SIMD3<Float>(0, 0, -1)), direction)
            }
            selectPanel(neighbor?.panelNumber ?? 1)
            guard selectedSession !== panel else {
                return
            }
        }
        panel.cancelScroll()
        panel.cancelTaps()
        panel.closePhoneEditor()
        panel.active = false
        if panel.localFile != nil {
            panel.loadHome()
            panel.pendingLocalNavigation = nil
            panel.localFile = nil
        }
        panel.media.setMuted(true)
        if workspace.audioOwnerID == panel.panelNumber {
            workspace.audioOwnerID = nil
        }
        workspace.panels.removeAll { $0 === panel }
        workspace.closedPanel?.close()
        workspace.closedPanel = panel
        workspace.hasUndo = true
        let id = UUID()
        workspace.undoID = id
        selectedSession.showNotice("Screen closed. Undo from More or the phone.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.workspace.undoID == id else {
                return
            }
            self.workspace.closedPanel?.close()
            self.workspace.closedPanel = nil
            self.workspace.hasUndo = false
        }
    }

    func undoClose() {
        guard let panel = workspace.closedPanel, workspace.panels.count < 3, signInSession == nil, backend == .replica,
            !native.phoneHosted
        else {
            return
        }
        if workspace.panels.contains(where: { $0.slot == panel.slot }),
            let free = (1...3).first(where: { candidate in !workspace.panels.contains { $0.slot == candidate } })
        {
            panel.slot = free
            panel.offset = .slot(free)
        }
        workspace.closedPanel = nil
        workspace.hasUndo = false
        workspace.undoID = UUID()
        panel.active = true
        panel.refreshPageBackdrop()
        workspace.panels.append(panel)
        workspace.panels.sort { $0.panelNumber < $1.panelNumber }
        selectPanel(panel.panelNumber)
    }

    func selectPanel(_ number: Int, keepPointer: Bool = false) {
        guard self === owner, number != selectedPanel, visiblePanels.contains(where: { $0.panelNumber == number }),
            signInSession == nil, selectedSession.popup == nil, !native.running
        else {
            return
        }
        let old = selectedSession
        old.cloudController.stop(web: old.web)
        old.cancelScroll()
        old.cancelTaps()
        old.scroll.shortsTraceID = UUID()
        old.closePhoneEditor()
        old.addressEditing = false
        old.bookmarksOpen = false
        old.historyOpen = false
        old.moreOpen = false
        old.effectiveCursor = nil
        old.media.trace("deselected")
        workspace.inputRoute.select(number)
        selectedSession.media.trace("selected")
        selectedSession.effectiveCursor = effectiveInput == .trackpad ? selectedSession.cursor : nil
        workspace.aimedPanel = keepPointer ? number : 0
        if workspace.input == .remote && !keepPointer {
            GlassesDisplay.shared.phone.clearAim()
            aimPhoneNow()
        }
        UISelectionFeedbackGenerator().selectionChanged()
        workspace.switchLog.append("Panel \(old.panelNumber) → \(number)")
        workspace.switchLog = Array(workspace.switchLog.suffix(16))
    }

    func updateWorkspacePointer(_ frame: RenderFrame) {
        guard self === owner else {
            return
        }
        workspace.pointerHit = nil
        guard frame.live, effectiveInput != .trackpad, visiblePanels.count > 1, signInSession == nil else {
            return
        }
        workspace.pointerHit = resolveWorkspacePointer()
    }

    func phoneRayInView() -> SIMD3<Float>? {
        GlassesDisplay.shared.phone.spatialRay().map { workspace.lastWorldCamera.inverse.act($0.direction) }
    }

    private func resolveWorkspacePointer() -> PanelPointerHit? {
        let ray =
            workspace.input == .remote
            ? GlassesDisplay.shared.phone.spatialRay()
            : PointerRay(direction: workspace.lastWorldCamera.act(SIMD3<Float>(0, 0, -1)))
        return ray.flatMap {
            PanelPointerHit.resolve(
                ray: $0, workspace: workspace.placement.anchor, selected: selectedPanel,
                panels: visiblePanels.map { .init(number: $0.panelNumber, offset: $0.offset) },
                topInset: chromeInset)
        }
    }

    func moveWorkspacePointer(_ delta: CGPoint) {
        selectedSession.moveCursor(delta)
    }

    private func panelForWorkspaceClick() -> BrowserScreen? {
        guard active, !selectedSession.panelWarming, signInSession == nil, selectedSession.popup == nil else {
            return nil
        }
        let panel = selectedSession
        if panel.drawingStereoVideo {
            return panel
        }
        if effectiveInput == .trackpad {
            panel.effectiveCursor = panel.cursor
        }
        if effectiveInput != .trackpad, visiblePanels.count > 1 {
            guard workspace.lastFrameLive, let hit = resolveWorkspacePointer() else {
                return nil
            }
            if session(hit.panel)?.panelWarming == true {
                return nil
            }
            if hit.panel != selectedPanel {
                selectPanel(hit.panel, keepPointer: true)
                return nil
            }
            panel.effectiveCursor = hit.point
        }
        return panel
    }

    func clickWorkspace() {
        guard let panel = panelForWorkspaceClick() else {
            return
        }
        if panel.drawingStereoVideo {
            panel.media.command("toggle")
            return
        }
        workspace.pointerTapAt = CACurrentMediaTime()
        recordInput("Tap → Panel \(panel.panelNumber)")
        panel.click()
    }

    private static let secondaryClickScript = Bundle.main.url(forResource: "secondary-click", withExtension: "js")
        .flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }

    func secondaryClickWorkspace() {
        guard let panel = panelForWorkspaceClick(), !panel.drawingStereoVideo, panel.receivesInput,
            let point = panel.effectiveCursor,
            !panel.addressEditing, !panel.bookmarksOpen, !panel.historyOpen, !panel.moreOpen, point.y >= 0
        else {
            return
        }
        if let top = panel.fullChromeY, showsFullChrome(at: CACurrentMediaTime()), point.y < top + chromeInset {
            return
        }
        let displayPoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        let source: CGPoint
        if let cinema = panel.media.mapping {
            guard let mapped = cinema.sourcePoint(at: displayPoint) else {
                return
            }
            source = mapped
        } else {
            guard let normal = panel.native.sourcePoint(point) else {
                return
            }
            source = normal
        }
        let bounds = panel.web.bounds
        guard bounds.contains(source), let script = Self.secondaryClickScript else {
            return
        }
        panel.cancelScroll()
        let generation = panel.tapGeneration
        recordInput("Right-click → Panel \(panel.panelNumber)")
        panel.web.callAsyncJavaScript(
            script,
            arguments: [
                "fractionX": Double((source.x - bounds.minX) / bounds.width),
                "fractionY": Double((source.y - bounds.minY) / bounds.height)
            ], in: nil, in: panel.scrollWorld
        ) { [weak panel] result in
            guard let panel, panel.tapGeneration == generation else {
                return
            }
            let outcome = (try? result.get()) as? String ?? "script unavailable"
            panel.diagnostics.secondaryClickReport = outcome
        }
    }

    func session(_ number: Int) -> BrowserScreen? {
        allPanels.first { $0.panelNumber == number }
    }

    func recordInput(_ event: String) {
        guard !workspace.panels.isEmpty else {
            return
        }
        workspace.inputLog.append(event)
        workspace.inputLog = Array(workspace.inputLog.suffix(16))
    }

    func placeSelectedPanelHere() {
        guard self === owner, workspace.lastFrameLive, workspace.placement.phase == .placed, visiblePanels.count > 1
        else {
            return
        }
        selectedSession.cancelTaps()
        selectedSession.cancelScroll()
        let target =
            workspace.anchorMode == .reclined
            ? workspace.lastWorldCamera : WebPanelMath.levelAnchor(lookingWith: workspace.lastWorldCamera)
        selectedSession.offset.rotation = (workspace.placement.anchor.inverse * target).normalized
        aimPhoneNow()
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
