import AppKit
import SwiftUI
import Combine

enum ActivityPlotKind: Equatable { case rest, outcomes }

@MainActor final class ActivityPlotStream {
    struct Snapshot {
        let buckets: [ActivityBucket]
        let range: ClosedRange<Date>
        let ticks: [Date]
        let restMaximum: Double
        let countMaximum: Double
        let selected: Date
        let daily: Bool
        let monthly: Bool
    }
    private(set) var latest: Snapshot?
    let changes = PassthroughSubject<Void, Never>()
    func update(_ snapshot: Snapshot) { latest = snapshot; changes.send() }
}

/// A persistent drawing surface avoids constructing a Charts layout for every
/// trackpad event. Input still uses the existing native gesture surface.
struct ActivityPlot: NSViewRepresentable {
    let kind: ActivityPlotKind
    let stream: ActivityPlotStream
    let zoom: (Double, Double) -> Void
    let pan: (Double) -> Void
    let select: (Double) -> Void
    func makeNSView(context: Context) -> ActivityPlotView { ActivityPlotView() }
    func updateNSView(_ view: ActivityPlotView, context: Context) {
        view.mouse.zoom = zoom; view.mouse.pan = pan; view.mouse.select = select
        view.bind(stream: stream, kind: kind)
    }
    static func dismantleNSView(_ view: ActivityPlotView, coordinator: ()) { view.disconnect() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActivityPlotView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: 100)
    }
}

private final class ActivityBarAccessibility: NSAccessibilityElement {
    var pressed: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { pressed?(); return true }
}

final class ActivityPlotView: NSView {
    let mouse = ActivityMouseSurface()
    private weak var stream: ActivityPlotStream?
    private var updates: AnyCancellable?
    private(set) var updateCount = 0
    private var requestedKind: ActivityPlotKind = .rest
    private var kind: ActivityPlotKind = .rest
    private var buckets: [ActivityBucket] = []
    private var range = Date.distantPast...Date.distantPast
    private var ticks: [Date] = []
    private var maximum: Double = 1
    private var selected = Date()
    private var daily = true, monthly = false
    private let grid = CAShapeLayer()
    private let bars = CALayer()
    private let ordinary = CAShapeLayer(), emphasized = CAShapeLayer(), skippedBars = CAShapeLayer(), postponedBars = CAShapeLayer()
    private var axisLayers: [CALayer] = []
    private var textures: [String: (CGImage, CGSize)] = [:]
    private var dateCache: [Date: (Int, String)] = [:]
    private var accessibleBars: [ActivityBarAccessibility]?
    private var lastBounds: CGRect?
    private var lastScale: CGFloat = 0
    private let green = NSColor(red: 0.17, green: 0.43, blue: 0.38, alpha: 1)
    private let skipped = NSColor(red: 0.70, green: 0.45, blue: 0.31, alpha: 1)
    private let postponed = NSColor(red: 0.55, green: 0.59, blue: 0.68, alpha: 1)
    override var isOpaque: Bool { false }
    var plotRect: CGRect { CGRect(x: 32, y: 22, width: max(1, bounds.width - 37), height: max(1, bounds.height - 29)) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer!.addSublayer(grid); layer!.addSublayer(bars)
        grid.fillColor = nil; grid.lineWidth = 0.5
        bars.masksToBounds = true
        for shape in [ordinary, emphasized, skippedBars, postponedBars] { bars.addSublayer(shape) }
        addSubview(mouse)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func bind(stream: ActivityPlotStream, kind: ActivityPlotKind) {
        requestedKind = kind
        if self.stream !== stream {
            self.stream = stream
            updates = stream.changes.sink { [weak self] in self?.refresh() }
        }
        refresh()
    }
    func disconnect() {
        updates = nil; stream = nil
        mouse.zoom = { _, _ in }; mouse.pan = { _ in }; mouse.select = { _ in }
    }
    private func refresh() {
        guard let snapshot = stream?.latest else { return }
        configure(kind: requestedKind, buckets: snapshot.buckets, range: snapshot.range, ticks: snapshot.ticks,
                  maximum: requestedKind == .rest ? snapshot.restMaximum : snapshot.countMaximum,
                  selected: snapshot.selected, daily: snapshot.daily, monthly: snapshot.monthly)
    }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard lastBounds != bounds || scale != lastScale else { return }
        lastBounds = bounds
        if scale != lastScale { textures.removeAll(keepingCapacity: true); lastScale = scale }
        mouse.frame = plotRect; accessibleBars = nil
        redrawLayers()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastBounds = nil; needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textures.removeAll(keepingCapacity: true)
        redrawLayers()
    }
    func configure(kind: ActivityPlotKind, buckets: [ActivityBucket], range: ClosedRange<Date>, ticks: [Date], maximum: Double, selected: Date, daily: Bool, monthly: Bool) {
        let same = self.range == range && self.kind == kind && self.maximum == maximum && self.selected == selected && self.daily == daily && self.monthly == monthly && self.ticks == ticks && self.buckets.elementsEqual(buckets, by: { $0.start == $1.start && $0.end == $1.end && $0.totals == $1.totals })
        guard !same else { return }
        updateCount += 1
        self.kind = kind; self.buckets = buckets; self.range = range; self.ticks = ticks
        self.maximum = maximum; self.selected = selected; self.daily = daily; self.monthly = monthly
        accessibleBars = nil
        let caption = kind == .rest ? "Minutes of rest chart" : "Break activity chart"
        if accessibilityLabel() != caption { setAccessibilityLabel(caption) }
        redrawLayers()
    }
    private func x(_ date: Date) -> CGFloat {
        plotRect.minX + date.timeIntervalSince(range.lowerBound) / max(1, range.upperBound.timeIntervalSince(range.lowerBound)) * plotRect.width
    }
    private func texture(_ text: String, scale: CGFloat) -> (CGImage, CGSize)? {
        if let cached = textures[text] { return cached }
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let measured = string.size()
        let width = max(1, Int(ceil(measured.width * scale))), height = max(1, Int(ceil(measured.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if textures.count > 128 { textures.removeAll(keepingCapacity: true) }
        let value = (image, CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        textures[text] = value
        return value
    }
    private func dateLabel(_ date: Date) -> String {
        let style = monthly ? 0 : daily ? 1 : range.upperBound.timeIntervalSince(range.lowerBound) > 2 * 3600 ? 2 : 3
        if let cached = dateCache[date], cached.0 == style { return cached.1 }
        let text: String
        if monthly { text = date.formatted(.dateTime.month(.abbreviated).year()) }
        else if daily { text = date.formatted(.dateTime.month(.abbreviated).day()) }
        else { text = date.formatted(style == 2 ? .dateTime.hour() : .dateTime.hour().minute()) }
        if dateCache.count > 256 { dateCache.removeAll(keepingCapacity: true) }
        dateCache[date] = (style, text)
        return text
    }
    private func redrawLayers() {
        guard bounds.width > 1, bounds.height > 1, range.upperBound > range.lowerBound else { return }
        let plot = plotRect, scale = window?.backingScaleFactor ?? 2
        let gridPath = CGMutablePath(), ordinaryPath = CGMutablePath(), emphasizedPath = CGMutablePath(), skipPath = CGMutablePath(), postponePath = CGMutablePath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grid.frame = plot; bars.frame = plot
        for shape in [ordinary, emphasized, skippedBars, postponedBars] { shape.frame = bars.bounds; shape.contentsScale = scale }
        grid.contentsScale = scale
        grid.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.32).cgColor
        ordinary.fillColor = green.withAlphaComponent(kind == .rest ? 0.6 : 1).cgColor
        emphasized.fillColor = green.cgColor; skippedBars.fillColor = skipped.cgColor; postponedBars.fillColor = postponed.cgColor
        var labelsUsed = 0
        func axis(_ image: CGImage, _ size: CGSize, _ point: CGPoint) {
            if labelsUsed == axisLayers.count {
                let label = CALayer(); label.anchorPoint = .zero; layer!.addSublayer(label); axisLayers.append(label)
            }
            let label = axisLayers[labelsUsed]; labelsUsed += 1
            label.isHidden = false; label.contentsScale = scale
            label.contents = image; label.bounds = CGRect(origin: .zero, size: size)
            label.position = CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
        }
        func align(_ value: CGFloat) -> CGFloat { (floor(value * scale) + 0.5) / scale }
        let rawStep = max(1e-9, maximum / 3), magnitude = pow(10, floor(log10(max(1e-9, maximum / 3))))
        let step = max(kind == .outcomes ? 1 : 0, ([1.0, 2, 5, 10].first { $0 * magnitude >= rawStep } ?? 10) * magnitude)
        var value = 0.0
        while value <= maximum + 1e-8 {
            let y = align(value / maximum * plot.height)
            gridPath.move(to: CGPoint(x: 0, y: y)); gridPath.addLine(to: CGPoint(x: plot.width, y: y))
            let text = abs(value.rounded() - value) < 1e-8 ? String(Int(value.rounded())) : String(format: "%.1f", value)
            if let (image, size) = texture(text, scale: scale) { axis(image, size, CGPoint(x: plot.minX - size.width - 5, y: plot.minY + y - size.height / 2)) }
            value += step
        }
        for date in (daily ? (kind == .outcomes ? buckets.map(\.start) : []) : ticks) where date >= range.lowerBound && date < range.upperBound {
            let position = align(x(date) - plot.minX)
            gridPath.move(to: CGPoint(x: position, y: 0)); gridPath.addLine(to: CGPoint(x: position, y: plot.height))
        }
        func bar(_ bucket: ActivityBucket, _ start: Double, _ end: Double, _ amount: Double, _ path: CGMutablePath, rounded: Bool = false) {
            guard amount > 0 else { return }
            let duration = bucket.end.timeIntervalSince(bucket.start)
            let left = x(bucket.start.addingTimeInterval(duration * start)) - plot.minX
            let right = x(bucket.start.addingTimeInterval(duration * end)) - plot.minX
            let height = amount / maximum * plot.height
            let rect = CGRect(x: left, y: 0, width: max(0, right - left), height: height)
            if rounded { path.addRoundedRect(in: rect, cornerWidth: min(2, rect.width / 2), cornerHeight: min(2, height / 2)) }
            else { path.addRect(rect) }
        }
        for bucket in buckets {
            if kind == .rest { bar(bucket, 0.12, 0.88, bucket.totals.rested / 60, bucket.start == selected ? emphasizedPath : ordinaryPath, rounded: true) }
            else {
                bar(bucket, daily ? 0.18 : 0.12, daily ? 0.38 : 0.34, Double(bucket.totals.completed), ordinaryPath)
                bar(bucket, daily ? 0.40 : 0.39, daily ? 0.60 : 0.61, Double(bucket.totals.skipped), skipPath)
                bar(bucket, daily ? 0.62 : 0.66, daily ? 0.82 : 0.88, Double(bucket.totals.postponed), postponePath)
            }
        }
        grid.path = gridPath; ordinary.path = ordinaryPath; emphasized.path = emphasizedPath; skippedBars.path = skipPath; postponedBars.path = postponePath
        var lastRight = -CGFloat.infinity
        for date in ticks {
            guard let (image, size) = texture(dateLabel(date), scale: scale) else { continue }
            let left = max(0, min(bounds.width - size.width, x(date) - size.width / 2))
            if left >= lastRight + 6 { axis(image, size, CGPoint(x: left, y: plot.minY - size.height - 5)); lastRight = left + size.width }
        }
        for index in labelsUsed..<axisLayers.count { axisLayers[index].isHidden = true }
        CATransaction.commit()
    }
    override func accessibilityChildren() -> [Any]? {
        if let accessibleBars { return accessibleBars }
        let span = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
        let children = buckets.map { bucket in
            let element = ActivityBarAccessibility()
            element.setAccessibilityRole(.button); element.setAccessibilityParent(self)
            element.setAccessibilityLabel(bucket.start.formatted(date: .abbreviated, time: daily ? .omitted : .shortened))
            element.setAccessibilityValue(kind == .rest ? "\(restLabel(bucket.totals.rested)) of rest" : "\(bucket.totals.completed) completed, \(bucket.totals.skipped) skipped, \(bucket.totals.postponed) postponed")
            element.setAccessibilityFrameInParentSpace(CGRect(x: x(bucket.start), y: plotRect.minY, width: max(1, x(bucket.end) - x(bucket.start)), height: plotRect.height).intersection(plotRect))
            let fraction = max(0, min(1, bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2).timeIntervalSince(range.lowerBound) / span))
            element.pressed = { [weak self] in self?.mouse.select(fraction) }
            return element
        }
        accessibleBars = children
        return children
    }
}

@MainActor func activityPlots(in view: NSView) -> [ActivityPlotView] {
    (view as? ActivityPlotView).map { [$0] } ?? view.subviews.flatMap { activityPlots(in: $0) }
}
