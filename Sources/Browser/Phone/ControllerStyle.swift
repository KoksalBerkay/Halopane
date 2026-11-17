import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

/// Colors for the phone controller.
enum ControllerPalette {
    static let background = Color(red: 11 / 255, green: 14 / 255, blue: 19 / 255)
    static let control = Color(red: 22 / 255, green: 28 / 255, blue: 37 / 255)
    static let text = Color(red: 201 / 255, green: 210 / 255, blue: 221 / 255)
    static let accent = Color(red: 95 / 255, green: 208 / 255, blue: 228 / 255)
    static let selected = Color(red: 27 / 255, green: 58 / 255, blue: 66 / 255)
    static let amber = Color(red: 240 / 255, green: 183 / 255, blue: 101 / 255)
    static let secondary = Color(red: 139 / 255, green: 150 / 255, blue: 165 / 255)
}

/// Button style for the phone controller.
struct ControllerButtonStyle: ButtonStyle {
    var selected = false
    var solid = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return configuration.label
            .foregroundStyle(
                solid ? ControllerPalette.background : selected ? ControllerPalette.accent : ControllerPalette.text
            )
            .background(
                solid
                    ? ControllerPalette.accent : selected ? ControllerPalette.selected : ControllerPalette.control,
                in: shape
            )
            .overlay {
                if selected && !solid {
                    shape.strokeBorder(ControllerPalette.accent.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
