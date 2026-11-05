import Foundation

/// Build once per history/filter change. Gestures query sorted prefix totals,
/// rather than filtering and scanning all saved events for every chart frame.
struct ActivityAggregation {
    private struct Series {
        let dates: [Date]
        let prefix: [DayRecord]
        init(_ items: [(Date, DayRecord)]) {
            let sorted = items.sorted { $0.0 < $1.0 }
            dates = sorted.map { $0.0 }
            var sums = [DayRecord()]
            sums.reserveCapacity(items.count + 1)
            for (_, record) in sorted {
                let previous = sums.last!
                sums.append(DayRecord(completed: previous.completed + record.completed, skipped: previous.skipped + record.skipped,
                                      postponed: previous.postponed + record.postponed, rested: previous.rested + record.rested))
            }
            prefix = sums
        }
        func lowerBound(_ date: Date) -> Int {
            var low = 0, high = dates.count
            while low < high {
                let middle = (low + high) / 2
                if dates[middle] < date { low = middle + 1 } else { high = middle }
            }
            return low
        }
        func total(from start: Date, to end: Date) -> DayRecord {
            guard end > start else { return DayRecord() }
            let a = prefix[lowerBound(start)], b = prefix[lowerBound(end)]
            return DayRecord(completed: b.completed - a.completed, skipped: b.skipped - a.skipped,
                             postponed: b.postponed - a.postponed, rested: max(0, b.rested - a.rested))
        }
    }
    private let calendar: Calendar
    private let daily: Series
    private let events: Series
    private let recordsByDay: [Date: DayRecord]
    private let untimedDays: [Date]

    init(history: ActivityHistory, selectedBreaks: Set<UUID>? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        let source = history.filtered(for: selectedBreaks, calendar: calendar)
        let records = source.records.compactMap { record in HistoryDates.date(for: record.day, calendar: calendar).map { ($0, record) } }
        daily = Series(records)
        recordsByDay = Dictionary(records, uniquingKeysWith: { _, latest in latest })
        var timed: [(Date, DayRecord)] = []
        func credit(_ date: Date, _ outcome: BreakOutcome, _ rested: Double) {
            switch outcome {
            case .completed: timed.append((date, DayRecord(completed: 1, rested: rested)))
            case .skipped: timed.append((date, DayRecord(skipped: 1)))
            case .postponed: timed.append((date, DayRecord(postponed: 1)))
            default: break
            }
        }
        for session in source.sessions {
            if let date = session.endedAt { credit(date, session.outcome, session.rested) }
        }
        for action in source.actions { credit(action.date, action.outcome, 0) }
        let exact = Series(timed)
        events = exact
        untimedDays = records.compactMap { date, record in
            let end = calendar.date(byAdding: .day, value: 1, to: date)!
            let known = exact.total(from: date, to: end)
            return record.completed > known.completed || record.skipped > known.skipped || record.postponed > known.postponed ? date : nil
        }.sorted()
    }

    func buckets(in range: ClosedRange<Date>) -> [ActivityBucket] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let isDaily = span > 2 * 86400, monthly = span > 120 * 86400
        let component: Calendar.Component = monthly ? .month : isDaily ? .day : span > 2 * 3600 ? .hour : .minute
        var cursor = calendar.dateInterval(of: component, for: range.lowerBound)!.start
        if component == .minute { cursor = cursor.addingTimeInterval(-Double(calendar.component(.minute, from: cursor) % 15) * 60) }
        var result: [ActivityBucket] = []
        while cursor < range.upperBound {
            let next = calendar.date(byAdding: component, value: component == .minute ? 15 : 1, to: cursor)!
            let total: DayRecord
            if monthly {
                total = daily.total(from: max(cursor, calendar.startOfDay(for: range.lowerBound)), to: min(next, range.upperBound))
            } else if isDaily {
                total = recordsByDay[cursor] ?? DayRecord()
            } else {
                total = events.total(from: max(cursor, range.lowerBound), to: min(next, range.upperBound))
            }
            result.append(ActivityBucket(start: cursor, end: next, totals: total))
            cursor = next
        }
        return result
    }

    func hasUntimedActivity(in range: ClosedRange<Date>) -> Bool {
        let first = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound.addingTimeInterval(-0.001))
        // The number of legacy days is generally tiny; no session scan is needed.
        var low = 0, high = untimedDays.count
        while low < high {
            let middle = (low + high) / 2
            if untimedDays[middle] < first { low = middle + 1 } else { high = middle }
        }
        return low < untimedDays.count && untimedDays[low] <= last
    }
}
