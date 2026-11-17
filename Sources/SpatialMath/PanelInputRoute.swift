/// A drag belongs to the panel that was active when it began.
public struct PanelInputRoute<Panel: Equatable> {
    public private(set) var selected: Panel
    public private(set) var dragPanel: Panel?

    public init(selected: Panel) {
        self.selected = selected
    }

    @discardableResult
    public mutating func select(_ panel: Panel) -> Bool {
        guard selected != panel else {
            return false
        }
        dragPanel = nil
        selected = panel
        return true
    }

    public mutating func beginDrag() -> Panel {
        dragPanel = selected
        return selected
    }

    public mutating func finishDrag() -> Panel? {
        defer {
            dragPanel = nil
        }
        return dragPanel
    }

    public mutating func cancelDrag() {
        dragPanel = nil
    }
}
