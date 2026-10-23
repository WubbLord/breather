# Development checks

Build with `zsh build.sh`. Run native UI checks through `zsh test-ui.sh --<check>-test`; the launcher isolates the test application's identity and preferences from the installed app.

Use `testCheck` and `testFailure` for development-check failures, including callbacks. They print the failing source location and exit with status 1. Do not use trapping assertions (`precondition`, `preconditionFailure`, `assert`, or `fatalError`) for expected test failures: they trigger disruptive macOS “quit unexpectedly” dialogs. Keep failures visible to the test runner; do not disable system crash reporting or catch and hide genuine application faults.

Launch the installed production app normally through Finder or `open /Applications/Breather.app`. Do not leave its executable running as a child of a tool execution session, where session cleanup can kill it and stop automatic breaks. Quit normally when updating to preserve countdowns and history.

# Keep the user's workspace undisturbed

The user works in other apps while Breather is being edited. Work entirely in the background whenever possible, including navigation and testing. Prefer shell commands, supported APIs, logs, and checks that do not activate an app or show windows. Do not repeatedly bring Breather, System Settings, Finder, or test popups to the foreground for progress checks.

Native UI checks can activate windows, show overlays, or open menus; the isolated test launcher does not make these checks invisible. Run only checks relevant to the change. When a check requires visible interaction, give the user a heads-up first and group the necessary interactions into one brief session. When restoring a production app that was already running, prefer a normal background launch (`open -g /Applications/Breather.app --args --background`) and preserve its previous window visibility where supported. Breather supports `--background` to suppress its initial window activation; `open -g` alone does not suppress the app’s own activation.

# Documentation

Keep README.md short: an introduction, basic features, build/install steps, and links. Put detailed behavior in [docs/usage.md](docs/usage.md) and verification, implementation, migration, and source-layout notes in [docs/development.md](docs/development.md). Update the relevant detailed document when behavior changes rather than adding another implementation paragraph to the README.

# Implementation constraints

- The application bundle ID is `local.breather.desktop`; saved preferences and history remain in `local.breather.app`. Preserve that distinction when updating or testing. Identity migration details are in the development guide.
- Keep page tabs and break switches as persistent native controls. Replacing/reconfiguring them on countdown ticks previously caused animation problems and a layout loop that consumed a CPU core. Ordinary ticks must not rebuild Activity charts or restart compositor animations.
- Assign a cover window’s level after `isFloatingPanel`; enabling floating-panel behavior resets its level. Keep covers nonactivating so keyboard input stays with the underlying app.
- Use the existing `ViewState` alias for SwiftUI’s State wrapper; this Mac’s command-line SDK also exports an unavailable State macro.
