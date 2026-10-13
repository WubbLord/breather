# Development checks

Build with `zsh build.sh`. Run native UI checks through `zsh test-ui.sh --<check>-test`; the launcher isolates the test application's identity and preferences from the installed app.

Use `testCheck` and `testFailure` for development-check failures, including callbacks. They print the failing source location and exit with status 1. Do not use trapping assertions (`precondition`, `preconditionFailure`, `assert`, or `fatalError`) for expected test failures: they trigger disruptive macOS “quit unexpectedly” dialogs. Keep failures visible to the test runner; do not disable system crash reporting or catch and hide genuine application faults.

Launch the installed production app normally through Finder or `open /Applications/Breather.app`. Do not leave its executable running as a child of a tool execution session, where session cleanup can kill it and stop automatic breaks. Quit normally when updating to preserve countdowns and history.
