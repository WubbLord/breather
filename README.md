# Breather

A minimal macOS app that reminds you to take breaks. Built with SwiftUI and AppKit; settings and history stay on your Mac.

- Custom breaks with full-screen covers and adjustable skip/postpone controls.
- A menu bar countdown, pause controls, and idle/sleep handling.
- Activity graphs with unlimited history.

The defaults are a 20-second break every 20 minutes and a five-minute break every hour.

## Build and install

Requires macOS 13 or later and Apple’s Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/WubbLord/breather.git
cd breather
zsh build.sh
open build/Breather.app
```

To install, quit any existing copy and move `build/Breather.app` into Applications. The build is signed locally and is not notarized.

## More information

- [Usage](docs/usage.md) — controls, scheduling, idle/sleep behavior, and activity history.
- [Development](docs/development.md) — build checks, implementation notes, and source layout.
- [Contributor instructions](AGENTS.md).
