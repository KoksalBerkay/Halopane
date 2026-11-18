import Combine
import QuartzCore
import SpatialMath
import UIKit
import simd

/// State shared by every screen in the glasses: the screen list, full screen, placement,
/// input mode, preferences, history, bookmarks, ad blocking and Home shortcuts.
/// Every BrowserScreen holds the same instance. The first screen is `primary`.
final class Workspace: ObservableObject {
    /// The first screen. Settings changes that affect a screen apply to it.
    weak var primary: BrowserScreen?

    // MARK: Screens and full screen

    /// Extra screens after the first. The first screen is `primary`.
    @Published var panels: [BrowserScreen] = []
    @Published var hasUndo = false
    var closedPanel: BrowserScreen?
    var undoID = UUID()
    var nextPanelID = 2
    @Published var audioOwnerID: Int?
    var audioCommandInFlight = false
    @Published var inputRoute = PanelInputRoute(selected: 1)
    @Published var fullScreen = false
    var expansion = PanelExpansion()
    var previousFullPanel: (id: Int, time: CFTimeInterval)?
    /// The part of the glasses display the user can actually see.
    @Published var visibleArea =
        (try? JSONDecoder().decode(
            VisibleArea.self, from: UserDefaults.standard.data(forKey: "viture.browser.visibleArea") ?? Data()))
        ?? VisibleArea()
    {
        didSet {
            if let data = try? JSONEncoder().encode(visibleArea) {
                UserDefaults.standard.set(data, forKey: "viture.browser.visibleArea")
            }
        }
    }
    @Published var calibratingVisibleArea = false
    /// The full-screen toolbar stays visible until this time.
    var toolbarUntil: CFTimeInterval = 0

    // MARK: Input and pointer

    @Published var input =
        WebInput(rawValue: UserDefaults.standard.string(forKey: "viture.browser.input") ?? "") ?? .remote
    {
        didSet {
            guard oldValue != input else {
                return
            }
            UserDefaults.standard.set(input.rawValue, forKey: "viture.browser.input")
            primary?.selectedSession.cancelScroll()
            primary?.selectedSession.cancelTaps()
            primary?.effectiveCursor = nil
            lastAimedPlacement = -1
            if input == .remote {
                GlassesDisplay.shared.phone.start()
            } else {
                GlassesDisplay.shared.phone.stop()
            }
        }
    }
    @Published var laserEnabled = UserDefaults.standard.object(forKey: "viture.browser.laser") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(laserEnabled, forKey: "viture.browser.laser")
        }
    }
    @Published var scrollEngine =
        BrowserScreen.ScrollEngine(rawValue: UserDefaults.standard.string(forKey: "viture.browser.scrollEngine") ?? "")
        ?? .native
    {
        didSet {
            primary?.cancelScroll()
            UserDefaults.standard.set(scrollEngine.rawValue, forKey: "viture.browser.scrollEngine")
        }
    }
    var pointerHit: PanelPointerHit?
    var pointerTapAt: CFTimeInterval = -.infinity
    /// The panel the phone was last aimed at.
    var aimedPanel = 0
    var inputLog: [String] = []
    var switchLog: [String] = []

    // MARK: Placement and tracking

    @Published var anchorMode =
        PanelAnchorMode(rawValue: UserDefaults.standard.string(forKey: "viture.browser.anchor") ?? "") ?? .world
    {
        didSet {
            UserDefaults.standard.set(anchorMode.rawValue, forKey: "viture.browser.anchor")
            if oldValue != anchorMode {
                primary?.resetPanelAnchor(reason: "Anchor mode changed to \(anchorMode.rawValue)")
            }
        }
    }
    @Published var followDeadZone = UserDefaults.standard.object(forKey: "viture.browser.followZone") as? Double ?? 22 {
        didSet {
            UserDefaults.standard.set(followDeadZone, forKey: "viture.browser.followZone")
        }
    }
    @Published var followSpeed = UserDefaults.standard.object(forKey: "viture.browser.followSpeed") as? Double ?? 5 {
        didSet {
            UserDefaults.standard.set(followSpeed, forKey: "viture.browser.followSpeed")
        }
    }
    var placement = WorkspacePlacement()
    var lastAimedPlacement = -1
    @Published var centerCountdown = 0
    @Published var centerMessage = ""
    var pendingRecenter: RecenterRequest?
    var lastPlacedConnection: Int?
    var initialSetup = false
    var trackingPaused = false
    var hadLiveTracking = false
    var lastWorldCamera = SceneMath.identity
    var lastFrameLive = false
    var poseRecoveryPending = false
    let drift = BrowserDriftLog()
    var inactiveSince: CFTimeInterval?
    var recentInactivePeriods: [ClosedRange<CFTimeInterval>] = []

    // MARK: Browsing preferences

    @Published var preferDesktop = UserDefaults.standard.bool(forKey: "viture.browser.desktop") {
        didSet {
            UserDefaults.standard.set(preferDesktop, forKey: "viture.browser.desktop")
        }
    }
    /// Pages shown as Mac Safari get MediaSource, which iPhone WebKit leaves off.
    /// Desktop players such as Netflix need it. On unless the user turns it off.
    @Published var desktopMediaSource =
        UserDefaults.standard.object(forKey: "viture.browser.desktopMediaSource") as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(desktopMediaSource, forKey: "viture.browser.desktopMediaSource")
        }
    }
    /// Draws the right eye from the same picture as the left instead of redrawing
    /// the left eye's layers. Some pages, such as Pluto TV's catalogue, lose their
    /// images in a redrawn copy. On unless the user turns it off.
    @Published var meshEyeCopy = UserDefaults.standard.object(forKey: "viture.glasses.meshEyeCopy") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(meshEyeCopy, forKey: "viture.glasses.meshEyeCopy")
        }
    }
    @Published var searchEngine =
        BrowserSearchEngine(
            rawValue: UserDefaults.standard.string(
                forKey: BrowserSearchEngine.preferenceKey) ?? "") ?? .duckDuckGo
    {
        didSet {
            UserDefaults.standard.set(searchEngine.rawValue, forKey: BrowserSearchEngine.preferenceKey)
        }
    }
    @Published var websiteAppearance =
        WebsiteAppearance(
            rawValue: UserDefaults.standard.string(
                forKey: WebsiteAppearance.preferenceKey) ?? "") ?? .system
    {
        didSet {
            guard oldValue != websiteAppearance else {
                return
            }
            UserDefaults.standard.set(websiteAppearance.rawValue, forKey: WebsiteAppearance.preferenceKey)
            primary?.updateWebsiteAppearance()
        }
    }
    // The controller always uses dark styling. Website preferences come from
    // the phone's scene trait, not the controller or the external window.
    var phoneSystemAppearance: UIUserInterfaceStyle = .dark
    /// Per-site desktop or mobile layout choices.
    var desktopSites =
        UserDefaults.standard.dictionary(forKey: "viture.browser.desktopSites") as? [String: Bool] ?? [:]
    /// Per-site choices to send, or not send, the Safari user agent. Sites not listed use the built-in list.
    var safariSites =
        UserDefaults.standard.dictionary(forKey: "viture.browser.safariSites") as? [String: Bool] ?? [:]

    // MARK: Shared data

    let contentBlocker = BrowserContentBlocker()
    let adSettings = AdBlockingStore()
    let homeShortcuts = HomeShortcutStore()
    @Published var history: [BrowserScreen.Visit] =
        (try? JSONDecoder().decode(
            [BrowserScreen.Visit].self, from: UserDefaults.standard.data(forKey: "viture.browser.history") ?? Data()))
        ?? []
    @Published var bookmarks: [String] =
        (try? JSONDecoder().decode(
            [String].self, from: UserDefaults.standard.data(forKey: "viture.browser.bookmarks") ?? Data())) ?? []
}
