#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/module-cache build/Breather.app/Contents/MacOS build/Breather.app/Contents/Resources
xcrun swiftc -O -module-cache-path build/module-cache Sources/Scheduler.swift Tests/SchedulerTests.swift -o build/SchedulerTests
build/SchedulerTests
xcrun swiftc -O -module-cache-path build/module-cache Sources/Scheduler.swift Tests/PriorityTests.swift -o build/PriorityTests
build/PriorityTests
xcrun swiftc -O -module-cache-path build/module-cache Sources/Scheduler.swift Tests/BreakTimingTests.swift -o build/BreakTimingTests
build/BreakTimingTests
xcrun swiftc -O -module-cache-path build/module-cache Sources/Scheduler.swift Tests/CountdownPersistenceTests.swift -o build/CountdownPersistenceTests
build/CountdownPersistenceTests
xcrun swiftc -O -module-cache-path build/module-cache Sources/History.swift Tests/HistoryTests.swift -o build/HistoryTests
build/HistoryTests
xcrun swiftc -O -module-cache-path build/module-cache Sources/ActivityScroll.swift Tests/ActivityScrollTests.swift -o build/ActivityScrollTests
build/ActivityScrollTests
xcrun swiftc -module-cache-path build/module-cache Sources/Icon.swift -o build/MakeIcon
build/MakeIcon build/Breather.iconset
xcrun swiftc -O -module-cache-path build/module-cache -parse-as-library Sources/Scheduler.swift Sources/History.swift Sources/ActivityView.swift Sources/ActivityMouseView.swift Sources/ActivityScroll.swift Sources/BreakAnimation.swift Sources/BreakSwitch.swift Sources/Breather.swift -o build/Breather.app/Contents/MacOS/Breather -framework AppKit -framework QuartzCore -framework SwiftUI -framework Charts -framework IOKit -framework ServiceManagement
cp Info.plist build/Breather.app/Contents/Info.plist
if [[ -f build/Breather.icns ]]; then cp build/Breather.icns build/Breather.app/Contents/Resources/Breather.icns; fi
codesign --force --deep --sign - build/Breather.app
codesign --verify --deep --strict build/Breather.app
