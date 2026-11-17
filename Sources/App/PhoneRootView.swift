import SwiftUI

/// The iPhone's root view. Opens the browser and shows its phone controller.
struct PhoneRootView: View {
    @ObservedObject private var display = GlassesDisplay.shared
    @ObservedObject private var browser = BrowserScreen.shared

    var body: some View {
        BrowserShell(browser: browser.selectedSession, display: display, native: browser.selectedSession.native)
            .onAppear {
                if !browser.active {
                    browser.open()
                }
            }
    }
}
