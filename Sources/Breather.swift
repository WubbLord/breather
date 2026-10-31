import AppKit
import QuartzCore
import SwiftUI
import IOKit
import ServiceManagement
import Darwin

typealias ViewState<Value> = SwiftUI.State<Value>

let teal = Color(red: 0.17, green: 0.43, blue: 0.38)
let paper = Color(red: 0.97, green: 0.965, blue: 0.95)
let uiTestArguments = ["--ui-smoke-test", "--break-actions-test", "--priority-ui-test", "--performance-test", "--activity-appearance-test", "--page-tabs-test", "--page-tabs-labels-test", "--green-switches-test", "--status-menu-test", "--background-startup-test", "--sleep-countdown-test", "--overlay-layering-test", "--idle-reset-test", "--countdown-pause-test", "--activity-labels-test", "--activity-filter-test", "--break-pause-test"]
// Keep saved data at the original location even when the application's menu bar
// identity changes. Existing schedules, activity, and preferences stay intact.
let breatherDataDomain = "local.breather.app"
let breatherApplicationIdentifiers = ["local.breather.desktop", "local.breather.app"]

@MainActor final class BreakModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
            scheduler.synchronize(preferences.plans)
            for plan in preferences.plans {
                if let previous = oldValue.plans.first(where: { $0.id == plan.id }), previous.interval != plan.interval {
                    scheduler.remaining[plan.id] = plan.interval
                    scheduler.waitingFor[plan.id] = nil
                }
            }
            saveSchedule()
            onPreferencesChanged?()
        }
    }
    @Published var scheduler = Scheduler()
    @Published var active: BreakPlan?
    @Published var secondsLeft: Double = 0
    @Published var phase = ""
    @Published var record = DayRecord()
    @Published var history = ActivityHistory()
    @Published var idle = false
    @Published var sleeping = false
    @Published var pauseUntil: Date?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onTick: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var timingActivity: NSObjectProtocol?
    private var idleRestTracker = IdleRestTracker()
    private var deferredIdleRest: [UUID: Double] = [:]
    private var sleepStartedAt: Date?
    private var sleepStartedUptime: Double?
    private var sleepReasons: Set<String> = []
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var breakTiming = BreakTiming(duration: 0, fade: 0)
    private var arrivalStarted: Double = 0
    private var preview = false
    private var activeSessionID: UUID?
    private var lastScheduleSave = ProcessInfo.processInfo.systemUptime

    init(testing: Bool = false, resetTestPreferences: Bool = true) {
        defaults = UserDefaults(suiteName: testing ? "local.breather.smoke" : breatherDataDomain)!
        if testing && resetTestPreferences { defaults.removePersistentDomain(forName: "local.breather.smoke") }
        var loadedPreferences = defaults.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        loadedPreferences.migratePriorityOrder()
        preferences = loadedPreferences
        // Save default plan IDs as well, so an untouched schedule can be matched on relaunch.
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
        if let data = defaults.data(forKey: "history.v1"), let value = try? JSONDecoder().decode(ActivityHistory.self, from: data) { history = value }
        history.recoverInterruptedSessions()
        let legacy = defaults.data(forKey: "daily.v1").flatMap { try? JSONDecoder().decode(DayRecord.self, from: $0) }
        history.migrate(legacy)
        record = history.records.first(where: { $0.day == HistoryDates.key(for: Date()) }) ?? DayRecord(day: HistoryDates.key(for: Date()))
        scheduler.reset(preferences.plans)
        if let data = defaults.data(forKey: "schedule.v1"), let saved = try? JSONDecoder().decode(SavedSchedule.self, from: data) {
            pauseUntil = scheduler.restore(saved, plans: preferences.plans)
        }
        saveRecord()
        saveSchedule()
    }
    var nextPlan: BreakPlan? { scheduler.next(preferences.plans) }
    var allEnabledBreaksPaused: Bool {
        let enabled = preferences.plans.filter(\.enabled)
        return !enabled.isEmpty && enabled.allSatisfy { scheduler.isBreakPaused($0.id) }
    }
    func waitingName(for plan: BreakPlan) -> String? {
        guard let blockerID = scheduler.waitingFor[plan.id] else { return nil }
        return preferences.plans.first(where: { $0.id == blockerID })?.name
    }
    func moveBreak(_ id: UUID, to target: UUID) {
        guard let source = preferences.plans.firstIndex(where: { $0.id == id }),
              let destination = preferences.plans.firstIndex(where: { $0.id == target }), source != destination else { return }
        var ordered = preferences.plans
        let moved = ordered.remove(at: source)
        ordered.insert(moved, at: destination)
        preferences.plans = ordered
    }
    var controlPlan: BreakPlan? {
        guard let active else { return nextPlan }
        return preferences.plans.first(where: { $0.id == active.id }) ?? active
    }
    var canSkip: Bool { preview || (controlPlan?.allowSkipping ?? false) }
    var canPostpone: Bool { phase != "Returning" && (preview || (controlPlan?.allowPostponing ?? false)) }
    var canPause: Bool { active == nil || canSkip }
    var visualTiming: BreakTiming { breakTiming }
    var breakStartUptime: Double { arrivalStarted }
    var fadeOutSeconds: Double { active != nil && phase == "Returning" ? min(breakTiming.fade, secondsLeft) : preferences.fadeSeconds }
    var nextSeconds: Double { nextPlan.map { scheduler.remaining[$0.id, default: $0.interval] } ?? 0 }
    var idleCountdownText: String? {
        guard idle, preferences.idleMode != .ignore, !scheduler.paused, !sleeping, active == nil, available, nextPlan != nil else { return nil }
        return preferences.idleMode == .pause ? "Idle — countdown paused" : "Idle — time away"
    }
    var available: Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        if preferences.weekdaysOnly && (weekday == 1 || weekday == 7) { return false }
        guard preferences.workHoursOnly else { return true }
        let hour = calendar.component(.hour, from: Date())
        if preferences.startHour < preferences.endHour { return hour >= preferences.startHour && hour < preferences.endHour }
        return hour >= preferences.startHour || hour < preferences.endHour
    }
    var stateText: String {
        if scheduler.paused { return pauseUntil.map { "Paused until " + $0.formatted(date: .omitted, time: .shortened) } ?? "Paused" }
        if allEnabledBreaksPaused { return "All breaks paused" }
        if sleeping { return "Taking time away" }
        if !available { return "Outside your break hours" }
        if let idleCountdownText { return idleCountdownText }
        return "A little space in your day"
    }
    func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        updateTimingActivity()
    }
    func updateTimingActivity() {
        let needed = timer != nil && !sleeping && (active != nil || (!scheduler.paused && preferences.plans.contains { $0.enabled && !scheduler.isBreakPaused($0.id) }))
        if needed && timingActivity == nil {
            timingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Deliver scheduled Breather breaks")
        } else if !needed, let activity = timingActivity {
            ProcessInfo.processInfo.endActivity(activity); timingActivity = nil
        }
    }
    func stopTimer() {
        timer?.invalidate(); timer = nil; updateTimingActivity()
    }
    func refreshDay() {
        let day = HistoryDates.key(for: Date())
        if record.day != day {
            history.update(record)
            record = history.records.first(where: { $0.day == day }) ?? DayRecord(day: day)
            saveRecord()
        }
    }
    func saveRecord() {
        history.update(record)
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history.v1") }
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: "daily.v1") }
    }
    func saveSchedule() {
        updateTimingActivity()
        let elapsed = active != nil && !preview ? (sleepStartedUptime ?? ProcessInfo.processInfo.systemUptime) - arrivalStarted : 0
        let saved = scheduler.savedSchedule(plans: preferences.plans, pauseUntil: pauseUntil, activeElapsed: elapsed)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "schedule.v1") }
        lastScheduleSave = ProcessInfo.processInfo.systemUptime
    }
    func tick(idleSeconds suppliedIdle: Double? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let wallTime = Date()
        let dt = now - lastTick; lastTick = now
        let previousBreakPauses = scheduler.breakPauses
        defer { if previousBreakPauses != scheduler.breakPauses || now - lastScheduleSave >= 15 { saveSchedule() } }
        refreshDay()
        if let until = pauseUntil, wallTime >= until { resume() }
        if sleeping || active != nil { scheduler.expireBreakPauses(now: wallTime) }
        guard !sleeping else { onTick?(); return }
        let idleSeconds = suppliedIdle ?? Self.systemIdleSeconds()
        if let rested = idleRestTracker.returnedAfterIdle(seconds: idleSeconds, preferences: preferences) {
            let futurePlans = preferences.plans.filter { $0.id != scheduler.activeID }
            if active != nil {
                for plan in futurePlans where rested >= plan.duration {
                    deferredIdleRest[plan.id] = max(deferredIdleRest[plan.id, default: 0], rested)
                }
            } else {
                scheduler.resetAfterRest(seconds: rested, plans: futurePlans)
                saveSchedule()
            }
        }
        if let plan = active {
            let elapsed = now - arrivalStarted
            secondsLeft = breakTiming.remaining(after: elapsed)
            switch breakTiming.phase(after: elapsed) {
            case .arriving: phase = "Arriving"
            case .resting: phase = "Resting"
            case .returning:
                if phase != "Returning" { phase = "Returning"; onEnd?() }
            case .finished:
                // Also remove the cover if a delayed callback missed the fade-out.
                if phase != "Returning" { phase = "Returning"; onEnd?() }
                if !preview { recordCompletion(plan) }
                if preferences.sound { NSSound(named: "Glass")?.play() }
                finish(plan)
            }
        } else {
            let isIdle = preferences.idleMode != .ignore && idleSeconds >= preferences.idleThreshold
            if idle != isIdle { idle = isIdle }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let excluded = preferences.skipMeetingApps && ["us.zoom.xos", "com.apple.FaceTime"].contains(front)
            if let plan = scheduler.tick(seconds: dt, idle: idleSeconds, preferences: preferences, excluded: excluded, available: available, now: wallTime) { begin(plan) }
        }
        onTick?()
    }
    static func systemIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000
    }
    func begin(_ plan: BreakPlan, preview: Bool = false) {
        guard active == nil, !sleeping else { return }
        self.preview = preview
        if !preview { scheduler.waitingFor[plan.id] = nil }
        active = plan; scheduler.activeID = plan.id
        breakTiming = BreakTiming(duration: plan.duration, fade: preferences.fadeSeconds)
        phase = "Arriving"; arrivalStarted = ProcessInfo.processInfo.systemUptime
        secondsLeft = plan.duration
        if !preview {
            activeSessionID = history.startSession(planID: plan.id, name: plan.name, duration: plan.duration)
            saveRecord()
        }
        if preferences.sound { NSSound(named: "Glass")?.play() }
        onStart?()
        saveSchedule()
    }
    func previewBreak() {
        let plan = BreakPlan(name: "Preview", interval: 1200, duration: 10)
        begin(plan, preview: true)
    }
    func finish(_ plan: BreakPlan, elapsed: Double? = nil) {
        if preview { scheduler.activeID = nil } else {
            scheduler.finish(controlPlan ?? plan, plans: preferences.plans, elapsed: elapsed ?? (ProcessInfo.processInfo.systemUptime - arrivalStarted))
        }
        active = nil; phase = ""; preview = false
        resumeOtherCountdowns()
        saveSchedule()
    }
    func resumeOtherCountdowns() {
        // Exclude the final fraction of break time from the next scheduler tick.
        lastTick = ProcessInfo.processInfo.systemUptime
        for plan in preferences.plans {
            if let rested = deferredIdleRest[plan.id] {
                scheduler.resetAfterRest(seconds: rested, plans: [plan])
            }
        }
        deferredIdleRest = [:]
    }
    func recordCompletion(_ plan: BreakPlan, at date: Date = Date()) {
        refreshDay()
        let day = HistoryDates.key(for: date)
        if day == record.day {
            record.completed += 1; record.rested += plan.duration
        } else {
            var completedDay = history.records.first(where: { $0.day == day }) ?? DayRecord(day: day)
            completedDay.completed += 1; completedDay.rested += plan.duration
            history.update(completedDay)
        }
        endSession(.completed, rested: plan.duration, at: date)
        saveRecord()
    }
    func endSession(_ outcome: BreakOutcome, rested: Double = 0, at date: Date = Date()) {
        guard let id = activeSessionID else { return }
        history.endSession(id, outcome: outcome, at: date, rested: rested); activeSessionID = nil
    }
    func interruptSession() { endSession(.interrupted); saveRecord() }
    func dismiss(postpone: Double? = nil) {
        guard let plan = active else { return }
        guard postpone == nil ? canSkip : canPostpone else { return }
        refreshDay()
        if !preview {
            if let minutes = postpone { scheduler.postpone(plan, minutes: minutes); record.postponed += 1 }
            else { scheduler.skip(plan); record.skipped += 1 }
            endSession(postpone == nil ? .skipped : .postponed)
            saveRecord()
        }
        scheduler.activeID = nil; active = nil; phase = ""; preview = false
        resumeOtherCountdowns()
        onDismiss?()
        saveSchedule()
    }
    func deferNext(_ minutes: Double) {
        guard canPostpone else { return }
        if active != nil { dismiss(postpone: minutes); return }
        guard let next = nextPlan else { return }
        refreshDay()
        scheduler.postpone(next, minutes: minutes); record.postponed += 1
        history.recordAction(.postponed, planID: next.id, name: next.name); saveRecord()
        saveSchedule()
    }
    func skipNext() {
        guard canSkip else { return }
        if active != nil { dismiss(); return }
        guard let next = nextPlan else { return }
        refreshDay()
        scheduler.skip(next); record.skipped += 1
        history.recordAction(.skipped, planID: next.id, name: next.name); saveRecord()
        saveSchedule()
    }
    func pause(minutes: Double? = nil) {
        guard canPause else { return }
        if active != nil { dismiss() }
        scheduler.paused = true; pauseUntil = minutes.map { Date().addingTimeInterval($0 * 60) }; onTick?()
        saveSchedule()
    }
    func resume() { scheduler.paused = false; pauseUntil = nil; lastTick = ProcessInfo.processInfo.systemUptime; saveSchedule(); onTick?() }
    func pauseBreak(_ plan: BreakPlan, minutes: Double? = nil) {
        guard active?.id != plan.id, preferences.plans.contains(where: { $0.id == plan.id }) else { return }
        if let minutes, !minutes.isFinite || minutes <= 0 { return }
        scheduler.pauseBreak(plan.id, until: minutes.map { Date().addingTimeInterval($0 * 60) })
        saveSchedule(); onTick?()
    }
    func resumeBreak(_ plan: BreakPlan) {
        scheduler.resumeBreak(plan.id)
        saveSchedule(); onTick?()
    }
    func reset(preservingDisabled: Bool = false) { scheduler.reset(preferences.plans, preservingDisabled: preservingDisabled); saveSchedule(); onTick?() }
    func cancelActiveBreak() {
        if active != nil { interruptSession(); scheduler.activeID = nil; active = nil; phase = ""; preview = false; onEnd?(); resumeOtherCountdowns() }
        saveSchedule()
    }
    func sleep(reason: String = "system", now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        sleepReasons.insert(reason)
        guard !sleeping else { return }
        idleRestTracker.reset()
        sleeping = true; sleepStartedAt = now; sleepStartedUptime = uptime; lastTick = uptime
        if active != nil {
            secondsLeft = breakTiming.remaining(after: uptime - arrivalStarted)
            onDismiss?()
        }
        saveSchedule(); onTick?()
    }
    func wake(reason: String = "system", now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime, rawIdle: Double? = nil) {
        sleepReasons.remove(reason)
        guard sleeping, sleepReasons.isEmpty else { return }
        let idleSeconds = rawIdle ?? Self.systemIdleSeconds()
        let slept = sleepStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let completedAt = sleepStartedAt?.addingTimeInterval(secondsLeft)
        let finishedDuringSleep = active != nil && slept >= secondsLeft
        if active != nil, let started = sleepStartedUptime {
            // Rebase the animation clock to include resting time asleep, whether
            // system uptime itself advanced during sleep or stopped entirely.
            arrivalStarted += max(0, uptime - started) - min(slept, secondsLeft)
            let elapsed = uptime - arrivalStarted
            secondsLeft = breakTiming.remaining(after: elapsed)
            switch breakTiming.phase(after: elapsed) {
            case .arriving: phase = "Arriving"
            case .resting: phase = "Resting"
            case .returning, .finished: phase = "Returning"
            }
        }
        sleepStartedAt = nil; sleepStartedUptime = nil; sleeping = false
        scheduler.expireBreakPauses(now: now)
        if finishedDuringSleep, let plan = active, let completedAt {
            if !preview { recordCompletion(plan, at: completedAt) }
            secondsLeft = 0
            // Finishing the remaining rest starts a full new countdown for this
            // break. Inactive breaks below still need their entire rest duration.
            finish(plan, elapsed: 0)
        }
        scheduler.resetAfterRest(seconds: slept, plans: preferences.plans)
        idle = preferences.idleMode != .ignore && idleSeconds >= preferences.idleThreshold
        lastTick = uptime
        saveSchedule(); onTick?()
        if active != nil {
            onStart?()
            if phase == "Returning" { onEnd?() }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { error = "Allow Breather in System Settings → General → Login Items." }
        } catch { self.error = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

struct Mark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(teal.opacity(0.10))
            Image(systemName: "leaf").font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(teal)
        }.frame(width: size, height: size)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.045)))
    }
}

struct Dashboard: View {
    @ObservedObject var model: BreakModel
    @ViewState<Bool> private var activity: Bool
    @ViewState<Bool> private var showSettings = false
    @ViewState<BreakPlan?> private var editPlan: BreakPlan?
    @ViewState<Bool> private var adding = false
    @ViewState private var prioritySource: UUID?
    @ViewState private var priorityTarget: UUID?
    init(model: BreakModel, activity: Bool = false) {
        self.model = model
        _activity = ViewState(initialValue: activity)
    }
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Mark()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Breather").font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text(model.stateText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 32, height: 32) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            PageTabs(activity: $activity).frame(width: 190, height: 28)
            if activity {
                ActivityView(model: model).equatable().frame(height: 522)
            } else {
            Card {
                HStack(spacing: 24) {
                    ZStack {
                        Circle().stroke(teal.opacity(0.09), lineWidth: 6)
                        Circle().trim(from: 0, to: progress).stroke(teal, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: model.scheduler.paused ? "pause" : model.idleCountdownText != nil ? "moon.zzz" : "leaf").font(.system(size: 26, weight: .light)).foregroundStyle(teal)
                    }.frame(width: 86, height: 86)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.scheduler.paused ? "TAKE YOUR TIME" : "YOUR NEXT BREATHER").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                        Text(model.allEnabledBreaksPaused ? "Paused" : model.nextPlan == nil ? "All quiet" : clockText(model.nextSeconds)).font(.system(size: 43, weight: .light, design: .rounded)).monospacedDigit()
                        Text(model.nextPlan.map { "\($0.name) · \(durationLabel($0.duration)) of rest" } ?? (model.allEnabledBreaksPaused ? "Resume a break below to continue" : "Enable a break to begin")).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let idleText = model.idleCountdownText {
                            Label(idleText, systemImage: "pause.circle")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(teal)
                                .help("Move the mouse or use the keyboard to resume your countdowns.")
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Button("Take a break") { if let plan = model.nextPlan { model.begin(plan) } }.buttonStyle(.borderedProminent).tint(teal).disabled(model.nextPlan == nil || model.active != nil)
                    if model.scheduler.paused {
                        Button("Resume") { model.resume() }.buttonStyle(.bordered)
                    } else {
                        Menu("Pause") {
                            Button("15 minutes") { model.pause(minutes: 15) }
                            Button("30 minutes") { model.pause(minutes: 30) }
                            Button("1 hour") { model.pause(minutes: 60) }
                            Button("1 day") { model.pause(minutes: 1440) }
                            Button("Until I resume") { model.pause() }
                        }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10)
                    }
                    Spacer()
                    Button("Preview") { model.previewBreak() }.buttonStyle(.plain).foregroundStyle(teal).disabled(model.active != nil)
                }.padding(.top, 18)
            }
            VStack(spacing: 12) {
                HStack {
                    Text("YOUR RHYTHM").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                    Text("Drag to reorder · Highest first").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 13)) }.buttonStyle(.plain).help("Add a break").accessibilityLabel("Add a break")
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.preferences.plans) { plan in
                            HStack(spacing: 14) {
                                PriorityDragGrip(id: plan.id, title: plan.name, changed: { target in
                                    prioritySource = plan.id; priorityTarget = target
                                }, ended: { target in
                                    if let target { model.moveBreak(plan.id, to: target) }
                                    prioritySource = nil; priorityTarget = nil
                                }).frame(width: 28, height: 36)
                                Image(systemName: plan.duration >= 60 ? "figure.walk" : "eye").font(.system(size: 18, weight: .light)).foregroundStyle(teal).frame(width: 28)
                                Button { editPlan = plan } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(plan.name).font(.system(size: 14, weight: .medium))
                                        Text("\(durationLabel(plan.duration)) every \(durationLabel(plan.interval))").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Edit \(plan.name)")
                                HStack(spacing: 8) {
                                    if model.scheduler.isBreakPaused(plan.id) {
                                        Button("Resume") { model.resumeBreak(plan) }
                                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(teal)
                                            .accessibilityLabel("Resume \(plan.name)")
                                    } else {
                                        Menu("Pause") {
                                            Button("15 minutes") { model.pauseBreak(plan, minutes: 15) }
                                            Button("30 minutes") { model.pauseBreak(plan, minutes: 30) }
                                            Button("1 hour") { model.pauseBreak(plan, minutes: 60) }
                                            Button("1 day") { model.pauseBreak(plan, minutes: 1440) }
                                            Button("Until I resume") { model.pauseBreak(plan) }
                                        }.menuStyle(.borderlessButton).font(.system(size: 11)).foregroundStyle(teal).fixedSize()
                                            .disabled(model.active?.id == plan.id)
                                            .accessibilityLabel("Pause \(plan.name)")
                                    }
                                    Button("Take now") { model.begin(plan) }
                                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                                        .disabled(model.active != nil || model.sleeping)
                                        .help("Start \(plan.name) now").accessibilityLabel("Take \(plan.name) now")
                                }.fixedSize()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(plan.enabled ? clockText(model.scheduler.remaining[plan.id, default: plan.interval]) : "Off").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    if let pause = model.scheduler.breakPauses[plan.id] {
                                        Text(pause.until.map { "Paused until " + $0.formatted(date: .omitted, time: .shortened) } ?? "Paused")
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(teal).lineLimit(1)
                                    } else if plan.enabled, let name = model.waitingName(for: plan) {
                                        Text("Waiting for \(name)").font(.system(size: 10, weight: .medium)).foregroundStyle(teal).lineLimit(1)
                                    } else if plan.enabled && model.idleCountdownText != nil { Text("Idle").font(.system(size: 10, weight: .medium)).foregroundStyle(teal) }
                                }.frame(width: 104, alignment: .trailing)
                                BreakEnabledSwitch(title: "Enable \(plan.name)", isOn: Binding(get: { model.preferences.plans.first(where: { $0.id == plan.id })?.enabled ?? false }, set: { value in
                                    if let index = model.preferences.plans.firstIndex(where: { $0.id == plan.id }) { model.preferences.plans[index].enabled = value }
                                })).fixedSize()
                            }.padding(17).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                                .opacity(prioritySource == plan.id ? 0.18 : 1)
                                .background(PriorityRowBounds(id: plan.id))
                                .overlay {
                                    if prioritySource == plan.id {
                                        RoundedRectangle(cornerRadius: 14).strokeBorder(teal.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false)
                                    }
                                }
                                .overlay(alignment: priorityDropBelow(plan.id) ? .bottom : .top) {
                                    if priorityTarget == plan.id {
                                        Capsule().fill(teal).frame(height: 2).offset(y: priorityDropBelow(plan.id) ? 5 : -5).allowsHitTesting(false)
                                    }
                                }
                                .contextMenu {
                                    if let index = model.preferences.plans.firstIndex(where: { $0.id == plan.id }) {
                                        Button("Move up in priority") { model.moveBreak(plan.id, to: model.preferences.plans[index - 1].id) }.disabled(index == 0)
                                        Button("Move down in priority") { model.moveBreak(plan.id, to: model.preferences.plans[index + 1].id) }.disabled(index == model.preferences.plans.count - 1)
                                    }
                                }
                        }
                    }.padding(.vertical, 6)
                }.frame(height: 170)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.record.completed) breathers today").font(.system(size: 12, weight: .medium))
                    Text("\(durationLabel(model.record.rested)) made for yourself").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Small pauses.\nA better pace.").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            }
        }.padding(30).frame(width: 680, height: 718, alignment: .top).background(paper).tint(teal).foregroundStyle(Color(red: 0.17, green: 0.22, blue: 0.20))
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(item: $editPlan) { plan in PlanEditor(model: model, original: plan) }
            .sheet(isPresented: $adding) { PlanEditor(model: model, original: nil) }
    }
    private func priorityDropBelow(_ id: UUID) -> Bool {
        guard let source = prioritySource,
              let from = model.preferences.plans.firstIndex(where: { $0.id == source }),
              let to = model.preferences.plans.firstIndex(where: { $0.id == id }) else { return false }
        return to > from
    }
    var progress: Double { guard let plan = model.nextPlan else { return 0 }; return max(0.02, min(1, 1 - model.nextSeconds / plan.interval)) }
}

func durationLabel(_ seconds: Double) -> String {
    if seconds == 0 { return "0 minutes" }
    if seconds < 60 { return "\(Int(seconds)) seconds" }
    if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) \(seconds == 3600 ? "hour" : "hours")" }
    let minutes = seconds / 60
    return "\(minutes == minutes.rounded() ? String(Int(minutes)) : String(format: "%.1f", minutes)) \(minutes == 1 ? "minute" : "minutes")"
}

struct SettingsView: View {
    @ObservedObject var model: BreakModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Make room for rest").font(.system(size: 23, weight: .medium, design: .rounded)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Form {
                Section("Menu bar") {
                    Toggle("Show countdown in menu bar", isOn: $model.preferences.menuBarCountdownVisible)
                }
                Section("Time away") {
                    Picker("When you’re idle", selection: $model.preferences.idleMode) { ForEach(IdleMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Stepper("Notice idle time after \(Int(model.preferences.idleThreshold)) seconds", value: $model.preferences.idleThreshold, in: 15...300, step: 15)
                    Text("Countdowns pause after this threshold. Credit begins after twice as long, gradually restoring a full work interval.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Skip breaks when Zoom or FaceTime is frontmost", isOn: $model.preferences.skipMeetingApps)
                }
                Section("Break screen") {
                    HStack { Text("Fade in and out"); Spacer(); Text("\(Int(model.preferences.fadeSeconds)) seconds").foregroundStyle(.secondary); Stepper("Fade seconds", value: $model.preferences.fadeSeconds, in: 0...10).labelsHidden() }
                    HStack { Text("Background opacity"); Slider(value: $model.preferences.dimOpacity, in: 0.5...1); Text("\(Int(model.preferences.dimOpacity * 100))%").monospacedDigit().frame(width: 40) }
                    Toggle("Play a gentle sound at the start and end", isOn: $model.preferences.sound)
                    HStack {
                        Text("Postpone buttons")
                        Spacer()
                        Picker("First", selection: $model.preferences.postpone1) { ForEach([1.0, 2, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) min").tag($0) } }.labelsHidden().frame(width: 85)
                        Picker("Second", selection: $model.preferences.postpone2) { ForEach([1.0, 2, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) min").tag($0) } }.labelsHidden().frame(width: 85)
                    }
                }
                Section("Availability") {
                    Toggle("Weekdays only", isOn: $model.preferences.weekdaysOnly)
                    Toggle("Only during work hours", isOn: $model.preferences.workHoursOnly)
                    if model.preferences.workHoursOnly {
                        HStack {
                            Picker("From", selection: $model.preferences.startHour) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                            Picker("Until", selection: $model.preferences.endHour) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        }
                    }
                    Toggle("Open Breather at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                }
            }.formStyle(.grouped)
            HStack {
                Button("Reset countdowns") { model.reset() }
                Spacer()
                Text("Saved automatically · Stored on your Mac").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 590, height: 660).background(paper).tint(teal)
    }
}

struct PlanEditor: View {
    @ObservedObject var model: BreakModel
    var original: BreakPlan?
    @Environment(\.dismiss) var dismiss
    @ViewState<String> private var name = ""
    @ViewState<Double> private var interval = 20.0
    @ViewState<Double> private var duration = 20.0
    @ViewState<Double> private var unit = 1.0
    @ViewState<Bool> private var confirmDelete = false
    @ViewState<Bool> private var allowSkipping = true
    @ViewState<Bool> private var allowPostponing = true
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(original == nil ? "A new kind of pause" : "Your \(original!.name.lowercased()) break").font(.system(size: 23, weight: .medium, design: .rounded))
            Form {
                TextField("Name", text: $name)
                HStack { Text("Every"); TextField("Minutes", value: $interval, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 75); Text("minutes").foregroundStyle(.secondary) }
                HStack { Text("Rest for"); TextField("Duration", value: $duration, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 75); Picker("Unit", selection: $unit) { Text("seconds").tag(1.0); Text("minutes").tag(60.0) }.labelsHidden().frame(width: 110) }
                Toggle("Allow skipping", isOn: $allowSkipping)
                Toggle("Allow postponing", isOn: $allowPostponing)
            }
            Text("Turn these off to remove the corresponding break buttons and menu actions. Keyboard input stays with the app behind the break screen.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Longer breaks take priority when two pauses are due together.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if original != nil { Button("Delete break", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(teal).disabled(!valid)
            }
        }.padding(28).frame(width: 460).background(paper).tint(teal)
            .onAppear {
                if let original {
                    name = original.name; interval = original.interval / 60; unit = original.duration >= 60 ? 60 : 1; duration = original.duration / unit
                    allowSkipping = original.allowSkipping; allowPostponing = original.allowPostponing
                }
            }
            .confirmationDialog("Delete this break?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.preferences.plans.removeAll { $0.id == original?.id }; dismiss() }
            }
    }
    var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40 && interval.isFinite && duration.isFinite && interval >= 1 && interval <= 1440 && duration >= 1 && duration * unit <= 3600 && duration * unit < interval * 60 }
    func save() {
        guard valid else { return }
        var plan = original ?? BreakPlan(name: name, interval: interval * 60, duration: duration * unit)
        plan.name = name.trimmingCharacters(in: .whitespacesAndNewlines); plan.interval = interval * 60; plan.duration = duration * unit
        plan.allowSkipping = allowSkipping; plan.allowPostponing = allowPostponing
        if let index = model.preferences.plans.firstIndex(where: { $0.id == plan.id }) { model.preferences.plans[index] = plan } else { model.preferences.plans.append(plan) }
        dismiss()
    }
}

struct BreakActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(configuration.isPressed ? 0.32 : 0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct BreakScreen: View {
    @ObservedObject var model: BreakModel
    let startedAt: Double
    let duration: Double
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.13, blue: 0.12).opacity(model.preferences.dimOpacity)
            VStack(spacing: 26) {
                Text("B R E A T H E R").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                ZStack {
                    BreakBreathingHalo(startedAt: startedAt).frame(width: 280, height: 280)
                    BreakProgressRing(startedAt: startedAt, duration: duration).frame(width: 150, height: 150).rotationEffect(.degrees(-90))
                    Text(clockText(model.secondsLeft)).font(.system(size: 37, weight: .ultraLight, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                }.frame(height: 240)
                VStack(spacing: 10) {
                    Text(model.phase == "Returning" ? "Welcome back." : (model.active?.duration ?? 0) >= 60 ? "Step away for a moment." : "Let your eyes wander.")
                        .font(.system(size: 32, weight: .light, design: .rounded)).foregroundStyle(.white)
                    Text(model.phase == "Returning" ? "Carry a little calm with you." : (model.active?.duration ?? 0) >= 60 ? "Stand up. Stretch. Take a slow breath." : "Look into the distance. Relax your shoulders.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 14) {
                    if model.canPostpone {
                    Button("Postpone \(Int(model.preferences.postpone1)) min") { model.dismiss(postpone: model.preferences.postpone1) }
                    Button("Postpone \(Int(model.preferences.postpone2)) min") { model.dismiss(postpone: model.preferences.postpone2) }
                    }
                    if model.canSkip {
                    Button("Skip break") { model.dismiss() }
                    }
                }.buttonStyle(BreakActionButtonStyle()).padding(.top, 22)
                Text(model.active?.name == "Preview" ? "Preview · Your schedule stays as it is" : "\(model.active?.name ?? "") break · Time to rest")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
        }.ignoresSafeArea()
    }
}

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor private final class MenuRunLoopAction: NSObject {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @objc func fire(_ timer: Timer) { body() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let testing = CommandLine.arguments.contains { uiTestArguments.contains($0) }
    lazy var model = BreakModel(testing: testing)
    var window: NSWindow!
    var status: NSStatusItem!
    var overlays: [NSWindow] = []
    var fadingOverlays: [NSWindow] = []
    var overlayRemoval: DispatchWorkItem?
    var observers: [NSObjectProtocol] = []
    var fadingOut = false
    private(set) var statusMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Breather"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(paper)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: Dashboard(model: model, activity: CommandLine.arguments.contains("--show-activity")).preferredColorScheme(.light))
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        if !CommandLine.arguments.contains("--background") { showWindow() }
        model.onStart = { [weak self] in self?.showOverlays() }
        model.onEnd = { [weak self] in self?.hideOverlays() }
        model.onDismiss = { [weak self] in self?.removeOverlaysImmediately() }
        model.onTick = { [weak self] in self?.updateStatus() }
        model.onPreferencesChanged = { [weak self] in self?.updateStatus() }
        observeSleep()
        model.startTimer(); updateStatus()
        if testing { runSmokeTest() }
    }
    func makeMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Breather", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Breather", action: #selector(showWindow), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Breather", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Breather", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu; main.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Breather", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2", .credits: NSAttributedString(string: "Small pauses. A better pace.\nBuilt for your Mac.")]) }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.interruptSession(); model.saveSchedule(); model.stopTimer() }
    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if !testing { item.autosaveName = "BreatherCountdown" }
        item.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Breather")
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        status = item
    }
    func updateStatus() {
        guard model.preferences.menuBarCountdownVisible else {
            if let item = status {
                // Clear ownership before cancellation: menuDidClose can call
                // updateStatus synchronously while AppKit ends tracking.
                status = nil; statusMenuOpen = false
                item.menu?.cancelTrackingWithoutAnimation()
                NSStatusBar.system.removeStatusItem(item)
            }
            return
        }
        // Explicitly register a new item when re-enabled rather than keeping a
        // detached/hidden remote Control Center item and trusting isVisible.
        if status == nil { makeStatusItem() }
        if !status.isVisible { status.isVisible = true }
        guard !statusMenuOpen else { return }
        let text: String
        if model.scheduler.paused { text = "Paused" }
        else if model.active != nil { text = clockText(model.secondsLeft) }
        else if model.allEnabledBreaksPaused { text = "Paused" }
        else if model.nextPlan == nil { text = "Off" }
        else {
            let countdown = clockText(model.nextSeconds)
            text = model.idleCountdownText != nil ? "Idle" : countdown
        }
        let title = " " + text
        let tooltip = "Breather · " + model.stateText
        if status.button?.title != title { status.button?.title = title }
        if status.button?.toolTip != tooltip { status.button?.toolTip = tooltip }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === status?.menu { statusMenuOpen = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === status?.menu {
            statusMenuOpen = false
            updateStatus()
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        // AppKit forbids changing menu structure inside menuWillOpen/menuDidClose.
        // Keep the open menu and its status-item anchor stable until tracking ends.
        guard !statusMenuOpen || menu !== status?.menu else { return }
        menu.removeAllItems()
        let heading = NSMenuItem(title: model.active != nil ? "Enjoy your breather" : model.stateText, action: nil, keyEquivalent: ""); menu.addItem(heading)
        menu.addItem(.separator())
        add(menu, "Show Breather", #selector(showWindow))
        if model.active == nil, let next = model.nextPlan {
            let name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.lowercased() == "break" || name.lowercased().hasSuffix(" break") ? name : "\(name) Break"
            add(menu, "Take \(title) now", #selector(takeBreak))
        }
        if model.scheduler.paused { add(menu, "Resume breaks", #selector(resume)) }
        else if model.canPause {
            let pause = NSMenuItem(title: "Pause breaks", action: nil, keyEquivalent: ""); let sub = NSMenu()
            add(sub, "15 minutes", #selector(pause15)); add(sub, "30 minutes", #selector(pause30)); add(sub, "1 hour", #selector(pauseHour)); add(sub, "1 day", #selector(pauseDay)); add(sub, "Until I resume", #selector(pauseForever)); pause.submenu = sub; menu.addItem(pause)
        }
        menu.addItem(.separator())
        add(menu, "Hide menu bar timer", #selector(hideMenuBarTimer))
        add(menu, "Quit Breather", #selector(quit))
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
    @objc func takeBreak() { if let plan = model.nextPlan { model.begin(plan) } }
    @objc func postponeFirst() { model.deferNext(model.preferences.postpone1) }
    @objc func postponeSecond() { model.deferNext(model.preferences.postpone2) }
    @objc func skip() { model.skipNext() }
    @objc func resume() { model.resume() }
    @objc func pause15() { model.pause(minutes: 15) }
    @objc func pause30() { model.pause(minutes: 30) }
    @objc func pauseHour() { model.pause(minutes: 60) }
    @objc func pauseDay() { model.pause(minutes: 1440) }
    @objc func pauseForever() { model.pause() }
    @objc func hideMenuBarTimer() { model.preferences.menuBarCountdownVisible = false }
    @objc func quit() { NSApp.terminate(nil) }
    func makeOverlayWindow(for screen: NSScreen) -> OverlayWindow {
        let overlay = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        overlay.setFrame(screen.frame, display: true)
        overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.hidesOnDeactivate = false; overlay.canHide = false
        overlay.isFloatingPanel = true; overlay.becomesKeyOnlyIfNeeded = true
        // isFloatingPanel changes the level to .floating. Apply the cover
        // level afterward so modal dialogs, menus, and palettes stay behind it.
        overlay.level = .init(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        overlay.animationBehavior = .none
        overlay.isReleasedWhenClosed = false
        return overlay
    }
    func showOverlays() {
        guard !model.sleeping else { return }
        if statusMenuOpen { status.menu?.cancelTrackingWithoutAnimation() }
        NSApp.unhideWithoutActivation()
        // Finish any prior dismissal before beginning another break.
        removeOverlaysImmediately()
        let screens = testing ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        for screen in screens {
            let overlay = makeOverlayWindow(for: screen)
            let content = OverlayHostingView(rootView: BreakScreen(model: model, startedAt: model.breakStartUptime, duration: model.visualTiming.duration).preferredColorScheme(.dark))
            content.frame = NSRect(origin: .zero, size: screen.frame.size)
            overlay.contentView = BreakCoverView(content: content, startedAt: model.breakStartUptime, timing: model.visualTiming)
            overlay.orderFrontRegardless(); overlays.append(overlay)
            // Prepare content before the first visible compositor frame.
            overlay.contentView?.layoutSubtreeIfNeeded()
            overlay.displayIfNeeded()
        }
    }
    func keepOverlaysVisible() {
        guard model.active != nil, !model.sleeping, model.phase != "Returning" else { return }
        for overlay in overlays { overlay.orderFrontRegardless() }
    }
    func hideOverlays() {
        guard !fadingOut else { return }
        fadingOut = true
        let old = overlays; overlays = []
        fadingOverlays = old
        let scheduled = model.active != nil && model.phase == "Returning"
        let duration = scheduled ? model.visualTiming.remaining(after: ProcessInfo.processInfo.systemUptime - model.breakStartUptime) : model.fadeOutSeconds
        // Scheduled fades already run on the compositor's original timeline.
        if !scheduled { for overlay in old { (overlay.contentView as? BreakCoverView)?.dismiss(duration: duration) } }
        let removal = DispatchWorkItem { [weak self] in
            for overlay in old { overlay.orderOut(nil); overlay.contentView = nil }
            self?.fadingOverlays = []
            self?.overlayRemoval = nil
            self?.fadingOut = false
        }
        overlayRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: removal)
    }
    func removeOverlaysImmediately() {
        overlayRemoval?.cancel(); overlayRemoval = nil
        for overlay in overlays + fadingOverlays { overlay.orderOut(nil); overlay.contentView = nil }
        overlays = []; fadingOverlays = []; fadingOut = false
    }
    func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.keepOverlaysVisible() }
            })
        }
        let transitions: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ]
        for (sleep, wake, reason) in transitions {
            observers.append(workspace.addObserver(forName: sleep, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleep(reason: reason) } })
            observers.append(workspace.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake(reason: reason) } })
        }
        let distributed = DistributedNotificationCenter.default()
        for (sleep, wake, reason) in [("com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "lock"), ("com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "screensaver")] {
            observers.append(distributed.addObserver(forName: .init(sleep), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleep(reason: reason) } })
            observers.append(distributed.addObserver(forName: .init(wake), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake(reason: reason) } })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.model.active != nil, self?.model.phase != "Returning" { self?.showOverlays() } }
        })
    }
    func snapshot(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "/private/tmp/Breather-\(name).png")) }
    }
    func verifyBreakControls() {
        let savedPreferences = model.preferences
        let savedRecord = model.record
        let savedHistory = model.history
        let savedScheduler = model.scheduler
        let normal = model.preferences.plans[0]
        let quickID = model.preferences.plans[1].id
        for allowSkip in [false, true] {
            for allowPostpone in [false, true] {
                model.preferences.plans[1].allowSkipping = allowSkip
                model.preferences.plans[1].allowPostponing = allowPostpone
                let quick = model.preferences.plans[1]
                testCheck(model.preferences.plans[0] == normal, "Controls apply only to the edited break")
                model.scheduler.remaining[quickID] = 100
                let skipped = model.record.skipped
                skip()
                testCheck(model.record.skipped == skipped + (allowSkip ? 1 : 0))
                testCheck(model.scheduler.remaining[quickID] == (allowSkip ? quick.interval : 100))
                model.scheduler.remaining[quickID] = 100
                let postponed = model.record.postponed
                postponeFirst()
                testCheck(model.record.postponed == postponed + (allowPostpone ? 1 : 0))
                testCheck(model.scheduler.remaining[quickID] == (allowPostpone ? model.preferences.postpone1 * 60 : 100))
                model.begin(quick)
                let menu = NSMenu(); menuNeedsUpdate(menu)
                testCheck(!menu.items.contains(where: { $0.action == #selector(skip) || $0.action == #selector(postponeFirst) || $0.action == #selector(postponeSecond) }), "The menu bar must never offer skip or postpone, including during a break")
                testCheck(!menu.items.contains(where: { $0.title == "Reset countdowns" }))
                testCheck(menu.items.contains(where: { $0.title == "Pause breaks" }) == allowSkip)
                if !allowSkip && !allowPostpone { snapshot(overlays[0].contentView!, name: "break-restricted") }
                model.dismiss()
                testCheck((model.active == nil) == allowSkip, "Skip button must honor skipping policy")
                if !allowSkip {
                    let before = model.record
                    pause15(); skip()
                    testCheck(model.active?.id == quickID && !model.scheduler.paused && model.record == before, "Pause/menu cannot bypass disabled skipping")
                } else { model.begin(quick) }
                let before = model.record
                postponeSecond()
                testCheck((model.active == nil) == allowPostpone, "Menu postponing must honor break policy")
                if !allowPostpone { testCheck(model.record == before, "Blocked actions must not change activity") }
                model.cancelActiveBreak()
                let data = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!
                let restored = try! JSONDecoder().decode(Preferences.self, from: data)
                testCheck(restored.plans[1].allowSkipping == allowSkip && restored.plans[1].allowPostponing == allowPostpone)
            }
        }
        model.preferences = savedPreferences; model.scheduler = savedScheduler
        model.record = savedRecord; model.history = savedHistory; model.saveRecord()
    }
    func verifyCustomBreakStart() {
        let savedPreferences = model.preferences
        let savedScheduler = model.scheduler
        let savedHistory = model.history
        let custom = BreakPlan(name: "Stretch", interval: 7200, duration: 90, enabled: false, allowSkipping: false, allowPostponing: false)
        model.preferences.plans.insert(custom, at: 0)
        let customWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
        customWindow.contentView = NSHostingView(rootView: Dashboard(model: model).preferredColorScheme(.light))
        customWindow.setContentSize(customWindow.contentView!.fittingSize); customWindow.orderFront(nil)
        snapshot(customWindow.contentView!, name: "dashboard-custom"); customWindow.orderOut(nil)
        testCheck(model.nextPlan?.id != custom.id, "Custom break must be independent of the next scheduled break")
        model.begin(custom)
        testCheck(model.active == custom && model.secondsLeft == 90, "Take now must start the chosen custom break, even with automatic scheduling off")
        testCheck(!model.canSkip && !model.canPostpone, "Manual starts must honor this break's controls")
        model.begin(savedPreferences.plans[0])
        testCheck(model.active == custom, "A second manual start must not replace the active break")
        model.cancelActiveBreak()
        model.sleeping = true
        model.begin(custom)
        testCheck(model.active == nil, "Manual starts must not run while asleep")
        model.sleeping = false
        model.preferences = savedPreferences; model.scheduler = savedScheduler; model.history = savedHistory; model.saveRecord(); model.saveSchedule()
    }
    func verifyImmediateBreakDismissal() {
        let savedPreferences = model.preferences
        let savedScheduler = model.scheduler
        let savedHistory = model.history
        model.preferences.fadeSeconds = 3
        let postponements: [Double?] = [nil, 5]
        for postpone in postponements {
            model.previewBreak()
            let covers = overlays
            testCheck(!covers.isEmpty && covers.allSatisfy(\.isVisible))
            model.dismiss(postpone: postpone)
            testCheck(covers.allSatisfy { !$0.isVisible && $0.contentView == nil }, "Skip and Postpone must immediately remove every cover despite nonzero fades")
            testCheck(overlays.isEmpty && fadingOverlays.isEmpty && overlayRemoval == nil)
        }
        model.previewBreak()
        let returningCovers = overlays
        model.phase = "Returning"
        hideOverlays()
        let pendingRemoval = overlayRemoval
        testCheck(!fadingOverlays.isEmpty && pendingRemoval != nil)
        model.dismiss()
        testCheck(pendingRemoval!.isCancelled && !fadingOut, "Immediate dismissal must cancel pending fade cleanup")
        testCheck(returningCovers.allSatisfy { !$0.isVisible && $0.contentView == nil }, "Skip during fade-out must immediately remove returning covers")
        testCheck(model.history == savedHistory, "Preview dismissal must preserve activity")
        model.preferences = savedPreferences; model.scheduler = savedScheduler; model.saveSchedule()
        print("Immediate dismissal regression passed: skip, postpone, nonzero fades, and cancellation during fade-out")
        fflush(stdout)
    }
    func verifyWindowClose() {
        window.makeKeyAndOrderFront(nil)
        let savedCountdowns = model.scheduler.remaining
        let savedActive = model.active
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        NSApp.mainMenu!.item(withTitle: "File")!.submenu!.update()
        testCheck(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-W must invoke the Close menu item")
        testCheck(!window.isVisible && status != nil && model.scheduler.remaining == savedCountdowns && model.active == savedActive, "Closing the dashboard must preserve the timer and any active break")
        if savedActive != nil { testCheck(overlays.allSatisfy(\.isVisible), "Command-W must not dismiss the break cover") }
        showWindow()
        testCheck(window.isVisible, "Closed dashboard must reopen")
    }
    func verifyOverlayKeyboardInput() {
        let activeID = model.active!.id
        testCheck(overlays.allSatisfy { $0.level.rawValue > NSWindow.Level.popUpMenu.rawValue }, "Covers must stay above modal dialogs and popup menus")
        testCheck(overlays.allSatisfy { !$0.canBecomeKey && !$0.canBecomeMain && !$0.hidesOnDeactivate && !$0.canHide && $0.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]) }, "Covers must remain across apps and Spaces without taking keyboard focus")
        let first = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        let input = NSTextField(frame: NSRect(x: 20, y: 100, width: 250, height: 24))
        let nextInput = NSTextField(frame: NSRect(x: 20, y: 50, width: 250, height: 24))
        let otherInput = NSTextField(frame: NSRect(x: 20, y: 100, width: 250, height: 24))
        first.contentView!.addSubview(input); first.contentView!.addSubview(nextInput)
        second.contentView!.addSubview(otherInput); input.nextKeyView = nextInput
        first.makeKeyAndOrderFront(nil); first.makeFirstResponder(input)
        func type(_ characters: String, key: UInt16, into target: NSWindow) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)!
            NSApp.sendEvent(event)
        }
        testCheck(first.isKeyWindow && !overlays.contains(where: \.isKeyWindow))
        type("a", key: 0, into: first)
        testCheck((first.firstResponder as? NSTextView)?.string == "a", "Typing during a break must reach the underlying text field")
        type("\t", key: 48, into: first)
        testCheck(input.stringValue == "a" && nextInput.currentEditor() != nil, "Tab must move between underlying controls")
        type("\u{1b}", key: 53, into: first)
        testCheck(model.active?.id == activeID, "Escape belongs to the underlying app, not the break")
        second.makeKeyAndOrderFront(nil); second.makeFirstResponder(otherInput)
        type("b", key: 11, into: second)
        keepOverlaysVisible()
        testCheck(second.isKeyWindow && (second.firstResponder as? NSTextView)?.string == "b", "Switching windows must preserve normal keyboard input")
        testCheck(overlays.allSatisfy(\.isVisible) && model.active?.id == activeID, "The cover must stay visible after switching windows")
        first.orderOut(nil); second.orderOut(nil); window.makeKeyAndOrderFront(nil)
        verifyWindowClose()
    }
    func verifyActivityRendering(_ completion: @escaping () -> Void) {
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        probe.contentView = NSHostingView(rootView: Dashboard(model: model, activity: true).preferredColorScheme(.light))
        probe.orderFront(nil); probe.contentView!.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let before = ActivityView.bodyEvaluationCount
            var ticks = 0
            let originalTick = self.model.onTick
            self.model.onTick = { ticks += 1; originalTick?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.model.onTick = originalTick
                probe.contentView!.layoutSubtreeIfNeeded()
                testCheck(ticks >= 3, "Performance regression check must exercise real timer callbacks")
                testCheck(ActivityView.bodyEvaluationCount == before, "Activity must not rebuild while only countdowns change")
                let oldHistory = self.model.history, oldRecord = self.model.record
                self.model.record.skipped += 1
                self.model.history.recordAction(.skipped); self.model.saveRecord()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    probe.contentView!.layoutSubtreeIfNeeded()
                    testCheck(ActivityView.bodyEvaluationCount > before, "Activity must still refresh when a real outcome changes history")
                    let beforeInteraction = ActivityView.bodyEvaluationCount
                    let plot = activityMouseSurfaces(in: probe.contentView!).first!
                    plot.zoom(0.9, 0.5); plot.pan(0.05); plot.select(0.4)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        probe.contentView!.layoutSubtreeIfNeeded()
                        testCheck(ActivityView.bodyEvaluationCount > beforeInteraction, "Equatable Activity must still redraw for zoom, pan, and selection")
                        self.model.history = oldHistory; self.model.record = oldRecord; self.model.saveRecord()
                        probe.orderOut(nil); probe.contentView = nil
                        print("Activity rendering regression passed: countdown ticks do not rebuild charts; history and interactions do")
                        completion()
                    }
                }
            }
        }
    }
    func verifySleepCountdowns() {
        testCheck(!window.isVisible && !NSApp.isActive, "Sleep check must run without taking focus")
        model.stopTimer()
        // Exercise model transitions without displaying covers or touching real sleep.
        model.onStart = nil; model.onEnd = nil; model.onDismiss = nil
        model.preferences.idleMode = .pause; model.preferences.idleThreshold = 300
        model.preferences.workHoursOnly = false; model.preferences.weekdaysOnly = false
        let plans = model.preferences.plans
        model.preferences.plans[1].enabled = false
        model.scheduler.remaining[plans[0].id] = 420
        model.scheduler.remaining[plans[1].id] = 123
        model.scheduler.waitingFor[plans[1].id] = plans[0].id
        let remaining = model.scheduler.remaining, waiting = model.scheduler.waitingFor
        let uptime = ProcessInfo.processInfo.systemUptime
        model.sleep(uptime: uptime)
        model.sleep(uptime: uptime)
        model.tick()
        testCheck(model.sleeping && model.scheduler.remaining == remaining && model.scheduler.waitingFor == waiting, "All countdowns and priority waits freeze during sleep")
        model.wake(uptime: uptime, rawIdle: 0)
        testCheck(!model.sleeping && !model.idle && model.scheduler.remaining == remaining && model.scheduler.waitingFor == waiting, "Short sleep resumes exact enabled/disabled timers without resetting")
        model.sleep(uptime: uptime)
        model.wake(uptime: uptime, rawIdle: 0)
        testCheck(!model.idle && model.scheduler.remaining == remaining, "Wake uses normal system inactivity without adding sleep time")
        model.sleep(uptime: uptime)
        model.wake(uptime: uptime, rawIdle: 300)
        testCheck(model.idle, "Normal system inactivity still triggers the configured idle threshold")
        model.wake()
        testCheck(model.scheduler.remaining == remaining, "Duplicate wakes cannot reset timers")
        model.sleep(reason: "display")
        model.sleep(reason: "system")
        model.wake(reason: "system")
        testCheck(model.sleeping, "A system wake cannot resume countdowns while the display is still asleep")
        model.wake(reason: "display")
        model.pause(minutes: 30)
        let until = model.pauseUntil
        model.sleep(); model.wake()
        testCheck(model.scheduler.paused && model.pauseUntil == until && model.scheduler.remaining == remaining, "Sleep preserves manual pauses")
        model.resume()
        model.scheduler.waitingFor = [:]
        let future = BreakPlan(name: "Future test", interval: 7200, duration: 2400)
        model.preferences.plans.append(future)
        model.scheduler.remaining[future.id] = 987
        model.begin(plans[0])
        let start = model.breakStartUptime, sessions = model.history.sessions.count
        let at = start + 45
        let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let sleepAt = nextMidnight.addingTimeInterval(-60)
        model.sleep(now: sleepAt, uptime: at)
        let left = model.secondsLeft, before = model.scheduler.remaining
        model.tick()
        testCheck(model.secondsLeft == left && model.active?.id == plans[0].id, "Sleeping callbacks must not double-apply rest progress")
        model.wake(now: sleepAt.addingTimeInterval(60), uptime: at + 60, rawIdle: 0)
        testCheck(abs(model.breakStartUptime - start) < 0.001 && model.secondsLeft == left - 60 && model.phase == "Resting", "Short sleep advances the active break and its animation clock by the sleep duration")
        let afterShortSleep = model.secondsLeft
        testCheck(model.history.sessions.count == sessions && model.record.completed == 0 && model.record.rested == 0)
        model.scheduler.waitingFor[plans[1].id] = plans[0].id
        model.sleep(now: sleepAt.addingTimeInterval(60), uptime: at + 60)
        // Repeated notifications must retain the start of the original sleep.
        model.sleep(now: sleepAt.addingTimeInterval(1200), uptime: at + 60)
        model.wake(now: sleepAt.addingTimeInterval(1860), uptime: at + 60, rawIdle: 0)
        testCheck(model.active == nil && model.scheduler.activeID == nil && model.secondsLeft == 0, "Long sleep finishes the active break without replaying its cover")
        testCheck(model.scheduler.remaining[future.id] == before[future.id] && model.scheduler.remaining[plans[1].id] == plans[1].interval, "Sleep resets a qualifying disabled break while preserving longer breaks")
        testCheck(model.scheduler.remaining[plans[0].id] == plans[0].interval, "A full duration of sleep resets the completed break to a fresh interval")
        testCheck(model.scheduler.waitingFor[plans[1].id] == nil, "Completing the break releases its priority dependents")
        let completion = model.history.sessions.last!
        let expectedEnd = sleepAt.addingTimeInterval(60 + afterShortSleep)
        testCheck(completion.outcome == .completed && completion.rested == plans[0].duration && completion.endedAt == expectedEnd, "Persist one completed break at the time its remaining rest was satisfied")
        let completionDay = model.history.records.first { $0.day == HistoryDates.key(for: expectedEnd) }!
        testCheck(completionDay.completed == 1 && completionDay.rested == plans[0].duration && model.record.completed == 0, "Cross-midnight sleep credits the day the break finished")
        let savedHistory = model.history, savedCountdowns = model.scheduler.remaining
        model.wake()
        testCheck(model.history == savedHistory && model.scheduler.remaining == savedCountdowns, "Duplicate wake cannot complete or reschedule a break twice")
        model.begin(plans[0])
        let exactStart = model.breakStartUptime
        model.scheduler.remaining[plans[0].id] = 42
        model.sleep(now: sleepAt, uptime: exactStart + 120)
        testCheck(model.secondsLeft == 180)
        model.wake(now: sleepAt.addingTimeInterval(179), uptime: exactStart + 120, rawIdle: 0)
        testCheck(model.active?.id == plans[0].id && model.secondsLeft == 1 && model.phase == "Returning" && model.scheduler.remaining[plans[0].id] == 42, "A sleep one second short of completion leaves one second, with the correct fade-out phase")
        model.sleep(now: sleepAt.addingTimeInterval(179), uptime: exactStart + 120)
        model.wake(now: sleepAt.addingTimeInterval(180), uptime: exactStart + 120, rawIdle: 0)
        testCheck(model.active == nil && model.history.sessions.last?.outcome == .completed && model.scheduler.remaining[plans[0].id] == plans[0].interval, "Separate short sleeps accumulate to finish the remainder and start a full new countdown at wake")
        testCheck(model.scheduler.remaining[future.id] == 987, "A shorter completion threshold for the active break must not apply to inactive breaks")
        model.begin(plans[0])
        let exampleStart = model.breakStartUptime
        let exampleSessions = model.history.sessions.count
        model.sleep(now: sleepAt, uptime: exampleStart)
        model.wake(now: sleepAt.addingTimeInterval(120), uptime: exampleStart, rawIdle: 0)
        testCheck(model.active?.id == plans[0].id && model.secondsLeft == 180 && abs(model.breakStartUptime - exampleStart + 120) < 0.001, "A newly started five-minute break has three minutes left after sleeping for two minutes")
        testCheck(model.scheduler.remaining[future.id] == 987, "Advancing an active break during sleep must not advance future countdowns")
        model.sleep(now: sleepAt.addingTimeInterval(120), uptime: exampleStart)
        model.wake(now: sleepAt.addingTimeInterval(720), uptime: exampleStart, rawIdle: 0)
        testCheck(model.active == nil && model.scheduler.remaining[plans[0].id] == plans[0].interval, "Sleep beyond the remaining duration starts the full next countdown only at wake")
        testCheck(model.history.sessions.count == exampleSessions && model.history.sessions.last?.endedAt == sleepAt.addingTimeInterval(300), "Completion time and statistics include the two separate sleeps exactly once")
        model.begin(plans[1])
        let quickStart = model.breakStartUptime
        model.sleep(now: sleepAt, uptime: quickStart + 15)
        model.wake(now: sleepAt.addingTimeInterval(5), uptime: quickStart + 15, rawIdle: 0)
        testCheck(model.active == nil && model.scheduler.remaining[plans[1].id] == plans[1].interval, "An active disabled break also resets fully when sleep covers only its remaining five seconds")
        let beforePreview = model.history
        model.previewBreak()
        model.sleep(now: sleepAt)
        model.wake(now: sleepAt.addingTimeInterval(60))
        testCheck(model.active == nil && model.history == beforePreview, "A sleeping preview finishes without adding statistics")
        model.scheduler.remaining[plans[0].id] = 41
        model.scheduler.remaining[plans[1].id] = 17
        model.scheduler.remaining[future.id] = 987
        model.pause(minutes: 30)
        let pausedUntil = model.pauseUntil, historyBeforeReset = model.history
        model.sleep(now: sleepAt)
        model.wake(now: sleepAt.addingTimeInterval(60))
        testCheck(model.scheduler.remaining[plans[0].id] == 41 && model.scheduler.remaining[future.id] == 987 && model.scheduler.remaining[plans[1].id] == plans[1].interval, "With no active break, reset each countdown using its full break duration")
        testCheck(model.scheduler.paused && model.pauseUntil == pausedUntil && model.history == historyBeforeReset, "Resetting schedules preserves manual pauses and adds no invented break completions")
        let saved = try! JSONDecoder().decode(SavedSchedule.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "schedule.v1")!)
        testCheck(saved.paused && saved.countdowns.first(where: { $0.id == plans[1].id })?.remaining == plans[1].interval, "Wake saves the reset countdowns")
        model.resume()
        testCheck(!window.isVisible && !NSApp.isActive, "Sleep checks must leave the user's workspace undisturbed")
        print("Sleep countdown checks passed: exact timer/priority preservation, normal idle detection, duplicate/overlapping notifications, manual pauses, partial-sleep progress, repeated sleeps, long-sleep completion, exact boundary, cross-midnight history, previews, and duration-based resets for all schedules")
    }
    func verifyOverlayLayering() {
        testCheck(!window.isVisible && !NSApp.isActive, "Layering checks must not show windows or take focus")
        for screen in NSScreen.screens {
            let cover = makeOverlayWindow(for: screen)
            let levels: [NSWindow.Level] = [.normal, .floating, .modalPanel, .statusBar, .popUpMenu, .screenSaver]
            testCheck(levels.allSatisfy { cover.level.rawValue > $0.rawValue }, "Final configured cover must stay above dialogs, floating palettes, and menus")
            testCheck(!cover.canBecomeKey && !cover.canBecomeMain && cover.styleMask.contains(.nonactivatingPanel), "Layering must preserve keyboard control of the underlying app")
            testCheck(!cover.hidesOnDeactivate && !cover.canHide && cover.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]), "Cover must stay across applications, Spaces, and full-screen windows")
            testCheck(cover.frame == screen.frame && !cover.isVisible, "Build the real cover for each display without displaying it")
            cover.close()
        }
        testCheck(!window.isVisible && !NSApp.isActive)
        print("Overlay layering check passed: production cover configuration stays above modal dialogs, palettes, and menus without taking keyboard focus")
    }
    func verifyIdleResets() {
        testCheck(!window.isVisible && !NSApp.isActive)
        model.stopTimer(); model.onStart = nil; model.onEnd = nil; model.onDismiss = nil
        model.preferences.idleMode = .pause; model.preferences.idleThreshold = 300
        model.preferences.skipMeetingApps = false
        model.preferences.workHoursOnly = false; model.preferences.weekdaysOnly = false
        let normal = model.preferences.plans[0], quick = model.preferences.plans[1]
        let longer = BreakPlan(name: "Longer rest", interval: 7200, duration: 900)
        model.preferences.plans.append(longer)
        model.preferences.plans[1].enabled = false
        model.scheduler.remaining[normal.id] = 41
        model.scheduler.remaining[quick.id] = 17
        model.scheduler.remaining[longer.id] = 987
        model.scheduler.waitingFor[quick.id] = normal.id
        let history = model.history
        model.tick(idleSeconds: 300)
        model.tick(idleSeconds: 600)
        testCheck(model.idle && model.scheduler.remaining[normal.id] == 41 && model.scheduler.remaining[quick.id] == 17, "Idle pause continues until user input returns")
        model.pause(minutes: 30)
        let until = model.pauseUntil
        model.tick(idleSeconds: 0)
        testCheck(model.scheduler.remaining[normal.id] == normal.interval && model.scheduler.remaining[quick.id] == quick.interval, "Returning from idle resets qualifying enabled and disabled breaks")
        testCheck(model.scheduler.remaining[longer.id] == 987 && model.scheduler.waitingFor[quick.id] == nil, "Longer breaks remain unchanged and satisfied waits are released")
        testCheck(model.scheduler.paused && model.pauseUntil == until && model.history == history, "Idle resets preserve global pause and do not add completion statistics")
        let saved = try! JSONDecoder().decode(SavedSchedule.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "schedule.v1")!)
        testCheck(saved.countdowns.first(where: { $0.id == normal.id })?.remaining == normal.interval, "Idle resets are saved immediately")
        model.scheduler.remaining[normal.id] = 123
        model.tick(idleSeconds: 0.1)
        testCheck(model.scheduler.remaining[normal.id] == 123, "Subsequent input cannot repeat an old idle reset")
        model.tick(idleSeconds: 299)
        model.tick(idleSeconds: 0)
        testCheck(model.scheduler.remaining[normal.id] == 123, "Short inactivity does not bypass the Idle threshold")
        model.scheduler.remaining[quick.id] = 17
        model.tick(idleSeconds: 300); model.tick(idleSeconds: 0)
        testCheck(model.scheduler.remaining[normal.id] == 123 && model.scheduler.remaining[quick.id] == 17, "The five minutes before Idle do not reset any countdown")
        model.tick(idleSeconds: 360); model.tick(idleSeconds: 0)
        testCheck(model.scheduler.remaining[normal.id] == 123 && model.scheduler.remaining[quick.id] == quick.interval, "Six minutes away grants only one minute of reset-eligible rest")
        model.begin(normal)
        let started = model.breakStartUptime, activeHistory = model.history
        model.tick(idleSeconds: 600)
        model.tick(idleSeconds: 0)
        testCheck(model.active?.id == normal.id && model.breakStartUptime == started && model.secondsLeft < normal.duration && model.history == activeHistory, "Idle does not hide, pause, finish, or restart an active break")
        model.cancelActiveBreak()
        model.preferences.idleMode = .ignore
        model.scheduler.remaining[normal.id] = 123
        model.tick(idleSeconds: 600); model.tick(idleSeconds: 0)
        testCheck(model.scheduler.remaining[normal.id] == 123, "Keep counting still ignores idle resets")
        testCheck(!window.isVisible && !NSApp.isActive)
        print("Idle model checks passed: return from idle, saved resets, disabled/custom plans, priority waits, pauses/history, one reset per period, threshold, ignore mode, and active-break preservation")
    }
    func verifyCountdownPause(_ completion: @escaping () -> Void) {
        testCheck(!window.isVisible && !NSApp.isActive)
        model.stopTimer(); model.onStart = nil; model.onEnd = nil; model.onDismiss = nil
        model.preferences.idleMode = .ignore; model.preferences.skipMeetingApps = false
        model.preferences.workHoursOnly = false; model.preferences.weekdaysOnly = false
        model.preferences.fadeSeconds = 0.4
        let automatic = BreakPlan(name: "Automatic pause test", interval: 600, duration: 1.2)
        let other = BreakPlan(name: "Other countdown", interval: 900, duration: 20)
        let disabled = BreakPlan(name: "Disabled manual break", interval: 1200, duration: 1.2, enabled: false)
        model.preferences.plans = [automatic, other, disabled]
        model.scheduler.reset(model.preferences.plans)
        model.scheduler.remaining[automatic.id] = 0
        model.scheduler.remaining[other.id] = 20
        model.scheduler.remaining[disabled.id] = 7
        model.tick(idleSeconds: 0)
        testCheck(model.active?.id == automatic.id, "Automatic break must start")
        let others = [other.id: model.scheduler.remaining[other.id]!, disabled.id: model.scheduler.remaining[disabled.id]!]
        func checkFrozen(_ message: String) {
            testCheck(others.allSatisfy { self.model.scheduler.remaining[$0.key] == $0.value }, message)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.model.tick(idleSeconds: 0)
            testCheck(self.model.phase == "Arriving")
            checkFrozen("Every other countdown must pause during fade-in")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.model.tick(idleSeconds: 0)
                testCheck(self.model.phase == "Returning")
                checkFrozen("Every other countdown must pause through fade-out")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.model.tick(idleSeconds: 0)
                    testCheck(self.model.active == nil && self.model.record.completed == 1)
                    checkFrozen("Completion must preserve other countdowns exactly")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.model.tick(idleSeconds: 0)
                        testCheck(self.model.scheduler.remaining[other.id]! < others[other.id]! - 0.2 && self.model.scheduler.remaining[disabled.id] == others[disabled.id], "Enabled countdowns resume after completion; disabled ones remain frozen")
                        self.model.begin(disabled)
                        let beforeManual = self.model.scheduler.remaining
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.model.tick(idleSeconds: 0)
                            testCheck(self.model.active?.id == disabled.id && self.model.scheduler.remaining == beforeManual, "Manually starting a disabled break pauses all other countdowns")
                            self.model.dismiss(postpone: 5)
                            testCheck(self.model.scheduler.remaining[other.id] == beforeManual[other.id], "Postponing must not charge paused break time")
                            self.model.begin(automatic)
                            let beforeSkip = self.model.scheduler.remaining
                            self.model.tick(idleSeconds: 0); self.model.dismiss()
                            testCheck(self.model.scheduler.remaining[other.id] == beforeSkip[other.id], "Skipping preserves other countdowns")
                            self.model.previewBreak()
                            let beforePreview = self.model.scheduler.remaining
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                self.model.tick(idleSeconds: 0)
                                testCheck(self.model.scheduler.remaining == beforePreview, "Previews pause every real countdown")
                                self.model.dismiss()
                                self.model.preferences.idleMode = .pause
                                self.model.preferences.idleThreshold = 300
                                self.model.begin(automatic)
                                let beforeIdle = self.model.scheduler.remaining
                                self.model.tick(idleSeconds: 600); self.model.tick(idleSeconds: 0)
                                testCheck(self.model.scheduler.remaining == beforeIdle, "Idle resets must wait until the active break ends")
                                self.model.dismiss()
                                testCheck(self.model.scheduler.remaining[other.id] == other.interval, "Deferred idle resets apply when the break ends")
                                testCheck(!self.window.isVisible && !NSApp.isActive)
                                print("Countdown pause checks passed: automatic/manual/disabled breaks, fade-in/out, completion/resume, skip/postpone, previews, and deferred idle resets")
                                completion()
                            }
                        }
                    }
                }
            }
        }
    }
    func runSmokeTest() {
        // Let the initial dashboard finish its first layout before sampling frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if CommandLine.arguments.contains("--break-pause-test") {
                self.verifyBreakPauses { NSApp.terminate(nil) }
                return
            }
            if CommandLine.arguments.contains("--activity-filter-test") {
                self.model.stopTimer()
                testCheck(!self.window.isVisible && !NSApp.isActive)
                self.verifyActivityFilters()
                testCheck(!self.window.isVisible && !NSApp.isActive)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--page-tabs-labels-test") {
                self.model.stopTimer()
                testCheck(!self.window.isVisible && !NSApp.isActive)
                self.window.contentView!.layoutSubtreeIfNeeded()
                let control = pageTabs(in: self.window.contentView!).first!
                let labels = control.subviews.compactMap { $0 as? NSTextField }
                testCheck(labels.map(\.stringValue) == ["Breaks", "Activity"], "Tab text must use native AppKit labels")
                let assignments = control.selectionAssignments
                let labelIDs = labels.map(ObjectIdentifier.init)
                for _ in 0..<100 { control.apply(false) }
                testCheck(control.selectionAssignments == assignments && control.subviews.compactMap { $0 as? NSTextField }.map(ObjectIdentifier.init) == labelIDs, "Countdown updates must preserve native labels and selection")
                for label in labels {
                    testCheck(label.hitTest(NSPoint(x: label.frame.midX, y: label.frame.midY)) == nil, "Labels must pass clicks to the segmented control")
                }
                self.snapshot(self.window.contentView!, name: "native-tabs-breaks")
                control.selectedSegment = 1
                control.sendAction(control.action!, to: control.target)
                testCheck(control.highlight.animation(forKey: "pageSlide") != nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Native text must retain the sliding highlight")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    testCheck(control.selectedSegment == 1 && labels[1].textColor == .white && labels[0].textColor != .white)
                    self.snapshot(self.window.contentView!, name: "native-tabs-activity")
                    testCheck(!self.window.isVisible && !NSApp.isActive)
                    print("Page tab labels passed: native text, stable updates, click passthrough, selection colors, and sliding highlight; rendered without showing windows")
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--activity-labels-test") {
                self.model.stopTimer()
                testCheck(!self.window.isVisible && !NSApp.isActive)
                self.verifyActivityAppearance(hidden: true)
                testCheck(!self.window.isVisible && !NSApp.isActive)
                print("Activity labels rendered in the background: shared daily/monthly axes, weekday summaries, and unchanged hourly views")
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--countdown-pause-test") {
                self.verifyCountdownPause { NSApp.terminate(nil) }
                return
            }
            if CommandLine.arguments.contains("--idle-reset-test") {
                self.verifyIdleResets()
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--overlay-layering-test") {
                self.verifyOverlayLayering()
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--sleep-countdown-test") {
                self.verifySleepCountdowns()
                self.model.cancelActiveBreak()
                self.model.preferences.idleMode = .ignore
                self.model.preferences.skipMeetingApps = false
                self.model.scheduler.reset(self.model.preferences.plans)
                let before = self.model.scheduler.remaining
                self.model.sleep()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.model.tick()
                    testCheck(self.model.scheduler.remaining == before, "Real callbacks while asleep must leave all timers unchanged")
                    self.model.wake()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.model.tick()
                        let id = self.model.preferences.plans[0].id
                        let elapsed = before[id]! - self.model.scheduler.remaining[id]!
                        testCheck(elapsed > 0.4 && elapsed < 0.9, "After wake only awake time may reduce countdowns")
                        testCheck(!self.window.isVisible && !NSApp.isActive)
                        print("Real callback sleep/wake check passed: sleeping time excluded, awake countdown resumed")
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            if CommandLine.arguments.contains("--background-startup-test") {
                testCheck(!self.window.isVisible && !NSApp.isActive, "Background launch must not show a window or activate Breather")
                self.snapshot(self.window.contentView!.superview!, name: "window-chrome")
                self.model.preferences.idleMode = .ignore
                self.model.preferences.skipMeetingApps = false
                let countdown = self.model.nextSeconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    testCheck(!self.window.isVisible && !NSApp.isActive, "Background timing must preserve window visibility and focus")
                    testCheck(self.model.nextSeconds < countdown - 0.4, "Automatic countdowns must run during a hidden launch")
                    print("Background startup passed: no visible window, no activation, and live countdowns")
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--status-menu-test") {
                self.verifyMenuBarVisibility { self.verifyStatusMenu { NSApp.terminate(nil) } }
                return
            }
            if CommandLine.arguments.contains("--green-switches-test") {
                self.snapshot(self.window.contentView!, name: "green-switches-on")
                self.verifyBreakSwitches {
                    let control = breakSwitches(in: self.window.contentView!).first!
                    control.performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.snapshot(self.window.contentView!, name: "green-switches-off")
                        control.performClick(nil)
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            if CommandLine.arguments.contains("--page-tabs-test") {
                self.snapshot(self.window.contentView!, name: "green-tabs-breaks")
                let control = pageTabs(in: self.window.contentView!).first!
                control.selectedSegment = 1
                control.sendAction(control.action!, to: control.target)
                verifyPageTabsAnimation {
                    self.snapshot(self.window.contentView!, name: "green-tabs-activity")
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--activity-appearance-test") {
                self.verifyActivityAppearance()
                print("Activity appearance test passed: daily groups, hourly views, and mouse input")
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--performance-test") {
                verifyBreathingHalo { verifyBreakAnimation { self.verifyPerformance { NSApp.terminate(nil) } } }
                return
            }
            if CommandLine.arguments.contains("--priority-ui-test") {
                self.verifyPriorityGripInput { self.verifyPriorityOrder() }
                return
            }
            if CommandLine.arguments.contains("--break-actions-test") {
                self.verifyImmediateBreakDismissal()
                self.model.preferences.fadeSeconds = 0
                self.model.previewBreak()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.snapshot(self.overlays[0].contentView!, name: "break-buttons")
                    self.model.dismiss()
                    print("Break action UI test passed")
                    NSApp.terminate(nil)
                }
                return
            }
            verifyBreakAnimation { self.verifyBreakSwitches { self.verifyActivityRendering { self.runVisualSmokeTest() } } }
        }
    }
    func verifyMenuBarVisibility(_ completion: @escaping () -> Void) {
        let savedPreferences = model.preferences, savedScheduler = model.scheduler, savedHistory = model.history
        let originalTick = model.onTick
        let originalItem = status!
        model.preferences.idleMode = .ignore; model.preferences.skipMeetingApps = false
        let plan = model.nextPlan!
        model.scheduler.remaining[plan.id] = 123
        model.preferences.menuBarCountdownVisible = true
        testCheck(status.isVisible && status.button!.title == " 02:03", "Enabling the setting must immediately show the current countdown")
        model.preferences.menuBarCountdownVisible = false
        testCheck(status == nil && model.scheduler.remaining[plan.id] == 123, "Hiding must unregister the menu item and preserve its countdown")
        let hidden = try! JSONDecoder().decode(Preferences.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!)
        testCheck(!hidden.menuBarCountdownVisible && hidden.plans == savedPreferences.plans, "The hidden preference must persist without changing breaks")
        let restored = BreakModel(testing: true, resetTestPreferences: false)
        testCheck(!restored.preferences.menuBarCountdownVisible && restored.preferences.plans == model.preferences.plans, "A relaunched model must restore menu visibility and saved schedules")
        var ticks = 0
        model.onTick = { ticks += 1; originalTick?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            testCheck(ticks >= 2 && self.model.nextSeconds < 122.6 && self.status == nil, "Real countdowns must continue while the menu item is hidden")
            self.model.preferences.menuBarCountdownVisible = true
            testCheck(self.status !== originalItem && self.status.isVisible && self.status.button!.title == " " + clockText(self.model.nextSeconds), "Showing must freshly register a status item with the latest countdown immediately")
            self.status.isVisible = false
            self.updateStatus()
            testCheck(self.status.isVisible, "An enabled preference must restore a hidden status item")
            let restoredItem = self.status!
            self.updateStatus(); self.updateStatus()
            testCheck(self.status === restoredItem, "Countdown ticks must retain the current registration")
            for _ in 0..<6 { self.model.preferences.menuBarCountdownVisible.toggle() }
            testCheck(self.status.isVisible && self.status !== restoredItem && self.model.history == savedHistory, "Each enable must register a fresh item without altering activity")
            let shown = try! JSONDecoder().decode(Preferences.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!)
            testCheck(shown.menuBarCountdownVisible, "The enabled preference must also persist")
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.appearance = NSAppearance(named: .aqua)
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: self.model).preferredColorScheme(.light))
            settingsWindow.orderFront(nil)
            self.snapshot(settingsWindow.contentView!, name: "menu-bar-settings")
            settingsWindow.orderOut(nil); settingsWindow.contentView = nil
            self.model.onTick = originalTick
            self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler; self.model.saveSchedule(); self.updateStatus()
            print("Menu bar visibility passed: immediate show/hide, relaunch persistence, hidden countdowns, restored visibility, repeated toggles, and preserved schedules/history")
            completion()
        }
    }
    func verifyStatusMenu(_ completion: @escaping () -> Void) {
        let menu = status.menu!
        let savedPreferences = model.preferences, savedScheduler = model.scheduler
        let originalTick = model.onTick
        model.preferences.idleMode = .ignore; model.preferences.skipMeetingApps = false
        model.scheduler.remaining[model.nextPlan!.id] = 123
        updateStatus()
        menuNeedsUpdate(menu)
        testCheck(!menu.items.contains(where: { $0.action == #selector(skip) || $0.action == #selector(postponeFirst) || $0.action == #selector(postponeSecond) || $0.title == "Reset countdowns" }), "The idle menu must omit skip, postpone, and reset commands")
        let hideIndex = menu.items.firstIndex(where: { $0.action == #selector(hideMenuBarTimer) })!
        testCheck(menu.items[hideIndex].title == "Hide menu bar timer", "The menu must provide the timer visibility command")
        let preparedItems = menu.items.map { ObjectIdentifier($0) }
        menuWillOpen(menu)
        testCheck(menu.items.map { ObjectIdentifier($0) } == preparedItems, "Opening a menu must not rebuild its items")
        let frozenTitle = status.button!.title
        model.scheduler.remaining[model.nextPlan!.id]! -= 2
        updateStatus(); menuNeedsUpdate(menu)
        testCheck(status.button!.title == frozenTitle && menu.items.map { ObjectIdentifier($0) } == preparedItems, "Open menu contents and the status-item anchor must stay stable")
        menuDidClose(menu)
        testCheck(status.button!.title != frozenTitle && !statusMenuOpen, "Closing the menu must immediately restore the latest countdown")
        let popupTitle = status.button!.title
        let startCountdown = model.nextSeconds
        var ticks = 0, samples = 0
        var visibleItems: [ObjectIdentifier]?
        model.onTick = { ticks += 1; originalTick?() }
        // Enter AppKit tracking from a run-loop timer, allowing the main dispatch
        // queue to process the scheduler's actor callbacks while the menu is open.
        func menuTimer(_ interval: Double, repeats: Bool, _ body: @escaping @MainActor () -> Void) -> Timer {
            let action = MenuRunLoopAction(body)
            return Timer(timeInterval: interval, target: action, selector: #selector(MenuRunLoopAction.fire(_:)), userInfo: nil, repeats: repeats)
        }
        let open = menuTimer(0.05, repeats: false) {
            let check = menuTimer(0.1, repeats: true) {
                guard self.statusMenuOpen else { return }
                samples += 1
                let ids = menu.items.map { ObjectIdentifier($0) }
                if visibleItems == nil { visibleItems = ids }
                self.menuNeedsUpdate(menu)
                testCheck(ids == visibleItems && self.status.button!.title == popupTitle, "Real popup tracking must preserve menu items and button text")
            }
            let close = menuTimer(1.4, repeats: false) { menu.cancelTrackingWithoutAnimation() }
            RunLoop.main.add(check, forMode: .common); RunLoop.main.add(close, forMode: .common)
            // Anchor the test popup inside its own window: macOS can withhold a
            // test bundle's status item independently of native menu behavior.
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 30, y: 30), in: self.window.contentView!)
            check.invalidate(); close.invalidate()
            fputs("Native menu tracking: samples=\(samples), ticks=\(ticks), elapsed=\(startCountdown - self.model.nextSeconds)\n", stderr)
            testCheck(samples >= 3 && ticks >= 3 && self.model.nextSeconds < startCountdown - 0.5, "Countdowns must keep advancing during real native menu tracking")
            testCheck(!self.statusMenuOpen && self.status.button!.title != popupTitle, "Cancelling the popup must close it and refresh the countdown")
            self.model.onTick = originalTick
            self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler
            self.model.saveSchedule(); self.updateStatus()
            let hide = menuTimer(0.6, repeats: false) { menu.performActionForItem(at: hideIndex) }
            let escape = menuTimer(1.5, repeats: false) { menu.cancelTrackingWithoutAnimation() }
            RunLoop.main.add(hide, forMode: .common); RunLoop.main.add(escape, forMode: .common)
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 30, y: 30), in: self.window.contentView!)
            hide.invalidate(); escape.invalidate()
            fputs("Native menu hide: itemRemoved=\(self.status == nil), menuClosed=\(!self.statusMenuOpen), preferenceHidden=\(!self.model.preferences.menuBarCountdownVisible)\n", stderr)
            testCheck(self.status == nil && !self.statusMenuOpen, "Hiding during native menu tracking must dismiss the dropdown and unregister the item")
            let hidden = try! JSONDecoder().decode(Preferences.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!)
            fputs("Native menu hide persistence: hidden=\(!hidden.menuBarCountdownVisible), plansPreserved=\(hidden.plans == savedPreferences.plans)\n", stderr)
            testCheck(!hidden.menuBarCountdownVisible && hidden.plans == savedPreferences.plans, "The menu's hide command must persist its setting and preserve breaks")
            self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler
            self.model.saveSchedule(); self.updateStatus()
            testCheck(self.status != nil && self.status.isVisible, "Re-enabling after an open-menu hide must register a working item")
            print("Status menu passed: prepare before opening, stable items/anchor, live scheduler during tracking, native cancellation, immediate refresh, and safe unregister/re-register while tracking")
            completion()
        }
        RunLoop.main.add(open, forMode: .common)
    }
    func verifyPerformance(_ completion: @escaping () -> Void) {
        let savedPreferences = model.preferences, savedScheduler = model.scheduler
        let originalTick = model.onTick
        model.preferences.idleMode = .ignore; model.preferences.skipMeetingApps = false
        var ticks = 0
        model.onTick = { ticks += 1; originalTick?() }
        window.contentView!.layoutSubtreeIfNeeded()
        let control = pageTabs(in: window.contentView!).first!
        func select(_ activity: Bool) {
            control.selectedSegment = activity ? 1 : 0
            control.sendAction(control.action!, to: control.target)
        }
        func cpuSeconds() -> Double {
            var usage = rusage()
            testCheck(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let stages = ["Breaks", "Activity", "Repeated tab switching", "Closed window", "Reopened after sleep/wake", "Active break"]
        func measure(_ index: Int) {
            switch index {
            case 0: select(false)
            case 1: select(true)
            case 2: for i in 0..<20 { select(i % 2 == 0) }; select(false)
            case 3: self.window.orderOut(nil)
            case 4:
                self.model.sleep(); self.model.wake()
                self.window.orderFront(nil)
            case 5:
                self.snapshot(self.window.contentView!, name: "performance-dashboard")
                self.model.preferences.fadeSeconds = 0.4; self.model.previewBreak()
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                testCheck(pageTabs(in: self.window.contentView!).first === control && control.selectedSegment == (index == 1 ? 1 : 0), "Tabs must preserve selection and their native control across countdown updates")
                let startCPU = cpuSeconds(), startTime = ProcessInfo.processInfo.systemUptime
                let startTicks = ticks, assignments = control.selectionAssignments, startCountdown = self.model.nextSeconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let wall = ProcessInfo.processInfo.systemUptime - startTime
                    let fraction = (cpuSeconds() - startCPU) / wall
                    print("Performance: \(stages[index]) = \(String(format: "%.1f", fraction * 100))% CPU, \(ticks - startTicks) scheduler ticks")
                    fflush(stdout)
                    testCheck(fraction < (index == 5 ? 0.10 : 0.20), "Steady UI and animated breaks must stay within their CPU budgets")
                    testCheck(ticks - startTicks >= 8 && control.selectionAssignments == assignments, "Real countdown ticks must continue without rewriting tab selection")
                    if index < 5 { testCheck(self.model.nextSeconds < startCountdown - 2, "Countdowns must keep advancing, including with the window closed") }
                    if index + 1 < stages.count { measure(index + 1) }
                    else {
                        self.model.dismiss(); self.model.onTick = originalTick
                        self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler; self.model.saveSchedule()
                        print("Performance regression passed: both pages, switching, closed window, sleep/wake, active cover, and uninterrupted scheduling")
                        completion()
                    }
                }
            }
        }
        measure(0)
    }
    func verifyPriorityGripInput(_ completion: @escaping () -> Void) {
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "Priority drag check failed", line: UInt = #line) {
            testCheck(condition(), message, line: line)
        }
        window.contentView!.layoutSubtreeIfNeeded()
        let grips = priorityGrips(in: window.contentView!)
        check(grips.count == model.preferences.plans.count && grips.count >= 2)
        let savedPreferences = model.preferences, savedHistory = model.history
        let before = model.scheduler.remaining
        let source = grips[1], target = grips[0]
        let root = window.contentView!
        for grip in grips {
            let point = root.superview!.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
            check(root.hitTest(point) === grip, "Rendered priority grips must receive pointer input through the hosting view")
        }
        check(source.acceptsFirstMouse(for: nil), "Priority grips must accept a drag into an inactive window")
        func center(_ grip: PriorityGripView) -> NSPoint {
            let rect = grip.convert(grip.bounds, to: nil)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            if type == .mouseEntered || type == .cursorUpdate {
                return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        source.updateTrackingAreas()
        let tracking = source.trackingAreas.filter { ($0.owner as? PriorityGripView) === source }
        check(tracking.count == 1 && tracking[0].options.contains([.cursorUpdate, .inVisibleRect, .activeAlways]), "The whole grip must own a stable native hover cursor")
        source.updateTrackingAreas()
        check(source.trackingAreas.contains { $0 === tracking[0] }, "Countdown layouts must keep the same hover tracking area")
        source.mouseEntered(with: event(.mouseEntered, center(source)))
        source.cursorUpdate(with: event(.cursorUpdate, center(source)))
        check(NSCursor.current == NSCursor.openHand, "Hover must show the grab cursor")
        let start = center(source)
        let destination = NSPoint(x: center(target).x, y: center(target).y + 12)
        let originalRow = priorityRows(in: root).first { $0.planID == source.planID }!
        let container = root.superview ?? root
        let originalRect = originalRow.convert(originalRow.bounds, to: container)
        check(originalRect.width > 500 && originalRect.height >= 68, "Drag geometry must encompass the full card")
        source.mouseDown(with: event(.leftMouseDown, start))
        source.mouseDragged(with: event(.leftMouseDragged, destination))
        check(source.dragPreview != nil, "Dragging must lift a snapshot of the entire card")
        let preview = source.dragPreview!
        check(preview.superview === container && preview.bounds.size == originalRect.size && preview.hitTest(.zero) == nil, "The floating card must cover the row without intercepting controls")
        check(source.grabCursorActive && NSCursor.current == NSCursor.closedHand, "Dragging must hold a grabbing cursor")
        let moved = NSPoint(x: destination.x + 22, y: destination.y + 9)
        source.mouseDragged(with: event(.leftMouseDragged, moved))
        let deltaStart = container.convert(start, from: nil), deltaEnd = container.convert(moved, from: nil)
        check(abs(preview.frame.minX - originalRect.minX - (deltaEnd.x - deltaStart.x)) < 0.1 && abs(preview.frame.minY - originalRect.minY - (deltaEnd.y - deltaStart.y)) < 0.1, "The complete card must follow mouse movement in both axes without a layout animation")
        check(self.model.preferences.plans == savedPreferences.plans, "A drag preview must not commit priority changes before release")
        source.mouseDragged(with: event(.leftMouseDragged, destination))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            check(priorityGrips(in: self.window.contentView!).contains { $0 === source }, "Drag input must survive a dashboard update without losing the grip")
            check(source.dragPreview === preview && source.grabCursorActive, "Countdown updates must preserve the floating card and grabbing cursor")
            check(preview.frame.size == originalRect.size && !preview.isHidden, "The floating card must remain visible after dashboard layout")
            self.snapshot(preview, name: "priority-drag-card")
            self.snapshot(container, name: "priority-drag")
            source.mouseUp(with: event(.leftMouseUp, destination))
            check(source.dragPreview == nil && !source.grabCursorActive && preview.superview == nil, "Dropping must remove the preview and release cursor tracking")
            check(self.model.preferences.plans.first!.id == source.planID, "Native mouse release must move the lower break upward")
            let saved = try! JSONDecoder().decode(Preferences.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!)
            check(saved.plans == self.model.preferences.plans, "Mouse dragging must persist the priority order")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let down = NSPoint(x: center(target).x, y: center(target).y - 12)
                source.mouseDown(with: event(.leftMouseDown, center(source)))
                source.mouseDragged(with: event(.leftMouseDragged, down))
                source.mouseUp(with: event(.leftMouseUp, down))
                check(self.model.preferences.plans == savedPreferences.plans, "Native dragging must also move a break down")
                source.mouseDown(with: event(.leftMouseDown, center(source)))
                source.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 0, y: 0)))
                source.mouseUp(with: event(.leftMouseUp, NSPoint(x: 0, y: 0)))
                check(self.model.preferences.plans == savedPreferences.plans && self.model.history == savedHistory, "Dropping outside the cards must leave priorities and activity unchanged")
                source.mouseDown(with: event(.leftMouseDown, center(source)))
                source.mouseDragged(with: event(.leftMouseDragged, center(target)))
                source.cancelDrag()
                check(source.dragPreview == nil && !source.grabCursorActive && self.model.preferences.plans == savedPreferences.plans, "Cancellation must remove the lifted card, restore the cursor, and preserve priority")
                for (id, value) in before {
                    check(abs(self.model.scheduler.remaining[id]! - value) < 1, "Dragging must preserve countdowns while real scheduler ticks continue")
                }
                print("Priority grip input passed: stable hover/grabbing cursors, pointer-following card, preview surviving updates, first-mouse acceptance, upward/downward releases, saved order, cancellation cleanup, and preserved countdowns/history")
                completion()
            }
        }
    }
    func verifyPriorityOrder() {
        let savedPreferences = model.preferences, savedScheduler = model.scheduler
        let savedHistory = model.history
        let normal = model.preferences.plans[0], quick = model.preferences.plans[1]
        let stretch = BreakPlan(name: "Stretch", interval: 1800, duration: 30)
        model.preferences.plans.append(stretch)
        let countdowns = model.scheduler.remaining
        model.moveBreak(quick.id, to: normal.id)
        testCheck(model.preferences.plans.map(\.id) == [quick.id, normal.id, stretch.id])
        model.moveBreak(stretch.id, to: quick.id)
        testCheck(model.preferences.plans.map(\.id) == [stretch.id, quick.id, normal.id])
        model.moveBreak(normal.id, to: stretch.id)
        testCheck(model.preferences.plans.map(\.id) == [normal.id, stretch.id, quick.id])
        testCheck(model.scheduler.remaining == countdowns, "Drag reordering must preserve every countdown")
        let data = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!
        var persisted = try! JSONDecoder().decode(Preferences.self, from: data)
        persisted.migratePriorityOrder()
        testCheck(persisted.plans == model.preferences.plans, "Dragged priority persists without automatic resorting")
        model.preferences = savedPreferences; model.scheduler = savedScheduler
        model.scheduler.remaining[normal.id] = 600
        model.scheduler.finish(quick, plans: model.preferences.plans, elapsed: 20)
        testCheck(model.waitingName(for: quick) == normal.name && model.nextPlan?.id == normal.id)
        model.moveBreak(quick.id, to: normal.id)
        testCheck(model.waitingName(for: quick) == nil && model.scheduler.remaining[quick.id] == 1180, "Moving above the blocker releases a wait without resetting the timer")
        model.moveBreak(normal.id, to: quick.id)
        model.scheduler.finish(quick, plans: model.preferences.plans, elapsed: 20)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.snapshot(self.window.contentView!, name: "priority")
            testCheck(self.model.waitingName(for: quick) == normal.name && self.model.scheduler.remaining[quick.id] == 1180)
            testCheck(self.model.history == savedHistory, "Reordering and waiting must not invent break activity")
            self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler; self.model.saveSchedule()
            print("Priority UI test passed: bidirectional drag-order operations, immediate persistence, unchanged countdowns/history, wait labels, and release after priority changes")
            NSApp.terminate(nil)
        }
    }
    func verifyBreakSwitches(_ completion: @escaping () -> Void) {
        window.contentView!.layoutSubtreeIfNeeded()
        let switches = breakSwitches(in: window.contentView!)
        testCheck(switches.count == model.preferences.plans.count, "Each break must have a native switch")
        let control = switches[0]
        let savedPreferences = model.preferences, savedScheduler = model.scheduler
        let plan = savedPreferences.plans[0]
        let history = model.history
        let heldCountdown = 1234.5
        model.scheduler.remaining[plan.id] = heldCountdown
        let start = ProcessInfo.processInfo.systemUptime
        control.performClick(nil)
        testCheck(!model.preferences.plans[0].enabled && control.state == .off, "Click immediately disables the chosen break")
        testCheck(model.preferences.plans.dropFirst() == savedPreferences.plans.dropFirst(), "Other breaks stay unchanged")
        let persisted = try! JSONDecoder().decode(Preferences.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!)
        testCheck(!persisted.plans[0].enabled, "Switch changes must persist immediately")
        let assignments = control.stateAssignments
        var ticks = 0
        let originalTick = model.onTick
        model.onTick = { ticks += 1; originalTick?() }
        print("Native switch click handled in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.model.onTick = originalTick
            self.window.contentView!.layoutSubtreeIfNeeded()
            testCheck(ticks >= 3, "Switch regression must exercise real countdown callbacks")
            testCheck(breakSwitches(in: self.window.contentView!).first === control && control.stateAssignments == assignments, "Countdown updates must preserve the switch without resetting its animation")
            testCheck(self.model.scheduler.remaining[plan.id] == heldCountdown, "Disabled break must preserve its remaining countdown")
            let storedSchedule = try! JSONDecoder().decode(SavedSchedule.self, from: UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "schedule.v1")!)
            var restored = Scheduler()
            _ = restored.restore(storedSchedule, plans: self.model.preferences.plans, now: Date().addingTimeInterval(86400))
            testCheck(restored.remaining[plan.id] == heldCountdown, "Disabled countdown must survive relaunch without advancing")
            control.performClick(nil)
            testCheck(self.model.preferences.plans[0].enabled && control.state == .on && self.model.scheduler.remaining[plan.id] == heldCountdown, "Re-enabling resumes the preserved countdown")
            for _ in 0..<8 { control.performClick(nil) }
            testCheck(self.model.preferences.plans[0].enabled && self.model.scheduler.remaining[plan.id] == heldCountdown && self.model.history == history, "Rapid switch clicks must preserve the countdown without inventing activity")
            testCheck(control.accessibilityRole() == .checkBox && control.accessibilitySubrole() == .switch, "Break controls must expose switch accessibility semantics")
            testCheck(control.accessibilityPerformPress() && !self.model.preferences.plans[0].enabled && (control.accessibilityValue() as! NSNumber).boolValue == false, "Accessibility press must disable the break and report its new value")
            testCheck(control.accessibilityPerformPress() && self.model.preferences.plans[0].enabled && (control.accessibilityValue() as! NSNumber).boolValue, "Accessibility press must also re-enable the break")
            self.model.preferences = savedPreferences; self.model.scheduler = savedScheduler; self.model.saveSchedule()
            print("Break switch regression passed: immediate persistence, stable animation across timer ticks, rapid toggles, and accessibility presses")
            completion()
        }
    }
    func verifyBreakPauses(_ completion: @escaping () -> Void) {
        testCheck(!window.isVisible && !NSApp.isActive)
        model.stopTimer()
        model.onStart = nil; model.onEnd = nil; model.onDismiss = nil
        model.preferences.idleMode = .ignore
        model.preferences.workHoursOnly = false; model.preferences.weekdaysOnly = false
        let normal = model.preferences.plans[0], quick = model.preferences.plans[1]
        model.scheduler = Scheduler(); model.scheduler.reset(model.preferences.plans)
        model.scheduler.remaining[normal.id] = 1000; model.scheduler.remaining[quick.id] = 200
        let history = model.history
        model.pauseBreak(normal, minutes: 30)
        testCheck(model.scheduler.remaining[normal.id] == 1000 && model.nextPlan?.id == quick.id)
        testCheck(model.scheduler.breakPauses[normal.id]?.until != nil)
        snapshot(window.contentView!, name: "break-pause-timed")
        let restored = BreakModel(testing: true, resetTestPreferences: false)
        testCheck(restored.scheduler.remaining[normal.id] == 1000 && restored.scheduler.breakPauses == model.scheduler.breakPauses, "Individual pauses persist through model relaunch")
        model.resumeBreak(normal)
        testCheck(!model.scheduler.isBreakPaused(normal.id) && model.scheduler.remaining[normal.id] == 1000)
        model.pauseBreak(quick)
        model.pause(); model.resume()
        testCheck(model.scheduler.isBreakPaused(quick.id), "Global resume must preserve a break-specific pause")
        model.begin(normal, preview: true)
        model.pauseBreak(normal)
        testCheck(!model.scheduler.isBreakPaused(normal.id) && model.active?.id == normal.id, "Card pause cannot bypass an active break")
        model.cancelActiveBreak()
        model.resumeBreak(quick); model.pauseBreak(normal)
        model.startTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            testCheck(self.model.scheduler.remaining[normal.id] == 1000 && self.model.scheduler.remaining[quick.id]! < 200, "Real callbacks must freeze only the selected break")
            let held = self.model.scheduler.remaining[quick.id]!
            self.model.pauseBreak(quick, minutes: 0.005)
            testCheck(self.model.allEnabledBreaksPaused && self.status.button!.title == " Paused", "Individually pausing every break must show Paused in the menu bar")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.model.stopTimer()
                testCheck(!self.model.scheduler.isBreakPaused(quick.id) && self.model.scheduler.remaining[quick.id]! < held, "Timed per-break pause must expire and resume with real callbacks")
                testCheck(self.model.scheduler.remaining[normal.id] == 1000, "Another break remains paused after timed expiry")
                testCheck(self.model.history == history, "Pausing and resuming must not invent break activity")
                self.model.pauseBreak(quick)
                self.snapshot(self.window.contentView!, name: "break-pause-all")
                testCheck(!self.window.isVisible && !NSApp.isActive)
                print("Break pause UI checks passed: hidden card rendering, independent callbacks, relaunch persistence, global overlap, active-break protection, timed resume, menu label, and unchanged history")
                completion()
            }
        }
    }
    func verifyActivityFilters() {
        let savedPreferences = model.preferences, savedHistory = model.history
        let quick = BreakPlan(name: "Quick", interval: 1200, duration: 20)
        let normal = BreakPlan(name: "Normal", interval: 3600, duration: 300, enabled: false)
        model.preferences.plans = [normal, quick]
        var fixture = ActivityHistory()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            for (plan, minute, outcome) in [(quick, 10, BreakOutcome.completed), (quick, 20, .completed), (normal, 30, .completed), (quick, 40, .skipped), (normal, 50, .postponed)] {
                let end = day.addingTimeInterval(Double(9 * 3600 + minute * 60))
                let id = fixture.startSession(planID: plan.id, name: plan.name, duration: plan.duration, at: end.addingTimeInterval(-plan.duration))
                fixture.endSession(id, outcome: outcome, at: end, rested: outcome == .completed ? plan.duration : 0)
            }
            fixture.update(DayRecord(day: HistoryDates.key(for: day), completed: 3, skipped: 1, postponed: 1, rested: 340))
        }
        model.history = fixture
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 582), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        for (name, selection, expectedRest, expectedCompleted) in [("all", nil as Set<UUID>?, 2380.0, 21), ("quick", Set([quick.id]), 280.0, 14), ("normal", Set([normal.id]), 2100.0, 7), ("none", Set<UUID>(), 0.0, 0)] {
            let view = ActivityView(model: model, initialBreaks: selection)
            let buckets = fixture.filtered(for: selection).buckets(in: calendar.date(byAdding: .day, value: -6, to: today)!...calendar.date(byAdding: .day, value: 1, to: today)!)
            let total = ActivityHistory.total(buckets.map { $0.totals })
            testCheck(total.rested == expectedRest && total.completed == expectedCompleted, "Filter must drive both graph buckets and summary totals")
            probe.contentView = NSHostingView(rootView: view.frame(width: 620, height: 522).padding(30).background(paper).tint(teal).preferredColorScheme(.light))
            snapshot(probe.contentView!, name: "activity-filter-\(name)")
            testCheck(!probe.isVisible && !NSApp.isActive)
        }
        let hour = ActivityView(model: model, initialSpan: 3600, initialCenter: today.addingTimeInterval(9.5 * 3600), initialBreaks: [quick.id])
        probe.contentView = NSHostingView(rootView: hour.frame(width: 620, height: 522).padding(30).background(paper).tint(teal).preferredColorScheme(.light))
        snapshot(probe.contentView!, name: "activity-filter-hour")
        testCheck(model.history == fixture, "Changing filters must not change saved history")
        probe.contentView = nil
        model.preferences = savedPreferences; model.history = savedHistory
        print("Activity filter checks passed: all/single/multiple/empty attribution, disabled plans, matching stats/graphs, hourly filtering, and hidden rendering")
    }
    func verifyActivityAppearance(hidden: Bool = false) {
        let activityWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
        activityWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model, activity: true).preferredColorScheme(.light))
        activityWindow.setContentSize(activityWindow.contentView!.fittingSize)
        if !hidden { activityWindow.orderFront(nil) }
        self.snapshot(activityWindow.contentView!, name: "activity-empty")
        let originalHistory = self.model.history
        var fixture = ActivityHistory()
        let today = Calendar.current.startOfDay(for: Date())
        for offset in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            let count = offset % 7 == 2 ? 0 : 8 + offset % 5
            fixture.update(DayRecord(day: HistoryDates.key(for: date), completed: count, skipped: offset % 3, postponed: offset % 4, rested: Double(count * 70)))
            for (name, seconds, duration) in [("Quick", 9 * 3600 + 10 * 60 + 5, 20.0), ("Quick", 9 * 3600 + 35 * 60 + 17, 20.0), ("Normal", 10 * 3600, 300.0)] {
                let start = date.addingTimeInterval(Double(seconds))
                let id = fixture.startSession(planID: self.model.preferences.plans[0].id, name: name, duration: duration, at: start)
                fixture.endSession(id, outcome: .completed, at: start.addingTimeInterval(duration + 3), rested: duration)
            }
        }
        self.model.history = fixture
        activityWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model, activity: true).preferredColorScheme(.light))
        self.snapshot(activityWindow.contentView!, name: "activity")
        if !hidden {
            verifyActivityHitTesting(activityWindow.contentView!)
            verifyActivityMouseInput()
        }
        for (name, span) in [("activity-month", ActivityViewport().maximumSpan), ("activity-twenty-days", 20 * 86400.0), ("activity-day", 86400.0), ("activity-six-hours", 21600.0), ("activity-hour", 3600.0), ("activity-custom", 7700.0)] {
            activityWindow.contentView = NSHostingView(rootView: ActivityView(model: self.model, initialSpan: span, initialCenter: today.addingTimeInterval(span >= 86400 ? 43200 : 9 * 3600 + 35 * 60)).padding(24).frame(width: 680).background(paper).preferredColorScheme(.light))
            activityWindow.setContentSize(activityWindow.contentView!.fittingSize)
            if !hidden { activityWindow.orderFront(nil) }
            self.snapshot(activityWindow.contentView!, name: name)
        }
        self.model.history = originalHistory; activityWindow.orderOut(nil)
    }

    func runVisualSmokeTest() {
        model.preferences.fadeSeconds = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.verifyImmediateBreakDismissal()
            self.verifyWindowClose()
            self.snapshot(self.window.contentView!, name: "dashboard")
            let idlePreferences = self.model.preferences
            self.model.preferences.idleMode = .pause; self.model.idle = true
            let idleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
            idleWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model).preferredColorScheme(.light))
            idleWindow.setContentSize(idleWindow.contentView!.fittingSize); idleWindow.orderFront(nil)
            self.snapshot(idleWindow.contentView!, name: "dashboard-idle"); idleWindow.orderOut(nil)
            self.model.preferences = idlePreferences; self.model.idle = false
            self.verifyActivityAppearance()
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 638, height: 708), styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: self.model).preferredColorScheme(.light)); settingsWindow.orderFront(nil)
            self.snapshot(settingsWindow.contentView!, name: "settings"); settingsWindow.orderOut(nil)
            let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            editorWindow.contentView = NSHostingView(rootView: PlanEditor(model: self.model, original: self.model.preferences.plans[1]).preferredColorScheme(.light))
            editorWindow.setContentSize(editorWindow.contentView!.fittingSize); editorWindow.orderFront(nil)
            self.snapshot(editorWindow.contentView!, name: "editor"); editorWindow.orderOut(nil)
            self.verifyBreakControls()
            self.verifyCustomBreakStart()
            let keyboardWindowBeforeBreak = NSApp.keyWindow
            let sessionsBeforePreview = self.model.history.sessions
            self.model.previewBreak()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                testCheck(!self.overlays.isEmpty, "Break overlay should exist")
                testCheck(NSApp.keyWindow === keyboardWindowBeforeBreak, "Beginning a break must preserve keyboard focus")
                self.verifyOverlayKeyboardInput()
                self.snapshot(self.overlays[0].contentView!, name: "break")
                self.model.dismiss(postpone: 5)
                testCheck(self.model.active == nil)
                testCheck(self.model.record.postponed == 0, "Preview must not affect statistics")
                testCheck(self.model.history.sessions == sessionsBeforePreview, "Preview must not add a timestamped break")
                self.model.pause(minutes: 15); testCheck(self.model.scheduler.paused)
                self.model.resume(); testCheck(!self.model.scheduler.paused)
                let pauseMenu = NSMenu(); self.menuNeedsUpdate(pauseMenu)
                testCheck(pauseMenu.items.first(where: { $0.title == "Pause breaks" })?.submenu?.items.contains(where: { $0.title == "1 day" && $0.action == #selector(self.pauseDay) }) == true)
                let beforePause = self.model.scheduler.remaining
                self.pauseDay()
                testCheck(self.model.scheduler.paused && abs(self.model.pauseUntil!.timeIntervalSinceNow - 86400) < 2, "One day pauses all countdowns for 24 hours")
                self.model.tick()
                testCheck(self.model.scheduler.remaining == beforePause, "Every break countdown must stay frozen while paused")
                let pausedData = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "schedule.v1")!
                let pausedSchedule = try! JSONDecoder().decode(SavedSchedule.self, from: pausedData)
                testCheck(pausedSchedule.paused && pausedSchedule.pauseUntil == self.model.pauseUntil, "One-day pause must persist across quits")
                self.model.resume()
                testCheck(!self.model.scheduler.paused && self.model.pauseUntil == nil && self.model.scheduler.remaining == beforePause)
                let quick = self.model.preferences.plans[1]
                self.model.begin(quick); self.model.dismiss(postpone: 10)
                testCheck(self.model.scheduler.remaining[quick.id] == 600)
                self.model.begin(quick)
                self.model.dismiss()
                testCheck(self.model.scheduler.remaining[quick.id] == quick.interval)
                self.model.preferences.plans[1].duration = 1.25
                self.model.preferences.fadeSeconds = 0.5
                self.model.preferences.plans[1].allowSkipping = false
                self.model.preferences.plans[1].allowPostponing = false
                self.model.preferences.idleMode = .ignore
                var observedAutomaticOverlay = false
                var observedCountdownDuringFadeOut = false
                self.model.onEnd = {
                    if self.model.phase == "Returning" && self.model.secondsLeft > 0 {
                        observedCountdownDuringFadeOut = true
                        testCheck(self.model.record.completed == 0, "A fading-out break is not yet completed")
                    }
                    self.hideOverlays()
                }
                self.model.onStart = {
                    self.showOverlays()
                    // AppKit processes activation/unhiding on the next event-loop turn.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        testCheck(!NSApp.isHidden && !self.overlays.isEmpty && self.overlays.allSatisfy(\.isVisible), "A due break must display visible overlays, including when the app was hidden")
                        observedAutomaticOverlay = true
                    }
                }
                self.model.scheduler.remaining[quick.id] = 0
                self.window.orderOut(nil); NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    testCheck(self.model.active == nil, "Timed break should finish")
                    testCheck(observedAutomaticOverlay, "Automatic break should have been visible before completing")
                    testCheck(self.model.record.completed == 1)
                    testCheck(observedCountdownDuringFadeOut, "Countdown must continue while the cover fades out")
                    testCheck(self.overlays.isEmpty)
                    let stored = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!
                    let loaded = try! JSONDecoder().decode(Preferences.self, from: stored)
                    testCheck(loaded.plans[1].duration == 1.25, "Settings should persist")
                    testCheck(!loaded.plans[1].allowSkipping && !loaded.plans[1].allowPostponing, "Restricted break settings should persist")
                    let historyData = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "history.v1")!
                    let history = try! JSONDecoder().decode(ActivityHistory.self, from: historyData)
                    let today = history.days().last!
                    testCheck(today.completed == 1 && today.skipped == 1 && today.postponed == 1 && today.rested == 1.25, "All break outcomes and rest time must persist in history; previews are excluded")
                    testCheck(history.sessions.count == 3 && history.sessions.filter { $0.outcome == .completed }.count == 1 && history.sessions.filter { $0.outcome == .skipped }.count == 1 && history.sessions.filter { $0.outcome == .postponed }.count == 1, "Activity must persist actual completed, skipped, and postponed sessions exactly once")
                    let completed = history.sessions.first { $0.outcome == .completed }!
                    let elapsed = completed.endedAt!.timeIntervalSince(completed.startedAt)
                    testCheck(elapsed >= 1.25 && elapsed < 1.85, "Both half-second fades must fit within the 1.25-second break, allowing timer callback latency")
                    testCheck(history.sessions.allSatisfy { $0.endedAt != nil && $0.endedAt! >= $0.startedAt }, "Persist real start and end times")
                    self.model.begin(quick)
                    self.model.sleep(); self.model.wake()
                    testCheck(self.model.active?.id == quick.id && self.model.history.sessions.last?.endedAt == nil, "Sleep must preserve the active break without claiming completion")
                    testCheck(!self.model.sleeping)
                    self.model.scheduler.remaining[quick.id] = 123
                    self.model.wake()
                    testCheck(self.model.scheduler.remaining[quick.id] == 123, "Duplicate wake notifications must not restart countdowns")
                    print("UI smoke test passed: Command-W close/reopen with timer and break preservation, dashboard, custom Take now, activity graphs and native mouse zoom/pan, editor, per-break controls, passive overlay keyboard input and window switching, one-day pause, preview, total duration including fades, background completion, history, sleep/wake")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main enum BreatherMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Run from the installed bundle after an identity upgrade, only when
        // the previous app's login setting was enabled. No timers or UI start.
        if CommandLine.arguments.contains("--restore-login-after-identity-update") {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                guard SMAppService.mainApp.status == .enabled else {
                    fputs("Breather login registration requires approval in System Settings.\n", stderr)
                    exit(1)
                }
                print("Breather's login registration restored for the current identity.")
                return
            } catch {
                fputs("Could not restore Breather's login registration: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--countdown-persistence-seed") {
            let model = BreakModel(testing: true)
            model.scheduler.remaining[model.preferences.plans[1].id] = 120
            model.scheduler.remaining[model.preferences.plans[0].id] = 180
            model.saveSchedule()
            UserDefaults(suiteName: "local.breather.smoke")!.synchronize()
            print("Seeded isolated countdowns: Quick 120 seconds, Normal 180 seconds.")
            return
        }
        if CommandLine.arguments.contains("--countdown-persistence-check") {
            let model = BreakModel(testing: true, resetTestPreferences: false)
            let quick = model.scheduler.remaining[model.preferences.plans[1].id]!
            let normal = model.scheduler.remaining[model.preferences.plans[0].id]!
            testCheck(quick > 100 && quick < 120 && abs(normal - quick - 60) < 0.1, "Countdowns must advance between processes without resetting")
            testCheck(model.active == nil && model.record.outcomes == 0 && model.record.rested == 0, "Restore must not invent break activity")
            print("Countdown persistence passed across process restart: Quick \(Int(quick))s, Normal \(Int(normal))s.")
            return
        }
        if CommandLine.arguments.contains("--quit-for-update") {
            let others = breatherApplicationIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for other in others { _ = other.terminate() }
            let deadline = Date().addingTimeInterval(8)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            if others.contains(where: { !$0.isTerminated }) { fputs("Breather did not finish quitting; update cancelled.\n", stderr); exit(1) }
            print("Breather quit cleanly for update.")
            return
        }
        // LaunchServices normally enforces this; direct launches also avoid duplicate timers.
        if !CommandLine.arguments.contains(where: { uiTestArguments.contains($0) }) {
            let identifiers = breatherApplicationIdentifiers.contains(Bundle.main.bundleIdentifier ?? "") ? breatherApplicationIdentifiers : [Bundle.main.bundleIdentifier ?? ""]
            if let existing = identifiers.flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) }).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                existing.activate(options: [])
                return
            }
        }
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
