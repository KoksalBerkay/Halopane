import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

/// A screen button in the panel switcher.
struct PanelChip: View {
    @ObservedObject var panel: BrowserScreen
    @ObservedObject var media: BrowserMedia
    @ObservedObject var owner: BrowserScreen
    var body: some View {
        let selected = owner.selectedPanel == panel.panelNumber
        let audible = media.video.map { !$0.paused && !$0.muted } ?? false
        Button {
            owner.selectPanel(panel.panelNumber)
        } label: {
            HStack(spacing: 4) {
                Text("\(panel.displayIndex)").monospacedDigit()
                if selected {
                    Text(panel.siteLabel).lineLimit(1)
                }
                if audible {
                    Circle().fill(ControllerPalette.amber).frame(width: 6, height: 6)
                }
            }.font(.footnote.weight(.semibold))
                .padding(.horizontal, selected ? 8 : 0)
                .frame(width: selected ? 96 : 32, height: 36)
                .frame(height: 44)
        }
        .buttonStyle(ControllerButtonStyle(selected: selected))
        .accessibilityLabel("Screen \(panel.displayIndex) · \(panel.siteLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Place screen here") {
                owner.selectPanel(panel.panelNumber)
                owner.placeSelectedPanelHere()
            }
            if panel !== owner {
                Button("Close screen", role: .destructive) {
                    owner.closePanel(panel)
                }
            }
        }
    }
}

/// Play, seek, mute, video view and 3D format for the selected video.
struct PlaybackControls: View {
    @ObservedObject var browser: BrowserScreen
    @ObservedObject var media: BrowserMedia
    let toggleAudio: () -> Void
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 6) {
            if let video = media.video {
                buttonRow(video)
                if let range = video.range, !media.seekFailed {
                    timeline(video, range: range)
                }
            }
            if media.nativeFullscreen && media.video == nil {
                Button("Exit video view") {
                    browser.exitVideoView()
                }.buttonStyle(ControllerButtonStyle())
            }
            if !media.status.isEmpty {
                Text(media.status).font(.caption).lineLimit(1)
            }
        }.padding(.horizontal, 6)
    }

    // Skip buttons appear only when the page reports a seekable range.
    private func buttonRow(_ video: BrowserMedia.Video) -> some View {
        HStack(spacing: 18) {
            if video.range != nil && !media.seekFailed {
                Button {
                    media.command("seek", value: video.time - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Back ten seconds")
            }
            Button {
                media.command("toggle")
            } label: {
                Image(systemName: video.paused ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(video.paused ? "Play" : "Pause")
            if video.range != nil && !media.seekFailed {
                Button {
                    media.command("seek", value: video.time + 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Forward ten seconds")
            }
            Button(action: toggleAudio) {
                Image(systemName: video.muted ? "speaker.slash" : "speaker.wave.2")
            }
            .accessibilityLabel(video.muted ? "Unmute" : "Mute")
            videoViewButton
            if !media.nativeFullscreen {
                stereoMenu
            }
        }.buttonStyle(ControllerButtonStyle())
    }

    private var videoViewButton: some View {
        let expanded = media.isVideoPresentation || browser.stereoPacking != nil
        return Button(expanded ? "Exit video view" : "Video view") {
            if expanded {
                browser.exitVideoView()
            } else {
                media.setCinema(true)
            }
        }.font(.footnote.weight(.semibold))
    }

    // Chooses how a 3D video packs its two eyes, or turns 3D off.
    private var stereoMenu: some View {
        Menu {
            Button("Off") {
                browser.setStereoVideo(nil)
            }
            ForEach(StereoPacking.allCases) { packing in
                Button(packing.rawValue) {
                    browser.setStereoVideo(packing)
                }
            }
            if browser.stereoPacking != nil {
                Button(browser.stereoSwapEyes ? "Restore eye order" : "Swap eyes") {
                    browser.swapStereoVideoEyes()
                }
            } else if let last = browser.preferredStereoPacking {
                Button("Last used: " + last.rawValue) {
                    browser.setStereoVideo(last)
                }
            }
        } label: {
            Text("3D").font(.footnote.weight(.semibold))
        }.accessibilityLabel("3D video format")
            .accessibilityValue(browser.stereoPacking?.rawValue ?? "Off")
    }

    // While dragging, only the label follows the slider. The page seeks on release.
    private func timeline(_ video: BrowserMedia.Video, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(clock(scrubbing ? scrubValue : video.time))
            Slider(
                value: Binding(
                    get: {
                        min(max(scrubbing ? scrubValue : video.time, range.lowerBound), range.upperBound)
                    },
                    set: {
                        scrubValue = $0
                    }), in: range,
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = video.time
                    } else {
                        media.command("seek", value: scrubValue)
                    }
                    scrubbing = editing
                }
            ).accessibilityLabel("Playback position")
            Text(clock(video.duration))
        }.font(.caption.monospacedDigit())
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(min(max(0, seconds), 1_000_000))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
