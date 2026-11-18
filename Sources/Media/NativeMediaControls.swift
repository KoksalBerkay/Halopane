import SwiftUI

/// The Spatial Player controls on the iPhone.
struct NativeMediaControls: View {
    @ObservedObject var session: NativeMediaSession
    @ObservedObject var display: GlassesDisplay
    let openInPanel: () -> Void
    @State private var dragged = CGSize.zero
    @State private var scrubbing = false
    @State private var scrub = 0.0
    @State private var surfaceSeekStart: Double?
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 12) {
            header
            statusLine
            Picker("View", selection: $session.projection) {
                ForEach(MediaProjection.allCases) {
                    Text($0.title).tag($0)
                }
            }.pickerStyle(.segmented)
            layoutRow
            DepthControlsRow(conversion: session.conversion)
            GeometryReader { geometry in
                touchSurface(width: geometry.size.width)
            }.frame(minHeight: 100)
            if session.isMovie {
                VStack(spacing: 4) {
                    if session.duration > 0 {
                        timeline
                    }
                    transportButtons
                }.frame(minHeight: 82)
            }
        }.padding(.horizontal, 10).padding(.bottom, 8)
            .onChange(of: session.projection) { _ in
                resetSurface()
            }
            .onDisappear(perform: resetSurface)
            .sheet(isPresented: $showingDiagnostics) {
                MediaDiagnosticsSheet(session: session, isPresented: $showingDiagnostics)
            }
    }

    // Recenter, title and close button.
    private var header: some View {
        HStack(spacing: 6) {
            Button(action: session.recenter) {
                Text("Recenter").font(.footnote.weight(.semibold)).frame(width: 88, height: 44)
            }.disabled(!canPan)
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Text("Spatial Player").font(.headline)
                Text(session.file?.title ?? "").font(.caption)
                    .foregroundStyle(ControllerPalette.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity)
            Spacer(minLength: 6)
            Button(action: session.close) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }.accessibilityLabel("Close player")
                .accessibilityIdentifier("closeSpatialPlayer")
        }.buttonStyle(ControllerButtonStyle())
            .foregroundStyle(ControllerPalette.text)
    }

    // Fixed height, so the controls below don't jump when the message changes.
    private var statusLine: some View {
        Text(phoneStatus ?? " ")
            .font(.footnote).foregroundStyle(ControllerPalette.secondary)
            .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
    }

    // Eye layout menu, world-fixed toggle and the options menu.
    private var layoutRow: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Layout", selection: $session.arrangement) {
                    ForEach(session.availableArrangements) {
                        Text($0.title).tag($0)
                    }
                }
                if session.arrangement != .mono {
                    Toggle("Swap eyes", isOn: $session.swapEyes)
                }
            } label: {
                Label(session.arrangement.title, systemImage: "rectangle.split.2x1")
                    .padding(.horizontal, 10).frame(height: 44)
            }.buttonStyle(ControllerButtonStyle())
            Spacer(minLength: 0)
            if session.canConvertTo3D || session.conversion.isActive {
                Convert3DButton(conversion: session.conversion) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        session.toggleConversion()
                    }
                }
            }
            if session.projection == .flat {
                Button {
                    session.roomScreen.toggle()
                } label: {
                    Label("World-fixed", systemImage: "scope")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }.buttonStyle(ControllerButtonStyle(selected: session.roomScreen))
                    .accessibilityLabel("World-fixed")
                    .accessibilityAddTraits(session.roomScreen ? .isSelected : [])
            }
            Menu {
                Button("Open in screen", systemImage: "rectangle.on.rectangle", action: openInPanel)
                Button("Media diagnostics", systemImage: "waveform.path.ecg") {
                    showingDiagnostics = true
                }
                Button("Close player", systemImage: "xmark", action: session.close)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.buttonStyle(ControllerButtonStyle()).accessibilityLabel("Player options")
        }.font(.footnote.weight(.semibold))
    }

    // The large pad: tap to play or pause, drag to look around or to scrub.
    private func touchSurface(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: surfaceIcon)
                .font(.system(size: 36, weight: .light)).foregroundStyle(ControllerPalette.accent)
                .accessibilityHidden(true)
            surfaceHint
        }
        .font(.subheadline).foregroundStyle(ControllerPalette.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [ControllerPalette.selected, ControllerPalette.background],
                center: .center, startRadius: 6, endRadius: 285), in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28).strokeBorder(ControllerPalette.control)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: togglePlayback)
        .gesture(
            DragGesture(minimumDistance: 12).onChanged { move in
                surfaceDragChanged(move, width: width)
            }.onEnded { _ in
                surfaceDragEnded()
            }
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder private var surfaceHint: some View {
        if session.isMovie {
            if canPan && session.projection != .flat {
                Text("Tap to play or pause · Drag to look around")
            } else {
                Text("Tap to play or pause · Slide to scrub")
            }
        } else if canPan {
            Text("Drag to look around")
        } else {
            Text("Photo")
        }
    }

    // A drag either turns the view or, for flat videos, previews a new time.
    private func surfaceDragChanged(_ move: DragGesture.Value, width: CGFloat) {
        if canPan && (!session.isMovie || session.projection != .flat) {
            session.pan(
                dx: move.translation.width - dragged.width,
                dy: move.translation.height - dragged.height)
            dragged = move.translation
        } else if session.isMovie, session.duration > 0, !session.loading {
            let start = surfaceSeekStart ?? session.position
            surfaceSeekStart = start
            // A full-width slide moves up to two minutes.
            let fraction = Double(move.translation.width / max(width, 1))
            session.showScrubPreview(start + fraction * min(120, session.duration))
        }
    }

    private func surfaceDragEnded() {
        if surfaceSeekStart != nil, let preview = session.scrubPreview {
            session.seek(to: preview)
        }
        resetSurface()
    }

    // Current time, position slider and total length.
    private var timeline: some View {
        HStack {
            Text(NativeMediaSession.timeLabel(session.scrubPreview ?? session.position))
            Slider(
                value: Binding(
                    get: {
                        min(session.scrubPreview ?? session.position, session.duration)
                    },
                    set: {
                        scrub = $0
                        session.showScrubPreview($0)
                    }),
                in: 0...session.duration,
                onEditingChanged: sliderEditingChanged
            ).accessibilityLabel("Playback position")
            Text(NativeMediaSession.timeLabel(session.duration))
        }.font(.caption.monospacedDigit()).foregroundStyle(ControllerPalette.secondary)
    }

    // While the slider is held, only preview the time. Seek once it is released.
    private func sliderEditingChanged(_ editing: Bool) {
        if editing {
            scrubbing = true
            scrub = min(session.position, session.duration)
            session.showScrubPreview(scrub)
        } else if scrubbing {
            scrubbing = false
            session.seek(to: scrub)
            session.showScrubPreview(nil)
        }
    }

    // Back 10 s, play or pause, forward 10 s.
    private var transportButtons: some View {
        HStack(spacing: 24) {
            Button {
                session.seek(to: session.position - 10)
            } label: {
                Image(systemName: "gobackward.10").frame(width: 44, height: 44)
            }.disabled(session.duration <= 0).accessibilityLabel("Back 10 seconds")
            Button(action: togglePlayback) {
                Image(systemName: session.playing ? "pause.fill" : "play.fill")
                    .frame(width: 56, height: 44)
            }.buttonStyle(ControllerButtonStyle(solid: true))
                .accessibilityLabel(session.playing ? "Pause" : "Play")
            Button {
                session.seek(to: session.position + 10)
            } label: {
                Image(systemName: "goforward.10").frame(width: 44, height: 44)
            }.disabled(session.duration <= 0).accessibilityLabel("Forward 10 seconds")
        }.buttonStyle(ControllerButtonStyle()).disabled(session.loading || session.error != nil)
    }

    private var canPan: Bool { session.projection != .flat || session.roomScreen }
    private var surfaceIcon: String {
        if session.isMovie {
            return session.playing ? "pause.fill" : "play.fill"
        }
        return canPan ? "hand.draw" : "photo"
    }
    private var phoneStatus: String? {
        if let error = session.error {
            return error
        }
        if !display.hasExternalDisplay {
            return "Connect the glasses to view this item."
        }
        return session.presentationHint(
            stereo: display.externalStereo, rendererUnavailable: display.nativeMediaRendererUnavailable)
    }

    private func togglePlayback() {
        guard session.isMovie, !session.loading, session.error == nil else {
            return
        }
        if session.playing {
            session.pause()
        } else {
            session.play()
        }
    }

    private func resetSurface() {
        dragged = .zero
        surfaceSeekStart = nil
        scrubbing = false
        if session.scrubPreview != nil {
            session.showScrubPreview(nil)
        }
    }
}
