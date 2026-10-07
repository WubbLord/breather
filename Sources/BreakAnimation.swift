import AppKit
import QuartzCore
import SwiftUI

private func fadeCurve() -> CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
}

/// The compositor owns the motion; scheduler ticks only update the text and state.
struct BreakProgressRing: NSViewRepresentable {
    let startedAt: Double
    let duration: Double
    func makeNSView(context: Context) -> BreakRingView { BreakRingView() }
    func updateNSView(_ view: BreakRingView, context: Context) {
        view.configure(startedAt: startedAt, duration: duration)
    }
}

final class BreakRingView: NSView {
    let ring = CAShapeLayer()
    private var start: Double?
    private var duration: Double?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.fillColor = nil
        ring.strokeColor = NSColor(red: 0.63, green: 0.82, blue: 0.74, alpha: 1).cgColor
        ring.lineWidth = 3
        ring.lineCap = .round
        layer!.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.contentsScale = window?.backingScaleFactor ?? 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        CATransaction.commit()
    }
    func configure(startedAt: Double, duration: Double) {
        guard start != startedAt || self.duration != duration else { return }
        start = startedAt; self.duration = duration
        let left = max(0, duration - (ProcessInfo.processInfo.systemUptime - startedAt))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.removeAnimation(forKey: "countdown")
        ring.strokeEnd = 0
        if left > 0 && duration > 0 {
            let motion = CABasicAnimation(keyPath: "strokeEnd")
            motion.fromValue = min(1, left / duration); motion.toValue = 0
            motion.duration = left
            motion.beginTime = CACurrentMediaTime()
            motion.timingFunction = CAMediaTimingFunction(name: .linear)
            ring.add(motion, forKey: "countdown")
        }
        CATransaction.commit()
    }
}

@MainActor func verifyBreakAnimation(_ completion: @escaping () -> Void) {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let timing = BreakTiming(duration: 2, fade: 0.7)
    let ring = BreakRingView(frame: NSRect(x: 0, y: 0, width: 150, height: 150))
    ring.configure(startedAt: startedAt, duration: timing.duration)
    let cover = BreakCoverView(content: ring, startedAt: startedAt, timing: timing)
    let probe = NSWindow(contentRect: ring.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    probe.isReleasedWhenClosed = false; probe.contentView = cover
    probe.orderFront(nil); cover.layoutSubtreeIfNeeded()
    var rings: [Float] = [], arrivals: [Float] = [], departures: [Float] = []
    let sample = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        if let progress = ring.ring.presentation()?.strokeEnd, elapsed < timing.fade { rings.append(Float(progress)) }
        if let opacity = cover.layer?.presentation()?.opacity {
            if elapsed < timing.fade { arrivals.append(opacity) }
            if elapsed > timing.duration - timing.fade && elapsed < timing.duration { departures.append(opacity) }
        }
        // SwiftUI calls this with each text update; the original animation must survive.
        ring.configure(startedAt: startedAt, duration: timing.duration)
    }
    RunLoop.main.add(sample, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + timing.duration + 0.1) {
        sample.invalidate()
        func steps(_ values: [Float]) -> Int { Set(values.map { Int(($0 * 1000).rounded()) }).count }
        print("Animation samples: \(steps(rings)) ring positions, \(steps(arrivals)) fade-in levels, \(steps(departures)) fade-out levels")
        fflush(stdout)
        precondition(steps(rings) >= 5 && rings.first! > rings.last!, "Ring must move continuously without scheduler ticks or animation restarts")
        precondition(steps(arrivals) >= 5 && arrivals.first! < arrivals.last!, "Fade-in must have intermediate compositor frames")
        precondition(steps(departures) >= 5 && departures.first! > departures.last!, "Fade-out must run continuously without scheduler ticks")
        precondition(cover.layer!.presentation()?.opacity ?? cover.layer!.opacity == 0, "Fade must end within the configured total duration")
        probe.orderOut(nil); probe.contentView = nil
        print("Break animation regression passed: continuous ring and both fades between scheduler ticks")
        completion()
    }
}

/// A dedicated parent layer keeps SwiftUI updates from restarting either fade.
final class BreakCoverView: NSView {
    init(content: NSView, startedAt: Double, timing: BreakTiming) {
        super.init(frame: content.frame)
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if timing.fade > 0 && timing.duration > 0 {
            layer!.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: timing.fade / timing.duration), NSNumber(value: 1 - timing.fade / timing.duration), 1]
            fade.timingFunctions = [fadeCurve(), CAMediaTimingFunction(name: .linear), fadeCurve()]
            fade.duration = timing.duration
            // Catch up after layout or a display change, using the break's original clock.
            fade.beginTime = CACurrentMediaTime() - max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            layer!.add(fade, forKey: "breakFades")
        } else { layer!.opacity = 1 }
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func dismiss(duration: Double) {
        let opacity = layer!.presentation()?.opacity ?? layer!.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer!.removeAnimation(forKey: "breakFades")
        layer!.opacity = 0
        if duration > 0 && opacity > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity; fade.toValue = 0
            fade.duration = duration; fade.timingFunction = fadeCurve()
            layer!.add(fade, forKey: "dismissal")
        }
        CATransaction.commit()
    }
}
