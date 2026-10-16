import AppKit
import QuartzCore
import SwiftUI

/// Native geometry for the complete card, without intercepting its controls.
struct PriorityRowBounds: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> PriorityRowView { PriorityRowView() }
    func updateNSView(_ view: PriorityRowView, context: Context) { view.planID = id }
}

final class PriorityRowView: NSView {
    var planID = UUID()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Local mouse tracking accepts the first click in an inactive window. A cached
/// card follows the pointer on a native layer; movement does not rebuild SwiftUI.
struct PriorityDragGrip: NSViewRepresentable {
    let id: UUID
    let title: String
    let changed: (UUID?) -> Void
    let ended: (UUID?) -> Void
    func makeNSView(context: Context) -> PriorityGripView { PriorityGripView() }
    func updateNSView(_ view: PriorityGripView, context: Context) {
        view.planID = id; view.changed = changed; view.ended = ended
        let label = "Drag \(title) to change priority"
        if view.accessibilityLabel() != label {
            view.setAccessibilityLabel(label)
            view.toolTip = "Drag up or down and release at the green marker"
        }
    }
    static func dismantleNSView(_ view: PriorityGripView, coordinator: ()) { view.cancelDrag(notify: false) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PriorityGripView, context: Context) -> CGSize? {
        CGSize(width: 28, height: 36)
    }
}

private final class PriorityDragPreview: NSView {
    init(frame: NSRect, image: NSImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16; layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: frame.size), cornerWidth: 14, cornerHeight: 14, transform: nil)
        let content = NSImageView(frame: bounds)
        content.image = image; content.imageScaling = .scaleAxesIndependently
        content.autoresizingMask = [.width, .height]; content.wantsLayer = true
        content.layer?.cornerRadius = 14; content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 0.22).cgColor
        addSubview(content)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PriorityGripView: NSView {
    var planID = UUID()
    var changed: (UUID?) -> Void = { _ in }
    var ended: (UUID?) -> Void = { _ in }
    private var origin: CGPoint?
    private var dragging = false
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var lastTarget: UUID?
    private var grabOffset = CGPoint.zero
    private var rows: [PriorityRowView] = []
    private var previewOrigin = NSRect.zero
    private weak var previewRoot: NSView?
    private weak var dragWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var dragPreview: NSView?
    private(set) var grabCursorActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 36) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect automatically follows layout. Keep one tracking area
        // through countdown refreshes rather than resetting the hover cursor.
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(area); hoverArea = area
        }
    }
    override func cursorUpdate(with event: NSEvent) { (grabCursorActive ? NSCursor.closedHand : NSCursor.openHand).set() }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; updateHover(); cursorUpdate(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; updateHover()
        if !grabCursorActive { NSCursor.arrow.set() }
    }
    private func updateHover() {
        layer?.backgroundColor = hovered ? NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 0.08).cgColor : nil
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: hovered ? 0.85 : 0.55).setFill()
        for x in [-3.0, 3] {
            for y in [-5.0, 0, 5] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.25, y: bounds.midY + y - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        cancelDrag(notify: false)
        origin = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = event.locationInWindow
        guard dragging || hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
        let starting = !dragging
        if starting {
            dragging = true
            beginPreview()
            // Prevent the hosting view's cursor rectangles from replacing the
            // grabbing hand as the card moves over buttons and other windows.
            dragWindow = window; dragWindow?.disableCursorRects()
            NSCursor.closedHand.push(); grabCursorActive = true
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelDrag() }
                })
            }
        }
        NSCursor.closedHand.set()
        _ = autoscroll(with: event)
        movePreview(to: point, from: origin)
        let target = target(at: point)
        if starting || target != lastTarget { lastTarget = target; changed(target) }
    }
    override func mouseUp(with event: NSEvent) {
        let destination = dragging ? target(at: event.locationInWindow) : nil
        cancelDrag(notify: false)
        ended(destination)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelDrag(notify: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    func cancelDrag(notify: Bool = true) {
        let wasDragging = dragging
        dragPreview?.removeFromSuperview(); dragPreview = nil; previewRoot = nil
        rows = []; origin = nil; dragging = false; lastTarget = nil; grabOffset = .zero
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        if grabCursorActive {
            NSCursor.pop(); grabCursorActive = false
            dragWindow?.enableCursorRects()
            if window === dragWindow { window?.invalidateCursorRects(for: self) }
        }
        dragWindow = nil
        if notify && wasDragging { ended(nil) }
    }
    private func beginPreview() {
        guard let root = window?.contentView, let origin else { return }
        root.layoutSubtreeIfNeeded()
        rows = priorityRows(in: root)
        guard let row = rows.first(where: { $0.planID == planID }) else { return }
        let windowRect = row.convert(row.bounds, to: nil)
        grabOffset = CGPoint(x: origin.x - windowRect.midX, y: origin.y - windowRect.midY)
        let rect = row.convert(row.bounds, to: root)
        guard rect.width > 0, rect.height > 0, let bitmap = root.bitmapImageRepForCachingDisplay(in: rect) else { return }
        root.cacheDisplay(in: rect, to: bitmap)
        bitmap.size = rect.size
        let image = NSImage(size: rect.size); image.addRepresentation(bitmap)
        // Keep the preview outside NSHostingView's managed subviews/layers:
        // SwiftUI redraws can otherwise draw above an ordinary added subview.
        let container = root.superview ?? root
        let frame = row.convert(row.bounds, to: container)
        let preview = PriorityDragPreview(frame: frame, image: image)
        preview.layer?.zPosition = 100
        container.addSubview(preview, positioned: .above, relativeTo: nil)
        previewOrigin = frame; previewRoot = container; dragPreview = preview
    }
    private func movePreview(to point: NSPoint, from origin: NSPoint) {
        guard let root = previewRoot, let preview = dragPreview else { return }
        let current = root.convert(point, from: nil), initial = root.convert(origin, from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = previewOrigin.offsetBy(dx: current.x - initial.x, dy: current.y - initial.y)
        CATransaction.commit()
    }
    private func target(at point: CGPoint) -> UUID? {
        PriorityDragTarget.destination(source: planID, pointer: point, grabOffset: grabOffset, rows: rows.map { row in
            PriorityDragRow(id: row.planID, frame: row.convert(row.bounds, to: nil), visibleFrame: row.visibleRect.isEmpty ? .zero : row.convert(row.visibleRect, to: nil))
        }, previous: lastTarget)
    }
}

@MainActor func priorityGrips(in view: NSView) -> [PriorityGripView] {
    (view as? PriorityGripView).map { [$0] } ?? view.subviews.flatMap { priorityGrips(in: $0) }
}

@MainActor func priorityRows(in view: NSView) -> [PriorityRowView] {
    (view as? PriorityRowView).map { [$0] } ?? view.subviews.flatMap { priorityRows(in: $0) }
}
