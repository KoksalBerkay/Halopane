import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

/// Adjust the part of the glasses display that is actually visible.
struct VisibleAreaCalibration: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        Form {
            Section {
                Text(
                    """
                    Adjust each edge until you can see the entire cyan border and all four corner marks in the \
                    glasses.
                    """
                )
                inset("Top", \.top)
                inset("Bottom", \.bottom)
                inset("Left", \.left)
                inset("Right", \.right)
                Button("Restore default insets") {
                    workspace.visibleArea = VisibleArea()
                }
            }
        }
        .navigationTitle("Visible area")
        .onAppear {
            workspace.calibratingVisibleArea = true
        }
        .onDisappear {
            workspace.calibratingVisibleArea = false
        }
    }
    private func inset(_ title: String, _ key: WritableKeyPath<VisibleArea, Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int(round(workspace.visibleArea[keyPath:key]*100)))%")
            Slider(
                value: Binding(
                    get: { workspace.visibleArea[keyPath: key] },
                    set: {
                        workspace.visibleArea[keyPath: key] = $0
                    }),
                in: 0...0.25, step: 0.01
            )
            .accessibilityLabel(title + " inset")
        }
    }
}
