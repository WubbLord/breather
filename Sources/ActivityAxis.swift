import Foundation

/// Calendar-anchored ticks for any visible range, independent of history and
/// presets. Each plot keeps this small formatting cache across pan/zoom frames.
final class ActivityAxis {
    enum Interval: Equatable {
        case minutes(Int), hours(Int), days(Int), weeks(Int), months(Int), years(Int)
        var seconds: Double {
            switch self {
            case .minutes(let n): return Double(n) * 60
            case .hours(let n): return Double(n) * 3600
            case .days(let n): return Double(n) * 86400
            case .weeks(let n): return Double(n) * 7 * 86400
            case .months(let n): return Double(n) * 30.4375 * 86400
            case .years(let n): return Double(n) * 365.25 * 86400
            }
        }
    }
    struct Tick: Equatable {
        let date: Date
        let position: Date
        let text: String
    }
    struct Layout {
        let interval: Interval
        let ticks: [Tick]
    }
    private struct Style: Hashable {
        enum Unit: Hashable { case hour, minute, day, weekday, month, year }
        let unit: Unit
        let date: Bool
        let year: Bool
        let zone: Bool
    }
    private struct LabelKey: Hashable { let date: Date; let style: Style }
    private let calendar: Calendar
    private let locale: Locale
    private let referenceYear: Int
    private var formatters: [Style: DateFormatter] = [:]
    private var labels: [LabelKey: String] = [:]
    private var widths: [String: Double] = [:]
    init(calendar: Calendar = .current, locale: Locale = .current, referenceDate: Date = Date()) {
        self.calendar = calendar; self.locale = locale
        referenceYear = calendar.component(.year, from: referenceDate)
    }

    func layout(in range: ClosedRange<Date>, width: Double, measure: (String) -> Double) -> Layout {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span.isFinite && span > 0 && width.isFinite && width > 0 else { return Layout(interval: .days(1), ticks: []) }
        let daily = span > 2 * 86400, monthly = span > 120 * 86400
        let candidates: [Interval] = [.minutes(15), .minutes(30), .hours(1), .hours(2), .hours(3), .hours(6), .hours(12), .days(1), .days(2), .days(3), .weeks(1), .weeks(2), .months(1), .months(2), .months(3), .months(6), .years(1), .years(2), .years(5), .years(10), .years(20), .years(50), .years(100)]
        let target = max(3, min(8, floor(width / 58)))
        let minimum = max(monthly ? Interval.months(1).seconds : daily ? 86400 : 0, span / target)
        var last = Layout(interval: .years(100), ticks: [])
        for interval in candidates where interval.seconds >= minimum * 0.99 {
            let dates = tickDates(in: range, interval: interval, daily: daily, monthly: monthly)
            let showYear = calendar.component(.year, from: range.lowerBound) != referenceYear ||
                calendar.component(.year, from: range.lowerBound) != calendar.component(.year, from: range.upperBound.addingTimeInterval(-0.001))
            let ticks = dates.enumerated().map { index, tick in
                let unit: Style.Unit
                switch interval {
                case .minutes: unit = .minute
                case .hours: unit = .hour
                case .days, .weeks: unit = span <= 8 * 86400 && !showYear ? .weekday : .day
                case .months: unit = .month
                case .years: unit = .year
                }
                let clock = unit == .hour || unit == .minute
                let hour = calendar.component(.hour, from: tick.date), minute = calendar.component(.minute, from: tick.date)
                let midnight = hour == 0 && minute == 0
                let crossesDay = !calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound)
                let repeatedHour = clock && [-3600.0, 3600].contains { offset in
                    let other = tick.date.addingTimeInterval(offset)
                    return calendar.isDate(tick.date, inSameDayAs: other) && calendar.component(.hour, from: other) == hour && calendar.component(.minute, from: other) == minute
                }
                let style = Style(unit: unit, date: clock && crossesDay && (index == 0 || midnight), year: showYear, zone: repeatedHour)
                return Tick(date: tick.date, position: tick.position, text: label(tick.date, style: style))
            }
            last = Layout(interval: interval, ticks: ticks)
            var right = -Double.infinity
            let fits = ticks.allSatisfy { tick in
                let size: Double
                if let cached = widths[tick.text] { size = cached }
                else { size = measure(tick.text); widths[tick.text] = size }
                let x = tick.position.timeIntervalSince(range.lowerBound) / span * width
                let fits = x - size / 2 >= right + 8
                right = x + size / 2
                return fits
            }
            if fits { return last }
        }
        return last
    }

    private func label(_ date: Date, style: Style) -> String {
        let key = LabelKey(date: date, style: style)
        if let cached = labels[key] { return cached }
        let formatter: DateFormatter
        if let cached = formatters[style] { formatter = cached }
        else {
            formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
            var template: String
            switch style.unit {
            case .hour: template = "j"
            case .minute: template = "jm"
            case .day: template = "MMMd"
            case .weekday: template = "EMMMd"
            case .month: template = "MMMy"
            case .year: template = "y"
            }
            if style.date { template += "MMMd" }
            if style.year && style.unit != .month && style.unit != .year && (style.date || (style.unit != .hour && style.unit != .minute)) { template += "y" }
            if style.zone { template += "z" }
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters[style] = formatter
        }
        let text = formatter.string(from: date)
        if labels.count > 512 { labels.removeAll(keepingCapacity: true); widths.removeAll(keepingCapacity: true) }
        labels[key] = text
        return text
    }

    private func tickDates(in range: ClosedRange<Date>, interval: Interval, daily: Bool, monthly: Bool) -> [(date: Date, position: Date)] {
        let epoch = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        func remainder(_ value: Int, _ step: Int) -> Int { (value % step + step) % step }
        var cursor: Date
        let component: Calendar.Component, step: Int
        switch interval {
        case .minutes(let n):
            component = .minute; step = n
            let start = calendar.dateInterval(of: .minute, for: range.lowerBound)!.start
            cursor = calendar.date(byAdding: .minute, value: -calendar.component(.minute, from: start) % n, to: start)!
        case .hours(let n):
            component = .hour; step = 1
            let start = calendar.dateInterval(of: .hour, for: range.lowerBound)!.start
            cursor = calendar.date(byAdding: .hour, value: -calendar.component(.hour, from: start) % n, to: start)!
        case .days(let n):
            component = .day; step = n
            let start = calendar.startOfDay(for: range.lowerBound)
            cursor = calendar.date(byAdding: .day, value: -remainder(calendar.dateComponents([.day], from: epoch, to: start).day!, n), to: start)!
        case .weeks(let n):
            component = .weekOfYear; step = n
            let start = calendar.dateInterval(of: .weekOfYear, for: range.lowerBound)!.start
            let anchor = calendar.dateInterval(of: .weekOfYear, for: epoch)!.start
            let weeks = calendar.dateComponents([.day], from: anchor, to: start).day! / 7
            cursor = calendar.date(byAdding: .weekOfYear, value: -remainder(weeks, n), to: start)!
        case .months(let n):
            component = .month; step = n
            let start = calendar.dateInterval(of: .month, for: range.lowerBound)!.start
            cursor = calendar.date(byAdding: .month, value: -remainder(calendar.dateComponents([.month], from: epoch, to: start).month!, n), to: start)!
        case .years(let n):
            component = .year; step = n
            let start = calendar.dateInterval(of: .year, for: range.lowerBound)!.start
            cursor = calendar.date(byAdding: .year, value: -remainder(calendar.component(.year, from: start), n), to: start)!
        }
        var result: [(date: Date, position: Date)] = []
        while cursor <= range.upperBound && result.count < 64 {
            let matches: Bool
            switch interval {
            case .minutes(let n): matches = calendar.component(.minute, from: cursor) % n == 0
            case .hours(let n): matches = calendar.component(.hour, from: cursor) % n == 0
            default: matches = true
            }
            let position: Date
            if daily {
                let bucket = calendar.dateInterval(of: monthly ? .month : .day, for: cursor)!
                position = bucket.start.addingTimeInterval(bucket.duration / 2)
            } else { position = cursor }
            if matches && range.contains(position) { result.append((cursor, position)) }
            guard let next = calendar.date(byAdding: component, value: step, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }
}
