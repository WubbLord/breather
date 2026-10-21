import Foundation

@main enum SleepResetTests {
    static func main() {
        let normal = BreakPlan(name: "Normal", interval: 3600, duration: 300)
        let quick = BreakPlan(name: "Quick", interval: 1200, duration: 20, enabled: false)
        let stretch = BreakPlan(name: "Stretch", interval: 7200, duration: 900)
        let plans = [normal, quick, stretch]
        var scheduler = Scheduler(); scheduler.reset(plans)
        scheduler.remaining[normal.id] = 17
        scheduler.remaining[quick.id] = 0
        scheduler.remaining[stretch.id] = 300
        scheduler.waitingFor[quick.id] = normal.id
        scheduler.waitingFor[stretch.id] = normal.id
        let original = scheduler.remaining, waits = scheduler.waitingFor
        for seconds in [Double.nan, .infinity, -1, 0, 19.99] {
            scheduler.resetAfterSleep(seconds: seconds, plans: plans)
            testCheck(scheduler.remaining == original && scheduler.waitingFor == waits, "Short or invalid sleep preserves countdowns and waits")
        }
        scheduler.resetAfterSleep(seconds: 20, plans: plans)
        testCheck(scheduler.remaining[quick.id] == quick.interval && scheduler.remaining[normal.id] == 17, "Exactly a full break duration resets even a disabled break; countdown remaining is irrelevant")
        testCheck(scheduler.waitingFor[quick.id] == nil && scheduler.waitingFor[stretch.id] == normal.id, "Only satisfied priority waits are released")
        scheduler.paused = true
        scheduler.postpone(normal, minutes: 5)
        scheduler.resetAfterSleep(seconds: 299.99, plans: plans)
        testCheck(scheduler.remaining[normal.id] == 300 && scheduler.remaining[stretch.id] == 300, "Each break has its own full-duration threshold")
        scheduler.resetAfterSleep(seconds: 300, plans: plans)
        testCheck(scheduler.remaining[normal.id] == normal.interval && scheduler.remaining[stretch.id] == 300, "Qualifying breaks restart full intervals while longer breaks stay frozen")
        testCheck(scheduler.paused && scheduler.waitingFor[stretch.id] == nil, "Sleep preserves a global pause while releasing satisfied dependents")
        scheduler.resetAfterSleep(seconds: 86400, plans: plans)
        testCheck(plans.allSatisfy { scheduler.remaining[$0.id] == $0.interval }, "Long sleep resets all normal, disabled, and custom breaks")
        let data = try! JSONEncoder().encode(scheduler.savedSchedule(plans: plans))
        let saved = try! JSONDecoder().decode(SavedSchedule.self, from: data)
        testCheck(saved.paused && saved.countdowns.allSatisfy { $0.remaining == $0.interval }, "Reset countdowns and global pause persist")
        print("Sleep reset tests passed: per-break durations, exact thresholds, disabled/custom/postponed breaks, priority waits, paused schedules, and persistence")
    }
}
