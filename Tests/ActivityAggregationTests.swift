import Foundation

@main enum ActivityAggregationTests {
    static func main() {
        var comparisons = 0
        for zone in ["America/New_York", "Europe/Paris"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let start = HistoryDates.date(for: "2026-10-15", calendar: calendar)!
            let ids = [UUID(), UUID(), UUID()]
            var history = ActivityHistory()
            var records: [String: DayRecord] = [:]
            func record(_ date: Date, _ outcome: BreakOutcome, _ rested: Double) {
                let key = HistoryDates.key(for: date, calendar: calendar)
                var day = records[key] ?? DayRecord(day: key)
                if outcome == .completed { day.completed += 1; day.rested += rested }
                if outcome == .skipped { day.skipped += 1 }
                if outcome == .postponed { day.postponed += 1 }
                records[key] = day
            }
            for i in 0..<600 {
                let end = start.addingTimeInterval(Double(i * 6473))
                let outcome: BreakOutcome = i % 17 == 0 ? .interrupted : i % 13 == 0 ? .postponed : i % 7 == 0 ? .skipped : .completed
                let duration = i % 2 == 0 ? 300.0 : 23.25
                let id = history.startSession(planID: ids[i % 3], name: "Break", duration: duration, at: end.addingTimeInterval(-duration))
                history.endSession(id, outcome: outcome, at: end, rested: outcome == .completed ? duration : 0)
                record(end, outcome, outcome == .completed ? duration : 0)
            }
            let fall = HistoryDates.date(for: "2026-11-01", calendar: calendar)!
            for offset in [70 * 60.0, 130 * 60.0] {
                let date = fall.addingTimeInterval(offset)
                history.recordAction(.skipped, planID: ids[0], name: "Break", at: date)
                record(date, .skipped, 0)
            }
            history.recordAction(.postponed, at: start.addingTimeInterval(180))
            record(start.addingTimeInterval(180), .postponed, 0)
            for day in records.values { history.update(day, calendar: calendar) }
            history.update(DayRecord(day: "2026-01-01", completed: 5, skipped: 2, rested: 999), calendar: calendar)
            let original = history
            for selection in [nil as Set<UUID>?, Set<UUID>(), Set([ids[0]]), Set([ids[1], ids[2]])] {
                let aggregation = ActivityAggregation(history: history, selectedBreaks: selection, calendar: calendar)
                let source = history.filtered(for: selection, calendar: calendar)
                var ranges: [ClosedRange<Date>] = [fall...calendar.date(byAdding: .day, value: 1, to: fall)!, start...start.addingTimeInterval(3600), start...start.addingTimeInterval(21600)]
                let spans: [Double] = [3600, 7700, 21600, 86400, 2 * 86400, 7 * 86400, 30 * 86400, 180 * 86400, 5 * 365 * 86400]
                for i in 0..<60 {
                    let lower = start.addingTimeInterval(Double(i * 38873 - 5 * 86400))
                    let span = spans[i % spans.count]
                    ranges.append(lower...lower.addingTimeInterval(span))
                }
                for range in ranges {
                    let old = source.buckets(in: range, calendar: calendar), indexed = aggregation.buckets(in: range)
                    testCheck(old.count == indexed.count, "Indexed aggregation preserves bucket boundaries")
                    for (a, b) in zip(old, indexed) {
                        testCheck(a.start == b.start && a.end == b.end && a.totals.day == b.totals.day)
                        testCheck(a.totals.completed == b.totals.completed && a.totals.skipped == b.totals.skipped && a.totals.postponed == b.totals.postponed, "Indexed totals match authoritative daily records and exact timed outcomes")
                        testCheck(abs(a.totals.rested - b.totals.rested) < 0.00001, "Rest totals remain exact to sub-millisecond precision")
                    }
                    testCheck(source.hasUntimedActivity(in: range, calendar: calendar) == aggregation.hasUntimedActivity(in: range), "Legacy timing notice stays accurate")
                    comparisons += 1
                }
            }
            testCheck(history == original, "Building and querying indexes never changes saved history")
        }
        print("Activity aggregation passed: \(comparisons) indexed/legacy comparisons across filters, DST, quarter-hour/hour/day/month bins, partial ranges, and untimed records")
    }
}
