// The command line. Run the app binary with arguments, or link it as `peekside`:
//   peekside              today's microphone and camera sessions
//   peekside --days 7     the last week
//   peekside now          what's using the mic, camera and keyboard right now
//   peekside --json       history as JSON

import Foundation

enum CLI {
    static func wants(_ args: [String]) -> Bool {
        let invokedAs = (args.first.map { ($0 as NSString).lastPathComponent } ?? "")
        let flags = args.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        return invokedAs == "peekside" || flags.contains { ["--json", "--days", "--help", "-h", "now", "--version", "--all"].contains($0) }
    }

    static func run(_ argv: [String]) -> Int32 {
        let args = Array(argv.dropFirst())
        let style = Style(enabled: isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
        if args.contains("--help") || args.contains("-h") { print(help); return 0 }
        if args.contains("--version") { print("peekside \(version)"); return 0 }

        if args.contains("now") {
            let mic = Sensors.microphone().compactMap(AppInfo.of(pid:))
            let keys = Sensors.keyboardMonitors().compactMap(AppInfo.of(pid:))
            let showSystem = args.contains("--all")
            let micApps = Array(Set(mic.filter { showSystem || !$0.system }.map(\.name))).sorted()
            print("Microphone  " + (micApps.isEmpty ? style.dim("not in use") : style.yellow(micApps.joined(separator: ", "))))
            print("Camera      " + (Sensors.cameraOn() ? style.green("on") + style.dim(" (macOS doesn't say which app)") : style.dim("off")))
            let keyApps = Array(Set(keys.filter { showSystem || !$0.system }.map(\.name))).sorted()
            print("Keystrokes  " + (keyApps.isEmpty ? style.dim("no apps can read them") : style.red(keyApps.joined(separator: ", "))))
            if !showSystem && (mic.contains(where: \.system) || keys.contains(where: \.system)) {
                print(style.dim("macOS services (Siri, accessibility) hidden; --all shows them"))
            }
            return 0
        }

        var days = 1
        if let i = args.firstIndex(of: "--days") {
            guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 else {
                FileHandle.standardError.write(Data("peekside: --days needs a number of days, 1 to 30\n".utf8))
                return 2
            }
            days = min(n, 30)
        }
        let from = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86_400))
        let history = Recorder.history()
            .filter { $0.finish(Date()) >= from && (args.contains("--all") || !$0.system) }
            .sorted { $0.start < $1.start }

        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write((try? encoder.encode(history)) ?? Data("[]".utf8))
            print()
            return 0
        }

        if history.isEmpty {
            print(days == 1 ? "No app has used your mic or camera today." : "No app used your mic or camera in the last \(days) days.")
            if !isAppRunning { print(style.dim("Peekside isn't running, so nothing is being recorded. Open Peekside.app to start.")) }
            return 0
        }
        let rows = history.map { s -> [String] in
            let day = days > 1 ? fmtDay(s.start) + " " : ""
            return [day + fmtRange(s.start, s.end), fmtDuration(s.duration(Date())), s.sensor.title,
                    s.app?.name ?? "Unknown app", s.sortedFlags.map(\.label).joined(separator: ", ")]
        }
        let header = ["WHEN", "FOR", "SENSOR", "APP", "FLAGS"]
        let widths = header.indices.map { i in ([header[i]] + rows.map { $0[i] }).map(\.count).max() ?? 0 }
        func line(_ cells: [String], _ styled: (Int, String) -> String) -> String {
            cells.indices.map { i in styled(i, i == cells.count - 1 ? cells[i] : cells[i].padding(toLength: widths[i], withPad: " ", startingAt: 0)) }
                .joined(separator: "  ")
        }
        print(line(header) { style.dim($1) })
        for (r, row) in rows.enumerated() {
            print(line(row) { i, c in
                switch i {
                case 0, 1: return style.dim(c)
                case 2: return history[r].sensor == .mic ? style.yellow(c) : style.green(c)
                case 3: return style.bold(c)
                case 4: return history[r].flags.contains(.locked) || history[r].flags.contains(.background) ? style.red(c) : c
                default: return c
                }
            })
        }
        return 0
    }

    private static var isAppRunning: Bool {
        let me = getpid()
        return Scanner.pids(named: "Peekside").contains { $0 != me }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static let help = """
    peekside: which apps used your microphone and camera, and which can read your keystrokes

      peekside                today's mic and camera sessions
      peekside --days 7       the last 7 days
      peekside now            what's using the mic, camera and keyboard right now
      peekside --all          include macOS services (Siri, dictation)
      peekside --json         history as JSON

    History is recorded by the menu bar app (open Peekside.app) and kept for 30 days.
    """

    struct Style {
        let enabled: Bool
        private func wrap(_ code: String, _ s: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        func bold(_ s: String) -> String { wrap("1", s) }
        func dim(_ s: String) -> String { wrap("2", s) }
        func red(_ s: String) -> String { wrap("31", s) }
        func green(_ s: String) -> String { wrap("32", s) }
        func yellow(_ s: String) -> String { wrap("33", s) }
    }
}

/// Finds running processes by executable name, for "is the app running?".
enum Scanner {
    static func pids(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, n))).filter { pid in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
                && (String(cString: buffer) as NSString).lastPathComponent == name
        }
    }
}
