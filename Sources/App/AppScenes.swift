import AdapterTracking
import Combine
import SwiftUI
import MetalKit
import SpatialMath
import simd
import UIKit

/// App entry point.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The public source code. Shown at the bottom of Settings.
    static let sourceCodeURL = URL(string: "https://github.com/KoksalBerkay/Halopane")!
    static let supportURL = URL(string: "https://buymeacoffee.com/KoksalBerkay")!

    static var displayNameAndVersion: String {
        let bundle = Bundle.main
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Halopane"
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return name
        }
        return "\(name) \(version)"
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        true
    }
}

/// Creates the iPhone window.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else {
            return
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = PhoneController(rootView: PhoneRootView())
        self.window = window
        window.makeKeyAndVisible()
        syncWebsiteAppearance(from: scene)
        if #available(iOS 17.0, *) {
            scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (scene: UIWindowScene, _) in
                BrowserScreen.shared.setPhoneSystemAppearance(scene.traitCollection.userInterfaceStyle)
            }
        }
        GlassesDisplay.shared.refreshInventory()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene {
            syncWebsiteAppearance(from: scene)
        }
        guard BrowserScreen.shared.signInSession != nil, let window, !window.isKeyWindow else {
            return
        }
        window.makeKey()
    }
    private func syncWebsiteAppearance(from scene: UIWindowScene) {
        BrowserScreen.shared.setPhoneSystemAppearance(scene.traitCollection.userInterfaceStyle)
    }

    func windowScene(
        _ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        if previousTraitCollection.userInterfaceStyle != windowScene.traitCollection.userInterfaceStyle {
            syncWebsiteAppearance(from: windowScene)
        }
    }

}

// The external scene may render while the phone retains keyboard ownership.
private final class GlassesWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}

/// Hosts the phone UI and registers the glasses as an external display.
private final class PhoneController: UIHostingController<PhoneRootView> {
    private var displayRegistration: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        if #available(iOS 27.0, *) {
            let config = UISceneConfiguration()
            config.delegateClass = ExternalSceneDelegate.self
            let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: config)
            let registration = registerSceneAccessory(accessory)
            displayRegistration = registration
            GlassesDisplay.shared.event("Registered iOS 27 external-display accessory")
        }
    }

    @available(iOS 26.0, *)
    override func updateProperties() {
        super.updateProperties()
        if #available(iOS 27.0, *), let registration = displayRegistration as? UISceneAccessoryRegistration {
            GlassesDisplay.shared.updateAvailability(registration.isAvailable)
        }
    }
}

/// Creates the window shown in the glasses.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else {
            return
        }
        let window = GlassesWindow(windowScene: scene)
        window.rootViewController = GlassesViewController()
        self.window = window
        window.isHidden = false
        GlassesDisplay.shared.connect(scene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? GlassesViewController)?.resumeDisplay()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        BrowserScreen.shared.cancelTaps()
        BrowserScreen.shared.cancelScroll()
        for panel in BrowserScreen.shared.workspace.panels {
            panel.cancelTaps()
            panel.cancelScroll()
        }
        NativeInput.shared.cancel("External display disconnected.")
        (window?.rootViewController as? GlassesViewController)?.stop()
        if let scene = scene as? UIWindowScene {
            GlassesDisplay.shared.disconnect(scene)
        }
        window = nil
    }

    func windowScene(
        _ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        GlassesDisplay.shared.connect(windowScene)
    }
}
