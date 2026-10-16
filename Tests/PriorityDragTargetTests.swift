import Foundation
import CoreGraphics

@main enum PriorityDragTargetTests {
    static func main() {
        let ids = (0..<4).map { _ in UUID() }
        let rows = ids.enumerated().map { PriorityDragRow(id: $0.element, frame: CGRect(x: 30, y: $0.offset * 80, width: 620, height: 70)) }
        let source = ids[2]
        let gripOffset = CGPoint(x: -292, y: 16)
        func destination(_ center: CGFloat, previous: UUID? = nil, offset: CGPoint = gripOffset, geometry: [PriorityDragRow] = rows, x: CGFloat = 48) -> UUID? {
            PriorityDragTarget.destination(source: source, pointer: CGPoint(x: x, y: center + offset.y), grabOffset: offset, rows: geometry, previous: previous)
        }
        testCheck(destination(195) == nil, "Releasing at the original position must preserve the order")
        testCheck(destination(250) == nil, "Entering another card's edge is not enough to reorder")
        testCheck(destination(282) == nil && destination(283) == ids[3], "The dragged card must clearly cross the next card's center")
        testCheck(destination(275, previous: ids[3]) == ids[3], "Small reversals around the swap threshold must keep the marker steady")
        testCheck(destination(266, previous: ids[3]) == nil, "Moving back out of the destination must release the target")
        for center in stride(from: CGFloat(175), through: 215, by: 2) {
            testCheck(destination(center, previous: ids[3]) == nil, "Returning close to the original slot must cancel a previously selected move")
        }
        testCheck(destination(107) == ids[1], "Upward movement must use the same deliberate crossing threshold")
        testCheck(destination(27) == ids[0], "A single drag can cross several cards")
        testCheck(destination(115, previous: ids[0]) == ids[1], "Returning across multiple cards must select the nearer slot without jumping to the origin")
        testCheck(destination(195, previous: ids[0]) == nil, "Returning to the origin also cancels a multi-card drag")
        testCheck(destination(283, offset: CGPoint(x: -292, y: -16)) == ids[3], "Grab position must not change which card center triggers a reorder")
        testCheck(destination(283, geometry: rows.reversed()) == ids[3], "Target selection must not depend on view traversal order")
        testCheck(destination(283, x: 0) == nil && destination(283, x: 700) == nil, "Dropping outside the cards must cancel")
        testCheck(destination(500, previous: ids[3]) == nil, "Dropping outside the visible list must cancel even after selecting a target")
        let clipped = rows.map { PriorityDragRow(id: $0.id, frame: $0.frame, visibleFrame: $0.id == ids[3] ? .zero : $0.visibleFrame) }
        testCheck(destination(283, previous: ids[3], geometry: clipped) == nil, "Invisible rows must not accept a drop")
        let sourceOffscreen = rows.map { PriorityDragRow(id: $0.id, frame: $0.frame, visibleFrame: $0.id == source ? .zero : $0.visibleFrame) }
        testCheck(destination(283, geometry: sourceOffscreen) == ids[3], "Autoscrolling the original slot out of view must still permit a deliberate drop on a visible row")
        testCheck(destination(.nan) == nil && destination(283, geometry: []) == nil, "Ignore invalid pointer data or a removed source row")
        print("Priority drag tests passed: deliberate crossings, grab offsets, return-to-origin cancellation, hysteresis, multi-card reversal, clipping, and outside drops")
    }
}
