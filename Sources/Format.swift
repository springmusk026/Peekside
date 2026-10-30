import Foundation

/// Fixed-width durations: "<1m", "45m", "1h 07m", "26h 03m".
func fmtDuration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    if m < 1 { return "<1m" }
    return m < 60 ? "\(m)m" : String(format: "%dh %02dm", m / 60, m % 60)
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

func fmtTime(_ date: Date) -> String { timeFormatter.string(from: date) }

/// "10:02 – 10:47", or "10:02 – now".
func fmtRange(_ start: Date, _ end: Date?) -> String {
    "\(fmtTime(start)) – \(end.map(fmtTime) ?? "now")"
}

func fmtDay(_ day: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    if cal.isDate(day, inSameDayAs: now) { return "Today" }
    if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: y) { return "Yesterday" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEdMMM")
    return f.string(from: day)
}

func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
