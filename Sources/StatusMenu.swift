import AppKit

/// A nonactivating menu surface for macOS 27's remotely hosted status button.
/// Keep NSMenu as the command source, but own the popup windows so they can
/// join another application's fullscreen Space without activating Breather.
@MainActor final class StatusMenuPresenter {
    private(set) var panels: [StatusMenuPanel] = []
    private var menus: [NSMenu] = []
    private var rows: [[StatusMenuRow]] = []
    private var selections: [Int?] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var anchor = NSRect.zero
    private var onClose: (() -> Void)?

    func present(_ menu: NSMenu, below anchor: NSRect, onClose: @escaping () -> Void) {
        close()
        self.anchor = anchor
        self.onClose = onClose
        append(menu, beside: nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.dismissIfOutside(NSEvent.mouseLocation)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissIfOutside(NSEvent.mouseLocation)
        }
        let initialApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didActivateApplicationNotification,
                       let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       application.processIdentifier == initialApplication { return }
                    self?.close()
                }
            })
        }
    }

    func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        trim(after: -1)
        let callback = onClose
        onClose = nil
        callback?()
    }

    func contains(_ point: NSPoint) -> Bool {
        anchor.contains(point) || panels.contains { $0.frame.contains(point) }
    }
    func dismissIfOutside(_ point: NSPoint) { if !contains(point) { close() } }

    private func trim(after depth: Int) {
        while panels.count > depth + 1 {
            panels.removeLast().orderOut(nil)
            menus.removeLast(); rows.removeLast(); selections.removeLast()
        }
    }

    private func append(_ menu: NSMenu, beside parentRow: StatusMenuRow?) {
        let depth = panels.count
        let font = NSFont.menuFont(ofSize: 0)
        let width = min(380, max(220, menu.items.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width + 46
        }.max() ?? 220))
        let heights = menu.items.map { $0.isSeparatorItem ? CGFloat(11) : CGFloat(28) }
        let height = heights.reduce(12, +)
        let panel = StatusMenuPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = depth == 0 ? "Breather menu" : "Pause breaks"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.level = .popUpMenu
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.animationBehavior = .none
        panel.onKey = { [weak self] event in self?.handleKey(event, depth: depth) }
        panel.onResignKey = { [weak self] in
            // A submenu temporarily takes the parent's key status. Check after
            // that transfer before treating a lost key window as dismissal.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.panels.isEmpty,
                      !self.panels.contains(where: { $0.isKeyWindow }) else { return }
                self.close()
            }
        }
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.material = .popover; content.blendingMode = .behindWindow; content.state = .active
        content.wantsLayer = true; content.layer?.cornerRadius = 10; content.layer?.masksToBounds = true
        content.setAccessibilityRole(.menu)
        panel.contentView = content
        var y = height - 6
        var menuRows: [StatusMenuRow] = []
        for (index, item) in menu.items.enumerated() {
            y -= heights[index]
            if item.isSeparatorItem {
                let separator = NSBox(frame: NSRect(x: 12, y: y + 5, width: width - 24, height: 1))
                separator.boxType = .separator; content.addSubview(separator)
                continue
            }
            let row = StatusMenuRow(item: item, index: index, font: font)
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: heights[index])
            row.onHover = { [weak self] in self?.highlight(index, depth: depth, openSubmenu: true) }
            row.onChoose = { [weak self] in self?.choose(index, depth: depth) }
            content.addSubview(row); menuRows.append(row)
        }
        let reference: NSRect
        if let parentRow, let parent = parentRow.window {
            reference = parent.convertToScreen(parentRow.convert(parentRow.bounds, to: nil))
        } else { reference = anchor }
        let screen = NSScreen.screens.first { $0.frame.intersects(reference) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? reference.insetBy(dx: -600, dy: -600)
        var x = parentRow == nil ? reference.maxX - width : reference.maxX + 2
        if parentRow != nil && x + width > bounds.maxX { x = reference.minX - width - 2 }
        let top = parentRow == nil ? reference.minY - 4 : reference.maxY + 6
        x = min(max(bounds.minX + 4, x), bounds.maxX - width - 4)
        let originY = min(max(bounds.minY + 4, top - height), bounds.maxY - height)
        panel.setFrameOrigin(NSPoint(x: x, y: originY))
        panels.append(panel); menus.append(menu); rows.append(menuRows); selections.append(nil)
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(nil)
    }

    private func highlight(_ index: Int, depth: Int, openSubmenu: Bool) {
        guard menus.indices.contains(depth), menus[depth].items.indices.contains(index) else { return }
        let item = menus[depth].items[index]
        guard item.isEnabled && (item.action != nil || item.submenu != nil) else { return }
        if selections[depth] != index {
            trim(after: depth)
            selections[depth] = index
            for row in rows[depth] { row.selected = row.index == index }
        }
        if openSubmenu, let submenu = item.submenu, panels.count == depth + 1,
           let row = rows[depth].first(where: { $0.index == index }) { append(submenu, beside: row) }
    }

    func choose(_ index: Int, depth: Int = 0) {
        guard menus.indices.contains(depth), menus[depth].items.indices.contains(index) else { return }
        let item = menus[depth].items[index]
        guard item.isEnabled else { return }
        if item.submenu != nil { highlight(index, depth: depth, openSubmenu: true); return }
        guard let action = item.action else { return }
        let target = item.target
        close()
        NSApp.sendAction(action, to: target, from: item)
    }

    func handleKey(_ event: NSEvent, depth: Int) {
        guard menus.indices.contains(depth) else { return }
        switch event.keyCode {
        case 53: close() // Escape
        case 123: // Left arrow
            if depth > 0 { trim(after: depth - 1); panels.last?.makeKey() }
        case 124: // Right arrow
            if let index = selections[depth] {
                highlight(index, depth: depth, openSubmenu: true)
                if panels.count > depth + 1 { selectNext(1, depth: depth + 1) }
            }
        case 125: selectNext(1, depth: depth)
        case 126: selectNext(-1, depth: depth)
        case 36, 49, 76:
            if let index = selections[depth] { choose(index, depth: depth) }
        default:
            if let text = event.charactersIgnoringModifiers?.lowercased(), !text.isEmpty,
               let index = menus[depth].items.firstIndex(where: { $0.isEnabled && $0.action != nil && $0.title.lowercased().hasPrefix(text) }) {
                highlight(index, depth: depth, openSubmenu: false)
            }
        }
    }
    private func selectNext(_ direction: Int, depth: Int) {
        guard menus.indices.contains(depth) else { return }
        let enabled = menus[depth].items.indices.filter {
            let item = menus[depth].items[$0]
            return item.isEnabled && (item.action != nil || item.submenu != nil)
        }
        guard !enabled.isEmpty else { return }
        let current = selections[depth].flatMap { enabled.firstIndex(of: $0) }
        let next = current.map { ($0 + direction + enabled.count) % enabled.count } ?? (direction > 0 ? 0 : enabled.count - 1)
        highlight(enabled[next], depth: depth, openSubmenu: false)
    }
}

@MainActor final class StatusMenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func resignKey() { super.resignKey(); onResignKey?() }
}

@MainActor private final class StatusMenuRow: NSButton {
    let index: Int
    var onHover: (() -> Void)?
    var onChoose: (() -> Void)?
    var selected = false { didSet { if oldValue != selected { updateColors() } } }
    private var tracking: NSTrackingArea?
    init(item: NSMenuItem, index: Int, font: NSFont) {
        self.index = index
        super.init(frame: .zero)
        title = item.title; self.font = font
        alignment = .left; isBordered = false
        isEnabled = item.isEnabled && (item.action != nil || item.submenu != nil)
        target = self; action = #selector(choose)
        setAccessibilityRole(.menuItem)
        if item.submenu != nil { image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil); imagePosition = .imageTrailing }
        (cell as? NSButtonCell)?.highlightsBy = []
        cell?.lineBreakMode = .byTruncatingTail
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func choose() { onChoose?() }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        let color: NSColor = !isEnabled ? .disabledControlTextColor : (selected ? .alternateSelectedControlTextColor : .labelColor)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        contentTintColor = color
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        cell?.draw(withFrame: bounds.insetBy(dx: 8, dy: 0), in: self)
    }
}
