# Changelog

## Unreleased

Fixes
- Apple's own apps were filed under "macOS" and hidden: FaceTime, Voice Memos, Photo Booth and Safari (which runs from a system cryptex), and web pages using the mic in Safari (WebKit's capture process). They now show as apps, light the menu bar eye and get red flags. Saved history is reclassified when it loads.
- A session no longer stretches across the time the Mac was asleep.
- A process that quit while being read no longer shows up as a nameless app with a "No window" flag.
- `peekside --days` rejects 0, negative and non-numbers instead of printing an empty future range.

Recording
- A pause of under 20 seconds (muting, switching devices) continues the session instead of starting a new one. On real history this joins about one session in five.
- Camera guesses: if an app starts the mic just after the camera comes on, the camera moves to that app; apps that can't use a camera (no camera usage description) are no longer guessed.
- Apps that can read keystrokes keep their "seen since" date across restarts.

Panel
- The header says how long the current use has lasted, and warns when it's a windowless process.
- "By app": each app's mic and camera time for the day, how often, and when last used.
- Hover the timeline to see which app a bar is, and when.
- ← and → step through days; "Back to today" returns.
- Copy an app's path from a session's menu.

Efficiency
- The panel clock ticks only while the panel is open; the menu bar icon is drawn once per state, app icons once per app, and processes are described once per pid instead of every second.
- History is written on a background queue.
- `--self-test` checks the recorder's logic, and runs in CI.

## 1.0.1 (2026-10-30)

- First run: a card offers Launch at login and red-flag notifications. Peekside only records while it's running, so without this, new users quietly got gaps in their timeline.
- The README opens with an animation of a call being picked up.

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
