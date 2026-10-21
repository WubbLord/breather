#!/bin/zsh
set -eu
cd "${0:A:h}"
case "${1:-}" in
    --ui-smoke-test|--break-actions-test|--priority-ui-test|--performance-test|--activity-appearance-test|--page-tabs-test|--green-switches-test|--status-menu-test|--background-startup-test|--sleep-countdown-test|--overlay-layering-test|--idle-reset-test) ;;
    *) print -u2 'Usage: zsh test-ui.sh --<UI-check>-test'; exit 2 ;;
esac
[[ $# == 1 && -x build/Breather.app/Contents/MacOS/Breather ]]
# Control Center tracks status items by application identity. Isolate the test
# bundle as well as its preferences so tests cannot replace a running app's item.
breather_ui_stage=$(mktemp -d /private/tmp/Breather-ui-tests.XXXXXX)
trap 'rm -rf "$breather_ui_stage"' EXIT
breather_ui_app="$breather_ui_stage/Breather UI Tests.app"
ditto build/Breather.app "$breather_ui_app"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier local.breather.ui-tests' "$breather_ui_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleName Breather UI Tests' "$breather_ui_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName Breather UI Tests' "$breather_ui_app/Contents/Info.plist"
codesign --force --deep --sign - "$breather_ui_app"
breather_ui_args=("$1" -ApplePersistenceIgnoreState YES)
if [[ "$1" == --background-startup-test || "$1" == --sleep-countdown-test || "$1" == --overlay-layering-test || "$1" == --idle-reset-test ]]; then breather_ui_args+=(--background); fi
"$breather_ui_app/Contents/MacOS/Breather" "${breather_ui_args[@]}"
