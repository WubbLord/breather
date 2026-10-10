# Breather

A small native macOS break timer with a minimal interface, custom breaks, a menu bar countdown, and 30 days of activity graphs. Built with SwiftUI and AppKit. Settings and history stay on your Mac.

## Getting started

Requires macOS 13 or later and Apple’s Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/WubbLord/breather.git
cd breather
zsh build.sh
open build/Breather.app
```

The build runs the scheduler, break-timing, countdown-persistence, history, and scroll-gesture tests, then creates an ad hoc signed app at `build/Breather.app`. It builds for your Mac’s native architecture. To install, quit an existing copy of Breather and drag the built app into Applications. Distribution builds are not notarized.

## Breaks

The default schedule is inspired by Time Out:

- **Quick:** 20 seconds every 20 minutes.
- **Normal:** 5 minutes every hour.
- Five-second fades included in each break’s total duration, with five- and ten-minute postponement buttons.
- Pause countdowns after 60 seconds of inactivity; begin crediting natural rest after 120 seconds. Count back toward a fresh work interval while you remain away.
- Skip a due break while Zoom or FaceTime is frontmost. Favor a longer break over a shorter one due within five minutes of it.
- Start fresh enabled countdowns after sleep, screen lock, or the screen saver; disabled countdowns stay frozen.
- Keep start-to-start cadence: a five-minute hourly break leaves about 55 minutes until the next one.

Click a schedule’s name to edit it, use the plus button to add one, and use Settings to adjust idle behavior, work hours, sounds, opacity, postponement, or opening at login. Close the window with Command-W, File → Close, or its close button; the timer keeps running in the menu bar. Reopen it through Show Breather in the menu bar or the Dock icon. Preview uses a ten-second break and preserves the schedule and statistics.

A break’s duration includes its fade-in and fade-out. For example, a 20-second break with three-second fades spends three seconds fading in, 14 seconds fully visible, and three seconds fading out. Core Animation continuously moves the countdown ring and eases the cover opacity on a shared timeline, independent of the quarter-second scheduler. The countdown runs throughout, and completion/rest time is recorded only after the full duration ends. Fades shorten automatically to at most half the duration each for very short breaks. Each running break keeps the fade setting it started with; changes apply to the next break. Changing displays catches up to the current animation position. Skip and Postpone have filled, outlined buttons with a pressed state. Either action immediately removes every break cover, including during a fade; normal completion still fades out.

Each break card has a **Take now** button that starts that specific break with its saved duration and skip/postpone settings. Manual starts work even when automatic scheduling for that break is off or countdowns are paused. The button is unavailable while another break is active or the Mac is asleep.

The **Pause** dropdown pauses all automatic break countdowns for 15 minutes, 1 hour, 1 day (24 hours), or until you resume. The same options are available in the menu bar. Timed pauses resume automatically and persist across app restarts; **Resume** ends a pause early.

When inactivity pauses your countdowns, the main countdown card shows **Idle — countdown paused**, and enabled break cards show **Idle** next to their timers. The indicator clears when mouse or keyboard activity resumes. The credit-for-time-away mode shows **Idle — time away** instead.

Each break has separate **Allow skipping** and **Allow postponing** switches in its editor. Both default to on, including for saved breaks from earlier versions. Turning one off removes its break-screen buttons and menu-bar actions and blocks that action in the timer. Pausing cannot dismiss an active break with skipping disabled. Automatic scheduling rules for idle time, sleep, meeting apps, and break priority still apply. You can always quit the app normally.

The break enable switches use persistent native macOS controls. Countdown refreshes leave their on/off animations alone, and a click immediately updates and saves the chosen break. Turning a break off freezes its remaining countdown; turning it back on resumes from that value. The saved countdown survives quitting, sleep, and screen lock while the break is off. Changing its interval or explicitly resetting countdowns starts a fresh interval.

Break covers stay above application windows on every display, desktop Space, and full-screen Space, including when switching apps or using Stage Manager. The cover does not take keyboard focus: typing, Tab, Escape, and normal app/window shortcuts continue to reach the underlying app. Click the cover’s Skip or Postpone buttons when allowed. Escape no longer skips a break. Ending a break leaves focus with whichever app you are currently using.

## Countdown persistence

Quitting saves the countdowns and their timestamp. Reopening subtracts the time that elapsed while Breather was quit, preserving upcoming deadlines and postponements. A countdown that became overdue while quit starts a fresh interval; missed breaks do not add statistics or cause a backlog. Paused countdowns stay paused, and a timed pause starts counting again from its expiration. Disabled breaks stay frozen.

Quitting during a break preserves the next scheduled start time without treating the interrupted break as completed. Breather also checkpoints countdowns every 15 seconds and whenever schedules or break controls change. Version 1.3 introduces this saved schedule, so the first upgrade from an older version starts fresh countdowns.

Break screens are delivered while Breather is running, including when its window is closed. No break is displayed while the app is quit; only elapsed time is applied when it reopens. The existing sleep and wake handling remains in effect while the app is running.

While schedules are running, Breather uses a macOS activity assertion to keep its timer responsive in the background while allowing normal system sleep. Delayed timer callbacks preserve elapsed work time instead of restarting countdowns. Actual sleep, lock, and screen saver notifications still reset the schedule; repeated wake notifications while already awake do not reset it again. Due breaks bring their screens forward even when Breather was hidden.

Breather keeps its settings and daily break totals in its own local macOS preferences. It makes no network requests and does not record keystrokes or app usage. Time Out’s executable, themes, icons, and other assets are not included. Calendar rules, arbitrary scripts, web themes, and Time Out’s other optional integrations are outside this implementation.

## Activity

The Activity tab keeps today and the previous 29 calendar days, including through app restarts. It opens with the most recent **7 days** by default. Its two graphs show completed rest time and completed, skipped, and postponed breaks. Choose **30 days**, **7 days**, **1 day**, **6 hours**, or **1 hour** from the time-scale menu. Day and six-hour views use hours on the x-axis; the one-hour view uses 15-minute ticks. The four statistics summarize the visible range. Click a bar to inspect its totals.

Over either graph, use the mouse wheel or a trackpad pinch to zoom continuously around the pointer. Scroll horizontally, use Shift-wheel, or drag to move the time range without changing its scale. Sideways gestures keep their pan direction through small vertical movements and momentum. Scroll zoom waits for clearly vertical motion and uses a gentler sensitivity; pinch zoom works as before. Both graphs stay synchronized. Arrows move by one visible range, and Today returns to the current day. Zoom and pan stay within the retained 30 days.

Activity graphs refresh when history changes or you interact with the time range. Ordinary countdown ticks do not rebuild charts. Each graph render calculates its buckets and totals once, and hourly aggregation indexes events in one pass. The menu bar redraws its countdown only when the displayed text changes; the scheduler retains its quarter-second timing.

The hourly graphs use real completion, skip, and postponement timestamps. Timestamp recording for actual breaks began with version 1.6; version 1.7 also timestamps actions on future breaks. Earlier daily totals remain visible in the daily graphs, and a small note explains when older activity has no exact times. No historical times are invented. Completed rest is credited when the break completes; interrupted sessions and previews do not contribute. All timestamped data uses the same 30-day retention as daily totals.

Rest time includes fully completed breaks and is credited to the day they complete. Skip/postpone counts reflect manual actions, including actions on the next scheduled break. Previews, automatic scheduling exclusions, and idle or sleeping time do not add activity. Existing daily totals migrate into history on the first launch of version 1.1; earlier days that the original version discarded cannot be recovered.

## Build and verify

Build and run the optional UI checks from the repository directory:

```sh
zsh build.sh
build/Breather.app/Contents/MacOS/Breather --ui-smoke-test
```

The build runs deterministic scheduler, break-timing, countdown-persistence, history, and scroll-gesture checks and ad hoc signs the app. Countdown checks cover elapsed quit time, overdue recovery, both pause types, postponement, changed/disabled/deleted plans, interrupted breaks, and clock changes. History checks cover retention across daylight-saving transitions, midnight rollover, migration, persistence, and totals. Scroll checks cover gesture locking, vertical jitter, momentum, zoom dead zones, and Shift-scroll. The UI smoke test runs in the macOS graphical session, briefly displays test windows, verifies controls, persisted activity, automatic break completion, and that real timer callbacks do not rebuild Activity graphs, and writes rendered screenshots to `/private/tmp/Breather-*.png`. Chart screenshots use sample data only in the isolated test preferences domain, so they do not alter normal settings.

The source deliberately aliases SwiftUI’s State property wrapper to `ViewState` because this Mac’s SDK also exports a State macro whose implementation is absent from its command line tools.

Opening at login uses macOS Service Management. If macOS requires approval, allow Breather in System Settings → General → Login Items.

## Source layout

- `Sources/Breather.swift` — interface, app lifecycle, break overlays, and UI smoke checks.
- `Sources/BreakAnimation.swift` — compositor-driven progress ring, fades, and native animation checks.
- `Sources/BreakSwitch.swift` — native break enable switches that preserve animation across countdown updates.
- `Sources/Scheduler.swift` — break schedules, preferences, and countdown persistence.
- `Sources/History.swift` — daily totals, timed outcomes, graph aggregation, and 30-day retention.
- `Sources/ActivityView.swift` — activity graphs, continuous zoom, and range selection.
- `Sources/ActivityScroll.swift` — scroll direction locking and zoom dead zones.
- `Sources/ActivityMouseView.swift` — native wheel, pinch, drag, and horizontal scroll controls.
- `Sources/Icon.swift` — app icon generation.
- `Tests/` — scheduler, timing, persistence, history, and scroll-gesture checks.
- `build.sh` — build, test, package, and sign the app.

Generated apps and build artifacts are excluded from Git.
