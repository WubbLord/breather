import AppKit
import SwiftUI

struct ActivityMouseView: NSViewRepresentable {
    var zoom: (Double, Double) -> Void
    var pan: (Double) -> Void
    var select: (Double) -> Void
    func makeNSView(context: Context) -> ActivityMouseSurface { ActivityMouseSurface() }
    func updateNSView(_ view: ActivityMouseSurface, context: Context) {
        view.zoom = zoom; view.pan = pan; view.select = select
    }
}

final class ActivityMouseSurface: NSView {
    var zoom: (Double, Double) -> Void = { _, _ in }
    var pan: (Double) -> Void = { _ in }
    var select: (Double) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func fraction(_ event: NSEvent) -> Double {
        max(0, min(1, convert(event.locationInWindow, from: nil).x / max(1, bounds.width)))
    }
    override func mouseDown(with event: NSEvent) { select(fraction(event)) }
    override func mouseDragged(with event: NSEvent) { pan(-event.deltaX / max(1, bounds.width)) }
    override func magnify(with event: NSEvent) { zoom(exp(-Double(event.magnification)), fraction(event)) }
    override func scrollWheel(with event: NSEvent) {
        let x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let shifted = event.modifierFlags.contains(.shift)
        if shifted || abs(x) > abs(y) {
            let delta = shifted && abs(y) > abs(x) ? y : x
            pan(-delta * (event.hasPreciseScrollingDeltas ? 1 : 12) / max(1, bounds.width))
        } else if y != 0 {
            zoom(exp(-y * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)), fraction(event))
        }
    }
}

@MainActor func verifyActivityMouseInput() {
    var viewport = ActivityViewport(span: 21600)
    viewport.move(to: Calendar.current.startOfDay(for: Date()).addingTimeInterval(43200))
    let surface = ActivityMouseSurface(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    surface.zoom = { viewport.zoom(factor: $0, anchor: $1) }
    surface.pan = { viewport.pan(fraction: $0) }
    func wheel(_ vertical: Int32, _ horizontal: Int32, flags: CGEventFlags = []) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)!
        event.location = CGPoint(x: 125, y: 50); event.flags = flags
        return NSEvent(cgEvent: event)!
    }
    let before = viewport.span
    let fixed = viewport.range.lowerBound.addingTimeInterval(before * 0.25)
    surface.scrollWheel(with: wheel(10, 0))
    precondition(viewport.span < before, "Mouse wheel must zoom continuously")
    precondition(abs(viewport.range.lowerBound.addingTimeInterval(viewport.span * 0.25).timeIntervalSince(fixed)) < 0.01, "Zoom keeps the time under the pointer fixed")
    let scale = viewport.span, center = viewport.center
    surface.scrollWheel(with: wheel(0, 20))
    precondition(viewport.span == scale && viewport.center != center, "Horizontal scrolling pans without changing scale")
    let shiftedCenter = viewport.center
    surface.scrollWheel(with: wheel(20, 0, flags: .maskShift))
    precondition(viewport.span == scale && viewport.center != shiftedCenter, "Shift-wheel pans with an ordinary mouse")
}

@MainActor func verifyActivityHitTesting(_ root: NSView) {
    func surfaces(_ view: NSView) -> [ActivityMouseSurface] {
        (view as? ActivityMouseSurface).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
    }
    root.layoutSubtreeIfNeeded()
    let plots = surfaces(root)
    precondition(plots.count == 2, "Both activity graphs have native mouse surfaces")
    for plot in plots {
        precondition(plot.bounds.width > 300 && plot.bounds.height > 30, "Mouse controls cover the rendered plot area")
        let point = root.superview!.convert(NSPoint(x: plot.bounds.midX, y: plot.bounds.midY), from: plot)
        let hit = root.hitTest(point)
        precondition(hit === plot, "Chart mouse surfaces receive input through the hosting view")
    }
}
