import AppKit
import HopCore

final class SwitcherPanel: NSPanel {
    var onCommandDigit: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
            onCommandDigit?(n - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class RoundedRowView: NSTableRowView {
    // Keep the selection emphasized (white text) even though the table never takes focus.
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class WindowRowView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("WindowRow")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id

        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        shortcut.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        for view in [icon, labels, shortcut] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: WindowItem, row: Int) {
        icon.image = item.icon
        var details: [String] = []
        if item.title.isEmpty {
            title.stringValue = item.appName
        } else {
            title.stringValue = item.title
            details.append(item.appName)
        }
        if item.isMinimized { details.append("Minimized") }
        if item.isAppHidden { details.append("Hidden") }
        subtitle.stringValue = details.joined(separator: " · ")
        subtitle.isHidden = details.isEmpty
        shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
    }
}

@MainActor
final class SwitcherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let catalog: WindowCatalog
    private let panel: SwitcherPanel
    private let background = NSVisualEffectView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var allItems: [WindowItem] = []
    private var items: [WindowItem] = []
    private var loaded = false
    private var generation = 0
    private var dismissing = false
    private var anchor = NSPoint.zero // top-left of the panel

    private let width: CGFloat = 640
    private let headerHeight: CGFloat = 56
    private let rowHeight: CGFloat = 46
    private let maxVisibleRows = 9
    private let listPadding: CGFloat = 6

    var isVisible: Bool { panel.isVisible }

    init(catalog: WindowCatalog) {
        self.catalog = catalog
        panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: headerHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        configurePanel()
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCommandDigit = { [weak self] row in self?.choose(row) }

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // The behind-window blur ignores layer clipping; only a mask image rounds it (and the shadow).
        background.maskImage = Self.roundedMask(radius: 16)
        panel.contentView = background

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        glass.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = "Search windows"
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = self

        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        for view in [glass, field, separator, scroll, emptyLabel] as [NSView] {
            background.addSubview(view)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? dismiss(restoreFocus: true) : show()
    }

    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            catalog.recordFocusedWindow(ofPID: front.processIdentifier)
        }
        generation += 1
        loaded = false
        allItems = []
        items = []
        field.stringValue = ""
        table.reloadData()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        anchor = NSPoint(x: (visible.midX - width / 2).rounded(), y: (visible.maxY - visible.height * 0.2).rounded())
        relayout()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        load(keepSelection: false)
    }

    func refreshIfVisible() {
        if isVisible { load(keepSelection: true) }
    }

    private func load(keepSelection: Bool) {
        let gen = generation
        catalog.snapshot(apps: AppInfo.regularApps()) { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.panel.isVisible else { return }
                self.allItems = snapshot
                self.loaded = true
                self.refilter(keepSelection: keepSelection)
            }
        }
    }

    private func dismiss(restoreFocus: Bool) {
        guard !dismissing else { return }
        dismissing = true
        generation += 1
        panel.orderOut(nil)
        // Hiding Hop hands focus back to whatever was active before.
        if restoreFocus { NSApp.hide(nil) }
        dismissing = false
    }

    private func choose(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        dismiss(restoreFocus: false)
        Focuser.focus(item)
        catalog.recordFocus(item.windowID)
    }

    @objc private func tableClicked() {
        if table.clickedRow >= 0 { choose(table.clickedRow) }
    }

    // MARK: - Filtering and layout

    private func refilter(keepSelection: Bool) {
        let previous = keepSelection && items.indices.contains(table.selectedRow) ? items[table.selectedRow].windowID : nil
        let query = field.stringValue
        items = Matcher.rank(allItems, query: query) { ($0.appName, $0.title) }
        table.reloadData()

        // With no query, preselect the previous window so ⌥Space, Return flips between two windows.
        var row = query.allSatisfy(\.isWhitespace) && items.count > 1 ? 1 : 0
        if let previous, let index = items.firstIndex(where: { $0.windowID == previous }) { row = index }
        select(row)
        relayout()
    }

    private func select(_ row: Int) {
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        select((current + delta + items.count) % items.count)
    }

    private func relayout() {
        let rows = min(items.count, maxVisibleRows)
        let showEmpty = loaded && items.isEmpty
        let listHeight: CGFloat = rows > 0 ? CGFloat(rows) * rowHeight + listPadding * 2 : (showEmpty ? 44 : 0)
        let height = headerHeight + listHeight

        panel.setFrame(NSRect(x: anchor.x, y: anchor.y - height, width: width, height: height), display: true)
        panel.invalidateShadow()

        glass.frame = NSRect(x: 20, y: height - 38, width: 22, height: 22)
        field.frame = NSRect(x: 52, y: height - 43, width: width - 72, height: 30)
        separator.frame = NSRect(x: 0, y: height - headerHeight, width: width, height: 1)
        separator.isHidden = listHeight == 0
        scroll.frame = NSRect(x: 0, y: listPadding, width: width, height: max(0, CGFloat(rows) * rowHeight))
        scroll.isHidden = rows == 0
        table.tableColumns.first?.width = width

        emptyLabel.isHidden = !showEmpty
        emptyLabel.stringValue = allItems.isEmpty ? "No open windows" : "No matching windows"
        emptyLabel.frame = NSRect(x: 0, y: 13, width: width, height: 18)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        refilter(keepSelection: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            move(1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(restoreFocus: true)
        default:
            return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { dismiss(restoreFocus: false) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: WindowRowView.id, owner: nil) as? WindowRowView ?? WindowRowView()
        view.configure(items[row], row: row)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedRowView()
    }
}
