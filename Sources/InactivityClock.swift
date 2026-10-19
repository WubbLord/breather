import Foundation

/// IOHID's idle clock can stop or restart over sleep. Carry only the missing
/// time forward, and discard that correction as soon as real input arrives.
struct InactivityClock {
    private var correction: Double = 0
    private var previousRaw: Double = 0
    private var previousEvents: UInt32?
    private var sleepStart: Double?
    private var idleAtSleep: Double = 0
    private var eventsAtSleep: UInt32 = 0

    mutating func sample(raw: Double, events: UInt32) -> Double {
        let raw = raw.isFinite ? max(0, raw) : 0
        if let previousEvents, events != previousEvents || raw + 0.05 < previousRaw {
            correction = 0
        }
        previousRaw = raw; previousEvents = events
        return raw + correction
    }

    mutating func sleep(now: Double, raw: Double, events: UInt32) {
        guard sleepStart == nil else { return }
        idleAtSleep = sample(raw: raw, events: events)
        eventsAtSleep = events; sleepStart = now
    }

    mutating func wake(now: Double, raw: Double, events: UInt32) -> Double {
        guard let start = sleepStart else { return sample(raw: raw, events: events) }
        sleepStart = nil
        let raw = raw.isFinite ? max(0, raw) : 0
        correction = events == eventsAtSleep ? max(0, idleAtSleep + max(0, now - start) - raw) : 0
        previousRaw = raw; previousEvents = events
        return raw + correction
    }
}
