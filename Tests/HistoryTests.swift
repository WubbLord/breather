import Foundation

@main enum HistoryTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = HistoryDates.date(for: "2026-11-10", calendar: calendar)!
        var history = ActivityHistory()
        func expect(_ value: Bool, _ message: String) { precondition(value, message) }
        for offset in 0..<40 {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let record = DayRecord(day: HistoryDates.key(for: date, calendar: calendar), completed: 1, skipped: 2, postponed: 3, rested: 20)
            history.update(record, now: today, calendar: calendar)
        }
        expect(history.records.count == 30, "Retain exactly today and previous 29 days")
        expect(history.records.first?.day == "2026-10-12", "Calendar-day cutoff includes DST change")
        expect(history.records.last?.day == "2026-11-10", "Include today")
        let total = ActivityHistory.total(history.days(now: today, calendar: calendar))
        expect(total.completed == 30 && total.skipped == 60 && total.postponed == 90 && total.rested == 600, "Totals across days")
        let saved = try! JSONEncoder().encode(history)
        let reloaded = try! JSONDecoder().decode(ActivityHistory.self, from: saved)
        expect(reloaded == history, "History survives restart")
        let changed = DayRecord(day: "2026-11-10", completed: 8, rested: 300)
        history.update(changed, now: today, calendar: calendar)
        expect(history.records.count == 30 && history.records.last == changed, "Updating today replaces instead of duplicating")
        history.migrate(DayRecord(day: "2026-11-10", completed: 999), now: today, calendar: calendar)
        expect(history.records.last == changed, "Legacy migration cannot overwrite persisted history")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        history.update(DayRecord(day: "2026-11-11"), now: tomorrow, calendar: calendar)
        expect(history.records.count == 30 && history.records.first?.day == "2026-10-13", "Prune at midnight without losing yesterday")
        expect(history.records.first(where: { $0.day == "2026-11-10" }) == changed, "Preserve yesterday's completed and rest totals")
        var sparse = ActivityHistory()
        sparse.migrate(DayRecord(day: "2026-11-09", completed: 4, skipped: 1, rested: 120), now: today, calendar: calendar)
        let days = sparse.days(now: today, calendar: calendar)
        expect(days.count == 30 && days[28].completed == 4 && days[29].completed == 0, "Fill unrecorded days with zero values")
        expect(sparse.days(count: 7, now: today, calendar: calendar).count == 7, "Seven-day view")
        sparse.migrate(DayRecord(day: "2020-01-01", completed: 8), now: today, calendar: calendar)
        expect(sparse.records.count == 1, "Discard legacy data outside retention")
        sparse.update(DayRecord(day: "invalid", completed: 8), now: today, calendar: calendar)
        expect(sparse.records.count == 1, "Ignore malformed dates")
        expect(HistoryDates.date(for: "2026-02-30", calendar: calendar) == nil, "Reject normalized invalid dates")
        print("History tests passed: 30-day retention, DST, totals, persistence, updates, rollover, migration, zero days, date validation")
    }
}
