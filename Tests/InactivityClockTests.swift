import Foundation

@main enum InactivityClockTests {
    static func main() {
        var clock = InactivityClock()
        testCheck(clock.sample(raw: 120, events: 10) == 120)
        clock.sleep(now: 1000, raw: 120, events: 10)
        clock.sleep(now: 1010, raw: 0, events: 10)
        testCheck(clock.wake(now: 1060, raw: 0, events: 10) == 180, "Short sleep preserves earlier inactivity without crossing five minutes")
        testCheck(clock.sample(raw: 1, events: 10) == 181, "Idle correction survives awake polling")
        clock.sleep(now: 1061, raw: 1, events: 10)
        testCheck(clock.wake(now: 1241, raw: 181, events: 10) == 361, "Repeated sleeps accumulate inactivity, without double-counting a running hardware clock")
        testCheck(clock.sample(raw: 0, events: 11) == 0, "Mouse or keyboard activity clears sleep credit")
        clock.sleep(now: 2000, raw: 30, events: 11)
        testCheck(clock.wake(now: 2600, raw: 2, events: 12) == 2, "Input during wake or unlock resets inactivity")
        clock.sleep(now: 3000, raw: 45, events: 12)
        testCheck(clock.wake(now: 3600, raw: 645, events: 12) == 645, "Hardware clocks already including sleep receive no extra credit")
        clock.sleep(now: 4000, raw: 45, events: 12)
        testCheck(clock.wake(now: 4600, raw: 45, events: 12) == 645, "Stopped hardware clock receives the missing sleep time")
        testCheck(clock.sample(raw: 0, events: 12) == 0, "A raw input reset also clears the correction")
        clock.sleep(now: 5000, raw: 45, events: 12)
        testCheck(clock.wake(now: 4900, raw: 45, events: 12) == 45, "Clock corrections cannot subtract inactivity")
        print("Inactivity tests passed: short/long sleep, repeated notifications, paused/running/reset hardware clocks, and real input")
    }
}
