import SwiftUI
import Charts

private let skipColor = Color(red: 0.70, green: 0.45, blue: 0.31)
private let postponeColor = Color(red: 0.55, green: 0.59, blue: 0.68)

func restLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
    return total % 3600 == 0 ? "\(total / 3600)h" : "\(total / 3600)h \((total % 3600) / 60)m"
}

struct ActivityView: View, Equatable {
    let history: ActivityHistory
    let currentDay: String
    static var bodyEvaluationCount = 0
    @ViewState private var viewport: ActivityViewport
    @ViewState private var selectedDate: Date? = nil
    init(model: BreakModel, initialSpan: Double? = nil, initialCenter: Date? = nil) {
        history = model.history
        currentDay = model.record.day
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(byAdding: .day, value: -7, to: end)!
        var view = ActivityViewport(span: initialSpan ?? end.timeIntervalSince(start))
        if initialSpan == nil { view.move(to: start.addingTimeInterval(end.timeIntervalSince(start) / 2)) }
        if let initialCenter { view.move(to: initialCenter) }
        _viewport = ViewState(initialValue: view)
    }
    // Countdown changes rebuild the dashboard, but only history/day changes
    // should invalidate its expensive chart subtree. State still drives zoom/pan.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.history == rhs.history && lhs.currentDay == rhs.currentDay
    }
    var daily: Bool { viewport.span > 2 * 86400 }
    var scaleLabel: String {
        if viewport.span == viewport.maximumSpan { return "30 days" }
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: viewport.range.lowerBound)!
        if abs(weekEnd.timeIntervalSince(viewport.range.upperBound)) < 0.01 { return "7 days" }
        if let day = Calendar.current.dateInterval(of: .day, for: viewport.center), abs(day.start.timeIntervalSince(viewport.range.lowerBound)) < 0.01 && abs(day.duration - viewport.span) < 0.01 { return "1 day" }
        if viewport.span > 2 * 86400 { return String(format: "%.1f days", viewport.span / 86400) }
        return restLabel(viewport.span)
    }
    var rangeLabel: String {
        let start = viewport.range.lowerBound, end = viewport.range.upperBound
        if daily { return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day()))" }
        let day = start.formatted(.dateTime.month(.abbreviated).day())
        let endDay = Calendar.current.isDate(start, inSameDayAs: end) ? "" : end.formatted(.dateTime.month(.abbreviated).day()) + " "
        return "\(day), \(start.formatted(date: .omitted, time: .shortened)) – \(endDay)\(end.formatted(date: .omitted, time: .shortened))"
    }
    var body: some View {
        if CommandLine.arguments.contains("--ui-smoke-test") { Self.bodyEvaluationCount += 1 }
        let buckets = history.buckets(in: viewport.range)
        let total = ActivityHistory.total(buckets.map { $0.totals })
        let focus = selectedDate ?? Date()
        let selected = buckets.first { $0.start <= focus && $0.end > focus } ?? buckets.last!
        let ticks = clockTicks(buckets)
        let restMaximum = max(1, (buckets.map { $0.totals.rested / 60 }.max() ?? 0) * 1.15)
        let countMaximum = max(1, Double(buckets.map { max($0.totals.completed, $0.totals.skipped, $0.totals.postponed) }.max() ?? 0) * 1.15)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("A little rest adds up.").font(.system(size: 17, weight: .medium, design: .rounded))
                    Spacer()
                    Menu {
                        Button("30 days") { preset(days: 30) }
                        Button("7 days") { preset(days: 7) }
                        Divider()
                        Button("1 day") { preset(hours: 24) }
                        Button("6 hours") { preset(hours: 6) }
                        Button("1 hour") { preset(hours: 1) }
                    } label: { Text(scaleLabel).frame(minWidth: 75) }
                    .accessibilityLabel("Activity time scale")
                }
                HStack(spacing: 10) {
                    metric("Rest time", restLabel(total.rested), color: teal)
                    metric("Completed", String(total.completed), color: teal)
                    metric("Skipped", String(total.skipped), color: skipColor)
                    metric("Postponed", String(total.postponed), color: postponeColor)
                }
                HStack {
                    Text(rangeLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { viewport.pan(fraction: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).accessibilityLabel("Earlier time range")
                        .disabled(viewport.range.lowerBound <= viewport.bounds.lowerBound)
                    Button { viewport.pan(fraction: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).accessibilityLabel("Later time range")
                        .disabled(viewport.range.upperBound >= viewport.bounds.upperBound)
                    Button("Today") { viewport.move(to: viewport.span >= 23 * 3600 ? Calendar.current.startOfDay(for: Date()).addingTimeInterval(43200) : Date()); selectedDate = nil }.buttonStyle(.plain).foregroundStyle(teal)
                }.padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 9) {
                    Text("MINUTES OF REST").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Chart(buckets) { bucket in
                        RectangleMark(xStart: .value("Start", barEdge(bucket, 0.12)), xEnd: .value("End", barEdge(bucket, 0.88)), yStart: .value("Baseline", 0), yEnd: .value("Minutes", bucket.totals.rested / 60))
                            .foregroundStyle(teal.opacity(bucket.id == selected.id ? 1 : 0.60)).cornerRadius(2)
                            .accessibilityLabel(bucket.start.formatted(date: .abbreviated, time: daily ? .omitted : .shortened))
                            .accessibilityValue("\(restLabel(bucket.totals.rested)) of rest")
                    }
                    .chartXScale(domain: viewport.range)
                    .chartYScale(domain: 0...restMaximum)
                    .chartXAxis { dateAxis(ticks) }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartOverlay { proxy in mouseOverlay(proxy) }
                    .chartPlotStyle { $0.clipped() }
                    .frame(height: 100)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("BREAK ACTIVITY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        legend("Completed", teal); legend("Skipped", skipColor); legend("Postponed", postponeColor)
                    }
                    Chart {
                        ForEach(buckets) { bucket in
                            RectangleMark(xStart: .value("Start", barEdge(bucket, 0.12)), xEnd: .value("End", barEdge(bucket, 0.34)), yStart: .value("Baseline", 0), yEnd: .value("Breaks", bucket.totals.completed)).foregroundStyle(teal)
                            RectangleMark(xStart: .value("Start", barEdge(bucket, 0.39)), xEnd: .value("End", barEdge(bucket, 0.61)), yStart: .value("Baseline", 0), yEnd: .value("Breaks", bucket.totals.skipped)).foregroundStyle(skipColor)
                            RectangleMark(xStart: .value("Start", barEdge(bucket, 0.66)), xEnd: .value("End", barEdge(bucket, 0.88)), yStart: .value("Baseline", 0), yEnd: .value("Breaks", bucket.totals.postponed)).foregroundStyle(postponeColor)
                        }
                    }
                    .chartXScale(domain: viewport.range)
                    .chartYScale(domain: 0...countMaximum)
                    .chartXAxis { dateAxis(ticks) }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        if let number = value.as(Double.self), number.rounded() == number { AxisGridLine(); AxisValueLabel() }
                    } }
                    .chartLegend(.hidden)
                    .chartOverlay { proxy in mouseOverlay(proxy) }
                    .chartPlotStyle { $0.clipped() }
                    .frame(height: 100)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(selected.start.formatted(date: .abbreviated, time: daily ? .omitted : .shortened)).font(.system(size: 12, weight: .semibold))
                    Text("\(restLabel(selected.totals.rested)) rest · \(selected.totals.completed) completed · \(selected.totals.skipped) skipped · \(selected.totals.postponed) postponed")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                Text("Wheel or pinch to zoom at the pointer. Scroll sideways, Shift-scroll, or drag to move through time. Click a bar for its totals.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !daily && history.hasUntimedActivity(in: viewport.range) {
                    Text("Some older activity has daily totals only. Its times are unavailable in hourly views.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("Rest time counts completed breaks. Skipped and postponed totals count your actions. Previews and idle time are excluded. History stays on this Mac for 30 days.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 4)
        }
        .onChange(of: currentDay) { _ in
            let old = viewport
            viewport = ActivityViewport(span: old.span == old.maximumSpan ? 40 * 86400 : old.span)
            viewport.move(to: old.span == old.maximumSpan ? viewport.center : old.center)
        }
    }
    func barEdge(_ bucket: ActivityBucket, _ fraction: Double) -> Date { bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) * fraction) }
    func clockTicks(_ buckets: [ActivityBucket]) -> [Date] {
        buckets.map { $0.start }.filter { date in
            date >= viewport.range.lowerBound && date <= viewport.range.upperBound && (viewport.span <= 12 * 3600 || Calendar.current.component(.hour, from: date) % 3 == 0)
        }
    }
    @AxisContentBuilder func dateAxis(_ ticks: [Date]) -> some AxisContent {
        if daily {
            AxisMarks(values: .stride(by: .day, count: viewport.span > 10 * 86400 ? 7 : 1)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
        } else if viewport.span > 2 * 3600 {
            AxisMarks(values: ticks) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour(), centered: false, anchor: .top) }
        } else {
            AxisMarks(values: ticks) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute(), centered: false, anchor: .top) }
        }
    }
    func preset(days: Int) {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        viewport.zoom(to: end.timeIntervalSince(start), around: start.addingTimeInterval(end.timeIntervalSince(start) / 2)); selectedDate = nil
    }
    func preset(hours: Int) {
        let target = selectedDate ?? Date()
        let calendar = Calendar.current
        let start: Date, end: Date
        if hours == 24 {
            start = calendar.startOfDay(for: target); end = calendar.date(byAdding: .day, value: 1, to: start)!
        } else {
            let hour = calendar.dateInterval(of: .hour, for: target)!.start
            start = hour.addingTimeInterval(-Double(calendar.component(.hour, from: hour) % hours) * 3600)
            end = start.addingTimeInterval(Double(hours) * 3600)
        }
        viewport.zoom(to: end.timeIntervalSince(start), around: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
    }
    func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
    func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 9)).foregroundStyle(.secondary) }
    }
    func mouseOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            let frame = geometry[proxy.plotAreaFrame]
            ActivityMouseView(zoom: { factor, anchor in viewport.zoom(factor: factor, anchor: anchor) }, pan: { viewport.pan(fraction: $0) }, select: { fraction in
                selectedDate = viewport.range.lowerBound.addingTimeInterval(viewport.span * fraction)
            }).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
        }
    }
}
