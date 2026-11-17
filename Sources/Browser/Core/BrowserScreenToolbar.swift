import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// The browser toolbar, its menus, bookmarks and history.
extension BrowserScreen {
    var addressChromeTitle: String {
        if addressEditing {
            return addressDraft.isEmpty ? "Address or search  │" : addressDraft + "│"
        }
        return pageAddress.isEmpty || pageAddress == "VITURE start page" ? "Address or search" : pageAddress
    }

    private var historyPage: [Visit] {
        Array(workspace.history.dropFirst(historyOffset).prefix(8))
    }

    var historyLabels: [String] {
        historyPage.map(\.title)
    }

    var hasMoreHistory: Bool { workspace.history.count > 8 }

    var historyNavLabel: String {
        historyOffset + 8 < workspace.history.count ? "Older history ›" : "‹ Return to recent history"
    }

    /// Handles a click on the browser toolbar or one of its open menus.
    /// Returns false when the click should go to the page instead.
    func chromeClick(at point: CGPoint) -> Bool {
        // In full screen the toolbar sits lower, so shift the point into toolbar coordinates.
        let chromeOffset = fullChromeY.map { CGFloat($0) + BrowserChromeLayout.height } ?? 0
        let chromePoint = CGPoint(x: point.x, y: point.y - chromeOffset)
        let chromeVisible =
            !owner.fullScreenRouting || (fullChromeY != nil && owner.showsFullChrome(at: CACurrentMediaTime()))
        if chromeVisible, let action = BrowserChromeLayout.action(at: chromePoint) {
            performToolbarAction(action)
            return true
        }
        if moreOpen {
            moreOpen = false
            if let row = BrowserChromeLayout.moreRow(at: chromePoint) {
                performMoreMenuRow(row)
            }
            return true
        }
        if historyOpen {
            clickHistoryMenu(at: chromePoint)
            return true
        }
        if !bookmarksOpen, isHome, media.mapping == nil, BrowserChromeLayout.homeSearch.contains(point) {
            startHomeSearch()
            return true
        }
        guard bookmarksOpen else {
            return false
        }
        clickBookmarksMenu(at: chromePoint)
        return true
    }

    private func performToolbarAction(_ action: BrowserChromeLayout.Action) {
        historyOpen = false
        cancelTaps()
        if action != .bookmarks {
            bookmarksOpen = false
        }
        if action != .more {
            moreOpen = false
        }
        switch action {
        case .back:
            goBack()
        case .forward:
            goForward()
        case .address:
            if !addressEditing {
                closePhoneEditor()
                addressDraft = web.url?.isFileURL == true ? "" : pageAddress
                addressEditing = true
            }
        case .reload:
            reloadPage()
        case .fullScreen:
            owner.toggleFullScreen()
        case .resetZoom:
            resetZoomAndRefresh()
        case .bookmarks:
            bookmarksOpen.toggle()
        case .home:
            loadHome()
        case .add:
            owner.addPanel()
        case .more:
            moreOpen.toggle()
        }
    }

    private func performMoreMenuRow(_ row: BrowserChromeLayout.MoreRow) {
        switch row {
        case .place:
            owner.placeSelectedPanelHere()
        case .close:
            owner.closePanel(self)
        case .desktop:
            toggleSiteDesktop()
        case .ads:
            toggleSiteAds()
        case .undo:
            if workspace.hasUndo {
                owner.undoClose()
            }
        case .addToHome:
            addCurrentPageToHome()
        case .history:
            historyOffset = 0
            historyOpen = true
        case .settings:
            closePhoneEditor()
            addressEditing = false
            controllerSettings = true
        case .openFiles:
            localPicker = .files
        case .openPhotos:
            localPicker = .photos
        }
    }

    // Row 0 clears history. Other rows open a visit, or delete it with the row's delete button.
    // The last row shows the next page of history.
    private func clickHistoryMenu(at chromePoint: CGPoint) {
        if BrowserChromeLayout.bookmarkFrame(0).contains(chromePoint) && !workspace.history.isEmpty {
            workspace.history.removeAll()
            owner.saveHistory()
            historyOffset = 0
            showNotice("History cleared.")
        } else if let index = historyPage.indices.first(where: {
            BrowserChromeLayout.bookmarkFrame($0 + 1).contains(chromePoint)
        }) {
            let visit = historyPage[index]
            if BrowserChromeLayout.bookmarkDeleteFrame(index + 1).contains(chromePoint) {
                workspace.history.removeAll { $0.url == visit.url }
                owner.saveHistory()
                if historyOffset >= workspace.history.count {
                    historyOffset = 0
                }
            } else {
                historyOpen = false
                navigate(visit.url)
            }
        } else if hasMoreHistory, BrowserChromeLayout.bookmarkFrame(historyPage.count + 1).contains(chromePoint) {
            // Pages of 8. After the last page, start over.
            if historyOffset + 8 < workspace.history.count {
                historyOffset += 8
            } else {
                historyOffset = 0
            }
        } else {
            historyOpen = false
        }
    }

    private func startHomeSearch() {
        closePhoneEditor()
        if !addressEditing || !homeSearchEditing {
            addressDraft = ""
        }
        homeSearchEditing = true
        addressEditing = true
    }

    // Row 0 bookmarks the current page. Other rows open a bookmark, or delete it.
    private func clickBookmarksMenu(at chromePoint: CGPoint) {
        if BrowserChromeLayout.bookmarkFrame(0).contains(chromePoint) {
            bookmarkCurrentPage()
        } else if let index = workspaceBookmarks.prefix(BrowserChromeLayout.maxBookmarks).indices.first(where: {
            BrowserChromeLayout.bookmarkFrame($0 + 1).contains(chromePoint)
        }) {
            let address = workspaceBookmarks[index]
            if BrowserChromeLayout.bookmarkDeleteFrame(index + 1).contains(chromePoint) {
                workspace.bookmarks.removeAll { $0 == address }
                owner.saveBookmarks()
                showNotice("Bookmark removed.")
            } else {
                navigate(address)
                bookmarksOpen = false
            }
        } else {
            bookmarksOpen = false
        }
    }

    func safeSavedAddress(_ url: URL?) -> String? {
        guard let url, BrowserDestination.isWebURL(url),
            !BrowserDestination.supportsDirectPhoneSignIn(url),
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.user == nil, parts.password == nil
        else {
            return nil
        }
        let sensitive = ["auth", "oauth", "signin", "sign-in", "login", "callback", "verify", "password", "token"]
        if parts.path.lowercased().split(separator: "/").contains(where: { sensitive.contains(String($0)) }) {
            return nil
        }
        let withoutTracking =
            parts.queryItems?.filter { item in
                let key = item.name.lowercased()
                return !key.hasPrefix("utm_")
                    && ![
                        "access_token", "refresh_token", "id_token", "token", "code", "state", "session", "sessionid",
                        "sid",
                        "sig", "signature", "key", "apikey", "api_key", "auth", "authorization", "fbclid", "gclid",
                        "msclkid"
                    ].contains(key)
            } ?? []
        parts.queryItems = withoutTracking.isEmpty ? nil : withoutTracking
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    private func bookmarkCurrentPage() {
        guard let address = safeSavedAddress(web.url) else {
            showNotice("This page can’t be bookmarked.")
            return
        }
        workspace.bookmarks = Array(
            ([address] + workspace.bookmarks.filter { $0 != address }).prefix(BrowserChromeLayout.maxBookmarks))
        owner.saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(workspace.bookmarks) {
            UserDefaults.standard.set(data, forKey: "viture.browser.bookmarks")
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(workspace.history) {
            UserDefaults.standard.set(data, forKey: "viture.browser.history")
        }
    }

    func recordVisit(allowTitle: Bool) {
        guard let address = safeSavedAddress(web.url), address != lastRecordedAddress else {
            return
        }
        lastRecordedAddress = address
        let title = allowTitle ? web.title?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let fallback = web.url?.host ?? "Page"
        let display = title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        workspace.history = Array(
            ([Visit(url: address, title: String(display.prefix(100)))] + workspace.history.filter { $0.url != address })
                .prefix(100))
        owner.saveHistory()
    }
}
