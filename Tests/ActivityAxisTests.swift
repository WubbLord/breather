import Foundation

@main enum ActivityAxisTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        let locale = Locale(identifier: "en_US_POSIX")
        func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 16, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let axis = ActivityAxis(calendar: calendar, locale: locale, referenceDate: date())
        func labels(_ start: Date, seconds: Double, width: Double = 560) -> ActivityAxis.Layout {
            axis.layout(in: start...start.addingTimeInterval(seconds), width: width) { Double($0.count) * 5.2 }
        }
        let examples: [(Double, ActivityAxis.Interval)] = [(3600, .minutes(15)), (21600, .hours(1)), (86400, .hours(3)), (3 * 86400, .days(1)), (7 * 86400, .days(1)), (14 * 86400, .days(2)), (30 * 86400, .weeks(1))]
        for (span, expected) in examples {
            let layout = labels(date(), seconds: span)
            testCheck(layout.interval == expected, "Unexpected interval for \(span): \(layout.interval), wanted \(expected)")
            testCheck(!layout.ticks.isEmpty, "Every ordinary span needs visible labels")
        }
        let old = labels(date(2025, 2, 3), seconds: 7 * 86400)
        testCheck(old.ticks.count == 7 && old.ticks.allSatisfy { calendar.component(.year, from: $0.date) == 2025 && $0.text.contains("2025") }, "Historical weeks must label the visible dates, including the year")
        let first = labels(date(), seconds: 14 * 86400)
        let shifted = labels(date(2026, 11, 17), seconds: 14 * 86400)
        let common = first.ticks.filter { tick in shifted.ticks.contains { $0.date == tick.date } }
        testCheck(common.count >= 5, "Small pans must retain the same calendar anchors")
        testCheck(common.allSatisfy { tick in shifted.ticks.contains(tick) }, "Panning must preserve shared label dates, positions, and text")
        let narrow = labels(date(), seconds: 14 * 86400, width: 240)
        testCheck(narrow.interval.seconds >= first.interval.seconds && narrow.ticks.count <= first.ticks.count, "Narrow graphs must use fewer labels")
        let overnight = labels(date(2026, 11, 16, 21), seconds: 6 * 3600)
        testCheck(overnight.ticks.contains { calendar.component(.day, from: $0.date) == 17 && $0.text.contains("Nov 17") }, "Hourly views must identify the new date at midnight")
        let newYear = labels(date(2026, 12, 28), seconds: 14 * 86400)
        testCheck(newYear.ticks.contains { $0.text.contains("2026") } && newYear.ticks.contains { $0.text.contains("2027") }, "Year boundaries must be unambiguous")
        let fallback = labels(date(2026, 11, 1), seconds: 6 * 3600, width: 1000)
        let repeated = fallback.ticks.filter { calendar.component(.hour, from: $0.date) == 1 }
        testCheck(repeated.count == 2 && repeated[0].text != repeated[1].text, "Repeated daylight-saving hours need distinct zone labels")
        let spring = labels(date(2026, 3, 8), seconds: 6 * 3600, width: 1000)
        testCheck(!spring.ticks.contains { calendar.component(.hour, from: $0.date) == 2 }, "Spring-forward ticks must not invent a missing hour")
        let ancient = labels(date(1999, 12, 17), seconds: 14 * 86400)
        testCheck(!ancient.ticks.isEmpty, "Negative offsets from the calendar anchor must still produce dates")
        let spans: [Double] = [3700, 7700, 19 * 3600, 2.8 * 86400, 11 * 86400, 47 * 86400, 150 * 86400, 900 * 86400, 12 * 365.25 * 86400]
        for width in [240.0, 560, 1000] {
            for span in spans {
                let layout = labels(date(2020, 2, 10, 7, 23), seconds: span, width: width)
                testCheck(!layout.ticks.isEmpty && layout.ticks.count <= 12, "Arbitrary zoom levels need bounded, nonempty labels")
                var right = -Double.infinity
                for tick in layout.ticks {
                    testCheck((date(2020, 2, 10, 7, 23)...date(2020, 2, 10, 7, 23).addingTimeInterval(span)).contains(tick.position), "A tick must be anchored inside the visible range")
                    let x = tick.position.timeIntervalSince(date(2020, 2, 10, 7, 23)) / span * width
                    let half = Double(tick.text.count) * 5.2 / 2
                    testCheck(x - half >= right + 7.99, "Axis labels must not overlap")
                    right = x + half
                }
            }
        }
        print("Activity axis passed: presets, 3 days, 2 weeks, historical panning, stable anchors, width/zoom adaptation, midnight, year boundaries, DST, and bounded nonoverlapping labels")
    }
}
