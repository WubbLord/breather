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

struct TimedAction: Codable, Equatable {
    var date: Date
    var outcome: BreakOutcome
}

struct ActivityHistory: Codable, Equatable {
    private(set) var records: [DayRecord] = []
    private(set) var sessions: [BreakSession] = []
    private(set) var actions: [TimedAction] = []
    init() {}
    private enum CodingKeys: String, CodingKey { case records, sessions, actions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decodeIfPresent([DayRecord].self, forKey: .records) ?? []
        sessions = try values.decodeIfPresent([BreakSession].self, forKey: .sessions) ?? []
        actions = try values.decodeIfPresent([TimedAction].self, forKey: .actions) ?? []
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
    mutating func recordAction(_ outcome: BreakOutcome, at date: Date = Date(), now: Date = Date(), calendar: Calendar = .current) {
        guard outcome == .skipped || outcome == .postponed else { return }
        actions.append(TimedAction(date: date, outcome: outcome))
        prune(now: now, calendar: calendar)
    }
    mutating func recoverInterruptedSessions() {
        // An unclean exit has no known end time. Do not invent one at relaunch.
        for index in sessions.indices where sessions[index].outcome == .inProgress { sessions[index].outcome = .interrupted }
    }

    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        actions = actions.filter { $0.date >= cutoff && $0.date < calendar.date(byAdding: .day, value: 1, to: today)! }
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

struct ActivityViewport {
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


extension ActivityViewport {
    mutating func zoom(factor: Double, anchor: Double) {
        guard factor.isFinite, factor > 0, anchor.isFinite else { return }
        let fraction = max(0, min(1, anchor))
        let fixedDate = range.lowerBound.addingTimeInterval(span * fraction)
        let newSpan = max(3600, min(maximumSpan, span * factor))
        zoom(to: newSpan, around: fixedDate.addingTimeInterval(newSpan * (0.5 - fraction)))
    }
    mutating func pan(fraction: Double) {
        guard fraction.isFinite else { return }
        move(to: center.addingTimeInterval(span * fraction))
    }
}

struct ActivityBucket: Identifiable {
    let start: Date
    let end: Date
    var totals: DayRecord = DayRecord()
    var id: Date { start }
}

extension ActivityHistory {
    // Daily summaries are authoritative for older history. Short ranges use exact
    // action/completion times; interrupted and preview sessions never add totals.
    func buckets(in range: ClosedRange<Date>, calendar: Calendar = .current) -> [ActivityBucket] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let daily = span > 2 * 86400
        let component: Calendar.Component = daily ? .day : (span > 2 * 3600 ? .hour : .minute)
        var cursor = calendar.dateInterval(of: component, for: range.lowerBound)!.start
        if component == .minute {
            cursor = cursor.addingTimeInterval(-Double(calendar.component(.minute, from: cursor) % 15) * 60)
        }
        var result: [ActivityBucket] = []
        let recordsByDay = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { _, latest in latest })
        while cursor < range.upperBound {
            let next = calendar.date(byAdding: component, value: component == .minute ? 15 : 1, to: cursor)!
            var bucket = ActivityBucket(start: cursor, end: next)
            if daily {
                bucket.totals = recordsByDay[HistoryDates.key(for: cursor, calendar: calendar)] ?? DayRecord()
            }
            result.append(bucket); cursor = next
        }
        if !daily {
            let indices = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.start, $0.offset) })
            func credit(_ date: Date, _ outcome: BreakOutcome, _ rested: Double) {
                guard date >= range.lowerBound && date < range.upperBound else { return }
                var start = calendar.dateInterval(of: component, for: date)!.start
                if component == .minute { start = start.addingTimeInterval(-Double(calendar.component(.minute, from: start) % 15) * 60) }
                guard let index = indices[start] else { return }
                switch outcome {
                case .completed: result[index].totals.completed += 1; result[index].totals.rested += rested
                case .skipped: result[index].totals.skipped += 1
                case .postponed: result[index].totals.postponed += 1
                default: break
                }
            }
            for session in sessions {
                if let date = session.endedAt, [.completed, .skipped, .postponed].contains(session.outcome) { credit(date, session.outcome, session.rested) }
            }
            for action in actions { credit(action.date, action.outcome, 0) }
        }
        return result
    }
    func hasUntimedActivity(in range: ClosedRange<Date>, calendar: Calendar = .current) -> Bool {
        let first = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound.addingTimeInterval(-0.001))
        return records.contains { record in
            guard let date = HistoryDates.date(for: record.day, calendar: calendar), date >= first, date <= last else { return false }
            let end = calendar.date(byAdding: .day, value: 1, to: date)!
            let exact = ActivityHistory.total(buckets(in: date...end, calendar: calendar).map { $0.totals })
            return record.completed > exact.completed || record.skipped > exact.skipped || record.postponed > exact.postponed
        }
    }
}
