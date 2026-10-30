import Foundation

/// `Peekside --self-test` runs the recorder on made-up readings and checks the sessions it makes,
/// then exits with the number of failures. Used by CI; needs no Xcode or test target.
enum SelfTest {
    private static var failures = 0

    @MainActor
    static func run() -> Int32 {
        classification()
        sessions()
        resuming()
        sleep()
        camera()
        locked()
        totals()
        print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
        return Int32(failures)
    }

    private static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
    }

    // MARK: Fixtures

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let zoom = AppInfo(name: "zoom.us", bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app", system: false, background: false)
    private static let facetime = AppInfo(name: "FaceTime", bundleID: "com.apple.FaceTime", path: "/System/Applications/FaceTime.app", system: false, background: false)
    private static let siri = AppInfo(name: "Siri", bundleID: nil, path: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd", system: true, background: true)

    /// Feeds one reading per second from `from` to `to` (seconds after t0).
    @MainActor
    private static func feed(_ r: Recorder, _ from: Int, _ to: Int, mic: [AppInfo] = [], camera: Bool = false,
                             locked: Bool = false, candidates: [AppInfo] = []) {
        for s in from...to {
            r.record(Recorder.Reading(time: t0.addingTimeInterval(TimeInterval(s)), locked: locked, mic: mic,
                                      camera: camera, cameraCandidates: { candidates }))
        }
    }

    // MARK: Checks

    private static func classification() {
        let classify = { (path: String) in
            AppInfo(name: "x", bundleID: nil, path: path, system: false, background: true).classified()
        }
        check(!classify("/System/Applications/FaceTime.app").system, "FaceTime is an app, not a macOS service")
        check(!classify("/Applications/Safari.app").system, "Safari is an app")
        check(classify("/System/Library/CoreServices/Siri.app").system, "Siri.app is a macOS service")
        check(classify("/usr/libexec/corespeechd").system, "corespeechd is a macOS service")
        let web = classify("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
        check(!web.system && !web.background && web.name.contains("Safari"), "WebKit's capture process stands for Safari")
        let call = classify("/usr/libexec/avconferenced")
        check(!call.system && !call.background, "FaceTime's call daemon counts as yours")
        check(AppInfo.visiblePath("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari")
              == "/Applications/Safari.app/Contents/MacOS/Safari", "Safari's cryptex path shows as /Applications")
    }

    @MainActor
    private static func sessions() {
        let r = Recorder(demo: [])
        feed(r, 0, 59, mic: [zoom, siri])
        check(r.sessions.count == 2, "one session per app (got \(r.sessions.count))")
        check(r.active.count == 1, "macOS services aren't active apps")
        feed(r, 60, 62)
        let z = r.sessions.first { $0.app == zoom }
        check(z?.end == t0.addingTimeInterval(59), "a session ends where it was last seen (got \(String(describing: z?.end)))")
        check(z?.flags.contains(.firstTime) == true, "an app's first use is flagged")
        feed(r, 100, 110, mic: [zoom])
        check(r.sessions.last?.flags.contains(.firstTime) == false, "only the first use is flagged")
    }

    @MainActor
    private static func resuming() {
        let r = Recorder(demo: [])
        feed(r, 0, 10, mic: [zoom])
        feed(r, 11, 20)                  // muted for 10s
        feed(r, 21, 30, mic: [zoom])
        check(r.sessions.count == 1, "a short pause continues the session (got \(r.sessions.count))")
        feed(r, 31, 80)                  // gone for 50s
        feed(r, 81, 90, mic: [zoom])
        check(r.sessions.count == 2, "a long pause starts a new session (got \(r.sessions.count))")
        check(r.sessions.first?.end == t0.addingTimeInterval(30), "the resumed session ends at its last sighting")
    }

    @MainActor
    private static func sleep() {
        let r = Recorder(demo: [])
        feed(r, 0, 10, mic: [zoom])
        feed(r, 3600, 3610, mic: [zoom])  // an hour asleep, still recording after waking
        check(r.sessions.count == 2, "sleep splits a session (got \(r.sessions.count))")
        check(r.sessions.first?.end == t0.addingTimeInterval(10), "the first part ends before sleep")
        check(r.total(.mic, on: t0) <= 30, "sleep isn't counted as use (got \(r.total(.mic, on: t0))s)")
    }

    @MainActor
    private static func camera() {
        // A call: mic and camera together
        let r = Recorder(demo: [])
        feed(r, 0, 5, mic: [zoom], camera: true, candidates: [facetime])
        let cam = r.sessions.first { $0.sensor == .camera }
        check(cam?.app == zoom && cam?.flags.contains(.guessed) == true, "the camera goes to the app that started the mic with it")

        // The camera comes on first, credited to the app in front, then another app starts the mic
        let r2 = Recorder(demo: [])
        feed(r2, 0, 2, camera: true, candidates: [facetime])
        check(r2.sessions.first?.app == facetime, "with no call, the camera goes to the app in front")
        feed(r2, 3, 6, mic: [zoom], camera: true, candidates: [facetime])
        check(r2.sessions.first { $0.sensor == .camera }?.app == zoom, "a mic starting just after moves the camera to that app")

        // Apps that can't use a camera aren't suspects
        let r3 = Recorder(demo: [])
        let notes = AppInfo(name: "Notes", bundleID: "com.example.notes", path: "/Applications/NoSuch.app", system: false, background: false)
        feed(r3, 0, 2, camera: true, candidates: [notes])
        check(r3.sessions.first?.app == nil, "an app that can't use the camera isn't guessed")
    }

    @MainActor
    private static func locked() {
        let r = Recorder(demo: [])
        feed(r, 0, 5, mic: [zoom])
        check(r.sessions.first?.flags.contains(.locked) == false, "not locked yet")
        feed(r, 6, 8, mic: [zoom], locked: true)
        check(r.sessions.first?.flags.contains(.locked) == true, "locking mid-session flags it")
        feed(r, 0 + 9, 12, mic: [siri], locked: true)
        check(r.sessions.last?.flags.isEmpty == true, "macOS services aren't flagged")
    }

    @MainActor
    private static func totals() {
        let day = Calendar.current.startOfDay(for: t0)
        func s(_ from: Int, _ to: Int) -> Session {
            Session(sensor: .mic, app: zoom, start: day.addingTimeInterval(TimeInterval(from)),
                    end: day.addingTimeInterval(TimeInterval(to)), lastSeen: day)
        }
        let r = Recorder(demo: [s(100, 200), s(150, 300), s(400, 500), s(-50, 10)], now: day.addingTimeInterval(1000))
        check(r.total(.mic, on: day) == 200 + 100 + 10, "overlaps count once and days are clipped (got \(r.total(.mic, on: day)))")
    }
}
