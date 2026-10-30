// Turns one-second sensor readings into sessions ("Zoom used the microphone 10:02–10:47"),
// flags the ones worth a look, and keeps 30 days of history in
// ~/Library/Application Support/Peekside/history.json.
//
// A session is open while its sensor and app keep showing up in readings. It ends where it was
// last seen once it's missing from two readings in a row, or when the Mac goes to sleep. One
// that starts again within `resumeWithin` continues instead (muting, switching devices).

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
    var app: AppInfo?
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

/// One app's use of the mic and camera over a day.
struct AppUsage: Identifiable {
    var id: String { app?.path ?? "" }
    let app: AppInfo?
    let mic: TimeInterval
    let camera: TimeInterval
    /// Time either was in use: a call using both counts once.
    let either: TimeInterval
    let count: Int
    let flags: Set<Flag>
    let last: Date
    let open: Bool
}

struct KeyMonitor: Codable, Identifiable, Equatable {
    var id: String { app.path }
    let app: AppInfo
    let firstSeen: Date
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var sessions: [Session] = []      // the last 30 days, oldest first
    @Published private(set) var monitors: [KeyMonitor] = []   // apps that can read keystrokes now
    /// The time shown in the panel. Ticks every second only while the panel is open.
    @Published private(set) var now = Date()

    @AppStorage("alerts") var alerts = false
    @AppStorage("watchingSince") private var watchingSince = 0.0

    /// Set by the panel as it opens and closes.
    var panelOpen = false {
        didSet { if panelOpen { now = Date() } }
    }

    /// A session seen in the latest readings.
    private struct Live {
        let id: UUID
        var lastSeen: Date
        var missing = 0
        var locked = false
    }

    private static let resumeWithin: TimeInterval = 20
    private static let callWindow: TimeInterval = 8   // mic and camera starting this close together are one call

    private var clock = Date()                                   // time of the current reading
    private var lastReading: Date?
    private var live: [String: Live] = [:]                       // open sessions, by sensor and app
    private var ended: [String: (id: UUID, at: Date)] = [:]      // the last session to end, by sensor and app
    private var cameraFromCall = false                           // the open camera session's app started the mic with it
    private var seen: [String: Set<String>] = [:]                // sensor -> app paths ever seen using it
    private var keysSince: [String: Date] = [:]                  // keystroke reader -> first seen
    private var described: [pid_t: (exe: String, app: AppInfo)] = [:]
    private var cameraCapable: [String: Bool] = [:]
    private var activated: [pid_t] = []                          // recently active apps, latest last
    private var loop: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private let demo: Bool
    private let disk = DispatchQueue(label: "Peekside.history", qos: .utility)

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
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAll(sync: true) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // Asleep, nothing is recording; without this a session would stretch across the night
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAll(sync: false) }
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.activated.removeAll { $0 == pid }
                self.activated.append(pid)
                if self.activated.count > 8 { self.activated.removeFirst() }
            }
        }
    }

    /// When Peekside started watching; made-up history pretends it's been a few days.
    var since: Date { demo ? Calendar.current.startOfDay(for: now).addingTimeInterval(-3 * 86_400) : Date(timeIntervalSince1970: watchingSince) }
    var active: [Session] { sessions.filter { $0.isOpen && !$0.system } }

    // MARK: Sampling

    /// One second's readings, as the recorder sees them.
    struct Reading {
        var time = Date()
        var locked = false
        var mic: [AppInfo] = []
        var camera = false
        var keys: [AppInfo] = []
        /// Apps that might have turned the camera on: the one you're using first, then those you used before.
        var cameraCandidates: () -> [AppInfo] = { [] }
    }

    private func tick() {
        let candidates = { [unowned self] in
            ([Sensors.frontmost].compactMap { $0 } + activated.reversed()).compactMap(describe)
        }
        record(Reading(time: Date(), locked: Sensors.screenLocked(), mic: Sensors.microphone().compactMap(describe),
                       camera: Sensors.cameraOn(), keys: Sensors.keyboardMonitors().compactMap(describe),
                       cameraCandidates: candidates))
        if described.count > 128 { described.removeAll() }
    }

    func record(_ reading: Reading) {
        clock = reading.time
        // A reading long overdue means the Mac slept or Peekside was stopped: what was open then has ended
        if let last = lastReading, clock.timeIntervalSince(last) > 90 { endAll(sync: false) }
        lastReading = clock
        if panelOpen || demo || clock.timeIntervalSince(now) >= 60 { now = clock }
        let locked = reading.locked

        // Microphone: one session per app (helpers count as their app)
        var micApps: [String: AppInfo] = [:]
        for app in reading.mic { micApps[app.path] = app }
        for (path, app) in micApps.sorted(by: { $0.key < $1.key }) { observe(.mic, key: "mic|\(path)", app: app, locked: locked) }

        // Camera: macOS doesn't say who, so name the likeliest app and say so
        if reading.camera {
            if live["camera"] == nil && !resume("camera", locked: locked) {
                let (app, fromCall) = cameraSuspect(reading.cameraCandidates)
                cameraFromCall = fromCall
                observe(.camera, key: "camera", app: app, locked: locked, extra: app == nil ? [] : [.guessed])
            } else {
                observe(.camera, key: "camera", app: nil, locked: locked)
            }
        }

        closeMissing(Set(micApps.keys.map { "mic|\($0)" } + (reading.camera ? ["camera"] : [])))
        updateMonitors(reading.keys)

        if !live.isEmpty, clock.timeIntervalSince(lastSave) > 30 { save() }
    }

    /// Describes a process once, then reuses that until its pid runs something else.
    private func describe(_ pid: pid_t) -> AppInfo? {
        guard let exe = Sensors.path(of: pid) else { return nil }
        if let known = described[pid], known.exe == exe { return known.app }
        let app = AppInfo.of(pid: pid, path: exe)
        described[pid] = (exe, app)
        return app
    }

    private func observe(_ sensor: Sensor, key: String, app: AppInfo?, locked: Bool, extra: Set<Flag> = []) {
        if var current = live[key] {
            current.lastSeen = clock
            current.missing = 0
            if locked && !current.locked { flagLocked(&current) }
            live[key] = current
            return
        }
        if resume(key, locked: locked) { return }

        var flags = extra
        if let app, !app.system {
            if locked { flags.insert(.locked) }
            if app.background { flags.insert(.background) }
            if !(seen[sensor.rawValue]?.contains(app.path) ?? false) {
                // Apps already running when Peekside first starts aren't "new"
                if clock.timeIntervalSince(since) > 60 { flags.insert(.firstTime) }
                seen[sensor.rawValue, default: []].insert(app.path)
            }
        } else if app == nil && locked {
            flags.insert(.locked)
        }
        let session = Session(sensor: sensor, app: app, start: clock, lastSeen: clock, flags: flags)
        sessions.append(session)
        live[key] = Live(id: session.id, lastSeen: clock, locked: flags.contains(.locked))
        if sensor == .mic, let app, !app.system { recreditCamera(to: app) }
        save()
        if let reason = session.sortedFlags.first(where: \.alerts) { notify(session, reason: reason) }
    }

    /// Continues the session for `key` if it ended moments ago: a short pause isn't a new session.
    private func resume(_ key: String, locked: Bool) -> Bool {
        guard let last = ended[key], clock.timeIntervalSince(last.at) < Self.resumeWithin,
              let i = sessions.lastIndex(where: { $0.id == last.id }) else { return false }
        sessions[i].end = nil
        ended[key] = nil
        var current = Live(id: last.id, lastSeen: clock, locked: sessions[i].flags.contains(.locked))
        if locked && !current.locked { flagLocked(&current) }
        live[key] = current
        return true
    }

    private func flagLocked(_ current: inout Live) {
        current.locked = true
        guard let i = sessions.lastIndex(where: { $0.id == current.id }), !sessions[i].system else { return }
        sessions[i].flags.insert(.locked)
        notify(sessions[i], reason: .locked)
    }

    /// Ends sessions missing from two readings in a row (a brief gap isn't a new session).
    private func closeMissing(_ present: Set<String>) {
        for (key, var current) in live where !present.contains(key) {
            current.missing += 1
            if current.missing >= 2 { end(key) } else { live[key] = current }
        }
    }

    /// Ends the session where it was last seen.
    private func end(_ key: String) {
        guard let current = live.removeValue(forKey: key) else { return }
        let at = current.lastSeen
        if let i = sessions.lastIndex(where: { $0.id == current.id }) {
            sessions[i].end = max(at, sessions[i].start)
            sessions[i].lastSeen = sessions[i].end!
        }
        ended[key] = (current.id, at)
        save()
    }

    private func endAll(sync: Bool) {
        for key in Array(live.keys) { end(key) }
        if sync { disk.sync {} }
    }

    // MARK: Who turned the camera on

    /// The app that most likely turned the camera on, and whether it's from a call (an app that
    /// started the microphone at the same moment) rather than a guess from what you were using.
    private func cameraSuspect(_ candidates: () -> [AppInfo]) -> (AppInfo?, Bool) {
        let call = sessions.suffix(32).last {
            $0.sensor == .mic && $0.isOpen && !$0.system && clock.timeIntervalSince($0.start) < Self.callWindow
        }
        if let app = call?.app { return (app, true) }
        // The app you're using, else the one you used last, among apps that can use a camera at all
        for app in candidates() where !app.system && canUseCamera(app) { return (app, false) }
        return (nil, false)
    }

    /// A call often turns the camera on a moment before the microphone. If an app starts the
    /// microphone just after the camera came on, credit the camera to it instead.
    private func recreditCamera(to app: AppInfo) {
        guard !cameraFromCall, let id = live["camera"]?.id,
              let i = sessions.lastIndex(where: { $0.id == id }),
              clock.timeIntervalSince(sessions[i].start) < Self.callWindow, sessions[i].app?.path != app.path else { return }
        sessions[i].app = app
        sessions[i].flags.insert(.guessed)
        if app.background && !app.system { sessions[i].flags.insert(.background) }
        cameraFromCall = true
    }

    /// Since macOS 10.14 an app must declare why it wants the camera, or macOS won't let it use it.
    private func canUseCamera(_ app: AppInfo) -> Bool {
        if let known = cameraCapable[app.path] { return known }
        let info = Bundle(path: app.path)?.infoDictionary
        let capable = app.bundleID?.hasPrefix("com.apple.") == true || info?["NSCameraUsageDescription"] != nil
        cameraCapable[app.path] = capable
        return capable
    }

    private func updateMonitors(_ apps: [AppInfo]) {
        var next: [String: KeyMonitor] = [:]
        for app in apps where next[app.path] == nil {
            if keysSince[app.path] == nil {
                keysSince[app.path] = clock
                if !app.system && clock.timeIntervalSince(since) > 60 && !(seen["keys"]?.contains(app.path) ?? false) {
                    notifyKeyboard(app)
                }
                seen["keys", default: []].insert(app.path)
                save()
            }
            next[app.path] = KeyMonitor(app: app, firstSeen: keysSince[app.path] ?? clock)
        }
        let sorted = next.values.sorted { ($0.app.system ? 1 : 0, $0.app.name) < ($1.app.system ? 1 : 0, $1.app.name) }
        if sorted != monitors { monitors = sorted }
    }

    // MARK: Days

    func sessions(on day: Date, includeSystem: Bool = false) -> [Session] {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        return sessions.filter { $0.start < end && $0.finish(now) > start && (includeSystem || !$0.system) }
    }

    /// Time the sensor was in use that day, counting overlapping sessions once.
    func total(_ sensor: Sensor, on day: Date) -> TimeInterval {
        covered(sessions(on: day).filter { $0.sensor == sensor }, on: day)
    }

    /// Each app's use of the mic and camera that day, most used first.
    func usage(on day: Date) -> [AppUsage] {
        let byApp = Dictionary(grouping: sessions(on: day)) { $0.app?.path ?? "" }
        return byApp.values.map { list in
            AppUsage(app: list[0].app, mic: covered(list.filter { $0.sensor == .mic }, on: day),
                     camera: covered(list.filter { $0.sensor == .camera }, on: day), either: covered(list, on: day),
                     count: Use.group(list).count, flags: list.reduce([]) { $0.union($1.flags) },
                     last: list.map { $0.finish(now) }.max()!, open: list.contains(where: \.isOpen))
        }
        .sorted { ($0.open ? 1 : 0, $0.either) > ($1.open ? 1 : 0, $1.either) }
    }

    /// How much of the day the sessions cover, counting overlaps once.
    private func covered(_ list: [Session], on day: Date) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86_400)
        let spans = list.map { (max($0.start, start), min($0.finish(now), end)) }.sorted { $0.0 < $1.0 }
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
        var keysSince: [String: Date]?   // added in 1.1
    }

    /// Writes the history on a background queue; encoding 30 days shouldn't hold up the panel.
    private func save() {
        guard !demo else { return }
        lastSave = clock
        let cutoff = clock.addingTimeInterval(-30 * 86_400)
        if let oldest = sessions.first, oldest.finish(clock) < cutoff {
            sessions.removeAll { $0.finish(clock) < cutoff }
        }
        var snapshot = sessions
        for current in live.values {
            if let i = snapshot.lastIndex(where: { $0.id == current.id }) { snapshot[i].lastSeen = current.lastSeen }
        }
        let saved = Saved(sessions: snapshot, seen: seen, keysSince: keysSince)
        disk.async { Self.write(saved) }
    }

    nonisolated private static func write(_ saved: Saved) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(saved).write(to: folder.appendingPathComponent("history.json"), options: .atomic)
    }

    private func load() {
        guard let saved = Self.read() else { return }
        seen = saved.seen
        keysSince = saved.keysSince ?? [:]
        // Sessions left open by a quit or crash end when they were last seen
        sessions = saved.sessions.map { s in
            var s = s
            if s.end == nil { s.end = s.lastSeen }
            s.app = s.app?.classified()
            return s
        }
    }

    nonisolated private static func read() -> Saved? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: folder.appendingPathComponent("history.json")))
            .flatMap { try? decoder.decode(Saved.self, from: $0) }
    }

    /// For the command line: the saved history, read without starting a recorder.
    nonisolated static func history() -> [Session] {
        (read()?.sessions ?? []).map { s in var s = s; s.app = s.app?.classified(); return s }
    }
}
