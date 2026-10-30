# Changelog

## 1.0 (2026-10-30)

First release.

- A timeline of which apps used your microphone and camera, and for how long, kept for 30 days on your Mac
- Per-app microphone attribution from macOS's own audio system; camera on/off with the likeliest app, marked as a guess
- Apps that can read your keystrokes (keyboard event taps), separated from macOS's own services
- Red flags: used while the screen was locked, the first time an app uses a sensor, a process with no window
- Optional notifications for red flags and for new apps reading keystrokes
- macOS's own listeners (Siri's "Hey Siri", dictation) shown separately
- `peekside` command line: today, `--days`, `now`, `--json`
- Universal app (Apple silicon and Intel)
