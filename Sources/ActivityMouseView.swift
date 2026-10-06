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
    private var scrollGesture = ActivityScrollGesture()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func fraction(_ event: NSEvent) -> Double {
        max(0, min(1, convert(event.locationInWindow, from: nil).x / max(1, bounds.width)))
    }
    override func mouseDown(with event: NSEvent) { select(fraction(event)) }
    override func mouseDragged(with event: NSEvent) { pan(-event.deltaX / max(1, bounds.width)) }
    override func magnify(with event: NSEvent) { zoom(exp(-Double(event.magnification)), fraction(event)) }
    override func scrollWheel(with event: NSEvent) {
        guard let movement = scrollGesture.movement(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, shifted: event.modifierFlags.contains(.shift),
            time: event.timestamp, phase: scrollPhase(event.phase), momentum: scrollPhase(event.momentumPhase)
        ) else { return }
        switch movement.direction {
        case .pan:
            pan(-movement.delta * (event.hasPreciseScrollingDeltas ? 1 : 12) / max(1, bounds.width))
        case .zoom:
            if movement.delta != 0 { zoom(exp(-movement.delta * (event.hasPreciseScrollingDeltas ? 0.006 : 0.04)), fraction(event)) }
        }
    }
    private func scrollPhase(_ phase: NSEvent.Phase) -> ActivityScrollGesture.Phase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) { return .ended }
        return phase.isEmpty ? .none : .changed
    }
}

@MainActor func verifyActivityMouseInput() {
    var viewport = ActivityViewport(span: 21600)
    viewport.move(to: Calendar.current.startOfDay(for: Date()).addingTimeInterval(43200))
    let surface = ActivityMouseSurface(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    surface.zoom = { viewport.zoom(factor: $0, anchor: $1) }
    surface.pan = { viewport.pan(fraction: $0) }
    var scrollTime = ProcessInfo.processInfo.systemUptime
    func wheel(_ vertical: Int32, _ horizontal: Int32, flags: CGEventFlags = [], advance: Double = 0.5) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)!
        scrollTime += advance; event.timestamp = UInt64(scrollTime * 1_000_000_000)
        event.location = CGPoint(x: 125, y: 50); event.flags = flags
        return NSEvent(cgEvent: event)!
    }
    let before = viewport.span
    let fixed = viewport.range.lowerBound.addingTimeInterval(before * 0.25)
    surface.scrollWheel(with: wheel(24, 0))
    precondition(viewport.span < before, "Mouse wheel must zoom continuously")
    precondition(abs(viewport.range.lowerBound.addingTimeInterval(viewport.span * 0.25).timeIntervalSince(fixed)) < 0.01, "Zoom keeps the time under the pointer fixed")
    let scale = viewport.span, center = viewport.center
    surface.scrollWheel(with: wheel(0, 20))
    precondition(viewport.span == scale && viewport.center != center, "Horizontal scrolling pans without changing scale")
    let shiftedCenter = viewport.center
    surface.scrollWheel(with: wheel(20, 0, flags: .maskShift))
    precondition(viewport.span == scale && viewport.center != shiftedCenter, "Shift-wheel pans with an ordinary mouse")
    surface.scrollWheel(with: wheel(3, 20))
    let panScale = viewport.span
    surface.scrollWheel(with: wheel(30, 1, advance: 0.01))
    surface.scrollWheel(with: wheel(-8, 0, advance: 0.01))
    precondition(viewport.span == panScale, "Sideways scrolling must ignore vertical jitter throughout the gesture")
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
