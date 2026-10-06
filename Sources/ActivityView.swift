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

struct ActivityView: View {
    @ObservedObject var model: BreakModel
    @ViewState<Int> private var range = 30
    @ViewState<String?> private var selectedKey: String? = nil
    var days: [DayRecord] { model.history.days(count: range) }
    var total: DayRecord { ActivityHistory.total(days) }
    var selected: DayRecord { days.first(where: { $0.day == selectedKey }) ?? days.last! }
    var domain: ClosedRange<Date> { days.first!.date...Calendar.current.date(byAdding: .day, value: 1, to: days.last!.date)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("A little rest adds up.").font(.system(size: 17, weight: .medium, design: .rounded))
                    Spacer()
                    Picker("History range", selection: $range) {
                        Text("7 days").tag(7); Text("30 days").tag(30)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
                }
                HStack(spacing: 10) {
                    metric("Rest time", restLabel(total.rested), color: teal)
                    metric("Completed", String(total.completed), color: teal)
                    metric("Skipped", String(total.skipped), color: skipColor)
                    metric("Postponed", String(total.postponed), color: postponeColor)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("MINUTES OF REST").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Chart(days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.rested / 60))
                            .foregroundStyle(teal.opacity(day.day == selected.day ? 1 : 0.60))
                            .cornerRadius(2)
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(restLabel(day.rested)) of rest")
                    }
                    .chartXScale(domain: domain)
                    .chartYScale(domain: 0...max(1, (days.map { $0.rested / 60 }.max() ?? 0) * 1.15))
                    .chartXAxis { dateAxis }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartOverlay { proxy in selectionOverlay(proxy) }
                    .frame(height: 80)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("BREAK ACTIVITY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        legend("Completed", teal); legend("Skipped", skipColor); legend("Postponed", postponeColor)
                    }
                    Chart {
                        ForEach(days) { day in
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Breaks", day.completed))
                                .foregroundStyle(teal).position(by: .value("Outcome", "Completed"))
                                .accessibilityLabel("\(day.day), completed").accessibilityValue(String(day.completed))
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Breaks", day.skipped))
                                .foregroundStyle(skipColor).position(by: .value("Outcome", "Skipped"))
                                .accessibilityLabel("\(day.day), skipped").accessibilityValue(String(day.skipped))
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Breaks", day.postponed))
                                .foregroundStyle(postponeColor).position(by: .value("Outcome", "Postponed"))
                                .accessibilityLabel("\(day.day), postponed").accessibilityValue(String(day.postponed))
                        }
                    }
                    .chartXScale(domain: domain)
                    .chartYScale(domain: 0...max(1, Double(days.map { max($0.completed, $0.skipped, $0.postponed) }.max() ?? 0) * 1.15))
                    .chartXAxis { dateAxis }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        if let number = value.as(Double.self), number.rounded() == number { AxisGridLine(); AxisValueLabel() }
                    } }
                    .chartLegend(.hidden)
                    .chartOverlay { proxy in selectionOverlay(proxy) }
                    .frame(height: 80)
                }.padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.system(size: 12, weight: .semibold))
                        Text("\(restLabel(selected.rested)) rest · \(selected.completed) completed · \(selected.skipped) skipped · \(selected.postponed) postponed")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { moveSelection(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(selected.day == days.first!.day).accessibilityLabel("Previous day")
                    Button { moveSelection(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(selected.day == days.last!.day).accessibilityLabel("Next day")
                }.padding(.horizontal, 2)
                Text(total.outcomes == 0 ? "Your history starts here. Take a break to add your first entry." : "Select a day in either graph to see its totals.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Rest time counts completed breaks. Skipped and postponed totals count your actions. Previews and idle time are excluded. History stays on this Mac for 30 days.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 4)
        }
        .onChange(of: range) { _ in if !days.contains(where: { $0.day == selectedKey }) { selectedKey = nil } }
    }
    @AxisContentBuilder var dateAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
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
    func selectionOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let frame = geometry[proxy.plotAreaFrame]
                    let x = value.location.x - frame.minX
                    guard x >= 0, x <= frame.width, let date: Date = proxy.value(atX: x) else { return }
                    let key = HistoryDates.key(for: date)
                    if days.contains(where: { $0.day == key }) { selectedKey = key }
                })
        }
    }
    func moveSelection(_ step: Int) {
        guard let index = days.firstIndex(where: { $0.day == selected.day }) else { return }
        let next = index + step
        if days.indices.contains(next) { selectedKey = days[next].day }
    }
}
