# Developing Breather

[Back to the README](../README.md). Read [AGENTS.md](../AGENTS.md) before making changes; detailed app behavior is in [Usage](usage.md).

## Building and installing

Requires macOS 13 or later and Apple’s Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/WubbLord/breather.git
cd breather
zsh build.sh
open build/Breather.app
```

The build runs the scheduler, priority, break-timing, countdown-persistence, history, and scroll-gesture tests, then creates an ad hoc signed app at `build/Breather.app`. It builds for your Mac’s native architecture. To install, quit an existing copy of Breather and drag the built app into Applications. Distribution builds are not notarized.

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

The menu-bar dropdown prepares its commands before native menu tracking starts. Its contents and menu-bar label stay stable while open, and the label catches up immediately on dismissal; countdowns continue underneath. A due break closes the dropdown before its overlay appears. The isolated `--status-menu-test` checks immediate visibility changes, restored preferences after relaunch, live countdowns while hidden, fresh registrations on enable, stable registration during countdown ticks, repeated toggles, unchanged schedules/history, and then menu preparation, stable tracking, live scheduling, native cancellation, immediate label refresh, and safely hiding/re-registering the item while a real popup is tracking.

Break enable switches use Breather’s green with a smooth compositor-driven thumb and track transition. Their native click, keyboard, and accessibility behavior is retained. The isolated `--green-switches-test` checks immediate persistence, preserved countdowns, stable animation during timer updates, and rapid toggles, and renders both switch states.

The page tabs use Breather’s green colors and a compositor-driven sliding highlight. Native selection, keyboard handling, and accessibility remain available. Countdown updates do not restart the slide; rapid switches reverse smoothly from the visible position. Reduce Motion uses an immediate selection change. The isolated `--page-tabs-test` verifies animation continuity, stable updates, reversal, and final selection, and renders both pages.

The isolated `--activity-labels-test` renders the shared date labels and selected-day weekday summaries across seven-day, monthly, twenty-day, and hourly views without showing windows.

The isolated `--activity-appearance-test` renders the 7-day, 30-day, and hourly charts with sample history and verifies chart hit testing and mouse input.

`zsh test-ui.sh --overlay-layering-test` builds the production cover configuration for each display without showing it, verifies its final level stays above modal dialogs, floating palettes, and popup menus, and checks that keyboard focus and Space behavior remain passive. The cover level is assigned after enabling floating-panel behavior because that AppKit setting resets the window level.

`zsh test-ui.sh --countdown-pause-test` verifies that automatic and manual breaks (including disabled plans), both fades, completion, skipping, postponing, and previews preserve other countdowns. It also checks resumption and deferred idle resets, without showing windows or covers.

`zsh test-ui.sh --idle-reset-test` checks return-from-idle resets, saved countdowns, disabled/custom plans, priority waits, manual pauses, unchanged history, one reset per idle period, the inactivity threshold, Keep counting, and active-break preservation without displaying windows.

`zsh test-ui.sh --sleep-countdown-test` checks timer and priority preservation, sleep/wake, normal inactivity thresholds, overlapping notifications, manual pauses, partial-sleep progress, repeated sleeps, long-sleep completion, exact-duration boundaries, cross-midnight completion history, previews, and full-duration countdown resets for active and inactive schedules without displaying windows or actually sleeping the Mac.

`zsh test-ui.sh --background-startup-test` checks a hidden startup without activating a window, while verifying that automatic countdowns still advance. Updates can relaunch the installed app without bringing it forward using `open -g /Applications/Breather.app --args --background`.

Background drag-geometry checks cover return-to-origin cancellation, grab offsets, deliberate midpoint crossings, threshold stability, multiple-card reversal, and clipped/outside drops. Priority checks cover waiting through the entire higher break, user-defined order, dependent breaks, idle/pause, skip/postpone, settings changes, migration, and persistence. The isolated `--priority-ui-test` exercises the native grip mouse handlers in both directions, persistence, cancellation outside cards, first-mouse acceptance, stable hover/grabbing cursors, a full card following the pointer in both axes, preview cleanup on drop/cancellation, stability through dashboard updates, and the reorder operations used by the context menu, saved priority, unchanged countdowns/history, and the waiting indicator; it writes `/private/tmp/Breather-priority.png` and `/private/tmp/Breather-priority-drag.png`.

The isolated `--performance-test` samples actual compositor frames to verify smooth breathing in both directions, reversal, original scale ranges, and animations surviving updates. It also verifies the continuous ring and both fades, then measures process CPU time across both pages, repeated tab switching, closing/reopening the window, sleep/wake, and an animated preview break. It checks that steady-state CPU stays below the layout-loop regression threshold, animated-break CPU stays under its tighter budget, the native tab control and selection remain stable, and real scheduler callbacks and countdowns continue. It does not change production settings or history.

The source deliberately aliases SwiftUI’s State property wrapper to `ViewState` because this Mac’s SDK also exports a State macro whose implementation is absent from its command line tools.

## Performance constraints

The Breaks/Activity tabs use one native segmented control with plain text labels and a fixed size. This avoids a SwiftUI segmented-picker sizing loop that could keep one CPU core busy, even with the window closed. Countdown updates preserve its selection without reconfiguring the control.

Activity graphs refresh when history changes or you interact with the time range. Ordinary countdown ticks do not rebuild charts. Each graph render calculates its buckets and totals once, and hourly aggregation indexes events in one pass. The menu bar redraws its countdown only when the displayed text changes; the scheduler retains its quarter-second timing.

## Application identity and migration

Version 1.8.22 uses application identity `local.breather.desktop` to leave behind a stale macOS menu bar association that made Breather follow another application's visibility switch. All saved break data continues using `local.breather.app`; the identity update does not move or reset it. Breather's own macOS menu bar switch controls the new registration. When upgrading from the old identity, preserve the **Open Breather at login** setting by disabling the old registration before replacement and restoring it in the updated app. The installed binary's `--restore-login-after-identity-update` command can restore a previously enabled login registration without starting another timer; use it only when that setting was enabled before the upgrade. Launch the installed app through Finder or its login registration; use the isolated launcher for development UI checks.

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
