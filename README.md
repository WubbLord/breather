# Breather

A small native macOS break timer with a minimal interface, custom breaks, a menu bar countdown, and activity graphs with unlimited history. Built with SwiftUI and AppKit. Settings and history stay on your Mac.

## Getting started

Requires macOS 13 or later and Apple’s Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/WubbLord/breather.git
cd breather
zsh build.sh
open build/Breather.app
```

The build runs the scheduler, priority, break-timing, countdown-persistence, history, and scroll-gesture tests, then creates an ad hoc signed app at `build/Breather.app`. It builds for your Mac’s native architecture. To install, quit an existing copy of Breather and drag the built app into Applications. Distribution builds are not notarized.

## Breaks

The default schedule is inspired by Time Out:

- **Quick:** 20 seconds every 20 minutes.
- **Normal:** 5 minutes every hour.
- Five-second fades included in each break’s total duration, with five- and ten-minute postponement buttons.
- Pause countdowns after 60 seconds of inactivity; begin crediting natural rest after 120 seconds. Count back toward a fresh work interval while you remain away.
- Skip a due break while Zoom or FaceTime is frontmost. Favor a higher priority break over a lower one due within five minutes of it.
- On waking, reset each break to its full interval if time asleep covered that break’s full rest duration. Longer breaks retain their saved countdowns. An active break finishes if sleep covered its remaining rest; shorter sleeps resume it unchanged.
- Keep start-to-start cadence: a five-minute hourly break leaves about 55 minutes until the next one.

Click a schedule’s name to edit it, use the plus button to add one, and use Settings to adjust idle behavior, work hours, sounds, opacity, postponement, or opening at login. Close the window with Command-W, File → Close, or its close button; the timer keeps running in the menu bar. Reopen it through Show Breather in the menu bar or the Dock icon. Preview uses a ten-second break and preserves the schedule and statistics.

In Settings → Menu bar, **Show countdown in menu bar** controls Breather’s leaf and countdown. It starts enabled, remembers your choice after quitting, unregisters the item when disabled, and registers a fresh item each time it is enabled. You can also choose **Hide menu bar timer** from its dropdown. Hiding it leaves automatic breaks and countdowns running. When the app indicates idleness, the menu bar shows just **Idle** to save space; the normal countdown returns when activity resumes. Reopen Breather from the Dock and enable the setting to show it again. The dropdown offers starting a break when none is active, pausing/resuming, showing the app, hiding the timer, and quitting; skip, postpone, and reset commands are absent.

Version 1.8.22 uses application identity `local.breather.desktop` to leave behind a stale macOS menu bar association that made Breather follow another application's visibility switch. All saved break data continues using `local.breather.app`; the identity update does not move or reset it. Breather's own macOS menu bar switch controls the new registration. When upgrading from the old identity, preserve the **Open Breather at login** setting by disabling the old registration before replacement and restoring it in the updated app. The installed binary's `--restore-login-after-identity-update` command can restore a previously enabled login registration without starting another timer; use it only when that setting was enabled before the upgrade. Launch the installed app through Finder or its login registration; use the isolated launcher for development UI checks.

A break’s duration includes its fade-in and fade-out. For example, a 20-second break with three-second fades spends three seconds fading in, 14 seconds fully visible, and three seconds fading out. Core Animation continuously moves the countdown ring and eases the cover opacity on a shared timeline, independent of the quarter-second scheduler. The two breathing circles also run on compositor layers: four seconds expanding and four seconds contracting, with the same sizes and easing, without per-frame SwiftUI updates. Countdown changes leave those animations running rather than restarting them, and changing displays catches up to their original timeline. The countdown runs throughout, and completion/rest time is recorded only after the full duration ends. Fades shorten automatically to at most half the duration each for very short breaks. Each running break keeps the fade setting it started with; changes apply to the next break. Skip and Postpone have filled, outlined buttons with a pressed state. Either action immediately removes every break cover, including during a fade; normal completion still fades out.

Each break card has a **Take now** button that starts that specific break with its saved duration and skip/postpone settings. Manual starts work even when automatic scheduling for that break is off or countdowns are paused. The button is unavailable while another break is active or the Mac is asleep.

Breaks appear in priority order, highest first. Existing schedules initially sort by break duration; drag the green dotted handle at the left of a card and release at the green insertion marker to change their significance. The handle highlights on hover with a grab cursor. During a drag, the full card follows your pointer with a grabbing cursor and a light shadow; a dashed placeholder marks its original position. The card must clearly pass another card’s center before its insertion marker changes. Small movements around that threshold keep the marker steady, and bringing the card back near its original position cancels the reorder. Dropping outside the list also cancels the move. Native layers move a single cached card image without per-mouse-movement dashboard updates. The new order saves immediately and controls simultaneous breaks and the five-minute collision window. You can also right-click a card to move it up or down. New breaks start at the bottom of the list.

When a break completes, if a higher priority break is due before its next countdown would end, its countdown waits instead. Its card shows **Waiting for [break name]**, and the main countdown shows the next break that is actually counting. The waiting countdown resumes from its saved value after the higher priority break finishes, including both fades. If several higher priority breaks qualify, the most significant one controls the wait. Postponing that break keeps the wait; skipping, disabling, deleting, or moving it below the waiting break releases it. Taking a waiting break manually remains available.

The **Pause** dropdown pauses all automatic break countdowns for 15 minutes, 30 minutes, 1 hour, 1 day (24 hours), or until you resume. The same options are available in the menu bar. Timed pauses resume automatically and persist across app restarts; **Resume** ends a pause early.

When inactivity pauses your countdowns, the main countdown card shows **Idle — countdown paused**, and enabled break cards show **Idle** next to their timers. The indicator clears when mouse or keyboard activity resumes. On that return, breaks whose full rest duration was covered by time after entering Idle restart their full countdown intervals, including disabled and custom breaks; longer breaks retain their countdowns. The initial detection threshold is excluded from rest credit: with a five-minute threshold, six minutes without input counts as one minute of rest for resets. This works with pause and credit modes; Keep counting ignores idle resets. An active break continues normally, and resetting upcoming breaks does not add completion statistics or cancel manual pauses. The credit-for-time-away mode shows **Idle — time away** instead.

Each break has separate **Allow skipping** and **Allow postponing** switches in its editor. Both default to on, including for saved breaks from earlier versions. Turning one off removes its break-screen buttons and blocks that action in the timer. Pausing cannot dismiss an active break with skipping disabled. Automatic scheduling rules for idle time, sleep, meeting apps, and break priority still apply. You can always quit the app normally.

The break enable switches use persistent native macOS controls. Countdown refreshes leave their on/off animations alone, and a click immediately updates and saves the chosen break. Turning a break off freezes its remaining countdown; turning it back on resumes from that value. The saved countdown survives quitting while the break is off. Sleep resets it when time away covers its full rest duration, just like enabled breaks. Changing its interval or explicitly resetting countdowns starts a fresh interval.

The Breaks/Activity tabs use one native segmented control with plain text labels and a fixed size. This avoids a SwiftUI segmented-picker sizing loop that could keep one CPU core busy, even with the window closed. Countdown updates preserve its selection without reconfiguring the control.

Break covers stay above application windows on every display, desktop Space, and full-screen Space, including when switching apps or using Stage Manager. The cover does not take keyboard focus: typing, Tab, Escape, and normal app/window shortcuts continue to reach the underlying app. Click the cover’s Skip or Postpone buttons when allowed. Escape no longer skips a break. Ending a break leaves focus with whichever app you are currently using.

## Countdown persistence

Quitting saves the countdowns and their timestamp. Reopening subtracts the time that elapsed while Breather was quit, preserving upcoming deadlines and postponements. A countdown that became overdue while quit starts a fresh interval; missed breaks do not add statistics or cause a backlog. Paused countdowns stay paused, and a timed pause starts counting again from its expiration. Disabled breaks stay frozen.

Priority waits also persist across quits: waiting countdowns stay frozen until the higher priority break is taken or the wait is released. Missing a break while quit does not count as taking it. Sleep preserves countdowns until wake, which resets breaks whose full rest duration was satisfied and releases their priority waits. Explicitly resetting countdowns starts fresh timers and clears their priority waits.

Quitting during a break preserves the next scheduled start time without treating the interrupted break as completed. Breather also checkpoints countdowns every 15 seconds and whenever schedules or break controls change. Version 1.3 introduces this saved schedule, so the first upgrade from an older version starts fresh countdowns.

Break screens are delivered while Breather is running, including when its window is closed. No break is displayed while the app is quit; only elapsed time is applied when it reopens. The existing sleep and wake handling remains in effect while the app is running.

While schedules are running, Breather uses a macOS activity assertion to keep its timer responsive in the background while allowing normal system sleep. Delayed timer callbacks preserve elapsed work time instead of restarting countdowns. Sleep, lock, and screen saver notifications freeze future countdowns. If time asleep is at least the remaining duration of an active break, wake records it as completed and resets its countdown to a full interval without showing its cover again. Time already spent in the active break counts toward satisfying that break; it does not have to sleep for the original full duration. Shorter sleeps resume the active break unchanged. Completion is credited once, for its configured duration, to the day its remaining rest was satisfied. On waking, every break whose configured rest duration is at most the sleep duration gets a full new countdown interval, including disabled, custom, waiting, and postponed breaks. Breaks requiring more rest keep their saved countdowns. This does not add activity entries for breaks that were never started, and manual pauses remain in effect. Idle detection uses the normal macOS inactivity reading, without adding sleeping time. Idle policies apply again after waking. Repeated or overlapping notifications preserve the original sleep boundary and wait until all sleep/lock conditions have cleared. Due breaks bring their screens forward even when Breather was hidden.

Breather keeps its settings and daily break totals in its own local macOS preferences. It makes no network requests and does not record keystrokes or app usage. Time Out’s executable, themes, icons, and other assets are not included. Calendar rules, arbitrary scripts, web themes, and Time Out’s other optional integrations are outside this implementation.

## Activity

The Activity tab retains daily totals, break timestamps, and skip/postpone events indefinitely, including through app restarts. It opens with the most recent **7 days** by default. Its two graphs show completed rest time and completed, skipped, and postponed breaks. Choose **All time**, **30 days**, **7 days**, **1 day**, **6 hours**, or **1 hour** from the time-scale menu. Day and six-hour views use hours on the x-axis; the one-hour view uses 15-minute ticks. The four statistics summarize the visible range. Click a bar to inspect its totals. In the daily Break Activity graph, each day’s three bars sit together beneath a centered date label, with extra space and a divider between days that matches the horizontal grid lines.

Over either graph, hold **Option** while scrolling, or use a trackpad pinch, to zoom continuously around the pointer. Ordinary vertical scrolling moves the page even when the pointer is over a graph. Scroll horizontally, use Shift-wheel, or drag to move the time range without changing its scale. Sideways gestures keep their pan direction through small vertical movements and momentum. Option-scroll zoom waits for clearly vertical motion and uses a gentler sensitivity; pinch zoom works as before. Both graphs stay synchronized. Arrows move by one visible range, and Today returns to the current day. Zoom and pan can reach all saved history. Long views combine daily summaries into monthly bars to keep multi-year graphs efficient; zoom back in to see individual days and hours.

Activity graphs refresh when history changes or you interact with the time range. Ordinary countdown ticks do not rebuild charts. Each graph render calculates its buckets and totals once, and hourly aggregation indexes events in one pass. The menu bar redraws its countdown only when the displayed text changes; the scheduler retains its quarter-second timing.

The hourly graphs use real completion, skip, and postponement timestamps. Timestamp recording for actual breaks began with version 1.6; version 1.7 also timestamps actions on future breaks. Earlier daily totals remain visible in the daily graphs, and a small note explains when older activity has no exact times. No historical times are invented. Completed rest is credited when the break completes; interrupted sessions and previews do not contribute. All timestamped data is retained indefinitely along with daily totals. Data deleted by older versions cannot be recovered.

Rest time includes fully completed breaks and is credited to the day they complete. Skip/postpone counts reflect manual actions, including actions on the next scheduled break. Previews, automatic scheduling exclusions, and idle or sleeping time do not add activity. Existing daily totals migrate into history on the first launch of version 1.1; earlier days that the original version discarded cannot be recovered.

## Build and verify

Build and run the optional UI checks from the repository directory:

```sh
zsh build.sh
zsh test-ui.sh --ui-smoke-test
zsh test-ui.sh --activity-appearance-test
zsh test-ui.sh --status-menu-test
zsh test-ui.sh --green-switches-test
zsh test-ui.sh --page-tabs-test
zsh test-ui.sh --priority-ui-test
zsh test-ui.sh --performance-test
```

The UI check launcher uses a separate application bundle ID as well as isolated preferences, keeping test status items separate from the installed app in macOS Control Center. It deletes its temporary bundle when the check finishes. Failed UI checks print `TEST FAILED` with their source location and exit with status 1, rather than deliberately trapping and triggering macOS’s “quit unexpectedly” alerts. The build verifies both synchronous failures and failures in a main-run-loop callback. Use this launcher for development checks; open the installed app normally through Finder or `open /Applications/Breather.app`, and quit it normally when updating.

The build runs deterministic idle-reset, sleep-reset, scheduler, break-timing, countdown-persistence, history, and scroll-gesture checks and ad hoc signs the app. Countdown checks cover elapsed quit time, overdue recovery, both pause types, postponement, changed/disabled/deleted plans, interrupted breaks, and clock changes. History checks cover unlimited retention, multi-year persistence, monthly totals, old hourly detail, daylight-saving transitions, midnight rollover, and migration. Scroll checks cover gesture locking, vertical jitter, momentum, zoom dead zones, ordinary page scrolling, Option-scroll zoom, and Shift-scroll. The UI smoke test runs in the macOS graphical session, briefly displays test windows, verifies controls, persisted activity, automatic break completion, and that real timer callbacks do not rebuild Activity graphs, and writes rendered screenshots to `/private/tmp/Breather-*.png`. Chart screenshots use sample data only in the isolated test preferences domain, so they do not alter normal settings.

On recent macOS versions, System Settings → Menu Bar → Allow in the Menu Bar can independently block an app even while its own toggle is on. Allow Breather there if its item is missing. The app’s registration checks cannot establish whether macOS is actually displaying the item: Apple confirms that the system permission can override the app while `isVisible` still reports true ([Apple Developer discussion](https://developer.apple.com/forums/thread/801489)).

The menu-bar dropdown prepares its commands before native menu tracking starts. Its contents and menu-bar label stay stable while open, and the label catches up immediately on dismissal; countdowns continue underneath. A due break closes the dropdown before its overlay appears. The isolated `--status-menu-test` checks immediate visibility changes, restored preferences after relaunch, live countdowns while hidden, fresh registrations on enable, stable registration during countdown ticks, repeated toggles, unchanged schedules/history, and then menu preparation, stable tracking, live scheduling, native cancellation, immediate label refresh, and safely hiding/re-registering the item while a real popup is tracking.

Break enable switches use Breather’s green with a smooth compositor-driven thumb and track transition. Their native click, keyboard, and accessibility behavior is retained. The isolated `--green-switches-test` checks immediate persistence, preserved countdowns, stable animation during timer updates, and rapid toggles, and renders both switch states.

The page tabs use Breather’s green colors and a compositor-driven sliding highlight. Native selection, keyboard handling, and accessibility remain available. Countdown updates do not restart the slide; rapid switches reverse smoothly from the visible position. Reduce Motion uses an immediate selection change. The isolated `--page-tabs-test` verifies animation continuity, stable updates, reversal, and final selection, and renders both pages.

The isolated `--activity-appearance-test` renders the 7-day, 30-day, and hourly charts with sample history and verifies chart hit testing and mouse input.

`zsh test-ui.sh --overlay-layering-test` builds the production cover configuration for each display without showing it, verifies its final level stays above modal dialogs, floating palettes, and popup menus, and checks that keyboard focus and Space behavior remain passive. The cover level is assigned after enabling floating-panel behavior because that AppKit setting resets the window level.

`zsh test-ui.sh --idle-reset-test` checks return-from-idle resets, saved countdowns, disabled/custom plans, priority waits, manual pauses, unchanged history, one reset per idle period, the inactivity threshold, Keep counting, and active-break preservation without displaying windows.

`zsh test-ui.sh --sleep-countdown-test` checks timer and priority preservation, sleep/wake, normal inactivity thresholds, overlapping notifications, manual pauses, short-sleep resume, long-sleep completion, exact-duration boundaries, cross-midnight completion history, previews, and full-duration countdown resets for active and inactive schedules without displaying windows or actually sleeping the Mac.

`zsh test-ui.sh --background-startup-test` checks a hidden startup without activating a window, while verifying that automatic countdowns still advance. Updates can relaunch the installed app without bringing it forward using `open -g /Applications/Breather.app --args --background`.

Background drag-geometry checks cover return-to-origin cancellation, grab offsets, deliberate midpoint crossings, threshold stability, multiple-card reversal, and clipped/outside drops. Priority checks cover waiting through the entire higher break, user-defined order, dependent breaks, idle/pause, skip/postpone, settings changes, migration, and persistence. The isolated `--priority-ui-test` exercises the native grip mouse handlers in both directions, persistence, cancellation outside cards, first-mouse acceptance, stable hover/grabbing cursors, a full card following the pointer in both axes, preview cleanup on drop/cancellation, stability through dashboard updates, and the reorder operations used by the context menu, saved priority, unchanged countdowns/history, and the waiting indicator; it writes `/private/tmp/Breather-priority.png` and `/private/tmp/Breather-priority-drag.png`.

The isolated `--performance-test` samples actual compositor frames to verify smooth breathing in both directions, reversal, original scale ranges, and animations surviving updates. It also verifies the continuous ring and both fades, then measures process CPU time across both pages, repeated tab switching, closing/reopening the window, sleep/wake, and an animated preview break. It checks that steady-state CPU stays below the layout-loop regression threshold, animated-break CPU stays under its tighter budget, the native tab control and selection remain stable, and real scheduler callbacks and countdowns continue. It does not change production settings or history.

The source deliberately aliases SwiftUI’s State property wrapper to `ViewState` because this Mac’s SDK also exports a State macro whose implementation is absent from its command line tools.

Opening at login uses macOS Service Management. If macOS requires approval, allow Breather in System Settings → General → Login Items.

## Source layout

- `Sources/Breather.swift` — interface, app lifecycle, break overlays, and UI smoke checks.
- `Sources/BreakAnimation.swift` — compositor-driven progress ring, fades, and native animation checks.
- `Sources/BreakSwitch.swift` — native green break enable switches that preserve animation across countdown updates.
- `Sources/PriorityDragTarget.swift` — pointer-to-card geometry and deliberate, reversible drop targeting.
- `Sources/PriorityDragGrip.swift` — native drag handles, stable cursors, card geometry, and compositor-backed drag previews, including inactive windows.
- `Sources/PageTabs.swift` — native page tabs with a green sliding highlight, stable selection, and fixed sizing.
- `Sources/Scheduler.swift` — break schedules, preferences, and countdown persistence.
- `Sources/History.swift` — daily totals, timed outcomes, graph aggregation, and unlimited retention.
- `Sources/ActivityView.swift` — activity graphs, continuous zoom, and range selection.
- `Sources/ActivityScroll.swift` — scroll direction locking and zoom dead zones.
- `Sources/ActivityMouseView.swift` — native wheel, pinch, drag, and horizontal scroll controls.
- `Sources/Icon.swift` — app icon generation.
- `Tests/` — scheduler, timing, persistence, history, and scroll-gesture checks.
- `build.sh` — build, test, package, and sign the app.
- `test-ui.sh` — run native UI checks under a separate application identity.

Generated apps and build artifacts are excluded from Git.
