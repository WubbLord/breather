import AppKit
import SwiftUI

/// Handle local reordering directly, without a pasteboard drag session or a
/// SwiftUI gesture that can lose its first mouse event in an inactive window.
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
            view.toolTip = "Drag up or down and release over another break"
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PriorityGripView, context: Context) -> CGSize? {
        CGSize(width: 24, height: 32)
    }
}

final class PriorityGripView: NSView {
    var planID = UUID()
    var changed: (UUID?) -> Void = { _ in }
    var ended: (UUID?) -> Void = { _ in }
    private var origin: CGPoint?
    private var dragging = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 32) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 0.55).setStroke()
        let lines = NSBezierPath(); lines.lineWidth = 1
        for offset in [-3.0, 0, 3] {
            lines.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY + offset))
            lines.line(to: NSPoint(x: bounds.midX + 6, y: bounds.midY + offset))
        }
        lines.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = event.locationInWindow
        guard dragging || hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
        dragging = true
        changed(target(at: point))
    }
    override func mouseUp(with event: NSEvent) {
        ended(dragging ? target(at: event.locationInWindow) : nil)
        origin = nil; dragging = false
    }
    private func target(at point: CGPoint) -> UUID? {
        guard let root = window?.contentView, point.x >= 30, point.x <= root.bounds.width - 30 else { return nil }
        return priorityGrips(in: root).first { grip in
            guard grip !== self, !grip.visibleRect.isEmpty else { return false }
            // Each row has 17 points of padding above and below its grip.
            let row = grip.convert(grip.bounds, to: nil).insetBy(dx: 0, dy: -17)
            return point.y >= row.minY && point.y <= row.maxY
        }?.planID
    }
}

@MainActor func priorityGrips(in view: NSView) -> [PriorityGripView] {
    (view as? PriorityGripView).map { [$0] } ?? view.subviews.flatMap { priorityGrips(in: $0) }
}
