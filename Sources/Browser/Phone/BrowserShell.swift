import UniformTypeIdentifiers
import SwiftUI
import WebKit

import SpatialMath
import AdapterTracking
/// The phone controller for the browser: trackpad, toolbar, menus and settings.
struct BrowserShell: View {
    @ObservedObject var browser: BrowserScreen
    /// The first screen. Workspace actions go through it.
    @ObservedObject var owner: BrowserScreen
    @ObservedObject var workspace: Workspace
    @ObservedObject var display: GlassesDisplay
    @ObservedObject var phone: PhoneRemote
    @ObservedObject var native: NativeInput
    @ObservedObject var tracking: AdapterTracking
    @ObservedObject var media: BrowserMedia
    @ObservedObject var nativeMedia: NativeMediaSession
    @FocusState var focus: Field?
    @AppStorage("viture.trackpad.hasSeenHelp") var hasSeenHelp = false
    @State var help = false
    @State private var pickingFiles = false
    @State private var pickingPhotos = false
    @State private var importTarget: BrowserScreen?
    @State private var presentationToReplace: UUID?
    @State var openingItem = false
    @State private var fileError: String?
    @State var morePresented = false
    @State var moreTarget: BrowserScreen?
    @State var moreSelection: MoreCommand?
    @State var limitNotice = false
    @State var noticeTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var typing: Bool { browser.addressEditing || browser.phoneEditor != nil }
    var playing: Bool { media.video?.paused == false }
    enum Field: Hashable { case address, page(UUID) }

    enum MoreCommand: String, Identifiable {
        case undo = "Undo close", files = "Open Files", photos = "Open Photos"
        case fixDisplay = "Fix display", restartTracking = "Restart tracking", aim = "Aim again"
        case help = "Trackpad help", settings = "Settings"
        case viewMedia = "Open in Spatial Player"
        case exitVideo = "Exit video view"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .viewMedia:
                return "eyeglasses"
            case .exitVideo:
                return "arrow.down.right.and.arrow.up.left"
            case .undo:
                return "arrow.uturn.backward"
            case .files:
                return "folder"
            case .photos:
                return "photo.on.rectangle"
            case .fixDisplay:
                return "display"
            case .restartTracking:
                return "arrow.clockwise"
            case .aim:
                return "scope"
            case .help:
                return "questionmark.circle"
            case .settings:
                return "gearshape"
            }
        }
    }

    init(browser: BrowserScreen, display: GlassesDisplay, native: NativeInput) {
        self.browser = browser
        self.owner = browser.owner
        self.workspace = browser.workspace
        self.display = display
        self.phone = display.phone
        self.native = native
        self.tracking = display.tracking
        self.media = browser.media
        self.nativeMedia = display.nativeMedia
    }

    var body: some View {
        Group {
            if nativeMedia.file != nil {
                NativeMediaControls(
                    session: nativeMedia, display: display, openInPanel: owner.returnNativeMediaToPanel)
            } else {
                browserContent
            }
        }
        .background(ControllerPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(ControllerPalette.accent)
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            persistentControls.frame(height: 44).padding(.horizontal, 10)
            currentScreen
        }
        .background(ControllerPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(ControllerPalette.accent)
        .sheet(isPresented: $morePresented, onDismiss: runMoreCommand) {
            moreSheet
        }
        .onChange(of: owner.selectedPanel) { _ in
            focus = nil
        }
        .onChange(of: browser.localPicker) { choice in
            handleLocalPickerRequest(choice)
        }
        .fileImporter(
            isPresented: $pickingFiles,
            allowedContentTypes: presentationToReplace != nil ? [.pdf] : LocalPanelFile.allowedFiles
        ) { result in
            handlePickedFile(result)
        }
        .onChange(of: pickingFiles) { visible in
            filePickerVisibilityChanged(visible)
        }
        .sheet(
            isPresented: $pickingPhotos,
            onDismiss: {
                if !openingItem {
                    importTarget?.localPickerStatus = nil
                }
            }
        ) {
            photosPicker
        }
        .alert(
            "Couldn’t open the item",
            isPresented: Binding(
                get: { fileError != nil },
                set: {
                    if !$0 {
                        fileError = nil
                    }
                })
        ) {
            Button("OK") {
                fileError = nil
            }
        } message: {
            Text(fileError ?? "")
        }
        .alert("Trackpad controls", isPresented: $help) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text(
                """
                Slide one finger to move the cursor. Tap to click. Tap with two fingers to right-click. \
                Drag with two fingers to scroll. Hold two fingers to recenter the workspace.
                """
            )
        }
    }

    // Settings, a website popup, the phone sign-in page, or the normal controller.
    @ViewBuilder private var currentScreen: some View {
        if browser.controllerSettings {
            settings
        } else if let popup = browser.popup {
            popupScreen(popup)
        } else if browser.phonePageActive {
            PhoneSignInView(browser: browser)
        } else {
            controller
        }
    }

    private func popupScreen(_ popup: WKWebView) -> some View {
        VStack {
            HStack {
                Text(browser.popupHost).lineLimit(1)
                Spacer()
                if browser.canResetPopupKeyboard {
                    Button("Reset keyboard") {
                        browser.restorePhoneSignInInput()
                    }.font(.footnote)
                }
                Button("Close") {
                    browser.closePopup()
                }
            }.padding(.horizontal)
            if browser.popupSignInProvider == .microsoft {
                MicrosoftPasskeyHint()
            }
            BrowserPopup(web: popup)
        }
    }

    private var photosPicker: some View {
        PanelPhotosPicker { provider in
            pickingPhotos = false
            guard let provider, let target = importTarget else {
                return
            }
            openPickedItem(for: target) {
                try await PanelPhotosPicker.open(provider)
            }
        }.ignoresSafeArea()
    }

    // A screen asked for a local file or photo. Open the matching iPhone picker.
    private func handleLocalPickerRequest(_ choice: LocalPanelPicker?) {
        guard let choice else {
            return
        }
        browser.localPicker = nil
        guard !openingItem, !pickingFiles, !pickingPhotos else {
            return
        }
        if choice == .presentationPDF && browser.localFile?.isPresentation != true {
            return
        }
        focus = nil
        importTarget = browser
        presentationToReplace = choice == .presentationPDF ? browser.localFile?.id : nil
        browser.localPickerStatus = "Choose an item on iPhone"
        switch choice {
        case .photos:
            pickingPhotos = true
        case .files, .presentationPDF:
            pickingFiles = true
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard let target = importTarget else {
            return
        }
        let replacing = presentationToReplace
        presentationToReplace = nil
        openPickedItem(for: target, replacingPresentation: replacing) {
            try LocalPanelFile.openOriginal(result.get())
        }
    }

    private func filePickerVisibilityChanged(_ visible: Bool) {
        guard !visible, let target = importTarget else {
            return
        }
        // A cancel may dismiss the importer without calling its result handler.
        DispatchQueue.main.async {
            if !openingItem, !pickingFiles, !pickingPhotos, importTarget === target {
                target.localPickerStatus = nil
            }
        }
    }

    private func openPickedItem(
        for target: BrowserScreen, replacingPresentation: UUID? = nil,
        load: @escaping @MainActor () async throws -> LocalPanelFile
    ) {
        openingItem = true
        target.localPickerStatus = "Opening selected item…"
        Task { @MainActor in
            defer {
                openingItem = false
                target.localPickerStatus = nil
                if importTarget === target {
                    importTarget = nil
                }
            }
            do {
                let file = try await load()
                if replacingPresentation == nil, await MediaFormat.prefersSpatialPlayer(for: file) {
                    owner.openNativeMedia(file, from: target)
                } else {
                    owner.openLocalFile(file, from: target, replacingPresentation: replacingPresentation)
                }
            } catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError {
                    fileError = error.localizedDescription
                    target.showNotice("Couldn’t open the item. See iPhone.")
                }
            }
        }
    }

}
