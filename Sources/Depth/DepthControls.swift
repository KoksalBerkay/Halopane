import SpatialMath
import SwiftUI

/// The one-tap 3D button. It lights up while 3D is on and shows a spinner while
/// the model prepares, so a slow first start never looks like a missed tap.
struct Convert3DButton: View {
    @ObservedObject var conversion: StereoConversion
    /// Lights the button for 3D that needs no conversion, such as a side-by-side video.
    var packedOn = false
    /// Sized like the playback bar's other buttons.
    var compact = false
    let action: () -> Void

    private var lit: Bool { conversion.isActive || packedOn }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if conversion.phase == .preparing && conversion.failure == nil {
                    ProgressView().controlSize(.mini).tint(ControllerPalette.accent)
                } else {
                    Image(systemName: "cube.transparent")
                }
                Text("3D")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, compact ? 4 : 10)
            .frame(minWidth: compact ? 0 : 56, minHeight: compact ? 0 : 44)
        }
        .buttonStyle(ControllerButtonStyle(selected: lit))
        .accessibilityLabel("Convert to 3D")
        .accessibilityValue(lit ? "On" : "Off")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// Depth slider and pop-out switch. Shown only while 3D is on, and every change
/// is visible in the glasses straight away.
struct DepthControlsRow: View {
    @ObservedObject var conversion: StereoConversion

    var body: some View {
        if conversion.isActive {
            HStack(spacing: 10) {
                Image(systemName: "square.2.layers.3d")
                    .foregroundStyle(ControllerPalette.accent)
                    .accessibilityHidden(true)
                Text("Depth").font(.footnote.weight(.semibold))
                Slider(value: strength, in: 0.1...1)
                    .tint(ControllerPalette.accent)
                    .accessibilityLabel("Depth strength")
                    .accessibilityValue("\(Int(conversion.settings.strength * 100)) percent")
                Button {
                    conversion.settings.popOut.toggle()
                } label: {
                    Text("Pop-out").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 36)
                }
                .buttonStyle(ControllerButtonStyle(selected: conversion.settings.popOut))
                .accessibilityHint("Lets near objects come out of the screen")
                .accessibilityAddTraits(conversion.settings.popOut ? .isSelected : [])
            }
            .foregroundStyle(ControllerPalette.text)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var strength: Binding<Double> {
        Binding(
            get: {
                Double(conversion.settings.strength)
            },
            set: {
                conversion.settings.strength = Float($0)
            })
    }
}

/// One line on the phone that says what 3D is waiting for, if anything.
struct ConversionHint: View {
    @ObservedObject var conversion: StereoConversion
    @ObservedObject var display: GlassesDisplay

    var body: some View {
        if let text {
            Text(text).font(.caption).foregroundStyle(ControllerPalette.secondary).lineLimit(2)
        }
    }

    private var text: String? {
        guard conversion.isActive else {
            return nil
        }
        if let failure = conversion.failure {
            return failure
        }
        if !display.externalStereo {
            return "Switch the glasses to 3D mode to see depth."
        }
        if conversion.phase == .preparing {
            return "Preparing 3D…"
        }
        return nil
    }
}
