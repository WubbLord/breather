import Foundation

@main enum IdleResetTests {
    static func main() {
        var preferences = Preferences()
        preferences.idleMode = .pause; preferences.idleThreshold = 300
        let normal = preferences.plans[0], quick = preferences.plans[1]
        var tracker = IdleRestTracker()
        func sample(_ seconds: Double) -> Double? { tracker.returnedAfterIdle(seconds: seconds, preferences: preferences) }
        testCheck(sample(0) == nil && sample(20) == nil && sample(299.9) == nil)
        testCheck(sample(0) == nil, "The five-minute idle threshold still applies")
        testCheck(sample(300) == nil && sample(900) == nil, "Idle duration is collected without repeatedly resetting timers")
        testCheck(sample(0.1) == 900, "Returning from idle exposes the full observed inactivity duration")
        testCheck(sample(0.2) == nil && sample(0) == nil, "Continued typing cannot replay a past idle reset")
        var scheduler = Scheduler(); scheduler.reset(preferences.plans)
        scheduler.remaining[normal.id] = 17; scheduler.remaining[quick.id] = 3
        scheduler.resetAfterRest(seconds: 299, plans: preferences.plans)
        testCheck(scheduler.remaining[normal.id] == 17 && scheduler.remaining[quick.id] == quick.interval, "Break duration is distinct from its interval and remaining countdown")
        scheduler.resetAfterRest(seconds: 300, plans: preferences.plans)
        testCheck(scheduler.remaining[normal.id] == normal.interval, "An exact full break duration resets its full interval")
        for mode: IdleMode in [.pause, .credit] {
            preferences.idleMode = mode
            tracker.reset()
            testCheck(sample(600) == nil && sample(0) == 600, "Both idle pause and credit modes reset on return")
        }
        preferences.idleMode = .ignore
        testCheck(sample(900) == nil && sample(0) == nil, "Keep counting continues to ignore idle time")
        preferences.idleMode = .pause
        _ = sample(900); tracker.reset()
        testCheck(sample(0) == nil, "Sleep clears the awake idle tracker instead of combining the two behaviors")
        for invalid in [Double.nan, .infinity, -1] {
            _ = sample(900)
            testCheck(sample(invalid) == nil && sample(0) == nil, "Invalid input cannot fabricate an idle period")
        }
        print("Idle reset tests passed: threshold preservation, return from idle, single reset per period, exact rest durations, idle modes, and separate sleep tracking")
    }
}
