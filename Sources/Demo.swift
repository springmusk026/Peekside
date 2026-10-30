import Foundation

/// Made-up history for screenshots, using apps that ship with every Mac (so their icons
/// render) and one unknown background helper to show a red flag.
enum Demo {
    /// A fixed afternoon, so screenshots are reproducible.
    static var now: Date { Calendar.current.date(bySettingHour: 16, minute: 40, second: 0, of: Date())! }

    static func app(_ name: String, _ path: String, background: Bool = false, system: Bool = false) -> AppInfo {
        AppInfo(name: name, bundleID: nil, path: path, system: system, background: background)
    }

    static let facetime = app("FaceTime", "/System/Applications/FaceTime.app")
    static let safari = app("Safari", "/Applications/Safari.app")
    static let memos = app("Voice Memos", "/System/Applications/VoiceMemos.app")
    static let booth = app("Photo Booth", "/System/Applications/Photo Booth.app")
    static let helper = app("SyncHelper", "/Users/Shared/.sync/SyncHelper", background: true)
    static let siri = app("Siri (listening for “Hey Siri”)", "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd", system: true)

    @MainActor
    static func recorder(active: Bool = true, empty: Bool = false) -> Recorder {
        Recorder(demo: empty ? [] : sessions(active: active), monitors: empty ? [] : monitors, now: now)
    }

    static func sessions(active: Bool) -> [Session] {
        let day = Calendar.current.startOfDay(for: now)
        func at(_ h: Int, _ m: Int) -> Date { day.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        func s(_ sensor: Sensor, _ app: AppInfo?, _ from: Date, _ to: Date?, _ flags: Set<Flag> = []) -> Session {
            Session(sensor: sensor, app: app, start: from, end: to, lastSeen: to ?? now, flags: flags)
        }
        var list = [
            s(.mic, siri, day, nil),
            s(.mic, facetime, at(9, 30), at(10, 15)),
            s(.camera, facetime, at(9, 30), at(10, 15), [.guessed]),
            s(.mic, safari, at(11, 5), at(11, 42), [.firstTime]),
            s(.camera, safari, at(11, 6), at(11, 42), [.guessed]),
            s(.mic, memos, at(13, 20), at(13, 34)),
            s(.mic, helper, at(3, 12), at(3, 31), [.locked, .background, .firstTime]),
            s(.camera, booth, at(14, 50), at(14, 53), [.guessed]),
        ]
        if active {
            list.append(s(.mic, facetime, at(16, 21), nil))
            list.append(s(.camera, facetime, at(16, 21), nil, [.guessed]))
        }
        return list
    }

    static var monitors: [KeyMonitor] {
        let since = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        return [
            KeyMonitor(app: app("Raycast-like launcher", "/Applications/Launcher.app"), firstSeen: since, lastSeen: now),
            KeyMonitor(app: app("Siri", "/System/Library/CoreServices/Siri.app", system: true), firstSeen: since, lastSeen: now),
            KeyMonitor(app: app("Accessibility", "/usr/libexec/universalaccessd", system: true), firstSeen: since, lastSeen: now),
        ]
    }
}
