import SwiftUI
import Charts

struct BreakTimelineView: View {
    @ObservedObject var model: BreakModel
    @ViewState<TimelineViewport> private var viewport = TimelineViewport()
    @ViewState<UUID?> private var selectedID: UUID? = nil
    @ViewState<Date?> private var dragCenter: Date? = nil
    @ViewState<Double?> private var pinchSpan: Double? = nil
    init(model: BreakModel, initialSpan: Double = 86400, initialCenter: Date? = nil) {
        self.model = model
        var initial = TimelineViewport(span: initialSpan)
        if let initialCenter { initial.move(to: initialCenter) }
        _viewport = ViewState(wrappedValue: initial)
    }
    var rows: [String] { Array(Set(model.history.sessions.map(\.name))).sorted() }
    var visible: [BreakSession] {
        model.history.sessions.filter {
            $0.startedAt <= viewport.range.upperBound && displayEnd($0) >= viewport.range.lowerBound
        }
    }
    var selected: BreakSession? { visible.first(where: { $0.id == selectedID }) ?? visible.last }
    var zoomLabel: String {
        if viewport.span >= viewport.maximumSpan - 1 { return "30 days" }
        if viewport.span >= 86400 { return "\(Int((viewport.span / 86400).rounded())) \(viewport.span < 129600 ? "day" : "days")" }
        return "\(Int((viewport.span / 3600).rounded())) \(viewport.span < 5400 ? "hour" : "hours")"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("BREAK TIMELINE").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Button { zoom(viewport.span * 2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(viewport.span >= viewport.maximumSpan).help("Zoom out").accessibilityLabel("Zoom out")
                Menu(zoomLabel) {
                    Button("30 days") { zoom(viewport.maximumSpan) }
                    Button("7 days") { zoom(604800) }
                    Button("1 day") { zoom(86400) }
                    Button("6 hours") { zoom(21600) }
                    Button("1 hour") { zoom(3600) }
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Timeline zoom")
                Button { zoom(viewport.span / 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(viewport.span <= 3600).help("Zoom in").accessibilityLabel("Zoom in")
            }.buttonStyle(.plain)
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(viewport.range.lowerBound <= viewport.bounds.lowerBound).accessibilityLabel("Earlier timeline")
                Text(windowLabel).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(viewport.range.upperBound >= viewport.bounds.upperBound).accessibilityLabel("Later timeline")
                Spacer()
                Button("Today") { viewport.move(to: Date()); selectedID = nil }
            }.buttonStyle(.plain).foregroundStyle(teal)
            if model.history.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your next break starts this timeline.").font(.system(size: 13, weight: .medium))
                    Text("Exact times are recorded from this update onward. Earlier daily totals are preserved below.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            } else {
                chart
                if let event = selected {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(event.name) · \(event.outcome.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(color(event.outcome))
                            Text(exactTimes(event)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if event.outcome == .completed { Text("\(restLabel(event.rested)) of rest").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Button { select(-1) } label: { Image(systemName: "chevron.left") }.disabled(selected?.id == visible.first?.id).accessibilityLabel("Previous break")
                        Button { select(1) } label: { Image(systemName: "chevron.right") }.disabled(selected?.id == visible.last?.id).accessibilityLabel("Next break")
                    }.buttonStyle(.plain)
                } else {
                    Text("No recorded breaks in this time window.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Click a break for exact times. Drag to move through time; pinch or use the zoom controls.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .onChange(of: model.record.day) { _ in
                var updated = TimelineViewport(span: viewport.span)
                updated.move(to: viewport.center); viewport = updated
            }
    }
    var chart: some View {
        Chart {
            ForEach(visible) { event in
                let row = Double(rows.firstIndex(of: event.name) ?? 0)
                RectangleMark(xStart: .value("Start", max(event.startedAt, viewport.range.lowerBound)), xEnd: .value("End", min(displayEnd(event), viewport.range.upperBound)), yStart: .value("Row", row - 0.14), yEnd: .value("Row", row + 0.14))
                    .foregroundStyle(color(event.outcome).opacity(event.id == selected?.id ? 1 : 0.65)).cornerRadius(3)
                if event.startedAt >= viewport.range.lowerBound {
                PointMark(x: .value("Start", event.startedAt), y: .value("Break", row))
                    .symbolSize(event.id == selected?.id ? 55 : 28).foregroundStyle(color(event.outcome))
                    .accessibilityLabel("\(event.name), \(event.outcome.title)").accessibilityValue(exactTimes(event))
                }
            }
        }
        .chartXScale(domain: viewport.range)
        .chartYScale(domain: -0.5...Double(max(1, rows.count)) - 0.5)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(); AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(viewport.span <= 86400 ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: rows.indices.map { Double($0) }) { value in
                if let row = value.as(Double.self), rows.indices.contains(Int(row)) {
                    AxisValueLabel { Text(rows[Int(row)]).font(.system(size: 10)).lineLimit(1) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                        let width = geometry[proxy.plotAreaFrame].width
                        guard width > 0 else { return }
                        if dragCenter == nil { dragCenter = viewport.center }
                        viewport.move(to: dragCenter!.addingTimeInterval(-Double(value.translation.width / width) * viewport.span))
                    }.onEnded { _ in dragCenter = nil })
                    .simultaneousGesture(MagnificationGesture().onChanged { value in
                        if pinchSpan == nil { pinchSpan = viewport.span }
                        viewport.zoom(to: pinchSpan! / Double(value))
                    }.onEnded { _ in pinchSpan = nil })
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        let frame = geometry[proxy.plotAreaFrame]
                        let x = value.location.x - frame.minX
                        guard x >= 0, x <= frame.width, let date: Date = proxy.value(atX: x) else { return }
                        let y = value.location.y - frame.minY
                        guard y >= 0, y <= frame.height else { return }
                        let row: Double? = proxy.value(atY: y)
                        let name = row.flatMap { rows.indices.contains(Int($0.rounded())) ? rows[Int($0.rounded())] : nil }
                        selectedID = visible.filter { name == nil || $0.name == name }.min {
                            abs($0.startedAt.timeIntervalSince(date)) < abs($1.startedAt.timeIntervalSince(date))
                        }?.id
                    })
            }
        }
        .frame(height: CGFloat(max(2, rows.count)) * 32 + 28)
    }
    var windowLabel: String {
        let start = viewport.range.lowerBound, end = viewport.range.upperBound
        if viewport.span <= 86400 {
            return start.formatted(.dateTime.month(.abbreviated).day().hour().minute()) + " – " + end.formatted(Calendar.current.isDate(start, inSameDayAs: end) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
        }
        return start.formatted(date: .abbreviated, time: .omitted) + " – " + end.formatted(date: .abbreviated, time: .omitted)
    }
    func displayEnd(_ event: BreakSession) -> Date {
        max(event.startedAt, event.endedAt ?? (event.outcome == .inProgress ? Date() : event.startedAt))
    }
    func exactTimes(_ event: BreakSession) -> String {
        let start = event.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
        guard let end = event.endedAt else { return start + (event.outcome == .inProgress ? " → In progress" : " → End time unavailable") }
        let format: Date.FormatStyle = Calendar.current.isDate(event.startedAt, inSameDayAs: end) ? .dateTime.hour().minute().second() : .dateTime.month(.abbreviated).day().hour().minute().second()
        return start + " → " + end.formatted(format)
    }
    func color(_ outcome: BreakOutcome) -> Color {
        switch outcome {
        case .completed, .inProgress: return teal
        case .skipped: return Color(red: 0.70, green: 0.45, blue: 0.31)
        case .postponed: return Color(red: 0.55, green: 0.59, blue: 0.68)
        case .interrupted: return .secondary
        }
    }
    func zoom(_ seconds: Double) { viewport.zoom(to: seconds, around: selected?.startedAt) }
    func move(_ direction: Double) { viewport.move(to: viewport.center.addingTimeInterval(direction * viewport.span * 0.8)); selectedID = nil }
    func select(_ direction: Int) {
        guard let event = selected, let index = visible.firstIndex(where: { $0.id == event.id }), visible.indices.contains(index + direction) else { return }
        selectedID = visible[index + direction].id
    }
}
