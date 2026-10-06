import Foundation

@main enum CountdownPersistenceTests {
    static func main() {
        let plans = BreakPlan.defaults
        let normal = plans[0], quick = plans[1]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var original = Scheduler(); original.reset(plans)
        original.remaining[quick.id] = 600; original.remaining[normal.id] = 1800
        let saved = original.savedSchedule(plans: plans, now: now)
        let decoded = try! JSONDecoder().decode(SavedSchedule.self, from: JSONEncoder().encode(saved))
        var restored = Scheduler()
        func expect(_ value: Bool, _ message: String) { precondition(value, message) }
        _ = restored.restore(decoded, plans: plans, now: now.addingTimeInterval(120))
        expect(restored.remaining[quick.id] == 480 && restored.remaining[normal.id] == 1680, "Both countdowns advance by elapsed quit time")
        expect(restored.activeID == nil && !restored.paused, "Relaunch restores deadlines without active breaks")
        _ = restored.restore(saved, plans: plans, now: now.addingTimeInterval(700))
        expect(restored.remaining[quick.id] == quick.interval && restored.remaining[normal.id] == 1100, "Only overdue countdowns get fresh intervals")
        _ = restored.restore(saved, plans: plans, now: now.addingTimeInterval(600))
        expect(restored.remaining[quick.id] == quick.interval, "Exact deadline is overdue")
        _ = restored.restore(saved, plans: plans, now: now.addingTimeInterval(86400))
        expect(restored.remaining[quick.id] == quick.interval && restored.remaining[normal.id] == normal.interval, "Long quit has no backlog")
        _ = restored.restore(saved, plans: plans, now: now.addingTimeInterval(-100))
        expect(restored.remaining[quick.id] == 600, "Clock moving backwards never lengthens countdowns")
        original.postpone(quick, minutes: 5)
        _ = restored.restore(original.savedSchedule(plans: plans, now: now), plans: plans, now: now.addingTimeInterval(60))
        expect(restored.remaining[quick.id] == 240, "Preserve postponed deadlines")
        original.remaining[quick.id] = 600
        original.paused = true
        let indefinitelyPaused = original.savedSchedule(plans: plans, now: now)
        let indefiniteUntil = restored.restore(indefinitelyPaused, plans: plans, now: now.addingTimeInterval(86400))
        expect(restored.paused && indefiniteUntil == nil && restored.remaining[quick.id] == 600, "Indefinite pause survives quitting")
        let until = now.addingTimeInterval(300)
        let temporarilyPaused = original.savedSchedule(plans: plans, now: now, pauseUntil: until)
        let futureUntil = restored.restore(temporarilyPaused, plans: plans, now: now.addingTimeInterval(60))
        expect(restored.paused && futureUntil == until && restored.remaining[quick.id] == 600, "Future timed pause remains frozen")
        let expiredUntil = restored.restore(temporarilyPaused, plans: plans, now: now.addingTimeInterval(360))
        expect(!restored.paused && expiredUntil == nil && restored.remaining[quick.id] == 540, "Count only time after timed pause expires")
        _ = restored.restore(temporarilyPaused, plans: plans, now: until)
        expect(!restored.paused && restored.remaining[quick.id] == 600, "Resume at pause expiry without premature countdown")
        var changed = plans; changed[1].interval = 900
        _ = restored.restore(saved, plans: changed, now: now.addingTimeInterval(120))
        expect(restored.remaining[quick.id] == 900 && restored.remaining[normal.id] == 1680, "Changed interval resets only that break")
        changed = plans; changed[1].enabled = false
        _ = restored.restore(saved, plans: changed, now: now.addingTimeInterval(120))
        expect(restored.remaining[quick.id] == quick.interval, "Changed enable state starts fresh")
        var disabled = original; disabled.paused = false
        _ = restored.restore(disabled.savedSchedule(plans: changed, now: now), plans: changed, now: now.addingTimeInterval(120))
        expect(restored.remaining[quick.id] == 600, "Disabled countdowns do not run while quit")
        let newPlan = BreakPlan(name: "Stretch", interval: 900, duration: 30)
        _ = restored.restore(saved, plans: [normal, newPlan], now: now.addingTimeInterval(60))
        expect(restored.remaining[quick.id] == nil && restored.remaining[newPlan.id] == 900, "Respect deleted and new plans")
        var active = original; active.paused = false; active.activeID = quick.id; active.remaining[quick.id] = 0
        let interrupted = active.savedSchedule(plans: plans, now: now, activeElapsed: 10)
        _ = restored.restore(interrupted, plans: plans, now: now.addingTimeInterval(60))
        expect(restored.remaining[quick.id] == quick.interval - 70 && restored.activeID == nil, "Quitting during a break preserves next start-to-start deadline")
        var corrupt = saved; corrupt.countdowns[1].remaining = -30
        _ = restored.restore(corrupt, plans: plans, now: now.addingTimeInterval(60))
        expect(restored.remaining[quick.id] == quick.interval, "Invalid remaining time falls back safely")
        print("Countdown persistence tests passed: elapsed quit time, postponed deadlines, overdue recovery, pauses, clock changes, disabled/custom plans, interrupted breaks, saved-data validation")
    }
}
