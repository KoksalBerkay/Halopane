import SwiftUI

/// Tools for finding decoding problems. Opened from the player's options menu.
struct MediaDiagnosticsSheet: View {
    @ObservedObject var session: NativeMediaSession
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Decoder and display") {
                    Picker(
                        "Spatial decoder",
                        selection: Binding(get: { session.stereoDecoder }, set: session.setStereoDecoder)
                    ) {
                        ForEach(StereoDecoderChoice.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    if session.arrangement == .separateEyes {
                        Picker("Flat stereo display", selection: $session.stereoPresentation) {
                            ForEach(StereoPresentationRoute.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        Picker("Eye preview", selection: $session.stereoEyePreview) {
                            ForEach(StereoEyePreview.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                    }
                    Text(
                        """
                        Changing the decoder reopens a spatial clip. \
                        Press Play again after closing this sheet.
                        """
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Paused frame") {
                    Button("Check frame", action: session.checkPausedFrame)
                        .disabled(!session.isMovie || session.playing || session.checkingFrame)
                    if !session.diagnosticStatus.isEmpty {
                        Text(session.diagnosticStatus)
                    } else {
                        Text("Pause on a frame where you see the blocks, then check it.")
                    }
                    NavigationLink("Compare paused frame") {
                        PausedFrameComparisonView(session: session)
                    }.disabled(!session.isMovie || session.playing)
                    ShareLink("Share media diagnostics", item: session.diagnostics.report)
                }
            }
            .navigationTitle("Media diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

/// Shows the paused frame on the phone next to the glasses output.
private struct PausedFrameComparisonView: View {
    @ObservedObject var session: NativeMediaSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let comparison = session.comparison {
                    if comparison.right != nil {
                        Picker("Eye", selection: $session.comparisonEye) {
                            Text("Left").tag(StereoEyePreview.leftOnly)
                            Text("Right").tag(StereoEyePreview.rightOnly)
                        }.pickerStyle(.segmented)
                    }
                    if let actual = comparison.uiImage(right: session.comparisonEye == .rightOnly) {
                        Image(uiImage: actual).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .background(.black, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Paused frame shown on the phone")
                    }
                    Text("Same frame on the phone and glasses · \(comparison.timeLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Glasses output", selection: $session.comparisonRoute) {
                        ForEach(ComparisonGlassesRoute.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }.pickerStyle(.segmented)
                    Text(
                        """
                        Turn your head slowly with Metal selected. Then try Image view. \
                        Both show the same frozen frame. Note where you see the blocks: \
                        phone, glasses in Metal, or glasses in Image view.
                        """
                    )
                    .font(.subheadline)
                    Text("The frame stays in memory. The shared report includes timing and output choices only.")
                        .font(.caption).foregroundStyle(.secondary)
                    ShareLink("Share media diagnostics", item: session.diagnostics.report)
                } else {
                    Text(
                        session.comparisonStatus.isEmpty
                            ? "Preparing the paused frame…" : session.comparisonStatus)
                }
            }.padding()
        }
        .navigationTitle("Compare paused frame")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: session.comparePausedFrame)
        .onDisappear(perform: session.endComparison)
    }
}
