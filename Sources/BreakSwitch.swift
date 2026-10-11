import AppKit
import QuartzCore
import SwiftUI

/// Native toggle handling with compositor-driven green switch rendering.
struct BreakEnabledSwitch: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    func makeCoordinator() -> Coordinator { Coordinator(binding: $isOn) }
    func makeNSView(context: Context) -> BreakSwitchControl {
        let view = BreakSwitchControl()
        view.controlSize = .small
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        view.setAccessibilityLabel(title)
        view.apply(isOn)
        return view
    }
    func updateNSView(_ view: BreakSwitchControl, context: Context) {
        context.coordinator.binding = $isOn
        view.setAccessibilityLabel(title)
        view.apply(isOn)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreakSwitchControl, context: Context) -> CGSize? {
        CGSize(width: 54, height: 24)
    }
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ sender: BreakSwitchControl) {
            sender.refreshAppearance()
            let enabled = sender.state == .on
            if binding.wrappedValue != enabled { binding.wrappedValue = enabled }
        }
    }
}

private final class BreakSwitchCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

final class BreakSwitchControl: NSButton {
    private(set) var stateAssignments = 0
    private let track = CALayer()
    let thumb = CALayer()
    private var renderedState: Bool?
    private var laidOutBounds: CGRect?
    private let green = NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = BreakSwitchCell()
        setButtonType(.pushOnPushOff)
        title = ""; isBordered = false
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        wantsLayer = true
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.12; thumb.shadowRadius = 1.5
        thumb.shadowOffset = CGSize(width: 0, height: -0.5)
        layer!.addSublayer(track); layer!.addSublayer(thumb)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 54, height: 24) }
    override func accessibilityValue() -> Any? { NSNumber(value: state == .on) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {}
    override func layout() {
        super.layout()
        guard laidOutBounds != bounds else { return }
        laidOutBounds = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds; track.cornerRadius = bounds.height / 2
        let diameter = max(0, bounds.height - 4)
        thumb.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        thumb.cornerRadius = diameter / 2
        thumb.shadowPath = CGPath(ellipseIn: thumb.bounds, transform: nil)
        thumb.position = thumbPosition(renderedState ?? (state == .on))
        CATransaction.commit()
    }
    private func thumbPosition(_ enabled: Bool) -> CGPoint {
        let inset = bounds.height / 2
        return CGPoint(x: enabled ? bounds.maxX - inset : bounds.minX + inset, y: bounds.midY)
    }
    func apply(_ enabled: Bool) {
        let target: NSControl.StateValue = enabled ? .on : .off
        if state != target {
            state = target
            stateAssignments += 1
        }
        refreshAppearance()
    }
    func refreshAppearance() {
        let enabled = state == .on
        guard renderedState != enabled else { return }
        let animate = renderedState != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderedState = enabled
        let from = thumb.presentation()?.position.x ?? thumb.position.x
        let oldColor = track.presentation()?.backgroundColor ?? track.backgroundColor
        let color = green.withAlphaComponent(enabled ? 1 : 0.12).cgColor
        let target = thumbPosition(enabled)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.removeAnimation(forKey: "switchSlide"); track.removeAnimation(forKey: "switchTint")
        thumb.position = target; track.backgroundColor = color
        if animate {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = from; slide.toValue = target.x
            slide.duration = 0.2; slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            thumb.add(slide, forKey: "switchSlide")
            let tint = CABasicAnimation(keyPath: "backgroundColor")
            tint.fromValue = oldColor; tint.toValue = color
            tint.duration = 0.2; tint.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            track.add(tint, forKey: "switchTint")
        }
        CATransaction.commit()
    }
}

@MainActor func breakSwitches(in view: NSView) -> [BreakSwitchControl] {
    (view as? BreakSwitchControl).map { [$0] } ?? view.subviews.flatMap { breakSwitches(in: $0) }
}
