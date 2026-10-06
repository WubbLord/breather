import Foundation

@main enum SchedulerTests {
    static func main() {
        var p = Preferences()
        let normal = p.plans[0], quick = p.plans[1]
        var s = Scheduler(); s.reset(p.plans)
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        for _ in 0..<1199 { expect(s.tick(seconds: 1, idle: 0, preferences: p) == nil, "Quick must not fire early") }
        expect(s.tick(seconds: 1, idle: 0, preferences: p)?.id == quick.id, "Quick fires at 20 minutes")
        expect(s.tick(seconds: 1, idle: 0, preferences: p) == nil, "No overlapping breaks")
        s.elapseDuringBreak(seconds: 20, plans: p.plans)
        s.finish(quick, elapsed: 20)
        expect(s.remaining[quick.id] == 1180 && s.remaining[normal.id] == 2380, "Quick maintains both start-to-start intervals")
        s.remaining[quick.id] = 0; s.remaining[normal.id] = 0
        s.activeID = nil
        expect(s.tick(seconds: 1, idle: 0, preferences: p)?.id == normal.id, "Longer break has priority")
        s.elapseDuringBreak(seconds: 300, plans: p.plans)
        s.finish(normal, elapsed: 300)
        expect(s.remaining[quick.id] == 900 && s.remaining[normal.id] == 3300, "Long rest satisfies simultaneous quick rest without cadence drift")
        s.postpone(quick, minutes: 5); expect(s.remaining[quick.id] == 300, "Postpone 5")
        s.postpone(quick, minutes: 10); expect(s.remaining[quick.id] == 600, "Postpone 10")
        s.skip(quick); expect(s.remaining[quick.id] == 1200, "Skip uses normal interval")
        s.paused = true; _ = s.tick(seconds: 10, idle: 0, preferences: p); expect(s.remaining[quick.id] == 1200, "Pause freezes countdown")
        s.paused = false
        _ = s.tick(seconds: 10, idle: 0, preferences: p, available: false); expect(s.remaining[quick.id] == 1200, "Outside work hours freezes countdown")
        s.remaining[quick.id] = 0; _ = s.tick(seconds: 1, idle: 0, preferences: p, excluded: true)
        expect(s.activeID == nil && s.remaining[quick.id] == 1200, "Meeting exclusion skips a due break")
        s.remaining[quick.id] = 100
        _ = s.tick(seconds: 1, idle: 61, preferences: p); expect(s.remaining[quick.id] == 100, "Idle pauses before credit")
        for _ in 0..<20 { _ = s.tick(seconds: 1, idle: 140, preferences: p) }
        expect(s.remaining[quick.id] == 120, "Natural rest gradually restores work time")
        for _ in 0..<1200 { _ = s.tick(seconds: 1, idle: 1400, preferences: p) }
        expect(s.remaining[quick.id] == 1200, "Prolonged idle restores a full interval")
        expect(s.remaining[normal.id]! <= normal.interval, "Idle credit is capped")
        s.remaining[quick.id] = 100; p.idleMode = .pause
        _ = s.tick(seconds: 1, idle: 300, preferences: p); expect(s.remaining[quick.id] == 100, "Pause idle policy never credits")
        p.idleMode = .ignore; _ = s.tick(seconds: 1, idle: 300, preferences: p); expect(s.remaining[quick.id] == 99, "Ignore idle keeps counting")
        _ = s.tick(seconds: 1000, idle: 0, preferences: p); expect(s.remaining[quick.id] == 1200, "Sleep gap resets timers")
        s.remaining[quick.id] = 0; s.remaining[normal.id] = 200
        expect(s.tick(seconds: 1, idle: 0, preferences: p) == nil && s.remaining[quick.id] == 1200, "Quick suppressed near normal break")
        p.plans[1].enabled = false; s.remaining[quick.id] = 0
        expect(s.tick(seconds: 1, idle: 0, preferences: p) == nil, "Disabled break cannot fire")
        p.plans.append(BreakPlan(name: "Stretch", interval: 600, duration: 30)); s.synchronize(p.plans)
        let stretch = p.plans.last!; expect(s.remaining[stretch.id] == 600, "Custom break starts with full interval")
        p.plans.removeLast(); s.synchronize(p.plans); expect(s.remaining[stretch.id] == nil, "Removed break leaves no timer")
        let roundTrip = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        expect(roundTrip.plans == p.plans && roundTrip.idleMode == p.idleMode, "Preferences preserve plan identity")
        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        var legacyPlans = legacy["plans"] as! [[String: Any]]
        for index in legacyPlans.indices { legacyPlans[index].removeValue(forKey: "allowSkipping"); legacyPlans[index].removeValue(forKey: "allowPostponing") }
        legacy["plans"] = legacyPlans
        let migrated = try! JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(migrated.plans == p.plans && migrated.idleMode == p.idleMode, "New controls preserve old schedules and preferences and default to allowed")
        for allowSkip in [false, true] {
            for allowPostpone in [false, true] {
                var custom = quick
                custom.allowSkipping = allowSkip; custom.allowPostponing = allowPostpone
                let saved = try! JSONDecoder().decode(BreakPlan.self, from: JSONEncoder().encode(custom))
                expect(saved == custom, "Skip/postpone controls persist independently")
            }
        }
        expect(clockText(0.1) == "00:01" && clockText(3600) == "1:00:00", "Countdown rounds up")
        print("Scheduler tests passed: deadlines, priority, pause, postpone, skip, idle policies, meeting rules, sleep, custom plans, persistence, control migration")
    }
}
