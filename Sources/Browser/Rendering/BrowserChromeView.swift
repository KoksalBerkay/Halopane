import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

/// The toolbar and menus drawn on a screen in the glasses.
final class BrowserChromeView: UIView {
    private var items: [UILabel] = []
    private let notice = UILabel(frame: CGRect(x: 150, y: 576, width: 700, height: 43))
    private let menu = UIView()
    private var rows = [UILabel]()
    private var previousMenu: [String] = []
    private var lastMenuKind = 0
    private let searchDraft = PaddedLabel(frame: BrowserChromeLayout.homeSearchActive)
    private let progress = UIView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 625))
        layer.anchorPoint = .zero
        layer.position = .zero
        isUserInteractionEnabled = false
        // One title per toolbar action, in BrowserChromeLayout.Action order.
        let titles = ["‹", "›", "↻", "⌂", "Address or search", "⛶", "1×", "★", "+", "⋯"]
        for (action, title) in zip(BrowserChromeLayout.Action.allCases, titles) {
            let inset: CGFloat = action == .address ? 14 : 0
            let item = makeLabel(frame: BrowserChromeLayout.frame(action), title: title, horizontalInset: inset)
            item.font = .systemFont(ofSize: action == .address ? 23 : 32, weight: .semibold)
            addSubview(item)
            items.append(item)
        }
        progress.backgroundColor = .systemCyan
        addSubview(progress)
        searchDraft.font = .monospacedSystemFont(ofSize: 26, weight: .medium)
        searchDraft.textColor = .white
        searchDraft.backgroundColor = UIColor(white: 0.10, alpha: 1)
        searchDraft.layer.cornerRadius = BrowserChromeLayout.homeSearchActive.height / 2
        searchDraft.layer.borderWidth = 2
        searchDraft.layer.borderColor = UIColor.systemCyan.cgColor
        searchDraft.clipsToBounds = true
        // Same left padding as the placeholder text on the Home page.
        searchDraft.horizontalInset = 30 * BrowserChromeLayout.homeSearchHoverScale
        searchDraft.textAlignment = .left
        searchDraft.lineBreakMode = .byTruncatingHead
        addSubview(searchDraft)
        addSubview(menu)
        notice.textAlignment = .center
        notice.font = .systemFont(ofSize: 21, weight: .medium)
        notice.textColor = .white
        notice.backgroundColor = UIColor(white: 0.10, alpha: 0.95)
        notice.layer.cornerRadius = 8
        notice.clipsToBounds = true
        addSubview(notice)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    private func makeLabel(frame: CGRect, title: String, horizontalInset: CGFloat = 0) -> UILabel {
        let label = PaddedLabel(frame: frame.insetBy(dx: 1, dy: 1))
        label.horizontalInset = horizontalInset
        label.text = title
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 21, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.08, alpha: 1)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func refresh(
        with browser: BrowserScreen, focused: Bool = true, showToolbar: Bool = true, toolbarTop: Float? = nil,
        inlineNotice: Bool = true
    ) {
        searchDraft.isHidden = !browser.isHome || !browser.addressEditing || !browser.homeSearchEditing
        if !searchDraft.isHidden, searchDraft.text != browser.addressChromeTitle {
            searchDraft.text = browser.addressChromeTitle
        }
        var message = browser.browserNotice
        if message.isEmpty {
            message = focused ? browser.owner.placementHint : ""
        }
        // Unfocused panels show a dimmed toolbar.
        let running = focused ? CGFloat(1) : 0.5
        let toolbarOffset = toolbarTop.map { CGFloat($0) + BrowserChromeLayout.height } ?? 0
        updateToolbar(browser, running: running, showToolbar: showToolbar, toolbarOffset: toolbarOffset)
        notice.isHidden = !inlineNotice || message.isEmpty
        if notice.text != message {
            notice.text = message
        }
        updateAddressField(browser)
        updateMenu(browser, showToolbar: showToolbar, toolbarOffset: toolbarOffset)
    }

    private func updateToolbar(
        _ browser: BrowserScreen, running: CGFloat, showToolbar: Bool, toolbarOffset: CGFloat
    ) {
        for (action, item) in zip(BrowserChromeLayout.Action.allCases, items) {
            item.alpha = running
            item.isHidden = !showToolbar || (action == .fullScreen && !browser.fullScreenAvailable)
            item.frame = BrowserChromeLayout.frame(action).offsetBy(dx: 0, dy: toolbarOffset).insetBy(dx: 1, dy: 1)
        }
        items[BrowserChromeLayout.Action.fullScreen.rawValue].text = browser.owner.workspace.fullScreen ? "⤢" : "⛶"
        progress.isHidden = !browser.isLoadingPage || !showToolbar
        progress.frame = CGRect(x: 0, y: toolbarOffset - 3, width: 1000 * browser.web.estimatedProgress, height: 3)
        // Dim buttons that can't be used right now.
        items[BrowserChromeLayout.Action.back.rawValue].alpha = running * (browser.canBack ? 1 : 0.55)
        items[BrowserChromeLayout.Action.forward.rawValue].alpha = running * (browser.canForward ? 1 : 0.55)
        items[BrowserChromeLayout.Action.add.rawValue].alpha =
            running * (browser.owner.visiblePanels.count < 4 ? 1 : 0.45)
    }

    private func updateAddressField(_ browser: BrowserScreen) {
        let field = items[BrowserChromeLayout.Action.address.rawValue]
        let address: String
        if browser.addressEditing {
            address = browser.addressChromeTitle
        } else {
            address = "\(browser.displayIndex)\(browser.playbackBadge) · \(browser.siteLabel)"
        }
        if field.text != address {
            field.text = address
        }
        // Keep the newly typed end visible if the draft exceeds the toolbar width.
        let truncation: NSLineBreakMode = browser.addressEditing ? .byTruncatingHead : .byTruncatingMiddle
        if field.lineBreakMode != truncation {
            field.lineBreakMode = truncation
        }
        // Typed text starts on the left, as in other browsers. The site name stays centered.
        let alignment: NSTextAlignment = browser.addressEditing ? .left : .center
        if field.textAlignment != alignment {
            field.textAlignment = alignment
        }
    }

    // Menu kinds: 0 none, 1 more, 2 history, 3 bookmarks.
    private func updateMenu(_ browser: BrowserScreen, showToolbar: Bool, toolbarOffset: CGFloat) {
        var mode = 0
        if browser.moreOpen {
            mode = 1
        } else if browser.historyOpen {
            mode = 2
        } else if browser.bookmarksOpen {
            mode = 3
        }
        menu.transform = CGAffineTransform(translationX: 0, y: toolbarOffset)
        menu.isHidden = mode == 0 || !showToolbar
        guard mode != 0 else {
            return
        }
        let entries = menuEntries(mode, browser: browser)
        // Rebuild the rows only when the menu content changes.
        if entries != previousMenu || lastMenuKind != mode {
            rebuildMenuRows(entries, mode: mode, browser: browser)
            previousMenu = entries
            lastMenuKind = mode
        }
    }

    private func menuEntries(_ mode: Int, browser: BrowserScreen) -> [String] {
        switch mode {
        case 1:
            var entries = [
                "Place screen here", browser === browser.owner ? "Go Home" : "Close screen",
                browser.websiteLayoutMenuTitle,
                browser.adsEnabledForCurrentSite ? "Turn off ad blocking" : "Turn on ad blocking",
                "Add to Home", "History", "Settings on iPhone", "Open Files", "Open Photos"
            ]
            if browser.owner.workspace.hasUndo {
                entries.append("Undo close")
            }
            return entries
        case 2:
            var entries = [browser.historyLabels.isEmpty ? "No history" : "Clear history"]
            entries += browser.historyLabels
            if browser.hasMoreHistory {
                entries.append(browser.historyNavLabel)
            }
            return entries
        default:
            return ["Bookmark current page"]
                + Array(browser.workspaceBookmarks.prefix(BrowserChromeLayout.maxBookmarks))
        }
    }

    // History and bookmark rows (not the first row) get a delete button on the right.
    private func rebuildMenuRows(_ entries: [String], mode: Int, browser: BrowserScreen) {
        rows.forEach {
            $0.removeFromSuperview()
        }
        rows = entries.enumerated().flatMap { index, title -> [UILabel] in
            var frame: CGRect
            if mode == 1 {
                frame = BrowserChromeLayout.moreFrame(BrowserChromeLayout.MoreRow.allCases[index])
            } else {
                frame = BrowserChromeLayout.bookmarkFrame(index)
            }
            let canRemove = index > 0 && (mode == 3 || (mode == 2 && index <= browser.historyLabels.count))
            if canRemove {
                frame.size.width -= 60
            }
            let row = makeLabel(frame: frame, title: title)
            menu.addSubview(row)
            if canRemove {
                let remove = makeLabel(frame: BrowserChromeLayout.bookmarkDeleteFrame(index), title: "×")
                remove.textColor = .systemRed
                menu.addSubview(remove)
                return [row, remove]
            }
            return [row]
        }
    }
}

/// A label that keeps its text away from its left and right edges.
final class PaddedLabel: UILabel {
    var horizontalInset: CGFloat = 0

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: horizontalInset, dy: 0))
    }
}
