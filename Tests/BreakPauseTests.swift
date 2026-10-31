import Foundation

@main enum BreakPauseTests {
    static func main() {
        var p = Preferences(); p.idleMode = .ignore
        let normal = p.plans[0], quick = p.plans[1]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func fresh() -> Scheduler {
            var s = Scheduler(); s.reset(p.plans)
            s.remaining[normal.id] = 1800; s.remaining[quick.id] = 600
            return s
        }
        func expect(_ value: Bool, _ message: String) { testCheck(value, message) }
        var s = fresh()
        s.pauseBreak(quick.id)
        _ = s.tick(seconds: 60, idle: 0, preferences: p, now: now)
        expect(s.remaining[quick.id] == 600 && s.remaining[normal.id] == 1740, "Only the individually paused countdown freezes")
        expect(s.next(p.plans)?.id == normal.id, "Upcoming break excludes paused plans")
        s.remaining[quick.id] = 0
        expect(s.tick(seconds: 1, idle: 0, preferences: p, now: now) == nil && s.remaining[quick.id] == 0, "A due but paused break cannot fire")
        s.resumeBreak(quick.id)
        expect(s.tick(seconds: 1, idle: 0, preferences: p, now: now)?.id == quick.id, "Manual resume releases a due countdown")
        s.pauseBreak(quick.id)
        expect(!s.isBreakPaused(quick.id), "Pausing cannot dismiss or bypass an active break")

        s = fresh(); s.waitingFor[quick.id] = normal.id
        s.pauseBreak(normal.id)
        expect(s.waitingFor[quick.id] == nil && s.remaining[quick.id] == 600, "Pausing a higher break releases dependents without resetting them")
        s.remaining[normal.id] = 0; s.remaining[quick.id] = 0
        expect(s.tick(seconds: 1, idle: 0, preferences: p, now: now)?.id == quick.id, "A paused higher break does not suppress a lower break in the collision window")
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor[quick.id] == nil && s.timeUntilStart(normal, plans: p.plans).isInfinite, "Completed breaks do not wait for paused higher-priority breaks")

        s = fresh(); s.pauseBreak(quick.id, until: now.addingTimeInterval(30))
        _ = s.tick(seconds: 60, idle: 0, preferences: p, now: now.addingTimeInterval(60))
        expect(!s.isBreakPaused(quick.id) && s.remaining[quick.id] == 570 && s.remaining[normal.id] == 1740, "A delayed tick counts only the part after a timed break pause expires")
        s = fresh(); s.pauseBreak(quick.id, until: now.addingTimeInterval(30))
        _ = s.tick(seconds: 30, idle: 0, preferences: p, now: now.addingTimeInterval(30))
        expect(!s.isBreakPaused(quick.id) && s.remaining[quick.id] == 600, "Exact pause expiry resumes without charging paused time")
        s = fresh(); s.pauseBreak(quick.id)
        p.idleMode = .credit
        _ = s.tick(seconds: 60, idle: 1000, preferences: p, now: now)
        expect(s.remaining[quick.id] == 600 && s.remaining[normal.id] == 1860, "Ordinary idle credit does not move an individually paused timer")
        s.resetAfterRest(seconds: 300, plans: p.plans)
        expect(s.isBreakPaused(quick.id) && s.remaining[quick.id] == quick.interval, "Existing qualified sleep/idle resets preserve the individual pause")
        p.idleMode = .ignore

        s = fresh(); s.paused = true
        s.pauseBreak(quick.id, until: now.addingTimeInterval(30))
        _ = s.tick(seconds: 60, idle: 0, preferences: p, now: now.addingTimeInterval(60))
        expect(s.paused && !s.isBreakPaused(quick.id) && s.remaining[quick.id] == 600, "Expiry of an individual pause never overrides a global pause")
        s.pauseBreak(quick.id); s.paused = false
        _ = s.tick(seconds: 60, idle: 0, preferences: p, now: now.addingTimeInterval(120))
        expect(s.isBreakPaused(quick.id) && s.remaining[quick.id] == 600 && s.remaining[normal.id] == 1740, "Global resume does not clear individual pauses")

        var restored = Scheduler()
        s = fresh(); s.pauseBreak(quick.id)
        let indefinite = try! JSONDecoder().decode(SavedSchedule.self, from: JSONEncoder().encode(s.savedSchedule(plans: p.plans, now: now)))
        _ = restored.restore(indefinite, plans: p.plans, now: now.addingTimeInterval(3600))
        expect(restored.isBreakPaused(quick.id) && restored.remaining[quick.id] == 600 && restored.remaining[normal.id] == normal.interval, "Indefinite pause and exact countdown persist through a long quit")
        s = fresh(); s.pauseBreak(quick.id, until: now.addingTimeInterval(300))
        let timed = s.savedSchedule(plans: p.plans, now: now)
        _ = restored.restore(timed, plans: p.plans, now: now.addingTimeInterval(100))
        expect(restored.breakPauses[quick.id]?.until == now.addingTimeInterval(300) && restored.remaining[quick.id] == 600 && restored.remaining[normal.id] == 1700, "Timed individual pauses persist while other countdowns advance across quit")
        _ = restored.restore(timed, plans: p.plans, now: now.addingTimeInterval(360))
        expect(!restored.isBreakPaused(quick.id) && restored.remaining[quick.id] == 540, "Relaunch counts only quit time after an individual pause expires")
        _ = restored.restore(timed, plans: p.plans, now: now.addingTimeInterval(300))
        expect(restored.remaining[quick.id] == 600, "Exact expiry during quit preserves the held countdown")
        s.paused = true
        let overlapping = s.savedSchedule(plans: p.plans, now: now, pauseUntil: now.addingTimeInterval(420))
        _ = restored.restore(overlapping, plans: p.plans, now: now.addingTimeInterval(480))
        expect(!restored.paused && restored.remaining[quick.id] == 540 && restored.remaining[normal.id] == 1740, "Overlapping global and individual pauses count only time after both have ended")
        let earlierGlobal = s.savedSchedule(plans: p.plans, now: now, pauseUntil: now.addingTimeInterval(120))
        _ = restored.restore(earlierGlobal, plans: p.plans, now: now.addingTimeInterval(360))
        expect(restored.remaining[quick.id] == 540 && restored.remaining[normal.id] == 1560, "A later individual deadline still controls its own break after global resume")
        let globalIndefinite = s.savedSchedule(plans: p.plans, now: now)
        _ = restored.restore(globalIndefinite, plans: p.plans, now: now.addingTimeInterval(480))
        expect(restored.paused && !restored.isBreakPaused(quick.id) && restored.remaining[quick.id] == 600, "An expired individual deadline cannot advance countdowns during indefinite global pause")

        s = fresh(); s.pauseBreak(quick.id)
        p.plans[1].enabled = false; s.synchronize(p.plans)
        p.plans[1].enabled = true
        _ = s.tick(seconds: 60, idle: 0, preferences: p, now: now)
        expect(s.isBreakPaused(quick.id) && s.remaining[quick.id] == 600, "Disabling and re-enabling does not remove an individual pause")
        s.synchronize([normal])
        expect(s.breakPauses.isEmpty && s.remaining[quick.id] == nil, "Deleting a break removes its pause")
        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(timed)) as! [String: Any]
        legacy.removeValue(forKey: "breakPauses")
        let legacySaved = try! JSONDecoder().decode(SavedSchedule.self, from: JSONSerialization.data(withJSONObject: legacy))
        _ = restored.restore(legacySaved, plans: p.plans, now: now)
        expect(restored.breakPauses.isEmpty && restored.remaining[quick.id] == 600, "Old saved schedules load without inventing individual pauses")
        print("Break pause tests passed: independent countdowns, timed expiry, global overlap, priority, active/disabled/deleted breaks, rest resets, quit persistence, and migration")
    }
}
