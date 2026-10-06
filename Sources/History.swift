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

enum BreakOutcome: String, Codable {
    case inProgress, completed, skipped, postponed, interrupted
    var title: String {
        switch self {
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .skipped: return "Skipped"
        case .postponed: return "Postponed"
        case .interrupted: return "Interrupted"
        }
    }
}

struct BreakSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var planID: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var plannedDuration: Double
    var rested: Double = 0
    var outcome: BreakOutcome = .inProgress
}

struct ActivityHistory: Codable, Equatable {
    private(set) var records: [DayRecord] = []
    private(set) var sessions: [BreakSession] = []
    init() {}
    private enum CodingKeys: String, CodingKey { case records, sessions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decodeIfPresent([DayRecord].self, forKey: .records) ?? []
        sessions = try values.decodeIfPresent([BreakSession].self, forKey: .sessions) ?? []
    }

    @discardableResult mutating func startSession(planID: UUID, name: String, duration: Double, at date: Date = Date(), now: Date = Date(), calendar: Calendar = .current) -> UUID {
        let session = BreakSession(planID: planID, name: name, startedAt: date, plannedDuration: duration)
        sessions.append(session)
        prune(now: now, calendar: calendar)
        return session.id
    }
    mutating func endSession(_ id: UUID, outcome: BreakOutcome, at date: Date = Date(), rested: Double = 0, now: Date = Date(), calendar: Calendar = .current) {
        guard outcome != .inProgress, let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].outcome == .inProgress else { return }
        sessions[index].outcome = outcome; sessions[index].endedAt = date
        sessions[index].rested = max(0, rested)
        prune(now: now, calendar: calendar)
    }
    mutating func recoverInterruptedSessions() {
        // An unclean exit has no known end time. Do not invent one at relaunch.
        for index in sessions.indices where sessions[index].outcome == .inProgress { sessions[index].outcome = .interrupted }
    }

    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        records = records.filter {
            guard let date = HistoryDates.date(for: $0.day, calendar: calendar) else { return false }
            return date >= cutoff && date <= today
        }.sorted { $0.day < $1.day }
        sessions = sessions.filter { max($0.startedAt, $0.endedAt ?? $0.startedAt) >= cutoff && $0.startedAt < calendar.date(byAdding: .day, value: 1, to: today)! }
            .sorted { $0.startedAt < $1.startedAt }
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

struct TimelineViewport {
    let bounds: ClosedRange<Date>
    private(set) var center: Date
    private(set) var span: TimeInterval
    var maximumSpan: TimeInterval { bounds.upperBound.timeIntervalSince(bounds.lowerBound) }
    var range: ClosedRange<Date> { center.addingTimeInterval(-span / 2)...center.addingTimeInterval(span / 2) }
    init(now: Date = Date(), calendar: Calendar = .current, span: TimeInterval = 86400) {
        let today = calendar.startOfDay(for: now)
        bounds = calendar.date(byAdding: .day, value: -29, to: today)!...calendar.date(byAdding: .day, value: 1, to: today)!
        self.span = 3600; center = now
        zoom(to: span)
    }
    mutating func zoom(to seconds: TimeInterval, around date: Date? = nil) {
        guard seconds.isFinite && seconds > 0 else { return }
        span = max(3600, min(maximumSpan, seconds))
        move(to: date ?? center)
    }
    mutating func move(to date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        center = max(bounds.lowerBound.addingTimeInterval(span / 2), min(bounds.upperBound.addingTimeInterval(-span / 2), date))
    }
}
