import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

// The More sheet and its commands.
extension BrowserShell {
    func showMoreCommands() {
        moreTarget = browser
        moreSelection = nil
        let mediaCommands: [MoreCommand] =
            browser.localFile.map { $0.kind != .document } == true ? [.viewMedia] : []
        let exits: [MoreCommand] = media.isVideoPresentation || browser.stereoPacking != nil ? [.exitVideo] : []
        moreCommands =
            exits + [.photos, .files] + mediaCommands + (workspace.hasUndo ? [.undo] : []) + [
                .fixDisplay, .restartTracking
            ] + ((owner.effectiveInput == .remote && tracking.active) ? [.aim] : []) + [.help, .settings]
        morePresented = true
    }

    var moreSheet: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        adBlockingSettings
                    } label: {
                        Label("Ad blocking", systemImage: "shield")
                    }
                }
                moreSection("Open", commands: [.photos, .files, .viewMedia])
                moreSection("Screen", commands: [.exitVideo, .undo])
                moreSection("Display and tracking", commands: [.fixDisplay, .restartTracking, .aim])
                moreSection("Help and settings", commands: [.help, .settings])
            }
            .navigationTitle("Phone and display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        morePresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func moreSection(_ title: String, commands: [MoreCommand]) -> some View {
        let visible = commands.filter { moreCommands.contains($0) }
        if !visible.isEmpty {
            Section(title) {
                ForEach(visible) { command in
                    Button {
                        moreSelection = command
                        morePresented = false
                    } label: {
                        Label(command.rawValue, systemImage: command.symbol)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    func runMoreCommand() {
        let command = moreSelection
        let target = moreTarget
        moreSelection = nil
        moreTarget = nil
        guard let command else {
            return
        }
        if command == .settings {
            focus = nil
            owner.selectedSession.controllerSettings = true
            return
        }
        guard let target else {
            return
        }
        guard target === owner.selectedSession else {
            owner.selectedSession.showNotice("Screen changed. Open the menu again.")
            return
        }
        switch command {
        case .undo:
            owner.undoClose()
        case .files:
            target.localPicker = .files
        case .photos:
            target.localPicker = .photos
        case .viewMedia:
            if let file = target.localFile {
                owner.openNativeMedia(file, from: target)
            }
        case .exitVideo:
            target.exitVideoView()
        case .fixDisplay:
            focus = nil
            target.resetBrowserView()
        case .restartTracking:
            owner.restartTracking()
        case .aim:
            if tracking.active {
                target.aimPhoneNow()
            }
        case .help:
            help = true
        case .settings:
            return
        }
    }
}
