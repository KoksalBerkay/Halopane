import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

// Multi-panel workspace rendering: panel placement, edge hint and notices.
extension GlassesSurface {
    /// Values shared by every panel while laying out one display frame.
    private struct WorkspaceFrame {
        let link: CADisplayLink
        let frame: RenderFrame
        let now: CFTimeInterval
        let active: BrowserScreen
        let panelCount: Int
        let eye: CGSize
        let viewport: SIMD2<Float>
        let visible: CGRect
        let pixels: CGSize?
        /// Full-screen expansion progress, 0 to 1.
        let blend: Float
        let fullRouting: Bool
        let fullyExpanded: Bool
        /// Opacity of the panels that are not selected while full screen fades in.
        let otherOpacity: CGFloat
        let stereoLayout: StereoCinemaLayout?
    }

    func updateWorkspace(_ link: CADisplayLink, frame: RenderFrame) {
        let sessions = browser.visiblePanels
        let ids = Set(sessions.map(\.panelNumber))
        for id in Array(mounts.keys) where !ids.contains(id) {
            mounts.removeValue(forKey: id)?.detach()
        }
        let eye = left.bounds.size
        let active = browser.selectedSession
        let now = CACurrentMediaTime()
        let visible = browser.workspace.visibleArea.rect(in: eye)
        let blend = browser.fullBlend(at: now)
        let fullRouting = browser.fullScreenRouting
        let fullyExpanded = browser.workspace.fullScreen && blend >= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Side-by-side output makes the drawable more than twice as wide as tall.
        let wide = bounds.width / max(1, bounds.height) > 2.5
        let stereoLayout = stereoCinemaLayout(
            active: active, wide: wide, fullyExpanded: fullyExpanded, eye: eye, visible: visible)
        if let stereoLayout, let crop = active.media.mapping?.crop {
            stereoVideo.display(active, crop: crop, layout: stereoLayout, eyeWidth: eye.width)
        } else {
            stereoVideo.releaseVideo()
        }
        let context = WorkspaceFrame(
            link: link, frame: frame, now: now, active: active, panelCount: sessions.count, eye: eye,
            viewport: SIMD2(Float(eye.width), Float(eye.height)), visible: visible,
            pixels: window?.windowScene?.screen.currentMode?.size, blend: blend, fullRouting: fullRouting,
            fullyExpanded: fullyExpanded, otherOpacity: browser.fullFade(at: now), stereoLayout: stereoLayout)
        var transforms: [Int: simd_float4x4] = [:]
        for panel in sessions {
            transforms[panel.panelNumber] = layOutPanel(panel, in: context)
        }
        if lastLayerOrder != active.panelNumber {
            if let mount = mounts[active.panelNumber], !mount.isWarming || fullRouting {
                left.insertSubview(mount, belowSubview: edgeHint)
            }
            lastLayerOrder = active.panelNumber
        }
        updateEdgeHint(active: active, transforms: transforms, in: context)
        updateWorkspaceNotice(active: active, wide: wide, in: context)
        calibration.isHidden = !browser.workspace.calibratingVisibleArea
        if !calibration.isHidden {
            drawCalibration(visible)
        }
        drawWorkspacePointer(
            now: now, active: active, sessions: sessions, transforms: transforms,
            visible: visible, viewport: context.viewport, settings: frame.settings)
        let mount = mounts[active.panelNumber]
        let canCompare =
            !fullRouting && mount.map { !$0.isHidden && !$0.isWarming } == true && !active.phonePageActive
        browser.recordDriftFrame(
            frame, applied: canCompare ? mount.map { matrix($0.layer.transform) } : nil,
            viewport: context.viewport, reportable: canCompare, now: CACurrentMediaTime())
        CATransaction.commit()
    }

    /// The layout for 3D video, or nil when this frame should show ordinary panels.
    private func stereoCinemaLayout(
        active: BrowserScreen, wide: Bool, fullyExpanded: Bool, eye: CGSize, visible: CGRect
    ) -> StereoCinemaLayout? {
        guard wide, fullyExpanded, !active.phonePageActive, active.popup == nil,
            !browser.workspace.calibratingVisibleArea, let packing = active.stereoPacking,
            let crop = active.media.mapping?.crop
        else {
            return nil
        }
        return StereoCinemaLayout(
            crop: crop, eyeSize: eye, visible: visible, packing: packing, swapped: active.stereoSwapEyes)
    }

    /// Places one panel for this frame and returns its screen transform.
    private func layOutPanel(_ panel: BrowserScreen, in context: WorkspaceFrame) -> simd_float4x4 {
        let active = context.active
        let frame = context.frame
        let viewport = context.viewport
        let showingStereo = panel === active && context.stereoLayout != nil
        panel.setDrawingStereoVideo(showingStereo)
        let slotCamera = panel.offset.camera(frame.orientation)
        let crossfade = browser.fullCrossfade(panel: panel.panelNumber, at: context.now)
        let expanded = (panel === active || crossfade != nil) ? context.blend : 0
        var full: FullScreenGeometry?
        if expanded > 0 {
            full = FullScreenGeometry(
                viewport: viewport, visible: context.visible, settings: frame.settings,
                content: panel.media.mapping?.destination ?? CGRect(x: 0, y: 0, width: 1000, height: 625))
        }
        let transform =
            full?.transform(camera: slotCamera, blend: expanded, viewport: viewport, settings: frame.settings)
            ?? WebPanelMath.screenTransform(
                camera: slotCamera, eyeOffset: 0, viewport: viewport, settings: frame.settings)
        if context.fullyExpanded, panel === active {
            limitCursorToVisiblePage(panel, visibleRange: full?.visibleLocalY)
        } else {
            limitCursorToVisiblePage(panel, visibleRange: nil)
        }
        let mount = mountForPanel(panel)
        noteFirstMount(panel, mount: mount, transform: transform, showingStereo: showingStereo, in: context)
        let released = mount.advanceWarmup(now: context.link.timestamp, finished: panel.navigationFinished)
        if released {
            panel.diagnostics.firstMountNote += "; moved to slot"
            lastLayerOrder = 0
        }
        // A warming page paints in front of the viewer before it moves to its slot.
        let staged = mount.isWarming && expanded == 0
        let applied: simd_float4x4
        if staged {
            applied = WebPanelMath.screenTransform(
                camera: SceneMath.identity, eyeOffset: 0, viewport: viewport, settings: frame.settings)
        } else {
            applied = transform
        }
        var relative = frame
        relative.orientation = slotCamera
        if !panel.phonePageActive {
            panel.tick(context.link, size: bounds.size, pixels: context.pixels, frame: relative)
        }
        showMount(
            mount, for: panel, transform: applied, crossfade: crossfade, staged: staged,
            showingStereo: showingStereo, in: context)
        if staged {
            left.insertSubview(mount, belowSubview: edgeHint)
        }
        mount.isUserInteractionEnabled =
            !showingStereo && !staged && (!context.fullRouting || panel === active)
        if showingStereo {
            return transform
        }
        let toolbarVisible =
            !context.fullRouting
            || (panel === active && context.fullyExpanded && browser.showsFullChrome(at: context.now))
        mount.refresh(
            focused: panel === active && !staged, showBorder: context.panelCount > 1 && !context.fullRouting,
            showToolbar: toolbarVisible, toolbarTop: panel.fullChromeY)
        return transform
    }

    // In full screen, keep the cursor inside the part of the page that is visible.
    private func limitCursorToVisiblePage(_ panel: BrowserScreen, visibleRange: ClosedRange<Float>?) {
        guard let range = visibleRange else {
            panel.fullChromeY = nil
            panel.fullCursorBounds = nil
            return
        }
        panel.fullChromeY = range.lowerBound
        let usable = range.lowerBound...max(range.lowerBound, min(range.upperBound, 624))
        panel.fullCursorBounds = usable
        panel.cursor.y = min(usable.upperBound, max(usable.lowerBound, panel.cursor.y))
    }

    // Hides a panel that is behind the viewer, positions it, and sets its opacity.
    private func showMount(
        _ mount: PanelMount, for panel: BrowserScreen, transform: simd_float4x4, crossfade: CGFloat?,
        staged: Bool, showingStereo: Bool, in context: WorkspaceFrame
    ) {
        let active = context.active
        let inFront = isInFront(transform)
        // In full screen, other panels fade out completely but stay attached.
        let parked =
            context.fullRouting && panel !== active && crossfade == nil && context.otherOpacity <= 0.001
        let culled = !inFront && !parked
        if mount.isHidden != culled {
            mount.isHidden = culled
            panel.media.trace(culled ? "off-axis cull" : "off-axis return")
        }
        if inFront {
            mount.layer.transform = caTransform(transform)
        }
        // Keep other pages attached at nonzero alpha so hiding the workspace does
        // not explicitly change page visibility or pause media.
        let opacity = crossfade ?? (panel === active ? 1 : context.otherOpacity)
        if showingStereo {
            mount.alpha = 0.0001
        } else {
            mount.alpha = max(0.0001, (staged ? 0.08 : 1) * opacity)
        }
    }

    private func mountForPanel(_ panel: BrowserScreen) -> PanelMount {
        if let attached = mounts[panel.panelNumber] {
            return attached
        }
        let mount = PanelMount(session: panel)
        left.insertSubview(mount, belowSubview: edgeHint)
        mounts[panel.panelNumber] = mount
        panel.media.trace("surface mounted")
        lastLayerOrder = 0
        return mount
    }

    // A page that first loads outside the view is warmed up in the center so it paints.
    private func noteFirstMount(
        _ panel: BrowserScreen, mount: PanelMount, transform: simd_float4x4, showingStereo: Bool,
        in context: WorkspaceFrame
    ) {
        guard !panel.phonePageActive && !showingStereo && mount.needsAttach && !mount.isWarming else {
            return
        }
        let viewRect = CGRect(origin: .zero, size: context.eye)
        let targetRect = projectedPanelRect(transform)
        let onScreen =
            targetRect.map { $0.intersection(viewRect).width > 50 && $0.intersection(viewRect).height > 50 }
            ?? false
        panel.diagnostics.firstMountNote =
            "Slot rect \(targetRect.map { NSCoder.string(for:$0) } ?? "behind view"); in view=\(onScreen)"
        if !onScreen {
            mount.beginWarmup(at: context.link.timestamp)
            panel.diagnostics.firstMountNote += "; centered for first paint"
        }
    }

    // Shows an arrow toward the selected panel when it is outside the visible area.
    private func updateEdgeHint(
        active: BrowserScreen, transforms: [Int: simd_float4x4], in context: WorkspaceFrame
    ) {
        edgeHint.isHidden = true
        guard !context.fullRouting, browser.signInSession == nil, let transform = transforms[active.panelNumber]
        else {
            return
        }
        let visible = context.visible
        let center = transform * SIMD4<Float>(500, 312.5, 0, 1)
        let direction = active.offset.camera(context.frame.orientation).inverse.act(SIMD3<Float>(0, 0, -1))
        let x = CGFloat(center.x / max(0.01, center.w))
        let y = CGFloat(center.y / max(0.01, center.w))
        guard center.w <= 0 || !visible.contains(CGPoint(x: x, y: y)) else {
            return
        }
        // Vertical: the panel is above or below the view, not to a side.
        let vertical = center.w > 0 && x >= visible.minX && x <= visible.maxX
        let leading = direction.x < 0
        let top = direction.y >= 0
        let width: CGFloat = min(290, visible.width - 24)
        let originX: CGFloat
        let originY: CGFloat
        let arrow: String
        if vertical {
            originX = visible.midX - width / 2
            originY = top ? visible.minY + 10 : visible.maxY - 64
            arrow = top ? "⌃" : "⌄"
        } else {
            originX = leading ? visible.minX + 12 : visible.maxX - width - 12
            originY = visible.midY - 27
            arrow = leading ? "‹" : "›"
        }
        edgeHint.frame = CGRect(x: originX, y: originY, width: width, height: 54)
        edgeHint.text = "\(arrow) \(active.displayIndex) · \(active.siteLabel)"
        edgeHint.isHidden = false
    }

    // The message at the bottom of the view. The first message that applies wins.
    private func updateWorkspaceNotice(active: BrowserScreen, wide: Bool, in context: WorkspaceFrame) {
        let waitingFor3D =
            !wide && context.fullyExpanded && active.stereoPacking != nil && active.media.cinema
        let message: String
        if let pickerStatus = active.localPickerStatus {
            message = pickerStatus
        } else if waitingFor3D {
            message = "Switch the glasses to 3D mode."
        } else if !browser.trackingNotice.isEmpty {
            message = browser.trackingNotice
        } else if !active.browserNotice.isEmpty {
            message = active.browserNotice
        } else if context.fullRouting {
            message = ""
        } else {
            message = browser.placementHint
        }
        workspaceNotice.isHidden = message.isEmpty
        workspaceNotice.text = message
        let visible = context.visible
        let noticeWidth = max(1, min(880, visible.width - 24))
        workspaceNotice.frame = CGRect(
            x: visible.midX - noticeWidth / 2, y: visible.maxY - 62, width: noticeWidth, height: 48)
    }
    private func drawCalibration(_ rect: CGRect) {
        let inset = rect.insetBy(dx: 2, dy: 2)
        guard inset.width > 0, inset.height > 0 else {
            return
        }
        let path = UIBezierPath(rect: inset)
        for (x, dx) in [(inset.minX, CGFloat(1)), (inset.maxX, CGFloat(-1))] {
            for (y, dy) in [(inset.minY, CGFloat(1)), (inset.maxY, CGFloat(-1))] {
                path.move(to: CGPoint(x: x + dx * 7, y: y + dy * 31))
                path.addLine(to: CGPoint(x: x + dx * 7, y: y + dy * 7))
                path.addLine(to: CGPoint(x: x + dx * 31, y: y + dy * 7))
            }
        }
        calibration.path = path.cgPath
    }

    private func drawWorkspacePointer(
        now: CFTimeInterval, active: BrowserScreen, sessions: [BrowserScreen],
        transforms: [Int: simd_float4x4], visible: CGRect,
        viewport: SIMD2<Float>, settings: SceneSettings
    ) {
        workspacePointers.forEach {
            $0.hide()
        }
        guard !active.drawingStereoVideo, browser.signInSession == nil, active.popup == nil,
            !browser.workspace.calibratingVisibleArea
        else {
            return
        }
        let input = browser.effectiveInput
        let hit = input == .trackpad || sessions.count == 1 ? nil : browser.workspace.pointerHit
        let targetID = hit?.panel ?? active.panelNumber
        let cursor = input != .trackpad && sessions.count > 1 ? hit?.point : active.effectiveCursor
        let rayProject: (SIMD3<Float>) -> CGPoint? = { direction in
            let clip =
                SceneMath.projection(horizontal: settings.horizontalFOV, vertical: settings.verticalFOV)
                * SIMD4(direction.x, direction.y, direction.z, 1)
            guard clip.w > 0.01 else {
                return nil
            }
            return CGPoint(
                x: CGFloat((clip.x / clip.w + 1) * viewport.x / 2),
                y: CGFloat((1 - clip.y / clip.w) * viewport.y / 2))
        }
        if mounts[targetID]?.isWarming != true || browser.fullScreenRouting,
            let cursor, let transform = transforms[targetID], isInFront(transform)
        {
            let cursorClip = transform * SIMD4(cursor.x, cursor.y, 0, 1)
            guard cursorClip.w > 0.03 else {
                return
            }
            let point = CGPoint(x: CGFloat(cursorClip.x / cursorClip.w), y: CGFloat(cursorClip.y / cursorClip.w))
            guard visible.insetBy(dx: -0.5, dy: -0.5).contains(point) else {
                return
            }
            let target = sessions.first { $0.panelNumber == targetID } ?? active
            let playing = target.media.isOverPlayingVideo(at: CGPoint(x: CGFloat(cursor.x), y: CGFloat(cursor.y)))
            let laser = input == .remote && browser.workspace.laserEnabled ? rayProject(SIMD3(0.15, -0.35, -0.3)) : nil
            let hover = !playing && workspacePointers.first?.hover(session: target, point: cursor, now: now) == true
            for pointer in workspacePointers {
                pointer.draw(
                    at: point, local: cursor, panel: targetID, playing: playing,
                    tap: browser.workspace.pointerTapAt, now: now, hand: laser, visible: visible, hover: hover)
            }
        } else if input == .remote, let ray = browser.phoneRayInView(), let projected = rayProject(ray),
            visible.contains(projected)
        {
            workspacePointers.forEach {
                $0.drawMiss(at: projected)
            }
        }
    }
}
