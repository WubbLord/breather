import AppKit
import SwiftUI

/// Keep AppKit's switch animation alive across unrelated countdown updates.
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
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ sender: NSSwitch) {
            let enabled = sender.state == .on
            if binding.wrappedValue != enabled { binding.wrappedValue = enabled }
        }
    }
}

final class BreakSwitchControl: NSSwitch {
    private(set) var stateAssignments = 0
    func apply(_ enabled: Bool) {
        let target: NSControl.StateValue = enabled ? .on : .off
        guard state != target else { return }
        state = target
        stateAssignments += 1
    }
}

@MainActor func breakSwitches(in view: NSView) -> [BreakSwitchControl] {
    (view as? BreakSwitchControl).map { [$0] } ?? view.subviews.flatMap { breakSwitches(in: $0) }
}
