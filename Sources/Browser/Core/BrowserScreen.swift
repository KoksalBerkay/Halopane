import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

/// Light, dark or system appearance for websites.
enum WebsiteAppearance: String, CaseIterable, Identifiable {
    case system = "Follow iPhone", dark = "Dark", light = "Light"
    var id: Self { self }
    static let preferenceKey = "viture.browser.websiteAppearance"

    func style(system: UIUserInterfaceStyle) -> UIUserInterfaceStyle {
        switch self {
        case .system:
            return system
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }
}

/// How screens are drawn in the glasses. Replica is the normal mode.
enum WebBackend: String, CaseIterable, Identifiable {
    case native = "A · Native mono"
    case replica = "B · Replicator control"
    case portal = "B · Private portal stereo"
    case snapshot = "C · Snapshot → Metal"
    var id: String { rawValue }
}
/// What moves the pointer: head, phone or trackpad.
enum WebInput: String, CaseIterable, Identifiable {
    case trackpad = "Trackpad"
    case gaze = "Gaze + tap"
    case remote = "Phone aim"
    var id: String { rawValue }
}

/// One browser screen in the glasses. State shared by all screens lives in `workspace`.
/// Workspace actions (adding screens, placement, the pointer) run on the first screen, `owner`.
final class BrowserScreen: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = BrowserScreen()
    let panelNumber: Int
    let native: NativeInput
    /// State shared by all screens. The first screen creates it; the others use the same one.
    let workspace: Workspace
    private var workspaceChanges: AnyCancellable?
    var scroll = ScrollState()
    var cloudPage = CloudPageState()
    var editorState = PhoneEditorState()
    var frameStats = FrameStats()
    var diagnostics = DiagnosticNotes()
    var slot: Int
    var displayIndex: Int { (owner.visiblePanels.firstIndex { $0 === self } ?? 0) + 1 }
    var siteLabel: String {
        if let localFile, localFile.matches(web.url) {
            return localFile.title
        }
        return web.url?.host?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? "Home"
    }
    var reportSiteLabel: String {
        if localFile != nil {
            return "local item"
        }
        return ReportSite.label(web.url)
    }
    /// The first screen lists every screen. Any other screen lists only itself.
    var allPanels: [BrowserScreen] {
        guard self === owner else {
            return [self]
        }
        return [self] + workspace.panels
    }
    var homeHoverAt: CFTimeInterval = 0
    var lastHomeCursor: SIMD2<Float>?
    var backdropQuery = 0
    var fullChromeY: Float?
    var fullCursorBounds: ClosedRange<Float>?
    var fullScreenAvailable: Bool { owner.backend == .replica && !owner.native.phoneHosted }
    @Published var localPicker: LocalPanelPicker?
    @Published var localPickerStatus: String?
    weak var nativeMediaSource: BrowserScreen?
    @Published var localFile: LocalPanelFile?
    var pendingLocalNavigation: WKNavigation?
    var localPhotoZoom: CGFloat = 1
    @Published var stereoPacking: StereoPacking?
    @Published var stereoSwapEyes = false
    var drawingStereoVideo = false

    var effectiveInput: WebInput { fullScreenRouting ? .trackpad : workspace.input }

    var selectedPanel: Int { workspace.inputRoute.selected }
    var selectedSession: BrowserScreen { session(selectedPanel) ?? self }
    private weak var workspaceOwner: BrowserScreen?
    var owner: BrowserScreen { workspaceOwner ?? self }
    var receivesInput: Bool { owner.selectedSession === self && owner.signInSession == nil }
    var offset = PanelOffset()
    var panelWarming = false
    var navigationFinished = false
    static var tapQueue = SerialTapQueue<QueuedTap>()
    @Published var active = false
    @Published var backend: WebBackend = .replica

    @Published var snapshotFPS = 30.0
    @Published var snapshotAfterUpdates = false
    @Published var urlText = ""

    var adsEnabled: Bool { workspace.adSettings.state.masterEnabled }
    @Published var xboxCloudProfile = BrowserScreen.savedCloudProfile(.xbox) {
        didSet {
            updateCloudProfile(.xbox, from: oldValue, to: xboxCloudProfile)
        }
    }
    @Published var geforceNowProfile = BrowserScreen.savedCloudProfile(.geforceNow) {
        didSet {
            updateCloudProfile(.geforceNow, from: oldValue, to: geforceNowProfile)
        }
    }
    @Published var lunaCloudProfile = BrowserScreen.savedCloudProfile(.luna) {
        didSet {
            updateCloudProfile(.luna, from: oldValue, to: lunaCloudProfile)
        }
    }
    let cloudController = CloudControllerBridge()
    var installedCloudApps = Set<CloudGamingService>()
    var installedRules: [WKContentRuleList] = []
    var homeObservation: AnyCancellable?
    var homeStatus: String?
    @Published var pageAddress = ""
    @Published var addressEditing = false {
        didSet {
            if !addressEditing {
                homeSearchEditing = false
            }
        }
    }
    var homeSearchEditing = false
    @Published var addressDraft = ""
    @Published var controllerSettings = false
    @Published var bookmarksOpen = false
    @Published var moreOpen = false
    @Published var historyOpen = false
    /// One history entry.
    struct Visit: Codable {
        let url: String
        let title: String
    }
    var lastRecordedAddress: String?
    var historyOffset = 0
    var workspaceBookmarks: [String] { workspace.bookmarks }
    var surfaceRevision = 0
    var backgrounded = false
    var needsProcessReload = false
    var didAttemptProcessReload = false
    @Published var canBack = false
    @Published var canForward = false
    var navigationObservers = [NSKeyValueObservation]()
    var lifecycleObservers = [NSObjectProtocol]()
    @Published var popup: WKWebView?
    @Published var phonePageActive = false
    @Published var canOpenSignInOnPhone = false
    @Published var popupSignInProvider: PhoneSignInProvider?
    var canResetPopupKeyboard: Bool { popupSignInProvider != nil }
    var popupSignInPreferences: (preferences: WKPreferences, wasEnabled: Bool)?
    @Published var popupHost = ""
    @Published var keyboardText = ""
    /// A web text field mirrored to the phone keyboard.
    struct PhoneEditor {
        let id: UUID
        var text: String
        let type: String
        let mode: String
        var secure: Bool { type == "password" }
    }
    @Published var phoneEditor: PhoneEditor?
    @Published var phoneEditorFocusRevision = 0
    static let phoneEditorWorld = WKContentWorld.world(name: "ViturePhoneEditor")
    static let selectPickerWorld = WKContentWorld.world(name: "VitureSelectPicker")
    var editorWorld: WKContentWorld { Self.phoneEditorWorld }
    /// A synthetic tap or swipe waiting in the shared tap queue.
    struct QueuedTap {
        weak var session: BrowserScreen?
        let point: CGPoint
        let generation: UUID
        let useApplicationRoute: Bool
        var swipeEnd: CGPoint? = nil
        var scrollToken: UUID? = nil
        var trace: UUID? = nil
        var catalogPage: URL? = nil
        var retries = 0
    }
    var tapGeneration = UUID()
    /// Scroll by moving the scroll view directly, or with JavaScript.
    enum ScrollEngine: String, CaseIterable, Identifiable {
        case native = "Native offset"
        case script = "JavaScript"
        var id: String { rawValue }
    }
    enum ShortsDrag { case none, probing, step }
    let scrollGain: CGFloat = 2.5
    let scrollWorld = WKContentWorld.world(name: "VitureTrackpadScroll")
    @Published var status = "Open the web probe with the glasses connected."
    @Published var metrics = ""
    @Published var inputStatus = "Trackpad moves the cyan cursor. Tap clicks; two fingers scroll."
    @Published var running = false
    @Published var completed = [String]()
    @Published var portalStatus = "Not attempted"
    let media = BrowserMedia()
    let webPreferences = WKPreferences()
    /// Whether WebKit's encrypted media (FairPlay) APIs were switched on for this screen.
    private(set) var encryptedMediaStatus = "Not set"
    /// The last MediaSource switch, for the diagnostics report.
    var mediaSourceStatus = "Not switched yet"
    let web: WKWebView
    @Published var isLoadingPage = false
    @Published var browserNotice = ""
    private var noticeID = UUID()
    var isCinema: Bool { media.mapping != nil }
    var isHome: Bool {
        Self.isBundledHome(web.url)
    }
    private static func isBundledHome(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let bundled = Bundle.main.url(forResource: "home", withExtension: "html") else {
            return false
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
            == bundled.resolvingSymlinksInPath().standardizedFileURL
    }
    var isFixture: Bool { web.url?.isFileURL == true && web.url?.lastPathComponent == "web-probe.html" }
    var cursor = SIMD2<Float>(500, 312.5)
    var effectiveCursor: SIMD2<Float>?
    var chromeInset: Float {
        return Float(BrowserChromeLayout.height)
    }
    var sourceReady = false
    var epoch = UUID()
    var uploadSnapshot: ((CGImage) throws -> Double)?

    init(panelNumber: Int = 1, slot: Int = 0, owner: BrowserScreen? = nil) {
        self.slot = slot
        self.panelNumber = panelNumber
        workspaceOwner = owner
        workspace = owner?.workspace ?? Workspace()
        native = owner == nil ? NativeInput.shared : NativeInput()
        let configuration = WKWebViewConfiguration()
        configuration.preferences = webPreferences
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isTextInteractionEnabled = false
        // Must run before the web view is created; WebKit copies the preferences then.
        let encryptedMedia = VXREnableEncryptedMedia(webPreferences)
        media.configure(in: configuration)
        let scripts = Self.browserScripts(media: media, scrollWorld: scrollWorld)
        scripts.forEach(configuration.userContentController.addUserScript)
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 625), configuration: configuration)
        super.init()
        encryptedMediaStatus = encryptedMedia
        if owner == nil {
            workspace.primary = self
            // Views observe the first screen. Keep them updating when shared state changes.
            workspaceChanges = workspace.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        applyWebsiteAppearance()
        web.configuration.userContentController.add(
            WeakMessageHandler(self), contentWorld: editorWorld, name: "vxrEditorTap")
        setUpBrowserFeatures(owner: owner)
        web.navigationDelegate = self
        web.uiDelegate = self
        native.web = web
        native.onHostChange = { [weak self] enabled in
            guard let self else {
                return
            }
            self.backend = enabled ? .portal : .replica
            self.modeChanged()
        }
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.contentInsetAdjustmentBehavior = .never
        observeNavigation()
        observeAppLifecycle()
    }

    func open() {
        resetPanelAnchor()
        active = true
        if self === owner, workspace.input == .remote {
            GlassesDisplay.shared.phone.start()
        }
        if !sourceReady {
            loadHome()
        }
        refreshPageBackdrop()
    }
    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func close() {
        returnSignInToGlasses()
        media.reset()
        cancelTaps()
        cancelScroll()
        active = false
        if self === owner, workspace.input == .remote {
            GlassesDisplay.shared.phone.stop()
        }
        resetPanelAnchor()
        closePhoneEditor()
        native.archive("Probe closing")
        native.cancel("Probe closed")
        if self === owner {
            native.dismissKeyboard()
        }
        cancelRun("Probe closed")
        web.evaluateJavaScript(
            "window.__vxrScrollToken=null;document.querySelectorAll('video').forEach(v=>v.pause())",
            completionHandler: nil)
    }
    func modeChanged() {
        if self === owner, !fullScreenAvailable {
            workspace.fullScreen = false
            workspace.expansion = PanelExpansion()
        }
        if backend != .replica || native.phoneHosted {
            selectPanel(1)
        }
        media.setCinema(false)
        cancelTaps()
        cancelScroll()
        closePhoneEditor()
        native.archive("Rendering backend changing")
        native.cancel("Backend changed")
        if backend != .portal, native.phoneHosted {
            native.setPhoneHost(false)
        }
        epoch = UUID()
        cancelRun("Backend changed")
        resetCounters()
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "vxrEditorTap" {
            guard message.webView === web, !message.frameInfo.isMainFrame, active, receivesInput,
                !phonePageActive, popup == nil, let started = editorState.tapStarted,
                CACurrentMediaTime() - started < 0.65, message.body as? Bool == true
            else {
                return
            }
            editorState.tapFrame = message.frameInfo
            return
        }
        guard message.name == "vxrHomeAction", message.webView === web, message.frameInfo.isMainFrame,
            Self.isBundledHome(message.frameInfo.request.url), isHome, active, receivesInput,
            popup == nil, let action = LocalPanelPicker.homeAction(message.body as? String)
        else {
            return
        }
        localPicker = action
    }

    func showNotice(_ message: String) {
        browserNotice = message
        let id = UUID()
        noticeID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.noticeID == id else {
                return
            }
            self.browserNotice = ""
        }
    }

}
