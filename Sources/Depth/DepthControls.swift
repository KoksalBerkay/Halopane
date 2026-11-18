import SpatialMath
import SwiftUI

/// The one-tap 3D button. It lights up while 3D is on and shows a spinner while
/// the model prepares, so a slow first start never looks like a missed tap.
struct Convert3DButton: View {
    @ObservedObject var conversion: StereoConversion
    let action: () -> Void

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
            .padding(.horizontal, 10)
            .frame(minWidth: 56, minHeight: 44)
        }
        .buttonStyle(ControllerButtonStyle(selected: conversion.isActive))
        .accessibilityLabel("Convert to 3D")
        .accessibilityValue(conversion.isActive ? "On" : "Off")
        .accessibilityAddTraits(conversion.isActive ? .isSelected : [])
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
