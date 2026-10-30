# Contributing

Thanks for helping. Peekside is small on purpose: one SwiftUI app, no dependencies, no Xcode project.

## Build and run

```sh
./build.sh              # build, install to ~/Applications and launch
./build.sh --no-install # build into build/ only
```

You need the Xcode command line tools (Swift 6) and macOS 14 or later.

## Where things live

- `Sources/Sensors.swift`: reads the microphone (CoreAudio process objects), camera (CoreMediaIO) and keyboard taps. Public APIs only.
- `Sources/Recorder.swift`: turns one-second readings into sessions, flags and history.
- `Sources/PanelView.swift`: the panel, built from the tokens in `Sources/Design.swift` (shared with Portside and Sweepside).

Render every state in light and dark with demo data before opening a PR that changes the UI:

```sh
build/Peekside.app/Contents/MacOS/Peekside --snapshot /tmp/peekside-shots
build/Peekside.app/Contents/MacOS/Peekside --demo-gif docs/demo.gif
```

## Principles

Peekside never sends anything anywhere, never needs admin rights, and says so when it's guessing
(the camera's app). Features that would break any of these are out of scope.
