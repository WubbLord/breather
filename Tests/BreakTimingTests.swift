import Foundation

@main enum BreakTimingTests {
    static func main() {
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let quick = BreakTiming(duration: 20, fade: 3)
        expect(quick.phase(after: 0) == .arriving && quick.remaining(after: 0) == 20, "Countdown begins with the fade-in")
        expect(quick.phase(after: 2) == .arriving && quick.remaining(after: 2) == 18, "Fade-in consumes the duration")
        expect(quick.phase(after: 3) == .resting && quick.phase(after: 16.99) == .resting, "A 20-second break has 14 fully visible seconds between 3-second fades")
        expect(quick.phase(after: 17) == .returning && quick.remaining(after: 17) == 3, "Fade-out begins while the countdown is still running")
        expect(quick.phase(after: 19) == .returning && quick.remaining(after: 19) == 1, "Countdown continues during fade-out")
        expect(quick.phase(after: 20) == .finished && quick.remaining(after: 20) == 0, "Finish at the configured total duration")
        expect(quick.phase(after: 30) == .finished && quick.remaining(after: 30) == 0, "Delayed callbacks do not add another fade or rest phase")
        let normal = BreakTiming(duration: 300, fade: 5)
        expect(normal.phase(after: 5) == .resting && normal.phase(after: 295) == .returning && normal.phase(after: 300) == .finished, "Five-minute breaks include both fades")
        let noFade = BreakTiming(duration: 20, fade: 0)
        expect(noFade.phase(after: 0) == .resting && noFade.phase(after: 19.9) == .resting && noFade.phase(after: 20) == .finished, "Zero fades preserve the full rest period")
        let short = BreakTiming(duration: 4, fade: 10)
        expect(short.fade == 2 && short.phase(after: 1.9) == .arriving && short.phase(after: 2) == .returning && short.phase(after: 4) == .finished, "Short breaks shorten both fades to fit the duration")
        for duration in [1.0, 10, 20, 90, 300] {
            let timing = BreakTiming(duration: duration, fade: 5)
            expect(timing.fade * 2 <= duration && timing.phase(after: duration) == .finished, "Custom and preview durations share the same total-time contract")
        }
        expect(BreakTiming(duration: 0, fade: 5).phase(after: 0) == .finished, "Zero duration finishes immediately")
        expect(BreakTiming(duration: .nan, fade: .infinity).duration == 0 && BreakTiming(duration: 20, fade: -1).fade == 0, "Invalid timing inputs cannot create unbounded fades")
        print("Break timing tests passed: total duration, continuous countdown, fade boundaries, short/custom breaks, zero fades, and delayed callbacks")
    }
}
