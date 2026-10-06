import AppKit
import SwiftUI
import IOKit
import ServiceManagement

typealias ViewState<Value> = SwiftUI.State<Value>

let teal = Color(red: 0.17, green: 0.43, blue: 0.38)
let paper = Color(red: 0.97, green: 0.965, blue: 0.95)

@MainActor final class BreakModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
            scheduler.synchronize(preferences.plans)
            for plan in preferences.plans {
                if let previous = oldValue.plans.first(where: { $0.id == plan.id }), previous.interval != plan.interval || previous.enabled != plan.enabled {
                    scheduler.remaining[plan.id] = plan.interval
                }
            }
            saveSchedule()
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
    var onTick: (() -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var timingActivity: NSObjectProtocol?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var phaseStart: Double = 0
    private var breakStarted: Double = 0
    private var arrivalStarted: Double = 0
    private var preview = false
    private var lastScheduleSave = ProcessInfo.processInfo.systemUptime

    init(testing: Bool = false, resetTestPreferences: Bool = true) {
        defaults = testing ? UserDefaults(suiteName: "local.breather.smoke")! : .standard
        if testing && resetTestPreferences { defaults.removePersistentDomain(forName: "local.breather.smoke") }
        preferences = defaults.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        // Save default plan IDs as well, so an untouched schedule can be matched on relaunch.
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
        if let data = defaults.data(forKey: "history.v1"), let value = try? JSONDecoder().decode(ActivityHistory.self, from: data) { history = value }
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
    var controlPlan: BreakPlan? {
        guard let active else { return nextPlan }
        return preferences.plans.first(where: { $0.id == active.id }) ?? active
    }
    var canSkip: Bool { preview || (controlPlan?.allowSkipping ?? false) }
    var canPostpone: Bool { phase != "Returning" && (preview || (controlPlan?.allowPostponing ?? false)) }
    var canPause: Bool { active == nil || canSkip }
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
        let needed = timer != nil && !sleeping && (active != nil || (!scheduler.paused && preferences.plans.contains(where: \.enabled)))
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
        let elapsed = active != nil && !preview ? ProcessInfo.processInfo.systemUptime - arrivalStarted : 0
        let saved = scheduler.savedSchedule(plans: preferences.plans, pauseUntil: pauseUntil, activeElapsed: elapsed)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "schedule.v1") }
        lastScheduleSave = ProcessInfo.processInfo.systemUptime
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick; lastTick = now
        defer { if now - lastScheduleSave >= 15 { saveSchedule() } }
        refreshDay()
        if let until = pauseUntil, Date() >= until { resume() }
        guard !sleeping else { onTick?(); return }
        if let plan = active {
            if !preview { scheduler.elapseDuringBreak(seconds: dt, plans: preferences.plans) }
            if phase == "Arriving" {
                secondsLeft = plan.duration
                if now - phaseStart >= preferences.fadeSeconds { phase = "Resting"; breakStarted = now }
            } else if phase == "Resting" {
                secondsLeft = max(0, plan.duration - (now - breakStarted))
                if secondsLeft <= 0 {
                    if !preview { record.completed += 1; record.rested += plan.duration; saveRecord() }
                    phase = "Returning"; phaseStart = now
                    if preferences.sound { NSSound(named: "Glass")?.play() }
                    onEnd?()
                }
            } else if phase == "Returning", now - phaseStart >= preferences.fadeSeconds { finish(plan) }
        } else {
            let idleSeconds = Self.systemIdleSeconds()
            idle = preferences.idleMode != .ignore && idleSeconds >= preferences.idleThreshold
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let excluded = preferences.skipMeetingApps && ["us.zoom.xos", "com.apple.FaceTime"].contains(front)
            if let plan = scheduler.tick(seconds: dt, idle: idleSeconds, preferences: preferences, excluded: excluded, available: available) { begin(plan) }
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
        active = plan; scheduler.activeID = plan.id
        phase = "Arriving"; phaseStart = ProcessInfo.processInfo.systemUptime; arrivalStarted = phaseStart
        secondsLeft = plan.duration
        if preferences.sound { NSSound(named: "Glass")?.play() }
        onStart?()
        saveSchedule()
    }
    func previewBreak() {
        let plan = BreakPlan(name: "Preview", interval: 1200, duration: 10)
        begin(plan, preview: true)
    }
    func finish(_ plan: BreakPlan) {
        if preview { scheduler.activeID = nil } else { scheduler.finish(plan, elapsed: ProcessInfo.processInfo.systemUptime - arrivalStarted) }
        active = nil; phase = ""; preview = false
        saveSchedule()
    }
    func dismiss(postpone: Double? = nil) {
        guard let plan = active else { return }
        guard postpone == nil ? canSkip : canPostpone else { return }
        refreshDay()
        if !preview && phase != "Returning" {
            if let minutes = postpone { scheduler.postpone(plan, minutes: minutes); record.postponed += 1 }
            else { scheduler.skip(plan); record.skipped += 1 }
            saveRecord()
        }
        scheduler.activeID = nil; active = nil; phase = ""; preview = false
        onEnd?()
        saveSchedule()
    }
    func deferNext(_ minutes: Double) {
        guard canPostpone else { return }
        if active != nil { dismiss(postpone: minutes); return }
        guard let next = nextPlan else { return }
        refreshDay()
        scheduler.postpone(next, minutes: minutes); record.postponed += 1; saveRecord()
        saveSchedule()
    }
    func skipNext() {
        guard canSkip else { return }
        if active != nil { dismiss(); return }
        guard let next = nextPlan else { return }
        refreshDay()
        scheduler.skip(next); record.skipped += 1; saveRecord()
        saveSchedule()
    }
    func pause(minutes: Double? = nil) {
        guard canPause else { return }
        if active != nil { dismiss() }
        scheduler.paused = true; pauseUntil = minutes.map { Date().addingTimeInterval($0 * 60) }; onTick?()
        saveSchedule()
    }
    func resume() { scheduler.paused = false; pauseUntil = nil; lastTick = ProcessInfo.processInfo.systemUptime; saveSchedule(); onTick?() }
    func reset() { scheduler.reset(preferences.plans); saveSchedule(); onTick?() }
    func cancelForSleep() {
        if active != nil { scheduler.activeID = nil; active = nil; phase = ""; preview = false; onEnd?() }
        reset()
    }
    func wake() {
        guard sleeping else { return }
        sleeping = false; idle = false; reset(); lastTick = ProcessInfo.processInfo.systemUptime
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
            Picker("Page", selection: $activity) {
                Text("Breaks").tag(false)
                Text("Activity").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if activity {
                ActivityView(model: model).frame(height: 522)
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
                        Text(model.nextPlan == nil ? "All quiet" : clockText(model.nextSeconds)).font(.system(size: 43, weight: .light, design: .rounded)).monospacedDigit()
                        Text(model.nextPlan.map { "\($0.name) · \(durationLabel($0.duration)) of rest" } ?? "Enable a break to begin").font(.system(size: 12)).foregroundStyle(.secondary)
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
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 13)) }.buttonStyle(.plain).help("Add a break").accessibilityLabel("Add a break")
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.preferences.plans) { plan in
                            HStack(spacing: 14) {
                                Image(systemName: plan.duration >= 60 ? "figure.walk" : "eye").font(.system(size: 18, weight: .light)).foregroundStyle(teal).frame(width: 28)
                                Button { editPlan = plan } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(plan.name).font(.system(size: 14, weight: .medium))
                                        Text("\(durationLabel(plan.duration)) every \(durationLabel(plan.interval))").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Edit \(plan.name)")
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(plan.enabled ? clockText(model.scheduler.remaining[plan.id, default: plan.interval]) : "Off").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    if plan.enabled && model.idleCountdownText != nil { Text("Idle").font(.system(size: 10, weight: .medium)).foregroundStyle(teal) }
                                }
                                Button("Take now") { model.begin(plan) }
                                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
                                    .disabled(model.active != nil || model.sleeping)
                                    .help("Start \(plan.name) now").accessibilityLabel("Take \(plan.name) now")
                                Toggle("Enable \(plan.name)", isOn: Binding(get: { plan.enabled }, set: { value in
                                    if let index = model.preferences.plans.firstIndex(where: { $0.id == plan.id }) { model.preferences.plans[index].enabled = value }
                                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }.padding(17).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }.frame(height: 158)
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

struct BreakScreen: View {
    @ObservedObject var model: BreakModel
    @ViewState<Bool> private var breathe = false
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.13, blue: 0.12).opacity(model.preferences.dimOpacity)
            VStack(spacing: 26) {
                Text("B R E A T H E R").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                ZStack {
                    Circle().fill(.white.opacity(0.025)).frame(width: 230, height: 230).scaleEffect(breathe ? 1.13 : 0.9)
                    Circle().stroke(.white.opacity(0.1), lineWidth: 1).frame(width: 180, height: 180).scaleEffect(breathe ? 1.08 : 0.94)
                    Circle().trim(from: 0, to: fraction).stroke(Color(red: 0.63, green: 0.82, blue: 0.74), style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 150, height: 150).rotationEffect(.degrees(-90))
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
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).padding(.top, 22)
                Text(model.active?.name == "Preview" ? "Preview · Your schedule stays as it is" : "\(model.active?.name ?? "") break · Time to rest")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
        }.ignoresSafeArea().onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
    var fraction: Double { guard let plan = model.active else { return 0 }; return max(0, min(1, model.secondsLeft / plan.duration)) }
}

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let testing = CommandLine.arguments.contains("--ui-smoke-test")
    lazy var model = BreakModel(testing: testing)
    var window: NSWindow!
    var status: NSStatusItem!
    var overlays: [NSWindow] = []
    var observers: [NSObjectProtocol] = []
    var fadingOut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Breather"; window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(paper)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: Dashboard(model: model, activity: CommandLine.arguments.contains("--show-activity")).preferredColorScheme(.light))
        window.setContentSize(window.contentView!.fittingSize)
        window.center(); showWindow()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Breather")
        status.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        model.onStart = { [weak self] in self?.showOverlays() }
        model.onEnd = { [weak self] in self?.hideOverlays() }
        model.onTick = { [weak self] in self?.updateStatus() }
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
    func applicationWillTerminate(_ notification: Notification) { model.saveRecord(); model.saveSchedule(); model.stopTimer() }
    func updateStatus() {
        guard status != nil else { return }
        status.button?.title = " " + (model.scheduler.paused ? "Paused" : model.active != nil ? clockText(model.secondsLeft) : model.nextPlan == nil ? "Off" : clockText(model.nextSeconds))
        status.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.button?.toolTip = "Breather · " + model.stateText
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: model.active != nil ? "Enjoy your breather" : model.stateText, action: nil, keyEquivalent: ""); menu.addItem(heading)
        menu.addItem(.separator())
        add(menu, "Show Breather", #selector(showWindow))
        add(menu, "Take a break now", #selector(takeBreak))
        if model.canPostpone {
            add(menu, "Postpone \(Int(model.preferences.postpone1)) minutes", #selector(postponeFirst))
            add(menu, "Postpone \(Int(model.preferences.postpone2)) minutes", #selector(postponeSecond))
        }
        if model.canSkip { add(menu, "Skip break", #selector(skip)) }
        if model.scheduler.paused { add(menu, "Resume breaks", #selector(resume)) }
        else if model.canPause {
            let pause = NSMenuItem(title: "Pause breaks", action: nil, keyEquivalent: ""); let sub = NSMenu()
            add(sub, "15 minutes", #selector(pause15)); add(sub, "1 hour", #selector(pauseHour)); add(sub, "1 day", #selector(pauseDay)); add(sub, "Until I resume", #selector(pauseForever)); pause.submenu = sub; menu.addItem(pause)
        }
        add(menu, "Reset countdowns", #selector(reset))
        menu.addItem(.separator()); add(menu, "Quit Breather", #selector(quit))
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
    @objc func takeBreak() { if let plan = model.nextPlan { model.begin(plan) } }
    @objc func postponeFirst() { model.deferNext(model.preferences.postpone1) }
    @objc func postponeSecond() { model.deferNext(model.preferences.postpone2) }
    @objc func skip() { model.skipNext() }
    @objc func resume() { model.resume() }
    @objc func pause15() { model.pause(minutes: 15) }
    @objc func pauseHour() { model.pause(minutes: 60) }
    @objc func pauseDay() { model.pause(minutes: 1440) }
    @objc func pauseForever() { model.pause() }
    @objc func reset() { model.reset() }
    @objc func quit() { NSApp.terminate(nil) }
    func showOverlays() {
        NSApp.unhideWithoutActivation()
        // Finish any prior dismissal before beginning another break.
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll(); fadingOut = false
        let screens = testing ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        for screen in screens {
            let overlay = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            overlay.setFrame(screen.frame, display: true)
            overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = false
            overlay.level = .init(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            overlay.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            overlay.hidesOnDeactivate = false; overlay.canHide = false
            overlay.isFloatingPanel = true; overlay.becomesKeyOnlyIfNeeded = true
            overlay.isReleasedWhenClosed = false
            overlay.contentView = OverlayHostingView(rootView: BreakScreen(model: model).preferredColorScheme(.dark))
            overlay.alphaValue = 0
            overlay.orderFrontRegardless(); overlays.append(overlay)
            NSAnimationContext.runAnimationGroup { context in context.duration = model.preferences.fadeSeconds; overlay.animator().alphaValue = 1 }
        }
    }
    func keepOverlaysVisible() {
        guard model.active != nil, model.phase != "Returning" else { return }
        for overlay in overlays { overlay.orderFrontRegardless() }
    }
    func hideOverlays() {
        guard !fadingOut else { return }
        fadingOut = true
        let old = overlays; overlays = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = model.preferences.fadeSeconds
            for overlay in old { overlay.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                for overlay in old { overlay.orderOut(nil) }
                self?.fadingOut = false
            }
        })
    }
    func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.keepOverlaysVisible() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleeping = true; self?.model.cancelForSleep() } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake() } })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleeping = true; self?.model.cancelForSleep() } })
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake() } })
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
                precondition(model.preferences.plans[0] == normal, "Controls apply only to the edited break")
                model.scheduler.remaining[quickID] = 100
                let skipped = model.record.skipped
                skip()
                precondition(model.record.skipped == skipped + (allowSkip ? 1 : 0))
                precondition(model.scheduler.remaining[quickID] == (allowSkip ? quick.interval : 100))
                model.scheduler.remaining[quickID] = 100
                let postponed = model.record.postponed
                postponeFirst()
                precondition(model.record.postponed == postponed + (allowPostpone ? 1 : 0))
                precondition(model.scheduler.remaining[quickID] == (allowPostpone ? model.preferences.postpone1 * 60 : 100))
                model.begin(quick)
                let menu = NSMenu(); menuWillOpen(menu)
                precondition(menu.items.contains(where: { $0.action == #selector(skip) }) == allowSkip)
                precondition(menu.items.contains(where: { $0.action == #selector(postponeFirst) }) == allowPostpone)
                precondition(menu.items.contains(where: { $0.title == "Pause breaks" }) == allowSkip)
                if !allowSkip && !allowPostpone { snapshot(overlays[0].contentView!, name: "break-restricted") }
                model.dismiss()
                precondition((model.active == nil) == allowSkip, "Skip button must honor skipping policy")
                if !allowSkip {
                    let before = model.record
                    pause15(); skip()
                    precondition(model.active?.id == quickID && !model.scheduler.paused && model.record == before, "Pause/menu cannot bypass disabled skipping")
                } else { model.begin(quick) }
                let before = model.record
                postponeSecond()
                precondition((model.active == nil) == allowPostpone, "Menu postponing must honor break policy")
                if !allowPostpone { precondition(model.record == before, "Blocked actions must not change activity") }
                model.cancelForSleep()
                let data = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!
                let restored = try! JSONDecoder().decode(Preferences.self, from: data)
                precondition(restored.plans[1].allowSkipping == allowSkip && restored.plans[1].allowPostponing == allowPostpone)
            }
        }
        model.preferences = savedPreferences; model.scheduler = savedScheduler
        model.record = savedRecord; model.history = savedHistory; model.saveRecord()
    }
    func verifyCustomBreakStart() {
        let savedPreferences = model.preferences
        let savedScheduler = model.scheduler
        let custom = BreakPlan(name: "Stretch", interval: 7200, duration: 90, enabled: false, allowSkipping: false, allowPostponing: false)
        model.preferences.plans.insert(custom, at: 0)
        let customWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
        customWindow.contentView = NSHostingView(rootView: Dashboard(model: model).preferredColorScheme(.light))
        customWindow.setContentSize(customWindow.contentView!.fittingSize); customWindow.orderFront(nil)
        snapshot(customWindow.contentView!, name: "dashboard-custom"); customWindow.orderOut(nil)
        precondition(model.nextPlan?.id != custom.id, "Custom break must be independent of the next scheduled break")
        model.begin(custom)
        precondition(model.active == custom && model.secondsLeft == 90, "Take now must start the chosen custom break, even with automatic scheduling off")
        precondition(!model.canSkip && !model.canPostpone, "Manual starts must honor this break's controls")
        model.begin(savedPreferences.plans[0])
        precondition(model.active == custom, "A second manual start must not replace the active break")
        model.cancelForSleep()
        model.sleeping = true
        model.begin(custom)
        precondition(model.active == nil, "Manual starts must not run while asleep")
        model.sleeping = false
        model.preferences = savedPreferences; model.scheduler = savedScheduler; model.saveSchedule()
    }
    func verifyWindowClose() {
        window.makeKeyAndOrderFront(nil)
        let savedCountdowns = model.scheduler.remaining
        let savedActive = model.active
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        NSApp.mainMenu!.item(withTitle: "File")!.submenu!.update()
        precondition(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-W must invoke the Close menu item")
        precondition(!window.isVisible && status != nil && model.scheduler.remaining == savedCountdowns && model.active == savedActive, "Closing the dashboard must preserve the timer and any active break")
        if savedActive != nil { precondition(overlays.allSatisfy(\.isVisible), "Command-W must not dismiss the break cover") }
        showWindow()
        precondition(window.isVisible, "Closed dashboard must reopen")
    }
    func verifyOverlayKeyboardInput() {
        let activeID = model.active!.id
        precondition(overlays.allSatisfy { !$0.canBecomeKey && !$0.canBecomeMain && !$0.hidesOnDeactivate && !$0.canHide && $0.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]) }, "Covers must remain across apps and Spaces without taking keyboard focus")
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
        precondition(first.isKeyWindow && !overlays.contains(where: \.isKeyWindow))
        type("a", key: 0, into: first)
        precondition((first.firstResponder as? NSTextView)?.string == "a", "Typing during a break must reach the underlying text field")
        type("\t", key: 48, into: first)
        precondition(input.stringValue == "a" && nextInput.currentEditor() != nil, "Tab must move between underlying controls")
        type("\u{1b}", key: 53, into: first)
        precondition(model.active?.id == activeID, "Escape belongs to the underlying app, not the break")
        second.makeKeyAndOrderFront(nil); second.makeFirstResponder(otherInput)
        type("b", key: 11, into: second)
        keepOverlaysVisible()
        precondition(second.isKeyWindow && (second.firstResponder as? NSTextView)?.string == "b", "Switching windows must preserve normal keyboard input")
        precondition(overlays.allSatisfy(\.isVisible) && model.active?.id == activeID, "The cover must stay visible after switching windows")
        first.orderOut(nil); second.orderOut(nil); window.makeKeyAndOrderFront(nil)
        verifyWindowClose()
    }
    func runSmokeTest() {
        model.preferences.fadeSeconds = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.verifyWindowClose()
            self.snapshot(self.window.contentView!, name: "dashboard")
            let idlePreferences = self.model.preferences
            self.model.preferences.idleMode = .pause; self.model.idle = true
            let idleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
            idleWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model).preferredColorScheme(.light))
            idleWindow.setContentSize(idleWindow.contentView!.fittingSize); idleWindow.orderFront(nil)
            self.snapshot(idleWindow.contentView!, name: "dashboard-idle"); idleWindow.orderOut(nil)
            self.model.preferences = idlePreferences; self.model.idle = false
            let activityWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 718), styleMask: [.titled], backing: .buffered, defer: false)
            activityWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model, activity: true).preferredColorScheme(.light))
            activityWindow.setContentSize(activityWindow.contentView!.fittingSize); activityWindow.orderFront(nil)
            self.snapshot(activityWindow.contentView!, name: "activity-empty")
            let originalHistory = self.model.history
            var fixture = ActivityHistory()
            let today = Calendar.current.startOfDay(for: Date())
            for offset in 0..<30 {
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
                let count = offset % 7 == 2 ? 0 : 8 + offset % 5
                fixture.update(DayRecord(day: HistoryDates.key(for: date), completed: count, skipped: offset % 3, postponed: offset % 4, rested: Double(count * 70)))
            }
            self.model.history = fixture
            activityWindow.contentView = NSHostingView(rootView: Dashboard(model: self.model, activity: true).preferredColorScheme(.light))
            self.snapshot(activityWindow.contentView!, name: "activity")
            self.model.history = originalHistory; activityWindow.orderOut(nil)
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
            self.model.previewBreak()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                precondition(!self.overlays.isEmpty, "Break overlay should exist")
                precondition(NSApp.keyWindow === keyboardWindowBeforeBreak, "Beginning a break must preserve keyboard focus")
                self.verifyOverlayKeyboardInput()
                self.snapshot(self.overlays[0].contentView!, name: "break")
                self.model.dismiss(postpone: 5)
                precondition(self.model.active == nil)
                precondition(self.model.record.postponed == 0, "Preview must not affect statistics")
                self.model.pause(minutes: 15); precondition(self.model.scheduler.paused)
                self.model.resume(); precondition(!self.model.scheduler.paused)
                let pauseMenu = NSMenu(); self.menuWillOpen(pauseMenu)
                precondition(pauseMenu.items.first(where: { $0.title == "Pause breaks" })?.submenu?.items.contains(where: { $0.title == "1 day" && $0.action == #selector(self.pauseDay) }) == true)
                let beforePause = self.model.scheduler.remaining
                self.pauseDay()
                precondition(self.model.scheduler.paused && abs(self.model.pauseUntil!.timeIntervalSinceNow - 86400) < 2, "One day pauses all countdowns for 24 hours")
                self.model.tick()
                precondition(self.model.scheduler.remaining == beforePause, "Every break countdown must stay frozen while paused")
                let pausedData = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "schedule.v1")!
                let pausedSchedule = try! JSONDecoder().decode(SavedSchedule.self, from: pausedData)
                precondition(pausedSchedule.paused && pausedSchedule.pauseUntil == self.model.pauseUntil, "One-day pause must persist across quits")
                self.model.resume()
                precondition(!self.model.scheduler.paused && self.model.pauseUntil == nil && self.model.scheduler.remaining == beforePause)
                let quick = self.model.preferences.plans[1]
                self.model.begin(quick); self.model.dismiss(postpone: 10)
                precondition(self.model.scheduler.remaining[quick.id] == 600)
                self.model.begin(quick)
                self.model.dismiss()
                precondition(self.model.scheduler.remaining[quick.id] == quick.interval)
                self.model.preferences.plans[1].duration = 0.5
                self.model.preferences.plans[1].allowSkipping = false
                self.model.preferences.plans[1].allowPostponing = false
                self.model.preferences.idleMode = .ignore
                var observedAutomaticOverlay = false
                self.model.onStart = {
                    self.showOverlays()
                    // AppKit processes activation/unhiding on the next event-loop turn.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        precondition(!NSApp.isHidden && !self.overlays.isEmpty && self.overlays.allSatisfy(\.isVisible), "A due break must display visible overlays, including when the app was hidden")
                        observedAutomaticOverlay = true
                    }
                }
                self.model.scheduler.remaining[quick.id] = 0
                self.window.orderOut(nil); NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    precondition(self.model.active == nil, "Timed break should finish")
                    precondition(observedAutomaticOverlay, "Automatic break should have been visible before completing")
                    precondition(self.model.record.completed == 1)
                    precondition(self.overlays.isEmpty)
                    let stored = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "preferences.v1")!
                    let loaded = try! JSONDecoder().decode(Preferences.self, from: stored)
                    precondition(loaded.plans[1].duration == 0.5, "Settings should persist")
                    precondition(!loaded.plans[1].allowSkipping && !loaded.plans[1].allowPostponing, "Restricted break settings should persist")
                    let historyData = UserDefaults(suiteName: "local.breather.smoke")!.data(forKey: "history.v1")!
                    let history = try! JSONDecoder().decode(ActivityHistory.self, from: historyData)
                    let today = history.days().last!
                    precondition(today.completed == 1 && today.skipped == 1 && today.postponed == 1 && today.rested == 0.5, "All break outcomes and rest time must persist in history; previews are excluded")
                    self.model.sleeping = true; self.model.cancelForSleep(); self.model.wake()
                    precondition(!self.model.sleeping)
                    self.model.scheduler.remaining[quick.id] = 123
                    self.model.wake()
                    precondition(self.model.scheduler.remaining[quick.id] == 123, "Duplicate wake notifications must not restart countdowns")
                    print("UI smoke test passed: Command-W close/reopen with timer and break preservation, dashboard, custom Take now, activity, editor, per-break controls, passive overlay keyboard input and window switching, one-day pause, preview, background completion, history, sleep/wake")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main enum BreatherMain {
    @MainActor static func main() {
        let app = NSApplication.shared
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
            precondition(quick > 100 && quick < 120 && abs(normal - quick - 60) < 0.1, "Countdowns must advance between processes without resetting")
            precondition(model.active == nil && model.record.outcomes == 0 && model.record.rested == 0, "Restore must not invent break activity")
            print("Countdown persistence passed across process restart: Quick \(Int(quick))s, Normal \(Int(normal))s.")
            return
        }
        if CommandLine.arguments.contains("--quit-for-update") {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.breather.app").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for other in others { _ = other.terminate() }
            let deadline = Date().addingTimeInterval(8)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            if others.contains(where: { !$0.isTerminated }) { fputs("Breather did not finish quitting; update cancelled.\n", stderr); exit(1) }
            print("Breather quit cleanly for update.")
            return
        }
        // LaunchServices normally enforces this; direct launches also avoid duplicate timers.
        if !CommandLine.arguments.contains("--ui-smoke-test"), let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate(options: [])
            return
        }
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
