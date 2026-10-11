import Foundation

/// Decide once per scroll gesture, including its momentum, rather than once per
/// event. Vertical motion scrolls the page unless zoom is explicitly requested.
struct ActivityScrollGesture {
    enum Phase { case none, began, changed, ended, cancelled }
    enum Direction { case pan, zoom, page }
    struct Movement {
        var direction: Direction
        var delta: Double
    }
    private var direction: Direction?
    private var pendingX: Double = 0
    private var pendingY: Double = 0
    private var lastTime: Double?

    mutating func reset() {
        direction = nil; pendingX = 0; pendingY = 0; lastTime = nil
    }
    mutating func movement(x: Double, y: Double, precise: Bool, shifted: Bool, zooming: Bool = false, time: Double, phase: Phase = .none, momentum: Phase = .none) -> Movement? {
        guard x.isFinite, y.isFinite, time.isFinite else { return nil }
        if phase == .cancelled || momentum == .cancelled { reset(); return nil }
        if phase == .began || (phase == .none && momentum == .none && lastTime.map { time - $0 > 0.25 || time < $0 } == true) { reset() }
        lastTime = time
        defer { if momentum == .ended { reset() } }
        if shifted {
            direction = .pan; pendingX = 0; pendingY = 0
            return Movement(direction: .pan, delta: abs(y) > abs(x) ? y : x)
        }
        if let direction { return Movement(direction: direction, delta: direction == .pan ? x : y) }
        pendingX += x; pendingY += y
        let panThreshold = precise ? 5.0 : 1.0
        let zoomThreshold = precise ? 12.0 : 1.0
        if abs(pendingY) >= zoomThreshold && abs(pendingY) >= 3 * abs(pendingX) {
            let verticalDirection: Direction = zooming ? .zoom : .page
            direction = verticalDirection
            // Consume the initial dead zone only for intentional zoom.
            let delta = zooming && precise ? pendingY - (pendingY < 0 ? -zoomThreshold : zoomThreshold) : pendingY
            pendingX = 0; pendingY = 0
            return Movement(direction: verticalDirection, delta: delta)
        }
        if abs(pendingX) >= panThreshold {
            direction = .pan
            let delta = pendingX
            pendingX = 0; pendingY = 0
            return Movement(direction: .pan, delta: delta)
        }
        return nil
    }
}
