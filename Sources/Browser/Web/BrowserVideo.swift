import Foundation
import SpatialMath
import WebKit

extension BrowserScreen {
    var preferredStereoPacking: StereoPacking? {
        guard let host = web.url?.host?.lowercased(),
            let saved = UserDefaults.standard.dictionary(forKey: "viture.stereo.packing")?[host] as? String
        else {
            return nil
        }
        return StereoPacking(rawValue: saved)
    }

    func setStereoVideo(_ packing: StereoPacking?) {
        guard self === owner.selectedSession else {
            return
        }
        if packing != nil {
            guard fullScreenAvailable, media.video != nil else {
                showNotice("Open a video to use 3D.")
                return
            }
            if !workspace.fullScreen {
                owner.toggleFullScreen()
            }
            if !media.cinema {
                media.setCinema(true)
            }
        }
        if packing != nil {
            conversion.stop()
        }
        stereoPacking = packing
        if packing == nil {
            stereoSwapEyes = false
        }
        if let packing, let host = web.url?.host?.lowercased() {
            var saved = UserDefaults.standard.dictionary(forKey: "viture.stereo.packing") ?? [:]
            saved[host] = packing.rawValue
            UserDefaults.standard.set(saved, forKey: "viture.stereo.packing")
        }
        if packing != nil && !GlassesDisplay.shared.externalStereo {
            showNotice("Switch the glasses to 3D mode.")
        }
    }

    func exitVideoView() {
        conversion.stop()
        setStereoVideo(nil)
        media.exitVideoPresentation()
        if self === owner.selectedSession, workspace.fullScreen {
            owner.toggleFullScreen()
        }
    }

    func swapStereoVideoEyes() {
        if stereoPacking != nil {
            stereoSwapEyes.toggle()
        }
    }
    func setDrawingStereoVideo(_ active: Bool) {
        drawingStereoVideo = active
    }

    var playbackBadge: String {
        if workspace.audioOwnerID == panelNumber, let video = media.video, !video.paused, !video.muted {
            return " ◖))"
        }
        return media.video.map { $0.paused ? "" : " ▸" } ?? ""
    }

    func togglePanelAudio() {
        guard receivesInput, let video = media.video, !workspace.audioCommandInFlight else {
            return
        }
        workspace.audioCommandInFlight = true
        if !video.muted {
            media.setMuted(true) { [weak self] _ in
                self?.workspace.audioCommandInFlight = false
            }
            return
        }
        // Captured by the completion handlers below.
        let workspace = self.workspace
        let audible = owner.allPanels.filter {
            $0 !== self && $0.media.video?.muted == false
                && ($0.media.video?.paused == false || $0.panelNumber == workspace.audioOwnerID)
        }
        func unmute() {
            guard active, owner.allPanels.contains(where: { $0 === self }) else {
                workspace.audioCommandInFlight = false
                return
            }
            media.setMuted(false) { ok in
                workspace.audioCommandInFlight = false
                if ok {
                    workspace.audioOwnerID = self.panelNumber
                } else {
                    self.showNotice("Couldn’t unmute this video. Try its player controls.")
                }
            }
        }
        guard !audible.isEmpty else {
            unmute()
            return
        }
        var remaining = audible.count
        var success = true
        for panel in audible {
            panel.media.setMuted(true) { ok in
                success = success && ok
                remaining -= 1
                guard remaining == 0 else {
                    return
                }
                if success {
                    unmute()
                } else {
                    workspace.audioCommandInFlight = false
                    self.showNotice("Couldn’t switch sound. Mute the other video first.")
                }
            }
        }
    }

    func audioEvent(from panel: BrowserScreen, audible: Bool) {
        guard panel.active, allPanels.contains(where: { $0 === panel }) else {
            return
        }
        if audible {
            workspace.audioOwnerID = panel.panelNumber
        } else if workspace.audioOwnerID == panel.panelNumber {
            workspace.audioOwnerID = nil
        }
    }
}
