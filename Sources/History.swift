import Foundation

struct DayRecord: Codable, Identifiable, Equatable {
    var day: String = ""
    var completed = 0
    var skipped = 0
    var postponed = 0
    var rested: Double = 0
    var id: String { day }
    var date: Date { HistoryDates.date(for: day) ?? .distantPast }
    var outcomes: Int { completed + skipped + postponed }
}

enum HistoryDates {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components), self.key(for: date, calendar: calendar) == key else { return nil }
        return date
    }
}

struct ActivityHistory: Codable, Equatable {
    private(set) var records: [DayRecord] = []

    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        records = records.filter {
            guard let date = HistoryDates.date(for: $0.day, calendar: calendar) else { return false }
            return date >= cutoff && date <= today
        }.sorted { $0.day < $1.day }
    }
    mutating func update(_ record: DayRecord, now: Date = Date(), calendar: Calendar = .current) {
        guard HistoryDates.date(for: record.day, calendar: calendar) != nil else { return }
        if let index = records.firstIndex(where: { $0.day == record.day }) { records[index] = record }
        else { records.append(record) }
        prune(now: now, calendar: calendar)
    }
    mutating func migrate(_ old: DayRecord?, now: Date = Date(), calendar: Calendar = .current) {
        if let old, !records.contains(where: { $0.day == old.day }) { update(old, now: now, calendar: calendar) }
        prune(now: now, calendar: calendar)
    }
    func days(count: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [DayRecord] {
        let length = max(1, min(30, count))
        let today = calendar.startOfDay(for: now)
        return (0..<length).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = HistoryDates.key(for: date, calendar: calendar)
            return records.first(where: { $0.day == key }) ?? DayRecord(day: key)
        }
    }
    static func total(_ days: [DayRecord]) -> DayRecord {
        days.reduce(DayRecord()) { sum, day in
            DayRecord(completed: sum.completed + day.completed, skipped: sum.skipped + day.skipped, postponed: sum.postponed + day.postponed, rested: sum.rested + day.rested)
        }
    }
}
