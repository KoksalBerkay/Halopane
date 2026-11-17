import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

// Adding and switching screens, and address entry helpers.
extension BrowserShell {
    var addPanelButton: some View {
        let atLimit = owner.allPanels.count >= 4
        return Button(action: addPanel) {
            Image(systemName: "plus").frame(width: 44, height: 44)
                .opacity(atLimit ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if atLimit {
                        Text("4/4").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(ControllerPalette.amber)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(ControllerPalette.background, in: Capsule())
                    }
                }
        }
        .disabled(!owner.canAddWebPanel)
        .accessibilityLabel("Add screen")
        .accessibilityValue(atLimit ? "Four of four screens" : "")
        .contextMenu {
            Button("New web screen", action: addPanel).disabled(atLimit)
            Button("Open Files") {
                browser.localPicker = .files
            }
            Button("Open Photos") {
                browser.localPicker = .photos
            }
            if workspace.hasUndo {
                Button("Undo close") {
                    owner.undoClose()
                }
            }
        }
    }

    private func addPanel() {
        guard owner.canAddWebPanel else {
            return
        }
        if owner.allPanels.count >= 4 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            limitNotice = true
            noticeTask?.cancel()
            noticeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled {
                    limitNotice = false
                }
            }
            return
        }
        owner.addPanel()
    }

    var panelSwitcher: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(owner.visiblePanels, id: \.panelNumber) { panel in
                        PanelChip(panel: panel, media: panel.media, owner: owner)
                            .id(panel.panelNumber)
                    }
                }.padding(.trailing, 8)
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(
                        width: 8)
                }
            }
            .onAppear {
                reader.scrollTo(owner.selectedPanel, anchor: .trailing)
            }
            .onChange(of: owner.selectedPanel) { id in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    reader.scrollTo(id, anchor: .trailing)
                }
            }
        }.frame(minWidth: 0, maxWidth: .infinity)
    }

    func keyboardType(for editor: BrowserScreen.PhoneEditor) -> UIKeyboardType {
        switch editor.mode {
        case "numeric":
            return .numberPad
        case "decimal":
            return .decimalPad
        case "email":
            return .emailAddress
        case "tel":
            return .phonePad
        case "url":
            return .URL
        case "search":
            return .webSearch
        default:
            switch editor.type {
            case "email":
                return .emailAddress
            case "number":
                return .numbersAndPunctuation
            case "tel":
                return .phonePad
            case "url":
                return .URL
            case "search":
                return .webSearch
            default:
                return .default
            }
        }
    }

    func submitAddress() {
        guard browser.receivesInput, browser.addressEditing else {
            return
        }
        browser.navigate(browser.addressDraft)
        browser.addressEditing = false
        focus = nil
    }
}
