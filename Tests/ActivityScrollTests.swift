import Foundation

@main enum ActivityScrollTests {
    static func main() {
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        var gesture = ActivityScrollGesture()
        expect(gesture.movement(x: 0, y: 3, precise: true, shifted: false, time: 0, phase: .began) == nil, "Small initial vertical noise must not zoom")
        let pan = gesture.movement(x: 15, y: 2, precise: true, shifted: false, time: 0.01, phase: .changed)
        expect(pan?.direction == .pan && pan?.delta == 15, "Horizontal motion locks the gesture to pan")
        let wobble = gesture.movement(x: 1, y: 20, precise: true, shifted: false, time: 0.02, phase: .changed)
        expect(wobble?.direction == .pan && wobble?.delta == 1, "Even dominant vertical wobble cannot zoom a locked pan")
        let verticalTail = gesture.movement(x: 0, y: -10, precise: true, shifted: false, time: 0.03, phase: .ended)
        expect(verticalTail?.direction == .pan && verticalTail?.delta == 0, "A vertical-only tail does not change the scale")
        let momentum = gesture.movement(x: 2, y: 15, precise: true, shifted: false, time: 0.4, momentum: .began)
        expect(momentum?.direction == .pan && momentum?.delta == 2, "Momentum retains pan direction even after a pause")
        _ = gesture.movement(x: 0, y: 0, precise: true, shifted: false, time: 0.5, momentum: .ended)
        let zoom = gesture.movement(x: 1, y: 20, precise: true, shifted: false, time: 0.6, phase: .began)
        expect(zoom?.direction == .zoom && zoom?.delta == 8, "A deliberate vertical gesture zooms after consuming its dead zone")
        let zoomWobble = gesture.movement(x: 20, y: -3, precise: true, shifted: false, time: 0.61, phase: .changed)
        expect(zoomWobble?.direction == .zoom && zoomWobble?.delta == -3, "Direction remains stable throughout a vertical zoom gesture")
        let nextPan = gesture.movement(x: 10, y: 12, precise: true, shifted: false, time: 0.7, phase: .began)
        expect(nextPan?.direction == .pan, "Diagonal gestures prefer panning, even with slightly larger vertical motion")
        _ = gesture.movement(x: 0, y: 0, precise: true, shifted: false, time: 0.8, phase: .cancelled)
        expect(gesture.movement(x: 0, y: 4, precise: true, shifted: false, time: 0.9) == nil, "Cancellation clears direction and pending deltas")
        expect(gesture.movement(x: 0, y: 6, precise: true, shifted: false, time: 0.91) == nil, "Small precise deltas accumulate without premature zoom")
        expect(gesture.movement(x: 0, y: 3, precise: true, shifted: false, time: 0.92)?.delta == 1, "Only movement past the zoom dead zone affects scale")
        expect(gesture.movement(x: 20, y: 2, precise: true, shifted: false, time: 1.3)?.direction == .pan, "Phaseless devices begin a new gesture after inactivity")
        expect(gesture.movement(x: 0, y: 10, precise: false, shifted: false, time: 1.8)?.direction == .zoom, "Traditional vertical mouse wheels still zoom")
        expect(gesture.movement(x: 0, y: 1, precise: false, shifted: false, time: 2.2)?.delta == 1, "A single traditional wheel notch still zooms at the gentler sensitivity")
        let shifted = gesture.movement(x: 0, y: 10, precise: false, shifted: true, time: 2.21)
        expect(shifted?.direction == .pan && shifted?.delta == 10, "Shift-wheel always pans immediately")
        expect(gesture.movement(x: .nan, y: 0, precise: true, shifted: false, time: 2.3) == nil, "Invalid deltas are ignored")
        print("Activity scroll tests passed: direction lock, jitter, dead zones, diagonal pan, momentum, cancellation, mouse wheels, and Shift-scroll")
    }
}
