import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

// The phone controller: trackpad area, bottom strip and banners.
extension BrowserShell {
    var controller: some View {
        VStack(spacing: 8) {
            trackpad
            bottomStrip.frame(height: typing ? 44 : 96)
        }
        .padding(.horizontal, 10).padding(.top, 8)
        .onChange(of: browser.popup != nil) {
            if $0 {
                browser.addressEditing = false
                focus = nil
            }
        }
        .onChange(of: browser.addressEditing) { editing in
            if !editing && focus == .address {
                focus = nil
            }
        }
        .onChange(of: browser.phoneEditorFocusRevision) { _ in
            refocusPageTextField()
        }
        .onChange(of: focus) { field in
            if field == nil && browser.addressEditing {
                browser.addressEditing = false
            }
        }
        .onAppear {
            if !hasSeenHelp {
                hasSeenHelp = true
                help = true
            }
        }
    }

    // The large touch area that drives the pointer, clicks and scrolling in the glasses.
    private var trackpad: some View {
        WebTouchpad(
            swipeToScroll: owner.effectiveInput != .trackpad, move: owner.moveWorkspacePointer,
            click: owner.clickWorkspace,
            scroll: owner.scrollWorkspace, beginScroll: owner.beginWorkspaceScroll,
            stopScroll: owner.cancelWorkspaceScroll,
            endScroll: owner.endWorkspaceScroll,
            recenter: workspace.fullScreen ? nil : owner.centerPanelNow, dark: true,
            fullScreen: workspace.fullScreen, playing: playing, reduceMotion: reduceMotion,
            selectedPanel: browser.panelNumber, panelLabel: browser.displayIndex,
            secondaryClick: owner.secondaryClickWorkspace,
            photoPinch: browser.canZoomLocalPhoto ? browser.zoomLocalPhoto : nil
        )
        .frame(maxWidth: .infinity, minHeight: typing ? 140 : 0, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if workspace.fullScreen || typing {
                Text(workspace.fullScreen ? "Full Screen · Screen \(browser.displayIndex)" : "Trackpad")
                    .font(.caption2.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(ControllerPalette.secondary)
                    .padding(12).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                controllerBanner
                if limitNotice {
                    Text("You can open up to four screens. Close one to add another.")
                        .font(.caption.weight(.semibold)).padding(8)
                        .foregroundStyle(ControllerPalette.amber)
                        .background(ControllerPalette.background, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // The page asked to focus its text field again. Drop focus first so the keyboard reappears.
    private func refocusPageTextField() {
        guard let editor = browser.phoneEditor, !browser.addressEditing, !native.keyboardVisible else {
            return
        }
        if focus == .page(editor.id) {
            focus = nil
        }
        DispatchQueue.main.async {
            if browser.phoneEditor?.id == editor.id && !browser.addressEditing {
                focus = .page(editor.id)
            }
        }
    }

    // Below the trackpad: an address field, a page text field, or status and playback controls.
    @ViewBuilder private var bottomStrip: some View {
        VStack(spacing: 4) {
            if browser.addressEditing {
                addressField
            }
            if let editor = browser.phoneEditor, !browser.addressEditing {
                pageTextField(editor)
            }
            if !typing {
                stripStatus
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ControllerPalette.control.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private var addressField: some View {
        HStack {
            TextField("Address or search", text: $browser.addressDraft)
                .keyboardType(.webSearch).submitLabel(.go).autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .address)
                .onSubmit(submitAddress)
            Button("Cancel") {
                focus = nil
                browser.addressEditing = false
            }
        }
        .padding(.horizontal, 8)
        .id(browser.panelNumber)
        .onAppear {
            focus = .address
        }
    }

    // Mirrors the web text field the user tapped, so they can type with the iPhone keyboard.
    private func pageTextField(_ editor: BrowserScreen.PhoneEditor) -> some View {
        HStack {
            let binding = Binding(
                get: { browser.phoneEditor?.id == editor.id ? browser.phoneEditor?.text ?? "" : "" },
                set: {
                    if browser.phoneEditor?.id == editor.id {
                        browser.updatePhoneEditor($0)
                    }
                })
            Group {
                if editor.secure {
                    SecureField("Password", text: binding)
                } else {
                    TextField("Type on phone", text: binding)
                        .keyboardType(keyboardType(for: editor))
                        .textContentType(editor.type == "one-time-code" ? .oneTimeCode : nil)
                }
            }
            .autocorrectionDisabled(editor.secure || editor.type == "email")
            .textInputAutocapitalization(editor.secure || editor.type == "email" ? .never : .sentences)
            .focused($focus, equals: .page(editor.id))
            .submitLabel(.go)
            .onSubmit {
                browser.submitPhoneEditor()
            }
            Button("Done") {
                browser.closePhoneEditor()
            }
        }.id(editor.id).onAppear {
            // Wait for the replacement field to join the view hierarchy.
            DispatchQueue.main.async {
                if browser.phoneEditor?.id == editor.id && !browser.addressEditing {
                    focus = .page(editor.id)
                }
            }
        }.padding(.horizontal, 8)
    }

    @ViewBuilder private var stripStatus: some View {
        if let file = browser.localFile, file.isPresentation {
            presentationActions(file)
        } else if media.nativeFullscreen || media.video != nil {
            PlaybackControls(browser: browser, media: media, toggleAudio: browser.togglePanelAudio)
                .id(browser.panelNumber)
        } else {
            trackingStatusRow
        }
    }

    @ViewBuilder private func presentationActions(_ file: LocalPanelFile) -> some View {
        Text("PowerPoint preview may change the slide layout.")
            .foregroundStyle(ControllerPalette.secondary).font(.caption)
        HStack(spacing: 14) {
            ShareLink(item: file.url) {
                Label("Share original", systemImage: "square.and.arrow.up")
            }
            Button {
                browser.localPicker = .presentationPDF
            } label: {
                Label("Open PDF version", systemImage: "doc")
            }
        }.font(.footnote.weight(.semibold)).frame(minHeight: 44)
    }

    private var trackingStatusRow: some View {
        let trackingOn = tracking.active && tracking.measurement != nil
        return HStack(spacing: 8) {
            Circle().fill(trackingOn ? ControllerPalette.accent : ControllerPalette.amber)
                .frame(width: 7, height: 7)
            Text((trackingOn ? "Tracking on" : "Tracking pending") + " · " + owner.effectiveInput.rawValue)
                .font(.footnote).foregroundStyle(ControllerPalette.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                browser.addressEditing = true
            } label: {
                Label("Keyboard", systemImage: "keyboard").font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 44)
            }.buttonStyle(ControllerButtonStyle())
        }.padding(.horizontal, 6)
    }

    @ViewBuilder private var controllerBanner: some View {
        Group {
            if openingItem {
                ProgressView("Opening selected item…").padding(8)
            } else if browser.canOpenSignInOnPhone {
                Button("Use sign-in on iPhone") {
                    browser.openSignInOnPhone()
                }
            } else if !display.hasExternalDisplay {
                Text("Connect the glasses to see the browser.")
            } else if tracking.status.hasPrefix("Tracking unavailable.") {
                VStack(spacing: 4) {
                    Text(tracking.status).multilineTextAlignment(.center)
                    Button("Restart tracking") {
                        owner.restartTracking()
                    }
                }
            } else if !tracking.active {
                Button("Connect head tracking") {
                    tracking.connect()
                }
            } else if owner.effectiveInput == .remote
                && (phone.status.contains("unavailable") || phone.status.hasPrefix("Motion error"))
            {
                Text(phone.status).lineLimit(2)
            }
        }.font(.caption).padding(.horizontal, 8).padding(.top, 8)
    }

    var persistentControls: some View {
        HStack(spacing: 6) {
            Button {
                owner.centerPanelNow()
            } label: {
                Text("Recenter").font(.footnote.weight(.semibold)).frame(width: 88, height: 44)
            }.disabled(!tracking.active || workspace.fullScreen)
            Button {
                if workspace.fullScreen && (media.isVideoPresentation || browser.stereoPacking != nil) {
                    browser.exitVideoView()
                } else {
                    owner.toggleFullScreen()
                }
            } label: {
                Image(
                    systemName: workspace.fullScreen
                        ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
                .frame(width: 44, height: 44)
            }.buttonStyle(ControllerButtonStyle(selected: workspace.fullScreen, solid: workspace.fullScreen))
                .disabled(!workspace.fullScreen && (!display.hasExternalDisplay || !owner.fullScreenAvailable))
                .accessibilityLabel(
                    workspace.fullScreen
                        ? (media.isVideoPresentation || browser.stereoPacking != nil
                            ? "Exit video view" : "Exit Full Screen")
                        : "Full Screen")
            addPanelButton
            panelSwitcher
            Button(action: showMoreCommands) {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("More")
        }.buttonStyle(ControllerButtonStyle())
    }
}
