import AppKit
import SwiftUI

/// Plain AppKit labels avoid SwiftUI's segmented-picker hosting/sizing feedback loop.
struct PageTabs: NSViewRepresentable {
    @Binding var activity: Bool
    func makeCoordinator() -> Coordinator { Coordinator(binding: $activity) }
    func makeNSView(context: Context) -> PageTabControl {
        let control = PageTabControl(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        control.segmentCount = 2
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.setLabel("Breaks", forSegment: 0)
        control.setLabel("Activity", forSegment: 1)
        control.setWidth(95, forSegment: 0)
        control.setWidth(95, forSegment: 1)
        control.setAccessibilityLabel("Page")
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
        @objc func changed(_ sender: NSSegmentedControl) {
            let value = sender.selectedSegment == 1
            if binding.wrappedValue != value { binding.wrappedValue = value }
        }
    }
}

final class PageTabControl: NSSegmentedControl {
    private(set) var selectionAssignments = 0
    func apply(_ activity: Bool) {
        let index = activity ? 1 : 0
        guard selectedSegment != index else { return }
        selectedSegment = index
        selectionAssignments += 1
    }
}

@MainActor func pageTabs(in view: NSView) -> [PageTabControl] {
    (view as? PageTabControl).map { [$0] } ?? view.subviews.flatMap { pageTabs(in: $0) }
}
