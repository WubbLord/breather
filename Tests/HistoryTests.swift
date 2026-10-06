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
        let legacyData = try! JSONSerialization.data(withJSONObject: ["records": [["day": "2026-11-10", "completed": 2, "skipped": 1, "postponed": 0, "rested": 40]]])
        var timed = try! JSONDecoder().decode(ActivityHistory.self, from: legacyData)
        expect(timed.records[0].completed == 2 && timed.sessions.isEmpty, "Old daily totals migrate without invented timestamps")
        let start = calendar.date(bySettingHour: 10, minute: 23, second: 17, of: today)!
        let id = timed.startSession(planID: UUID(), name: "Quick", duration: 20, at: start, now: start, calendar: calendar)
        expect(timed.sessions.first?.startedAt == start && timed.sessions.first?.outcome == .inProgress, "Persist exact break start immediately")
        let end = start.addingTimeInterval(23.25)
        timed.endSession(id, outcome: .completed, at: end, rested: 20, now: end, calendar: calendar)
        expect(timed.sessions[0].endedAt == end && timed.sessions[0].rested == 20 && timed.sessions[0].name == "Quick", "Preserve exact end, rest, and historical name")
        timed.endSession(id, outcome: .interrupted, at: end.addingTimeInterval(60), now: end, calendar: calendar)
        expect(timed.sessions[0].outcome == .completed && timed.sessions[0].endedAt == end, "A completed session cannot be reclassified on quit")
        for outcome in [BreakOutcome.skipped, .postponed, .interrupted] {
            let event = timed.startSession(planID: UUID(), name: outcome.title, duration: 300, at: start, now: end, calendar: calendar)
            timed.endSession(event, outcome: outcome, at: end, now: end, calendar: calendar)
        }
        let crash = timed.startSession(planID: UUID(), name: "Crash", duration: 300, at: start, now: end, calendar: calendar)
        timed.recoverInterruptedSessions()
        expect(timed.sessions.first(where: { $0.id == crash })?.outcome == .interrupted && timed.sessions.first(where: { $0.id == crash })?.endedAt == nil, "Unclean exit is interrupted without inventing an end time")
        let persisted = try! JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(timed))
        expect(persisted == timed && persisted.records[0].completed == 2, "Exact sessions survive relaunch without changing daily totals")
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        let old = timed.startSession(planID: UUID(), name: "Old", duration: 20, at: cutoff.addingTimeInterval(-100), now: start, calendar: calendar)
        expect(!timed.sessions.contains(where: { $0.id == old }), "Prune timestamp history on the same calendar-day boundary")
        var crossing = ActivityHistory()
        let boundary = crossing.startSession(planID: UUID(), name: "Midnight", duration: 300, at: cutoff.addingTimeInterval(-10), now: cutoff.addingTimeInterval(-10), calendar: calendar)
        crossing.endSession(boundary, outcome: .completed, at: cutoff.addingTimeInterval(290), rested: 300, now: start, calendar: calendar)
        expect(crossing.sessions.count == 1 && crossing.sessions[0].startedAt < cutoff, "Retain a break spanning the retention boundary")
        crossing.prune(now: tomorrow, calendar: calendar)
        expect(crossing.sessions.isEmpty, "Remove the boundary-spanning break once its end is outside retention")
        var viewport = TimelineViewport(now: start, calendar: calendar)
        viewport.zoom(to: 1)
        expect(viewport.span == 3600 && viewport.range.contains(start), "Zoom reaches one-hour granularity around the current time")
        viewport.zoom(to: .infinity); expect(viewport.span == 3600, "Ignore invalid zoom inputs")
        viewport.move(to: .distantPast); expect(viewport.range.lowerBound == cutoff, "Pan clamps to oldest retained day")
        viewport.move(to: .distantFuture); expect(viewport.range.upperBound == tomorrow, "Pan clamps to the end of today")
        viewport.zoom(to: 86400 * 40)
        expect(viewport.range == cutoff...tomorrow && viewport.span == 86400 * 30 + 3600, "Full range uses calendar days across daylight-saving change")
        print("History tests passed: retention, DST, migration, exact timestamps, outcomes, interruptions, persistence, midnight boundaries, hourly zoom and pan limits")
    }
}
