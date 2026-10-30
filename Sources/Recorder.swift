// Turns one-second sensor readings into sessions ("Zoom used the microphone 10:02–10:47"),
// flags the ones worth a look, and keeps 30 days of history in
// ~/Library/Application Support/Peekside, one file per day.

import AppKit
import SwiftUI
import UserNotifications

enum Sensor: String, Codable, CaseIterable {
    case mic, camera

    var title: String { self == .mic ? "Microphone" : "Camera" }
    var icon: String { self == .mic ? "mic.fill" : "video.fill" }
    var color: Color { self == .mic ? .mic : .camera }
}

enum Flag: String, Codable, CaseIterable, Comparable {
    case locked       // started or continued while the screen was locked
    case firstTime    // the first time this app used this sensor since Peekside started watching
    case background   // a process with no window or Dock icon
    case guessed      // camera only: macOS doesn't say which app, so this is the likeliest one

    var label: String {
        switch self {
        case .locked:     return "While locked"
        case .firstTime:  return "First time"
        case .background: return "No window"
        case .guessed:    return "Likely"
        }
    }

    var help: String {
        switch self {
        case .locked:     return "Used while your screen was locked."
        case .firstTime:  return "The first time Peekside has seen this app use it."
        case .background: return "A background process with no window or Dock icon."
        case .guessed:    return "macOS doesn't say which app turned the camera on. This is the app that started the microphone at the same moment, or the app you were using."
        }
    }

    /// Flags that deserve a notification.
    var alerts: Bool { self == .locked || self == .firstTime || self == .background }

    static func < (a: Flag, b: Flag) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    let sensor: Sensor
    /// Nil when the camera was on and no app could be named.
    let app: AppInfo?
    let start: Date
    var end: Date?
    /// Last time it was seen running; becomes the end if Peekside quits mid-session.
    var lastSeen: Date
    var flags: Set<Flag> = []

    var isOpen: Bool { end == nil }
    var system: Bool { app?.system == true }
    func finish(_ now: Date) -> Date { end ?? now }
    func duration(_ now: Date) -> TimeInterval { finish(now).timeIntervalSince(start) }
    var sortedFlags: [Flag] { flags.sorted() }
}

struct KeyMonitor: Codable, Identifiable, Equatable {
    var id: String { app.path }
    let app: AppInfo
    let firstSeen: Date
    var lastSeen: Date
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var sessions: [Session] = []      // the last 30 days, oldest first
    @Published private(set) var monitors: [KeyMonitor] = []   // apps that can read keystrokes now
    @Published private(set) var now = Date()

    @AppStorage("alerts") var alerts = false
    @AppStorage("watchingSince") private var watchingSince = 0.0

    private var seen: [String: Set<String>] = [:]   // sensor -> app paths ever seen using it
    private var missing: [String: Int] = [:]          // open session key -> ticks not seen
    private var loop: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private let demo: Bool

    init(demo sessions: [Session]? = nil, monitors: [KeyMonitor] = [], now: Date = Date()) {
        demo = sessions != nil
        if let sessions {
            self.sessions = sessions
            self.monitors = monitors
            self.now = now
            return
        }
        if watchingSince == 0 { watchingSince = Date().timeIntervalSince1970 }
        load()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.closeAll() }
        }
    }

    var since: Date { Date(timeIntervalSince1970: watchingSince) }
    var active: [Session] { sessions.filter { $0.isOpen && !$0.system } }

    // MARK: Sampling

    private func tick() {
        now = Date()
        let locked = Sensors.screenLocked()

        // Microphone: one session per app (helpers count as their app)
        var micApps: [String: AppInfo] = [:]
        for pid in Sensors.microphone() {
            let app = AppInfo.of(pid: pid)
            micApps[app.path] = app
        }
        for (path, app) in micApps { observe(.mic, key: path, app: app, locked: locked) }

        // Camera: macOS doesn't say who, so name the likeliest app and say so
        if Sensors.cameraOn() {
            if !sessions.contains(where: { $0.isOpen && $0.sensor == .camera }) {
                let app = cameraSuspect()
                observe(.camera, key: "camera", app: app, locked: locked, extra: app == nil ? [] : [.guessed])
            } else {
                observe(.camera, key: "camera", app: nil, locked: locked)
            }
        }

        let present = Set(micApps.keys.map { "mic|\($0)" } + (Sensors.cameraOn() ? ["camera|camera"] : []))
        closeMissing(present)
        updateMonitors()

        if sessions.contains(where: \.isOpen), now.timeIntervalSince(lastSave) > 30 { save() }
    }

    private func key(_ s: Session) -> String {
        s.sensor == .camera ? "camera|camera" : "mic|\(s.app?.path ?? "")"
    }

    private func observe(_ sensor: Sensor, key: String, app: AppInfo?, locked: Bool, extra: Set<Flag> = []) {
        let fullKey = "\(sensor.rawValue)|\(key)"
        missing[fullKey] = 0
        if let i = sessions.lastIndex(where: { $0.isOpen && self.key($0) == fullKey }) {
            sessions[i].lastSeen = now
            if locked && !sessions[i].system && !sessions[i].flags.contains(.locked) {
                sessions[i].flags.insert(.locked)
                notify(sessions[i], reason: .locked)
            }
            return
        }
        var flags = extra
        if let app, !app.system {
            if locked { flags.insert(.locked) }
            if app.background { flags.insert(.background) }
            if !(seen[sensor.rawValue]?.contains(app.path) ?? false) {
                // Apps already running when Peekside first starts aren't "new"
                if now.timeIntervalSince(since) > 60 { flags.insert(.firstTime) }
                seen[sensor.rawValue, default: []].insert(app.path)
            }
        } else if app == nil && locked {
            flags.insert(.locked)
        }
        let session = Session(sensor: sensor, app: app, start: now, lastSeen: now, flags: flags)
        sessions.append(session)
        save()
        if let reason = session.sortedFlags.first(where: \.alerts) { notify(session, reason: reason) }
    }

    /// Ends sessions not seen for two ticks in a row (a brief gap isn't a new session).
    private func closeMissing(_ present: Set<String>) {
        var changed = false
        for i in sessions.indices where sessions[i].isOpen {
            let k = key(sessions[i])
            if present.contains(k) { continue }
            missing[k, default: 0] += 1
            if missing[k]! >= 2 {
                sessions[i].end = sessions[i].lastSeen
                missing[k] = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// The app that most likely turned the camera on: one that started the microphone in
    /// the last few seconds (a call), else the app you're using.
    private func cameraSuspect() -> AppInfo? {
        let recent = sessions.last { $0.sensor == .mic && $0.isOpen && !$0.system && now.timeIntervalSince($0.start) < 8 }
        if let app = recent?.app { return app }
        return Sensors.frontmost.map(AppInfo.of(pid:)).flatMap { $0.system ? nil : $0 }
    }

    private func updateMonitors() {
        let apps = Dictionary(Sensors.keyboardMonitors().map { AppInfo.of(pid: $0) }.map { ($0.path, $0) },
                              uniquingKeysWith: { a, _ in a })
        var next: [KeyMonitor] = []
        for (path, app) in apps {
            if var existing = monitors.first(where: { $0.id == path }) {
                existing.lastSeen = now
                next.append(existing)
            } else {
                next.append(KeyMonitor(app: app, firstSeen: now, lastSeen: now))
                if !app.system && now.timeIntervalSince(since) > 60 && !(seen["keys"]?.contains(path) ?? false) {
                    notifyKeyboard(app)
                }
                seen["keys", default: []].insert(path)
            }
        }
        next.sort { ($0.app.system ? 1 : 0, $0.app.name) < ($1.app.system ? 1 : 0, $1.app.name) }
        if next != monitors { monitors = next }
    }

    private func closeAll() {
        for i in sessions.indices where sessions[i].isOpen { sessions[i].end = Date() }
        save()
    }

    // MARK: Days

    func sessions(on day: Date, includeSystem: Bool = false) -> [Session] {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        return sessions.filter { $0.start < end && $0.finish(now) > start && (includeSystem || !$0.system) }
    }

    /// Time the sensor was in use that day, counting overlapping sessions once.
    func total(_ sensor: Sensor, on day: Date) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86_400)
        let spans = sessions(on: day).filter { $0.sensor == sensor }
            .map { (max($0.start, start), min($0.finish(now), end)) }
            .sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for span in spans {
            if let c = current, span.0 <= c.1 { current = (c.0, max(c.1, span.1)) }
            else { if let c = current { total += c.1.timeIntervalSince(c.0) }; current = span }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    // MARK: Notifications

    private func notify(_ session: Session, reason: Flag) {
        guard alerts, !demo, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        let who = session.app?.name ?? "An app"
        let what = session.sensor == .mic ? "microphone" : "camera"
        switch reason {
        case .locked:     content.title = "\(who) is using the \(what) while your Mac is locked"
        case .firstTime:  content.title = "\(who) is using the \(what) for the first time"
        case .background: content.title = "\(who) is using the \(what) with no window open"
        case .guessed:    return
        }
        content.body = session.app.map { abbreviate($0.path) } ?? "macOS doesn't say which app."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil))
    }

    private func notifyKeyboard(_ app: AppInfo) {
        guard alerts, !demo, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) can now read what you type"
        content.body = "It's receiving every key press. If you didn't expect this, remove it in System Settings › Privacy & Security › Input Monitoring."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "keys-\(app.path)", content: content, trigger: nil))
    }

    static func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Storage

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peekside", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Saved: Codable {
        var sessions: [Session]
        var seen: [String: Set<String>]
    }

    private func save() {
        guard !demo else { return }
        lastSave = now
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        sessions.removeAll { $0.finish(now) < cutoff }
        Self.write(Saved(sessions: sessions, seen: seen))
    }

    nonisolated private static func write(_ saved: Saved) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(saved).write(to: folder.appendingPathComponent("history.json"), options: .atomic)
    }

    private func load() {
        guard let saved = Self.read() else { return }
        seen = saved.seen
        // Sessions left open by a quit or crash end when they were last seen
        sessions = saved.sessions.map { s in var s = s; if s.end == nil { s.end = s.lastSeen }; return s }
    }

    nonisolated private static func read() -> Saved? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: folder.appendingPathComponent("history.json")))
            .flatMap { try? decoder.decode(Saved.self, from: $0) }
    }

    /// For the command line: the saved history, read without starting a recorder.
    nonisolated static func history() -> [Session] {
        read()?.sessions ?? []
    }
}
