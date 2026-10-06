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

The build runs the scheduler, countdown-persistence, and history tests, then creates an ad hoc signed app at `build/Breather.app`. It builds for your Mac’s native architecture. To install, quit an existing copy of Breather and drag the built app into Applications. Distribution builds are not notarized.

## Breaks

The default schedule is inspired by Time Out:

- **Quick:** 20 seconds every 20 minutes.
- **Normal:** 5 minutes every hour.
- Five-second fades, with five- and ten-minute postponement buttons.
- Pause countdowns after 60 seconds of inactivity; begin crediting natural rest after 120 seconds. Count back toward a fresh work interval while you remain away.
- Skip a due break while Zoom or FaceTime is frontmost. Favor a longer break over a shorter one due within five minutes of it.
- Start fresh countdowns after sleep, screen lock, or the screen saver.
- Keep start-to-start cadence: a five-minute hourly break leaves about 55 minutes until the next one.

Click a schedule’s name to edit it, use the plus button to add one, and use Settings to adjust idle behavior, work hours, sounds, opacity, postponement, or opening at login. Closing the window keeps the timer running in the menu bar. Preview uses a ten-second break and preserves the schedule and statistics.

Each break card has a **Take now** button that starts that specific break with its saved duration and skip/postpone settings. Manual starts work even when automatic scheduling for that break is off or countdowns are paused. The button is unavailable while another break is active or the Mac is asleep.

The **Pause** dropdown pauses all automatic break countdowns for 15 minutes, 1 hour, 1 day (24 hours), or until you resume. The same options are available in the menu bar. Timed pauses resume automatically and persist across app restarts; **Resume** ends a pause early.

Each break has separate **Allow skipping** and **Allow postponing** switches in its editor. Both default to on, including for saved breaks from earlier versions. Turning one off removes its break-screen buttons and menu-bar actions and blocks that action in the timer. Pausing cannot dismiss an active break with skipping disabled. Automatic scheduling rules for idle time, sleep, meeting apps, and break priority still apply. You can always quit the app normally.

Break covers stay above application windows on every display, desktop Space, and full-screen Space, including when switching apps or using Stage Manager. The cover does not take keyboard focus: typing, Tab, Escape, and normal app/window shortcuts continue to reach the underlying app. Click the cover’s Skip or Postpone buttons when allowed. Escape no longer skips a break. Ending a break leaves focus with whichever app you are currently using.

## Countdown persistence

Quitting saves the countdowns and their timestamp. Reopening subtracts the time that elapsed while Breather was quit, preserving upcoming deadlines and postponements. A countdown that became overdue while quit starts a fresh interval; missed breaks do not add statistics or cause a backlog. Paused countdowns stay paused, and a timed pause starts counting again from its expiration. Disabled breaks stay frozen.

Quitting during a break preserves the next scheduled start time without treating the interrupted break as completed. Breather also checkpoints countdowns every 15 seconds and whenever schedules or break controls change. Version 1.3 introduces this saved schedule, so the first upgrade from an older version starts fresh countdowns.

Break screens are delivered while Breather is running, including when its window is closed. No break is displayed while the app is quit; only elapsed time is applied when it reopens. The existing sleep and wake handling remains in effect while the app is running.

While schedules are running, Breather uses a macOS activity assertion to keep its timer responsive in the background while allowing normal system sleep. Delayed timer callbacks preserve elapsed work time instead of restarting countdowns. Actual sleep, lock, and screen saver notifications still reset the schedule; repeated wake notifications while already awake do not reset it again. Due breaks bring their screens forward even when Breather was hidden.

Breather keeps its settings and daily break totals in its own local macOS preferences. It makes no network requests and does not record keystrokes or app usage. Time Out’s executable, themes, icons, and other assets are not included. Calendar rules, arbitrary scripts, web themes, and Time Out’s other optional integrations are outside this implementation.

## Activity

The Activity tab keeps today and the previous 29 calendar days, including through app restarts. Switch between 7-day and 30-day graphs for completed rest time and completed, skipped, and postponed breaks. Click a day in either graph or use the previous/next day buttons to inspect its totals. Older entries are automatically removed.

Rest time includes fully completed breaks and is credited to the day they complete. Skip/postpone counts reflect manual actions, including actions on the next scheduled break. Previews, automatic scheduling exclusions, and idle or sleeping time do not add activity. Existing daily totals migrate into history on the first launch of version 1.1; earlier days that the original version discarded cannot be recovered.

## Build and verify

Build and run the optional UI checks from the repository directory:

```sh
zsh build.sh
build/Breather.app/Contents/MacOS/Breather --ui-smoke-test
```

The build runs deterministic scheduler, countdown-persistence, and history checks and ad hoc signs the app. Countdown checks cover elapsed quit time, overdue recovery, both pause types, postponement, changed/disabled/deleted plans, interrupted breaks, and clock changes. History checks cover retention across daylight-saving transitions, midnight rollover, migration, persistence, and totals. The UI smoke test runs in the macOS graphical session, briefly displays test windows, verifies controls, persisted activity, and automatic break completion, and writes rendered screenshots to `/private/tmp/Breather-*.png`. Chart screenshots use sample data only in the isolated test preferences domain, so they do not alter normal settings.

The source deliberately aliases SwiftUI’s State property wrapper to `ViewState` because this Mac’s SDK also exports a State macro whose implementation is absent from its command line tools.

Opening at login uses macOS Service Management. If macOS requires approval, allow Breather in System Settings → General → Login Items.

## Source layout

- `Sources/Breather.swift` — interface, app lifecycle, break overlays, and UI smoke checks.
- `Sources/Scheduler.swift` — break schedules, preferences, and countdown persistence.
- `Sources/History.swift` — daily totals and 30-day retention.
- `Sources/ActivityView.swift` — activity charts and day selection.
- `Sources/Icon.swift` — app icon generation.
- `Tests/` — scheduler, persistence, and history checks.
- `build.sh` — build, test, package, and sign the app.

Generated apps and build artifacts are excluded from Git.
