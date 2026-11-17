import CoreGraphics
import Foundation

/// Positions of the toolbar buttons and menu rows on a screen.
public enum BrowserChromeLayout {
    public enum Action: Int, CaseIterable {
        case back, forward, reload, home, address, fullScreen, resetZoom, bookmarks, add, more
    }

    public enum MoreRow: Int, CaseIterable {
        case place, close, desktop, ads, addToHome, history, settings, openFiles, openPhotos, undo
    }
    public static let homeSearch = CGRect(x: 180, y: 28, width: 640, height: 72)
    /// The Home page enlarges its search bar by this much under the pointer (`#search.hover` in home.html).
    public static let homeSearchHoverScale: CGFloat = 1.045
    /// The search bar's size while typing, matching the enlarged bar on the page.
    public static var homeSearchActive: CGRect {
        let growth = homeSearchHoverScale - 1
        return homeSearch.insetBy(dx: -homeSearch.width * growth / 2, dy: -homeSearch.height * growth / 2)
    }
    public static func moreFrame(_ row: MoreRow) -> CGRect {
        CGRect(x: 660, y: CGFloat(row.rawValue) * 46, width: 340, height: 46)
    }
    public static func moreRow(at point: CGPoint) -> MoreRow? {
        MoreRow.allCases.first { moreFrame($0).contains(point) }
    }
    public static let height: CGFloat = 56
    public static let top: CGFloat = -height
    public static let maxBookmarks = 8
    public static func frame(_ action: Action) -> CGRect {
        let edges: [CGFloat] = [0, 64, 128, 192, 256, 676, 740, 808, 872, 936, 1000]
        return CGRect(
            x: edges[action.rawValue], y: top, width: edges[action.rawValue + 1] - edges[action.rawValue],
            height: height)
    }
    public static func action(at point: CGPoint) -> Action? {
        Action.allCases.first { frame($0).contains(point) }
    }
    public static func bookmarkDeleteFrame(_ row: Int) -> CGRect {
        let full = bookmarkFrame(row)
        return CGRect(x: full.maxX - 60, y: full.minY, width: 60, height: full.height)
    }
    public static func bookmarkFrame(_ row: Int) -> CGRect {
        CGRect(x: 500, y: CGFloat(row) * 46, width: 500, height: 46)
    }
}
