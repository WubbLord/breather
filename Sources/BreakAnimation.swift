import AppKit
import QuartzCore
import SwiftUI

private func fadeCurve() -> CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
}

/// Two breathing circles animate on the compositor without a per-frame SwiftUI update.
struct BreakBreathingHalo: NSViewRepresentable {
    let startedAt: Double
    func makeNSView(context: Context) -> BreakHaloView { BreakHaloView() }
    func updateNSView(_ view: BreakHaloView, context: Context) { view.configure(startedAt: startedAt) }
}

final class BreakHaloView: NSView {
    let glow = CAShapeLayer()
    let outline = CAShapeLayer()
    private var start: Double?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glow.fillColor = NSColor.white.withAlphaComponent(0.025).cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        outline.lineWidth = 1
        layer!.addSublayer(glow); layer!.addSublayer(outline)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (circle, diameter) in [(glow, 230.0), (outline, 180.0)] {
            circle.contentsScale = window?.backingScaleFactor ?? 2
            circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            circle.position = CGPoint(x: bounds.midX, y: bounds.midY)
            circle.path = CGPath(ellipseIn: circle.bounds, transform: nil)
        }
        CATransaction.commit()
    }
    func configure(startedAt: Double) {
        guard start != startedAt else { return }
        start = startedAt
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (circle, minimum, maximum) in [(glow, 0.9, 1.13), (outline, 0.94, 1.08)] {
            circle.transform = CATransform3DMakeScale(minimum, minimum, 1)
            let motion = CABasicAnimation(keyPath: "transform.scale")
            motion.fromValue = minimum; motion.toValue = maximum
            motion.duration = 4; motion.autoreverses = true; motion.repeatCount = .infinity
            motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            motion.beginTime = CACurrentMediaTime() - max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            circle.add(motion, forKey: "breathing")
        }
        CATransaction.commit()
    }
}

@MainActor func verifyBreathingHalo(_ completion: @escaping () -> Void) {
    // Start halfway through inhaling so one short test covers both directions and the turn.
    let startedAt = ProcessInfo.processInfo.systemUptime - 2
    let halo = BreakHaloView(frame: CGRect(x: 0, y: 0, width: 280, height: 280))
    halo.configure(startedAt: startedAt)
    let originalAnimationStart = halo.glow.animation(forKey: "breathing")!.beginTime
    let probe = NSWindow(contentRect: halo.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    probe.isReleasedWhenClosed = false; probe.contentView = halo
    probe.orderFront(nil); halo.layoutSubtreeIfNeeded()
    var inhaling: [Double] = [], exhaling: [Double] = [], outlines: [Double] = []
    let sample = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        if let scale = halo.glow.presentation()?.transform.m11 {
            if elapsed < 4 { inhaling.append(scale) } else { exhaling.append(scale) }
        }
        if let scale = halo.outline.presentation()?.transform.m11 { outlines.append(scale) }
        halo.configure(startedAt: startedAt)
    }
    RunLoop.main.add(sample, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
        sample.invalidate()
        func steps(_ values: [Double]) -> Int { Set(values.map { Int(($0 * 10000).rounded()) }).count }
        precondition(steps(inhaling) >= 20 && inhaling.first! < inhaling.last!, "Breathing must grow smoothly between scheduler ticks")
        precondition(steps(exhaling) >= 20 && exhaling.first! > exhaling.last!, "Breathing must shrink smoothly after reversing")
        precondition(abs(inhaling.max()! - 1.13) < 0.003 && abs(outlines.max()! - 1.08) < 0.003, "Keep the original circle sizes and full scale range")
        precondition(halo.glow.animation(forKey: "breathing")!.beginTime == originalAnimationStart, "Countdown updates must not restart breathing")
        print("Breathing regression passed: \(steps(inhaling)) inhale levels, \(steps(exhaling)) exhale levels, smooth reversal, original timing/sizes, and stable animations")
        probe.orderOut(nil); probe.contentView = nil
        halo.glow.removeAllAnimations(); halo.outline.removeAllAnimations()
        completion()
    }
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
            // AppKit may resynchronize its backing layer's model opacity during
            // layout. Keep the final transparent presentation until removal.
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
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
