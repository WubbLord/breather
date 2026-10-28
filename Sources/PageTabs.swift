import AppKit
import QuartzCore
import SwiftUI

/// Keep native selection, keyboard/accessibility handling, and fixed sizing.
struct PageTabs: NSViewRepresentable {
    @Binding var activity: Bool
    func makeCoordinator() -> Coordinator { Coordinator(binding: $activity) }
    func makeNSView(context: Context) -> PageTabControl {
        let control = PageTabControl(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.apply(activity)
        return control
    }
    func updateNSView(_ control: PageTabControl, context: Context) {
        context.coordinator.binding = $activity
        control.apply(activity)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageTabControl, context: Context) -> CGSize? {
        CGSize(width: 190, height: 28)
    }
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ sender: PageTabControl) {
            sender.refreshSelection()
            let value = sender.selectedSegment == 1
            if binding.wrappedValue != value { binding.wrappedValue = value }
        }
    }
}

/// The cell still tracks clicks and keyboard input; layers render its appearance.
private final class PageTabCell: NSSegmentedCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

/// Let the segmented control keep mouse tracking while AppKit renders crisp text.
private final class PageTabLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PageTabControl: NSSegmentedControl {
    private(set) var selectionAssignments = 0
    let highlight = CALayer()
    private let track = CALayer()
    private let labels = [PageTabLabel(labelWithString: "Breaks"), PageTabLabel(labelWithString: "Activity")]
    private var renderedSelection: Int?
    private var laidOutBounds: CGRect?
    private let green = NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = PageTabCell()
        segmentCount = 2; segmentStyle = .rounded; trackingMode = .selectOne
        segmentDistribution = .fillEqually
        setLabel("Breaks", forSegment: 0); setLabel("Activity", forSegment: 1)
        setWidth(95, forSegment: 0); setWidth(95, forSegment: 1)
        setAccessibilityLabel("Page")
        wantsLayer = true
        track.backgroundColor = green.withAlphaComponent(0.09).cgColor
        track.cornerRadius = 7
        highlight.backgroundColor = green.cgColor
        highlight.cornerRadius = 5
        layer!.addSublayer(track); layer!.addSublayer(highlight)
        for label in labels {
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.alignment = .center
            label.textColor = green
            label.setAccessibilityElement(false)
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) {}
    override func layout() {
        super.layout()
        guard laidOutBounds != bounds else { return }
        laidOutBounds = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        highlight.bounds = CGRect(x: 0, y: 0, width: (bounds.width - 4) / 2, height: bounds.height - 4)
        highlight.position = highlightPosition(renderedSelection ?? 0)
        for (index, label) in labels.enumerated() {
            let height = ceil(label.intrinsicContentSize.height)
            label.frame = CGRect(x: bounds.minX + CGFloat(index) * bounds.width / 2, y: floor(bounds.midY - height / 2), width: bounds.width / 2, height: height)
        }
        CATransaction.commit()
    }
    private func highlightPosition(_ index: Int) -> CGPoint {
        CGPoint(x: bounds.minX + 2 + (bounds.width - 4) / 2 * (CGFloat(index) + 0.5), y: bounds.midY)
    }
    func apply(_ activity: Bool) {
        let index = activity ? 1 : 0
        if selectedSegment != index {
            selectedSegment = index
            selectionAssignments += 1
        }
        refreshSelection()
    }
    func refreshSelection() {
        let index = selectedSegment
        guard (0...1).contains(index), renderedSelection != index else { return }
        let animate = renderedSelection != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderedSelection = index
        let from = highlight.presentation()?.position.x ?? highlight.position.x
        let target = highlightPosition(index)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.removeAnimation(forKey: "pageSlide")
        highlight.position = target
        if animate {
            let motion = CABasicAnimation(keyPath: "position.x")
            motion.fromValue = from; motion.toValue = target.x
            motion.duration = 0.24; motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlight.add(motion, forKey: "pageSlide")
        }
        for (labelIndex, label) in labels.enumerated() {
            label.textColor = labelIndex == index ? .white : green
        }
        CATransaction.commit()
    }
}

@MainActor func pageTabs(in view: NSView) -> [PageTabControl] {
    (view as? PageTabControl).map { [$0] } ?? view.subviews.flatMap { pageTabs(in: $0) }
}

@MainActor func verifyPageTabsAnimation(_ completion: @escaping () -> Void) {
    let control = PageTabControl(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
    let probe = NSWindow(contentRect: control.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    probe.isReleasedWhenClosed = false; probe.contentView = control
    control.apply(false); probe.orderFront(nil); control.layoutSubtreeIfNeeded()
    let left = control.highlight.position.x
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        control.apply(true)
        let right = control.highlight.position.x
        let animation = control.highlight.animation(forKey: "pageSlide")
        let assignments = control.selectionAssignments
        var positions: [Double] = []
        let sample = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            if let x = control.highlight.presentation()?.position.x { positions.append(x) }
            control.apply(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            sample.invalidate()
            testCheck(right > left && control.selectedSegment == 1 && control.selectionAssignments == assignments, "Selection must stay stable across countdown-style updates")
            if animation != nil {
                testCheck(Set(positions.map { Int(($0 * 10).rounded()) }).count >= 8 && positions.first! < positions.last!, "Page highlight must slide through continuous intermediate positions")
            }
            testCheck(abs(control.highlight.presentation()!.position.x - right) < 0.1, "Highlight must settle over Activity")
            control.apply(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let before = control.highlight.presentation()!.position.x
                control.apply(true)
                if let reversal = control.highlight.animation(forKey: "pageSlide") as? CABasicAnimation {
                    testCheck(abs((reversal.fromValue as! Double) - before) < 1, "Rapid switches must reverse from the visible position without jumping")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    testCheck(control.selectedSegment == 1 && abs(control.highlight.presentation()!.position.x - right) < 0.1, "Rapid switches must finish on the selected page")
                    print("Page tabs passed: continuous slide, stable updates, smooth reversal, and final selection")
                    probe.orderOut(nil); probe.contentView = nil
                    completion()
                }
            }
        }
    }
}
