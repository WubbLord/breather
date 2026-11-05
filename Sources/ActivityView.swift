import SwiftUI
import Combine

private let skipColor = Color(red: 0.70, green: 0.45, blue: 0.31)
private let postponeColor = Color(red: 0.55, green: 0.59, blue: 0.68)

func restLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
    return total % 3600 == 0 ? "\(total / 3600)h" : "\(total / 3600)h \((total % 3600) / 60)m"
}

@MainActor private final class ActivityDisplay: ObservableObject {
    struct Values: Equatable {
        var scale = "7 days", range = "", selectionTitle = "", selectionSummary = ""
        var total = DayRecord()
    }
    @Published private(set) var values = Values()
    func update(_ value: Values) { if values != value { values = value } }
}

@MainActor private final class ActivityDataCache: ObservableObject {
    @Published private(set) var options: [ActivityBreakOption]
    @Published private(set) var selectedBreaks: Set<UUID>?
    @Published private(set) var atStart = false
    @Published private(set) var atEnd = false
    @Published private(set) var isDaily = true
    @Published private(set) var hasUntimed = false
    let display = ActivityDisplay()
    let plots = ActivityPlotStream()
    private var history: ActivityHistory
    private var aggregation: ActivityAggregation
    private var viewport: ActivityViewport
    private var selectedDate: Date?
    private var allTime = false
    init(history: ActivityHistory, selectedBreaks: Set<UUID>?, currentBreaks: [ActivityBreakOption], initialSpan: Double?, initialCenter: Date?) {
        self.history = history; self.selectedBreaks = selectedBreaks
        aggregation = ActivityAggregation(history: history, selectedBreaks: selectedBreaks)
        options = history.breakOptions(current: currentBreaks)
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(byAdding: .day, value: -7, to: end)!
        viewport = ActivityViewport(span: initialSpan ?? end.timeIntervalSince(start), earliestDate: history.firstDate())
        if initialSpan == nil { viewport.move(to: start.addingTimeInterval(end.timeIntervalSince(start) / 2)) }
        if let initialCenter { viewport.move(to: initialCenter) }
        reproject()
    }
    func update(history: ActivityHistory, currentBreaks: [ActivityBreakOption]) {
        self.history = history
        aggregation = ActivityAggregation(history: history, selectedBreaks: selectedBreaks)
        let nextOptions = history.breakOptions(current: currentBreaks)
        if options != nextOptions { options = nextOptions }
        refreshViewport()
    }
    func selectBreaks(_ selected: Set<UUID>?) {
        guard selectedBreaks != selected else { return }
        selectedBreaks = selected
        aggregation = ActivityAggregation(history: history, selectedBreaks: selected)
        reproject()
    }
    func zoom(factor: Double, anchor: Double) { allTime = false; viewport.zoom(factor: factor, anchor: anchor); reproject() }
    func pan(fraction: Double) { viewport.pan(fraction: fraction); reproject() }
    func select(fraction: Double) { selectedDate = viewport.range.lowerBound.addingTimeInterval(viewport.span * fraction); reproject() }
    func today() {
        viewport.move(to: viewport.span >= 23 * 3600 ? Calendar.current.startOfDay(for: Date()).addingTimeInterval(43200) : Date())
        selectedDate = nil; reproject()
    }
    func showAllTime() { allTime = true; viewport.zoom(to: viewport.maximumSpan); selectedDate = nil; reproject() }
    func refreshViewport() {
        let old = viewport
        viewport = ActivityViewport(span: old.span, earliestDate: history.firstDate())
        if allTime && old.span == old.maximumSpan { viewport.zoom(to: viewport.maximumSpan) }
        else { viewport.move(to: old.center) }
        reproject()
    }
    private func reproject() {
        let buckets = aggregation.buckets(in: viewport.range)
        let total = ActivityHistory.total(buckets.map { $0.totals })
        let focus = selectedDate ?? Date()
        guard let selected = buckets.first(where: { $0.start <= focus && $0.end > focus }) ?? buckets.last else { return }
        let restMaximum = max(1, (buckets.map { $0.totals.rested / 60 }.max() ?? 0) * 1.15)
        let countMaximum = max(1, Double(buckets.map { max($0.totals.completed, $0.totals.skipped, $0.totals.postponed) }.max() ?? 0) * 1.15)
        plots.update(.init(buckets: buckets, range: viewport.range, ticks: daily ? dayLabels(buckets) : clockTicks(buckets), restMaximum: restMaximum, countMaximum: countMaximum, selected: selected.id, daily: daily, monthly: monthly))
        display.update(.init(scale: scaleLabel, range: rangeLabel, selectionTitle: selectedDateLabel(selected.start), selectionSummary: "\(restLabel(selected.totals.rested)) rest · \(selected.totals.completed) completed · \(selected.totals.skipped) skipped · \(selected.totals.postponed) postponed", total: total))
        let first = viewport.range.lowerBound <= viewport.bounds.lowerBound, last = viewport.range.upperBound >= viewport.bounds.upperBound
        if atStart != first { atStart = first }; if atEnd != last { atEnd = last }
        if isDaily != daily { isDaily = daily }
        let untimed = !daily && aggregation.hasUntimedActivity(in: viewport.range)
        if hasUntimed != untimed { hasUntimed = untimed }
    }
    func breakFilterLabel(_ options: [ActivityBreakOption]) -> String {
        guard let selectedBreaks else { return "All breaks" }
        let selected = options.filter { selectedBreaks.contains($0.id) }
        if selected.isEmpty { return "No breaks" }
        return selected.count == 1 ? selected[0].name : "\(selected.count) breaks"
    }
    var daily: Bool { viewport.span > 2 * 86400 }
    var monthly: Bool { viewport.span > 120 * 86400 }
    var scaleLabel: String {
        if allTime && viewport.span == viewport.maximumSpan { return "All time" }
        let monthEnd = Calendar.current.date(byAdding: .day, value: 30, to: viewport.range.lowerBound)!
        if abs(monthEnd.timeIntervalSince(viewport.range.upperBound)) < 0.01 { return "30 days" }
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: viewport.range.lowerBound)!
        if abs(weekEnd.timeIntervalSince(viewport.range.upperBound)) < 0.01 { return "7 days" }
        if let day = Calendar.current.dateInterval(of: .day, for: viewport.center), abs(day.start.timeIntervalSince(viewport.range.lowerBound)) < 0.01 && abs(day.duration - viewport.span) < 0.01 { return "1 day" }
        if viewport.span > 2 * 86400 { return String(format: "%.1f days", viewport.span / 86400) }
        return restLabel(viewport.span)
    }
    var rangeLabel: String {
        let start = viewport.range.lowerBound, end = viewport.range.upperBound
        if daily {
            let format: Date.FormatStyle = viewport.span > 365 * 86400 ? .dateTime.year().month(.abbreviated).day() : .dateTime.month(.abbreviated).day()
            return "\(start.formatted(format)) – \(end.addingTimeInterval(-1).formatted(format))"
        }
        let day = start.formatted(.dateTime.month(.abbreviated).day())
        let endDay = Calendar.current.isDate(start, inSameDayAs: end) ? "" : end.formatted(.dateTime.month(.abbreviated).day()) + " "
        return "\(day), \(start.formatted(date: .omitted, time: .shortened)) – \(endDay)\(end.formatted(date: .omitted, time: .shortened))"
    }
    func barEdge(_ bucket: ActivityBucket, _ fraction: Double) -> Date { bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) * fraction) }
    func dayLabels(_ buckets: [ActivityBucket]) -> [Date] {
        if monthly {
            let step = max(1, Int(ceil(Double(buckets.count) / 7)))
            return buckets.enumerated().filter { $0.offset % step == 0 }.map { barEdge($0.element, 0.5) }.filter { viewport.range.contains($0) }
        }
        return buckets.filter { viewport.span <= 10 * 86400 || Calendar.current.component(.weekday, from: $0.start) == 1 }
            .map { barEdge($0, 0.5) }
            .filter { viewport.range.contains($0) }
    }
    func clockTicks(_ buckets: [ActivityBucket]) -> [Date] {
        buckets.map { $0.start }.filter { date in
            date >= viewport.range.lowerBound && date <= viewport.range.upperBound && (viewport.span <= 12 * 3600 || Calendar.current.component(.hour, from: date) % 3 == 0)
        }
    }
    func selectedDateLabel(_ date: Date) -> String {
        if monthly { return date.formatted(.dateTime.month(.wide).year()) }
        let format: Date.FormatStyle = .dateTime.weekday(.wide).month(.abbreviated).day().year()
        return date.formatted(daily ? format : format.hour().minute())
    }
    func preset(days: Int) {
        allTime = false
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        viewport.zoom(to: end.timeIntervalSince(start), around: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
        selectedDate = nil; reproject()
    }
    func preset(hours: Int) {
        allTime = false
        let target = selectedDate ?? Date(), calendar = Calendar.current
        let start: Date, end: Date
        if hours == 24 {
            start = calendar.startOfDay(for: target); end = calendar.date(byAdding: .day, value: 1, to: start)!
        } else {
            let hour = calendar.dateInterval(of: .hour, for: target)!.start
            start = hour.addingTimeInterval(-Double(calendar.component(.hour, from: hour) % hours) * 3600)
            end = start.addingTimeInterval(Double(hours) * 3600)
        }
        viewport.zoom(to: end.timeIntervalSince(start), around: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
        reproject()
    }
}

// Subscribe to each displayed value independently: a changing zoom caption
// must not invalidate the totals, range text, and selected-day summary.
private struct ActivityLabel: View {
    let display: ActivityDisplay
    let field: KeyPath<ActivityDisplay.Values, String>
    @ViewState private var value: String
    init(display: ActivityDisplay, field: KeyPath<ActivityDisplay.Values, String>) {
        self.display = display; self.field = field
        _value = ViewState(wrappedValue: display.values[keyPath: field])
    }
    var body: some View {
        Text(value).onReceive(display.$values.map { $0[keyPath: field] }.removeDuplicates()) { value = $0 }
    }
}

private struct ActivityMetrics: View {
    let display: ActivityDisplay
    @ViewState private var total: DayRecord
    init(display: ActivityDisplay) {
        self.display = display; _total = ViewState(wrappedValue: display.values.total)
    }
    var body: some View {
        ActivityMetricRow(total: total).equatable()
            .onReceive(display.$values.map(\.total).removeDuplicates()) { total = $0 }
    }
}

/// Updating the live zoom caption directly keeps its menu and the surrounding
/// SwiftUI layout stable through high-frequency trackpad events.
private struct ActivityScaleMenu: NSViewRepresentable {
    let data: ActivityDataCache
    @MainActor final class Coordinator: NSObject {
        var data: ActivityDataCache
        var updates: AnyCancellable?
        init(_ data: ActivityDataCache) { self.data = data }
        @objc func choose(_ item: NSMenuItem) {
            switch item.tag {
            case 0: data.showAllTime()
            case 1: data.preset(days: 30)
            case 2: data.preset(days: 7)
            case 3: data.preset(hours: 24)
            case 4: data.preset(hours: 6)
            case 5: data.preset(hours: 1)
            default: break
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(data) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
        button.setAccessibilityLabel("Activity time scale")
        let menu = NSMenu()
        menu.addItem(withTitle: data.display.values.scale, action: nil, keyEquivalent: "")
        for (index, title) in ["All time", "30 days", "7 days", "1 day", "6 hours", "1 hour"].enumerated() {
            if index == 3 { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.tag = index; item.target = context.coordinator
        }
        button.menu = menu
        context.coordinator.updates = data.display.$values.map(\.scale).removeDuplicates().sink { [weak button] title in
            button?.menu?.items.first?.title = title
            button?.title = title
        }
        return button
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) { context.coordinator.data = data }
    static func dismantleNSView(_ view: NSPopUpButton, coordinator: Coordinator) { coordinator.updates = nil }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? { CGSize(width: 104, height: 24) }
}

private struct ActivityMetricRow: View, Equatable {
    let total: DayRecord
    var body: some View {
        HStack(spacing: 10) {
            metric("Rest time", restLabel(total.rested), color: teal)
            metric("Completed", String(total.completed), color: teal)
            metric("Skipped", String(total.skipped), color: skipColor)
            metric("Postponed", String(total.postponed), color: postponeColor)
        }
    }
    func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActivityView: View, Equatable {
    let history: ActivityHistory
    let currentDay: String
    let currentBreaks: [ActivityBreakOption]
    @StateObject private var data: ActivityDataCache
    @ViewState private var showBreakFilter = false
    static var bodyEvaluationCount = 0
    static var initializationCount = 0
    init(model: BreakModel, initialSpan: Double? = nil, initialCenter: Date? = nil, initialBreaks: Set<UUID>? = nil) {
        if CommandLine.arguments.contains("--background-performance-test") { Self.initializationCount += 1 }
        history = model.history; currentDay = model.record.day
        currentBreaks = model.preferences.plans.map { ActivityBreakOption(id: $0.id, name: $0.name) }
        _data = StateObject(wrappedValue: ActivityDataCache(history: model.history, selectedBreaks: initialBreaks, currentBreaks: model.preferences.plans.map { ActivityBreakOption(id: $0.id, name: $0.name) }, initialSpan: initialSpan, initialCenter: initialCenter))
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.history == rhs.history && lhs.currentDay == rhs.currentDay && lhs.currentBreaks == rhs.currentBreaks }
    var body: some View {
        if (CommandLine.arguments.contains("--ui-smoke-test") || CommandLine.arguments.contains("--activity-gesture-performance-test")) { Self.bodyEvaluationCount += 1 }
        let options = data.options
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("A little rest adds up.").font(.system(size: 17, weight: .medium, design: .rounded))
                    Spacer()
                    ActivityScaleMenu(data: data).frame(width: 104, height: 24)
                    Button { showBreakFilter.toggle() } label: {
                        HStack {
                            Text(data.breakFilterLabel(options)).lineLimit(1).truncationMode(.tail).frame(minWidth: 75, maxWidth: 110)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .accessibilityLabel("Filter Activity by break")
                    .popover(isPresented: $showBreakFilter, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("All breaks", isOn: Binding(get: {
                                data.selectedBreaks == nil
                            }, set: { data.selectBreaks($0 ? nil : []) }))
                            Divider()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(options) { option in
                                        Toggle(option.name, isOn: Binding(get: {
                                            data.selectedBreaks?.contains(option.id) ?? true
                                        }, set: { enabled in
                                            var selection = data.selectedBreaks ?? Set(options.map(\.id))
                                            if enabled { selection.insert(option.id) } else { selection.remove(option.id) }
                                            data.selectBreaks(selection == Set(options.map(\.id)) ? nil : selection)
                                        }))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: min(280, CGFloat(options.count) * 26))
                        }.toggleStyle(.checkbox).padding(14).frame(width: 230).tint(teal)
                    }
                }
                ActivityMetrics(display: data.display)
                HStack {
                    ActivityLabel(display: data.display, field: \.range).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { data.pan(fraction: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).accessibilityLabel("Earlier time range")
                        .disabled(data.atStart)
                    Button { data.pan(fraction: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).accessibilityLabel("Later time range")
                        .disabled(data.atEnd)
                    Button("Today") { data.today() }.buttonStyle(.plain).foregroundStyle(teal)
                }.padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 9) {
                    Text("MINUTES OF REST").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    plot(.rest)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("BREAK ACTIVITY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        legend("Completed", teal); legend("Skipped", skipColor); legend("Postponed", postponeColor)
                    }
                    plot(.outcomes)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    ActivityLabel(display: data.display, field: \.selectionTitle).font(.system(size: 12, weight: .semibold))
                    ActivityLabel(display: data.display, field: \.selectionSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                Text("Option-scroll or pinch to zoom at the pointer. Scroll sideways, Shift-scroll, or drag to move through time. Click a bar for its totals.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if data.selectedBreaks != nil {
                    Text("Older activity without a break type is included only with All breaks.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !data.isDaily && data.hasUntimed {
                    Text("Some older activity has daily totals only. Its times are unavailable in hourly views.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("Rest time counts completed breaks. Skipped and postponed totals count your actions. Previews and idle time are excluded. History stays on this Mac without a time limit.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 4)
        }
        .onChange(of: currentDay) { _ in data.refreshViewport() }
        .onChange(of: history) { _ in data.update(history: history, currentBreaks: currentBreaks) }
        .onChange(of: currentBreaks) { _ in data.update(history: history, currentBreaks: currentBreaks) }
    }
    func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 9)).foregroundStyle(.secondary) }
    }
    func plot(_ kind: ActivityPlotKind) -> some View {
        ActivityPlot(kind: kind, stream: data.plots, zoom: { data.zoom(factor: $0, anchor: $1) }, pan: { data.pan(fraction: $0) }, select: { data.select(fraction: $0) }).frame(height: 100)
    }
}
