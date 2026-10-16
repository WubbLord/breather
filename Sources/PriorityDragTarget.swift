import Foundation
import CoreGraphics

struct PriorityDragRow {
    let id: UUID
    let frame: CGRect
    let visibleFrame: CGRect
    init(id: UUID, frame: CGRect, visibleFrame: CGRect? = nil) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame ?? frame
    }
}

enum PriorityDragTarget {
    // Enter a new slot deliberately; keep its marker steady through small
    // reversals. Returning toward the original slot clears the destination.
    static let threshold: CGFloat = 8

    static func destination(source: UUID, pointer: CGPoint, grabOffset: CGPoint, rows: [PriorityDragRow], previous: UUID?) -> UUID? {
        guard pointer.x.isFinite, pointer.y.isFinite, grabOffset.y.isFinite,
              let original = rows.first(where: { $0.id == source }),
              pointer.x >= original.frame.minX, pointer.x <= original.frame.maxX else { return nil }
        let visible = rows.filter { !$0.visibleFrame.isEmpty }
        let dropArea = visible.reduce(CGRect.null) { $0.union($1.visibleFrame) }.insetBy(dx: 0, dy: -5)
        guard dropArea.contains(pointer) else { return nil }
        let center = pointer.y - grabOffset.y
        let origin = original.frame.midY
        guard center != origin else { return nil }
        let direction: CGFloat = center > origin ? 1 : -1
        let previousDistance = rows.first(where: { $0.id == previous }).map { ($0.frame.midY - origin) * direction } ?? 0
        return visible.filter { row in
            let distance = (row.frame.midY - origin) * direction
            guard row.id != source, distance > 0 else { return false }
            let buffer = previousDistance >= distance ? -threshold : threshold
            return (center - row.frame.midY) * direction >= buffer
        }.max { ($0.frame.midY - origin) * direction < ($1.frame.midY - origin) * direction }?.id
    }
}
