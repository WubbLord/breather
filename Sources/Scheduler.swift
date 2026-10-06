import Foundation

struct BreakPlan: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var interval: Double
    var duration: Double
    var enabled: Bool = true
    var allowSkipping: Bool = true
    var allowPostponing: Bool = true
    static let defaults = [
        BreakPlan(name: "Normal", interval: 3600, duration: 300),
        BreakPlan(name: "Quick", interval: 1200, duration: 20)
    ]
}

extension BreakPlan {
    private enum CodingKeys: String, CodingKey {
        case id, name, interval, duration, enabled, allowSkipping, allowPostponing
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            interval: try values.decode(Double.self, forKey: .interval),
            duration: try values.decode(Double.self, forKey: .duration),
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            allowSkipping: try values.decodeIfPresent(Bool.self, forKey: .allowSkipping) ?? true,
            allowPostponing: try values.decodeIfPresent(Bool.self, forKey: .allowPostponing) ?? true
        )
    }
}

enum IdleMode: String, Codable, CaseIterable {
    case credit, pause, ignore
    var title: String {
        switch self { case .credit: return "Give credit for time away"; case .pause: return "Pause the countdown"; case .ignore: return "Keep counting" }
    }
}

struct Preferences: Codable {
    var plans = BreakPlan.defaults
    var idleMode: IdleMode = .credit
    var idleThreshold: Double = 60
    var fadeSeconds: Double = 5
    var postpone1: Double = 5
    var postpone2: Double = 10
    var skipMeetingApps = true
    var sound = false
    var workHoursOnly = false
    var weekdaysOnly = false
    var startHour = 8
    var endHour = 17
    var dimOpacity: Double = 0.94
}

/// Measures work rather than wall-clock deadlines. Actual sleep is handled by the app's sleep notifications.
struct Scheduler {
    var remaining: [UUID: Double] = [:]
    var paused = false
    var activeID: UUID?

    mutating func synchronize(_ plans: [BreakPlan]) {
        let ids = Set(plans.map(\.id))
        remaining = remaining.filter { ids.contains($0.key) }
        for plan in plans where remaining[plan.id] == nil { remaining[plan.id] = plan.interval }
    }
    mutating func reset(_ plans: [BreakPlan]) {
        remaining = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0.interval) })
    }
    mutating func postpone(_ plan: BreakPlan, minutes: Double) { remaining[plan.id] = minutes * 60 }
    mutating func skip(_ plan: BreakPlan) { remaining[plan.id] = plan.interval }
    mutating func elapseDuringBreak(seconds: Double, plans: [BreakPlan]) {
        guard !paused, let active = plans.first(where: { $0.id == activeID }) else { return }
        for other in plans where other.enabled && other.id != activeID {
            remaining[other.id] = max(0, remaining[other.id, default: other.interval] - seconds)
            if remaining[other.id] == 0 && other.duration <= active.duration { skip(other) }
        }
    }
    mutating func finish(_ plan: BreakPlan, elapsed: Double = 0) {
        activeID = nil
        // Preserve start-to-start cadence instead of adding the rest duration to every interval.
        remaining[plan.id] = max(1, plan.interval - elapsed)
    }
    func next(_ plans: [BreakPlan]) -> BreakPlan? {
        plans.filter(\.enabled).min { remaining[$0.id, default: $0.interval] < remaining[$1.id, default: $1.interval] }
    }
    mutating func tick(seconds dt: Double, idle: Double, preferences p: Preferences, excluded: Bool = false, available: Bool = true) -> BreakPlan? {
        synchronize(p.plans)
        guard !paused, activeID == nil, available, dt > 0 else { return nil }
        // A delayed callback can be caused by background throttling, not just sleep.
        // Keep elapsed work time so an overdue break can still be delivered.
        let isIdle = p.idleMode != .ignore && idle >= p.idleThreshold
        for plan in p.plans where plan.enabled {
            if isIdle {
                if p.idleMode == .credit && idle >= p.idleThreshold * 2 {
                    remaining[plan.id] = min(plan.interval, remaining[plan.id, default: plan.interval] + dt)
                }
            } else { remaining[plan.id] = max(0, remaining[plan.id, default: plan.interval] - dt) }
        }
        guard !isIdle else { return nil }
        let due = p.plans.filter { $0.enabled && remaining[$0.id, default: $0.interval] <= 0 }
            .sorted { $0.duration > $1.duration }
        guard let candidate = due.first else { return nil }
        if excluded {
            for plan in due { skip(plan) }
            return nil
        }
        // Time Out's configured five-minute priority window favors the longer break.
        if p.plans.contains(where: { $0.enabled && $0.duration > candidate.duration && remaining[$0.id, default: $0.interval] <= 300 }) {
            skip(candidate)
            return nil
        }
        for plan in due where plan.id != candidate.id { skip(plan) }
        activeID = candidate.id
        return candidate
    }
}

struct SavedCountdown: Codable {
    var id: UUID
    var remaining: Double
    var interval: Double
    var enabled: Bool
}

/// Saves relative countdowns with a timestamp so elapsed time can be applied after relaunch.
struct SavedSchedule: Codable {
    var savedAt: Date
    var countdowns: [SavedCountdown]
    var paused: Bool
    var pauseUntil: Date?
}

extension Scheduler {
    func savedSchedule(plans: [BreakPlan], now: Date = Date(), pauseUntil: Date? = nil, activeElapsed: Double = 0) -> SavedSchedule {
        let countdowns = plans.map { plan in
            let value = plan.id == activeID ? max(1, plan.interval - max(0, activeElapsed)) : remaining[plan.id, default: plan.interval]
            return SavedCountdown(id: plan.id, remaining: value, interval: plan.interval, enabled: plan.enabled)
        }
        return SavedSchedule(savedAt: now, countdowns: countdowns, paused: paused, pauseUntil: pauseUntil)
    }
    mutating func restore(_ saved: SavedSchedule, plans: [BreakPlan], now: Date = Date()) -> Date? {
        reset(plans); activeID = nil
        let elapsed = max(0, now.timeIntervalSince(saved.savedAt))
        let countingSeconds: Double
        let restoredPauseUntil: Date?
        if saved.paused {
            if let until = saved.pauseUntil, now >= until {
                paused = false; restoredPauseUntil = nil
                countingSeconds = min(elapsed, max(0, now.timeIntervalSince(until)))
            } else {
                paused = true; restoredPauseUntil = saved.pauseUntil; countingSeconds = 0
            }
        } else { paused = false; restoredPauseUntil = nil; countingSeconds = elapsed }
        for plan in plans {
            guard let value = saved.countdowns.first(where: { $0.id == plan.id }),
                  value.interval == plan.interval, value.enabled == plan.enabled,
                  value.remaining.isFinite, value.remaining >= 0 else { continue }
            let timeLeft = value.remaining - (plan.enabled ? countingSeconds : 0)
            // A break that was missed while the app was quit starts a fresh interval.
            // Relaunch never invents completed/skipped breaks or an interruption backlog.
            remaining[plan.id] = timeLeft > 0 ? timeLeft : plan.interval
        }
        return restoredPauseUntil
    }
}

func clockText(_ seconds: Double) -> String {
    let value = max(0, Int(ceil(seconds)))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}
