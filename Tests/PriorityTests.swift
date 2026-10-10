import Foundation

@main enum PriorityTests {
    static func main() {
        func expect(_ value: Bool, _ message: String) { precondition(value, message) }
        var p = Preferences()
        let normal = p.plans[0], quick = p.plans[1]
        var s = Scheduler(); s.reset(p.plans)
        s.remaining[normal.id] = 600
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor[quick.id] == normal.id && s.remaining[quick.id] == 1180, "Completed Quick waits for the upcoming higher-priority Normal")
        expect(s.next(p.plans)?.id == normal.id, "Next countdown excludes waiting breaks")
        expect(s.tick(seconds: 599, idle: 0, preferences: p) == nil && s.remaining[quick.id] == 1180, "Waiting countdown stays frozen before the higher break starts")
        expect(s.tick(seconds: 1, idle: 0, preferences: p)?.id == normal.id, "Higher break still starts on time")
        s.elapseDuringBreak(seconds: 300, plans: p.plans)
        expect(s.remaining[quick.id] == 1180 && s.waitingFor[quick.id] == normal.id, "Waiting includes the higher break's full duration")
        s.finish(normal, plans: p.plans, elapsed: 300)
        expect(s.waitingFor[quick.id] == nil && s.remaining[quick.id] == 1180, "Completion releases the preserved countdown")
        _ = s.tick(seconds: 60, idle: 0, preferences: p)
        expect(s.remaining[quick.id] == 1120, "Countdown resumes after higher completion")

        s.reset(p.plans); s.remaining[normal.id] = 1200
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor.isEmpty, "A higher break scheduled after the new countdown does not hold it")
        s.remaining[normal.id] = 600; s.finish(quick, plans: p.plans)
        p.idleMode = .credit
        _ = s.tick(seconds: 30, idle: 1000, preferences: p)
        expect(s.remaining[quick.id] == 1200, "Idle credit leaves a waiting countdown unchanged")
        s.paused = true; _ = s.tick(seconds: 30, idle: 0, preferences: p)
        expect(s.waitingFor[quick.id] == normal.id && s.remaining[quick.id] == 1200, "Pause preserves the priority wait")
        s.paused = false; s.postpone(normal, minutes: 20)
        expect(s.waitingFor[quick.id] == normal.id, "Postponing the higher break retains the wait")
        s.skip(normal)
        expect(s.waitingFor.isEmpty, "Skipping the awaited occurrence releases dependent countdowns")

        for change in 0..<3 {
            var changed = p
            s.reset(p.plans); s.remaining[normal.id] = 600; s.finish(quick, plans: p.plans)
            if change == 0 { changed.plans[0].enabled = false }
            if change == 1 { changed.plans.removeFirst() }
            if change == 2 { changed.plans.reverse() }
            s.synchronize(changed.plans)
            expect(s.waitingFor.isEmpty && s.remaining[quick.id] == 1200, "Disable, delete, and priority reversal release obsolete waits without resetting countdowns")
        }
        p.plans.reverse(); s.reset(p.plans)
        s.remaining[normal.id] = 0; s.remaining[quick.id] = 0
        expect(s.tick(seconds: 1, idle: 0, preferences: p)?.id == quick.id, "User order wins over duration when breaks are simultaneously due")
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor[quick.id] == nil, "Top-priority break never waits for a lower break")

        let medium = BreakPlan(name: "Stretch", interval: 800, duration: 30)
        p.plans = [normal, medium, quick]; s.reset(p.plans)
        s.remaining[normal.id] = 500; s.remaining[medium.id] = 100
        s.finish(quick, plans: p.plans)
        expect(s.waitingFor[quick.id] == normal.id, "Among upcoming higher breaks, the most significant one controls the wait")
        s.waitingFor = [medium.id: normal.id]; s.remaining[normal.id] = 1000; s.remaining[medium.id] = 600
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor[quick.id] == normal.id, "Transitive waits remain ordered without cycles")
        s.remaining[normal.id] = 1300
        s.finish(quick, plans: p.plans, elapsed: 20)
        expect(s.waitingFor[quick.id] == nil, "An already-waiting higher break cannot falsely appear to start earlier")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        p.plans = [normal, medium, quick]; s.reset(p.plans)
        s.waitingFor[quick.id] = medium.id
        s.remaining[medium.id] = 10; s.activeID = normal.id
        s.elapseDuringBreak(seconds: 20, plans: p.plans)
        expect(s.waitingFor[quick.id] == normal.id && s.remaining[quick.id] == 1200, "When a higher cover absorbs the awaited break, wait through that cover's completion")
        s.finish(normal, plans: p.plans, elapsed: 300)
        expect(s.waitingFor[quick.id] == nil, "Absorbing cover completion releases transitive dependents")
        p.plans = [normal, quick]; s.reset(p.plans); s.remaining[normal.id] = 600
        s.finish(quick, plans: p.plans, elapsed: 20)
        let saved = try! JSONDecoder().decode(SavedSchedule.self, from: JSONEncoder().encode(s.savedSchedule(plans: p.plans, now: now)))
        var restored = Scheduler()
        _ = restored.restore(saved, plans: p.plans, now: now.addingTimeInterval(60))
        expect(restored.remaining[quick.id] == 1180 && restored.remaining[normal.id] == 540 && restored.waitingFor[quick.id] == normal.id, "Waiting persists while only running countdowns advance across quit")
        _ = restored.restore(saved, plans: p.plans, now: now.addingTimeInterval(3600))
        expect(restored.remaining[quick.id] == 1180 && restored.waitingFor[quick.id] == normal.id, "Missed higher breaks create no fake completion and keep the wait")
        var legacySaved = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        var countdowns = legacySaved["countdowns"] as! [[String: Any]]
        for index in countdowns.indices { countdowns[index].removeValue(forKey: "waitingFor") }
        legacySaved["countdowns"] = countdowns
        let legacySchedule = try! JSONDecoder().decode(SavedSchedule.self, from: JSONSerialization.data(withJSONObject: legacySaved))
        _ = restored.restore(legacySchedule, plans: p.plans, now: now)
        expect(restored.waitingFor.isEmpty, "Older schedules migrate without invented waits")

        p.plans = [quick, medium, normal]
        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        legacy.removeValue(forKey: "priorityOrderVersion")
        var migrated = try! JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        migrated.migratePriorityOrder()
        expect(migrated.plans.map(\.id) == [normal.id, medium.id, quick.id], "Existing breaks initially sort by duration, most significant first")
        migrated.plans.reverse()
        var customOrder = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(migrated))
        customOrder.migratePriorityOrder()
        expect(customOrder.plans == migrated.plans, "A saved user order is never resorted")
        print("Priority tests passed: completion waits, full-duration release, user order, idle/pause, postponement, skip, disable/delete/reorder, transitive waits, quit persistence, and migration")
    }
}
