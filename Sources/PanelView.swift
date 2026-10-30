import ServiceManagement
import SwiftUI

/// Forces a state when rendering snapshots.
struct PanelPreview {
    var dayOffset = 0
    var showSystem = false
    var setup: Bool? = nil
}

struct PanelView: View {
    var preview: PanelPreview? = nil
    @EnvironmentObject private var recorder: Recorder
    @State private var dayOffset = 0
    @State private var showSystem = false
    @AppStorage("setupDone") private var setupDone = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openSettings) private var openSettings

    private var offset: Int { preview?.dayOffset ?? dayOffset }
    private var day: Date { Calendar.current.date(byAdding: .day, value: -offset, to: recorder.now)! }
    private var systemShown: Bool { preview?.showSystem ?? showSystem }

    var body: some View {
        let sessions = recorder.sessions(on: day).sorted { $0.start > $1.start }
        VStack(alignment: .leading, spacing: Space.s) {
            header.entrance(0)
            if preview?.setup ?? (!setupDone && SMAppService.mainApp.status != .enabled) {
                SetupCard(done: { withAnimation(Motion.spring) { setupDone = true } }).entrance(1)
            }
            TodayCard(day: day, offset: offset, onDay: { dayOffset = $0 }).entrance(1)
            if isSnapshot {
                lists(sessions)
            } else {
                ViewThatFits(in: .vertical) {
                    lists(sessions)
                    ScrollView { lists(sessions) }.scrollIndicators(.never)
                }
                .frame(maxHeight: 380)
            }
            footer.entrance(4)
        }
        .padding(Space.m)
        .frame(width: 380)
    }

    // MARK: Header: what's happening right now

    private var header: some View {
        let active = recorder.active
        let mic = active.filter { $0.sensor == .mic }.compactMap(\.app?.name)
        let camera = active.contains { $0.sensor == .camera }
        return HStack(alignment: .top, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    if active.isEmpty {
                        StatusDot(color: .secondary, hollow: true)
                        Text("Nothing is using your mic or camera")
                    } else {
                        StatusDot(color: camera ? .camera : .mic, active: !isSnapshot)
                        Text(nowLine(mic: mic, camera: camera, active: active))
                            .lineLimit(1)
                    }
                }
                .font(Typo.title)
                if active.contains(where: { $0.flags.contains(.locked) }) {
                    Text("While your screen is locked").font(Typo.caption).foregroundStyle(Color.critical).padding(.leading, 15)
                }
            }
            Spacer()
            CircleButton(icon: "gearshape", help: "Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func nowLine(mic: [String], camera: Bool, active: [Session]) -> String {
        let cameraApp = active.first { $0.sensor == .camera }?.app?.name
        let names = Array(Set(mic + [cameraApp].compactMap { $0 })).sorted()
        let who = names.isEmpty ? "An app" : names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        switch (mic.isEmpty, camera) {
        case (false, true): return "\(who) is using the mic and camera"
        case (true, true):  return "\(who) is using the camera"
        default:            return "\(who) is using the mic"
        }
    }

    // MARK: Lists

    @ViewBuilder private func lists(_ sessions: [Session]) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if sessions.isEmpty {
                Card {
                    Text(offset == 0 ? "No app has used your mic or camera today." : "No app used your mic or camera that day.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                    if recorder.since > Calendar.current.startOfDay(for: day) && offset == 0 {
                        Text("Watching since \(fmtTime(recorder.since)). Peekside records while it's running.")
                            .font(Typo.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                SessionSection(title: "Sessions", sessions: sessions)
            }
            KeyboardSection(monitors: recorder.monitors)
            systemSection
        }
        .entrance(2)
    }

    @ViewBuilder private var systemSection: some View {
        let system = recorder.sessions(on: day, includeSystem: true).filter(\.system).sorted { $0.start > $1.start }
        if !system.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Button {
                    withAnimation(Motion.spring) { showSystem.toggle() }
                } label: {
                    HStack(spacing: Space.xxs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(systemShown ? 90 : 0))
                            .frame(width: 12)
                        Text("macOS used the mic \(system.count) time\(system.count == 1 ? "" : "s") (Siri, dictation…)")
                        Spacer()
                    }
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                if systemShown {
                    SessionSection(title: nil, sessions: system)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Recorded on this Mac only. Nothing leaves it.")
                .font(Typo.caption).foregroundStyle(.tertiary)
            Spacer()
            FooterButton(title: "Quit", icon: nil) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - First run

/// Shown until you've made the two choices that decide whether Peekside is useful:
/// it only records while running, and red flags only reach you with notifications.
struct SetupCard: View {
    let done: () -> Void
    @EnvironmentObject private var recorder: Recorder
    @State private var login = SMAppService.mainApp.status == .enabled
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Card(glow: .mic) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Peekside only sees what happens while it's running").font(Typo.title)
                Text("Start it with your Mac so the timeline has no gaps, and get a notification when something looks wrong.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SetupToggle(title: "Launch at login", on: login && !isSnapshot) {
                    do {
                        if login { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
                    } catch {}
                    login = SMAppService.mainApp.status == .enabled
                }
                SetupToggle(title: "Notify me about red flags", on: recorder.alerts && !isSnapshot) {
                    recorder.alerts.toggle()
                    if recorder.alerts { Recorder.requestNotifications() }
                }
            }
            HStack {
                Spacer()
                FooterButton(title: "Done", icon: nil, action: done)
            }
        }
    }
}

/// A checkbox row drawn by hand, so it renders in snapshots.
struct SetupToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? Color.primary.opacity(0.85) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.2))
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.background).opacity(on ? 1 : 0)
                }
                .frame(width: 15, height: 15)
                Text(title).font(Typo.body)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .animation(Motion.quick, value: on)
    }
}

// MARK: - Today

/// The day at a glance: a timeline per sensor and how long each was in use.
struct TodayCard: View {
    let day: Date
    let offset: Int
    let onDay: (Int) -> Void
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        let sessions = recorder.sessions(on: day)
        Card {
            HStack(spacing: Space.xs) {
                Text(fmtDay(day, now: recorder.now)).font(Typo.heading).foregroundStyle(.secondary)
                Spacer()
                DayButton(icon: "chevron.left", help: "Previous day", enabled: offset < 29) { onDay(offset + 1) }
                DayButton(icon: "chevron.right", help: "Next day", enabled: offset > 0) { onDay(offset - 1) }
            }
            HStack(spacing: Space.l) {
                ForEach(Sensor.allCases, id: \.self) { sensor in
                    let total = recorder.total(sensor, on: day)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(total > 0 ? fmtDuration(total) : "–")
                            .font(Typo.display)
                            .foregroundStyle(total > 0 ? Color.primary : Color.secondary)
                        HStack(spacing: 5) {
                            Circle().fill(sensor.color).frame(width: 6, height: 6)
                            Text(sensor.title).font(Typo.micro).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            Timeline(day: day, sessions: sessions, now: recorder.now)
                .frame(height: 46)
        }
    }
}

/// 24 hours, one lane per sensor. Flagged sessions get a red mark where they start.
struct Timeline: View {
    let day: Date
    let sessions: [Session]
    let now: Date

    var body: some View {
        Canvas { ctx, size in
            let start = Calendar.current.startOfDay(for: day)
            let span: TimeInterval = 86_400
            let laneHeight: CGFloat = 8, gap: CGFloat = 6
            func x(_ date: Date) -> CGFloat { size.width * CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1)) }

            for (lane, sensor) in Sensor.allCases.enumerated() {
                let y = CGFloat(lane) * (laneHeight + gap)
                let track = Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: laneHeight), cornerRadius: laneHeight / 2)
                ctx.fill(track, with: .color(.track.opacity(0.6)))
                for s in sessions where s.sensor == sensor {
                    let x0 = x(s.start), x1 = max(x(s.finish(now)), x0 + 2.5)
                    let bar = Path(roundedRect: CGRect(x: x0, y: y, width: x1 - x0, height: laneHeight), cornerRadius: laneHeight / 2)
                    ctx.fill(bar, with: .color(sensor.color))
                    if s.flags.contains(.locked) || s.flags.contains(.background) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x0 - 1, y: y - 4, width: 4, height: 4)), with: .color(.critical))
                    }
                }
            }

            // Hour marks and labels
            let labelY = 2 * (laneHeight + gap) + 2
            for hour in stride(from: 0, through: 24, by: 6) {
                let px = size.width * CGFloat(hour) / 24
                let label = Text(hour == 24 ? "" : String(format: "%02d", hour)).font(Typo.mono).foregroundStyle(.tertiary)
                ctx.draw(label, at: CGPoint(x: min(max(px, 8), size.width - 8), y: labelY), anchor: .top)
            }
            // Now
            if Calendar.current.isDate(day, inSameDayAs: now) {
                let px = x(now)
                var line = Path()
                line.move(to: CGPoint(x: px, y: -2))
                line.addLine(to: CGPoint(x: px, y: 2 * laneHeight + gap + 2))
                ctx.stroke(line, with: .color(.primary.opacity(0.5)), lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline of microphone and camera use")
    }
}

struct DayButton: View {
    let icon: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.surface))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Sessions

/// A row in the list: one app's microphone and camera use, merged when they happened together
/// (a call uses both, and two near-identical rows say less than one).
struct Use: Identifiable {
    let id: UUID
    let app: AppInfo?
    let sensors: [Sensor]
    let start: Date
    let end: Date?
    let flags: Set<Flag>

    static func group(_ sessions: [Session]) -> [Use] {
        var used = Set<UUID>()
        var uses: [Use] = []
        for s in sessions where !used.contains(s.id) {
            used.insert(s.id)
            let partner = sessions.first { o in
                !used.contains(o.id) && o.sensor != s.sensor && o.app?.path == s.app?.path && s.app != nil
                    && abs(o.start.timeIntervalSince(s.start)) < 90
            }
            if let p = partner {
                used.insert(p.id)
                let ends = [s.end, p.end]
                uses.append(Use(id: s.id, app: s.app, sensors: [.mic, .camera], start: min(s.start, p.start),
                                end: ends.contains(where: { $0 == nil }) ? nil : ends.compactMap { $0 }.max(),
                                flags: s.flags.union(p.flags)))
            } else {
                uses.append(Use(id: s.id, app: s.app, sensors: [s.sensor], start: s.start, end: s.end, flags: s.flags))
            }
        }
        return uses
    }

    func duration(_ now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
    var label: String { sensors.count == 2 ? "Mic + camera" : sensors[0].title }
    var sortedFlags: [Flag] { flags.sorted() }
}

struct SessionSection: View {
    let title: String?
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let title {
                HStack(spacing: Space.xxs) {
                    Text(title).font(Typo.heading).foregroundStyle(.secondary)
                    Text("\(Use.group(sessions).count)").font(Typo.mono).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Space.xxs)
            }
            Card(padding: 0, spacing: 0) {
                ForEach(Array(Use.group(sessions).enumerated()), id: \.element.id) { i, use in
                    if i > 0 { Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 44) }
                    SessionRow(use: use)
                }
            }
        }
    }
}

struct SessionRow: View {
    let use: Use
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        let open = use.end == nil
        let tint = use.sensors.contains(.camera) ? Sensor.camera.color : Sensor.mic.color
        HStack(alignment: .center, spacing: Space.s) {
            AppIcon(app: use.app, sensor: use.sensors.count == 2 ? .camera : use.sensors[0])
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(use.app?.name ?? "Unknown app").font(Typo.title).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(fmtDuration(use.duration(recorder.now)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 5) {
                    ForEach(use.sensors, id: \.self) { sensor in
                        Image(systemName: sensor.icon).font(.system(size: 8.5)).foregroundStyle(sensor.color)
                    }
                    Text(fmtRange(use.start, use.end)).foregroundStyle(open ? tint : .secondary)
                    if use.flags.contains(.guessed) {
                        Text("· likely").foregroundStyle(.tertiary).help(Flag.guessed.help)
                    }
                }
                .font(Typo.mono)
                let flags = use.sortedFlags.filter { $0 != .guessed }
                if !flags.isEmpty {
                    HStack(spacing: Space.xxs) {
                        ForEach(flags, id: \.self) { flag in
                            Badge(text: flag.label, tint: flag == .firstTime ? .secondary : .critical).help(flag.help)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .help("\(use.label)\n" + (use.app.map { abbreviate($0.path) } ?? "macOS doesn't say which app uses the camera."))
        .contextMenu {
            if let app = use.app {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "") }
            }
            Button("Open Privacy Settings") { PrivacySettings.open(use.sensors.contains(.camera) ? "Privacy_Camera" : "Privacy_Microphone") }
        }
    }
}

/// The app's own icon, with a small sensor badge.
struct AppIcon: View {
    let app: AppInfo?
    var sensor: Sensor? = nil
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let app, !isSnapshot || FileManager.default.fileExists(atPath: app.path),
                   let icon = Self.bitmap(app.path) {
                    Image(decorative: icon, scale: 2).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.surface)
                        .overlay(Image(systemName: "questionmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 26, height: 26)
            if let sensor {
                Image(systemName: sensor.icon)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(sensor.color))
                    // A shadow, not a ring in the window color: ImageRenderer dims the whole image for that
                    .shadow(color: .black.opacity(0.35), radius: 0.6)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// The icon redrawn as a plain 8-bit sRGB bitmap. App icons can carry extended-range color,
    /// which makes ImageRenderer tone-map the whole snapshot to about 65% brightness.
    private static func bitmap(_ path: String) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: 52, height: 52)
        guard let source = NSWorkspace.shared.icon(forFile: path).cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 52, height: 52, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: 52, height: 52))
        return ctx.makeImage()
    }
}

// MARK: - Keyboard

struct KeyboardSection: View {
    let monitors: [KeyMonitor]

    var body: some View {
        let apps = monitors.filter { !$0.app.system }
        let system = monitors.count - apps.count
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xxs) {
                Text("Can read your keystrokes").font(Typo.heading).foregroundStyle(.secondary)
                Text("\(apps.count)").font(Typo.mono).foregroundStyle(.tertiary)
                Spacer()
                Button("Input Monitoring…") { PrivacySettings.open("Privacy_ListenEvent") }
                    .buttonStyle(.plain).font(Typo.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxs)
            Card(padding: 0, spacing: 0) {
                if apps.isEmpty {
                    HStack(spacing: Space.xs) {
                        StatusDot(color: .camera)
                        Text("No apps are reading what you type.").font(Typo.caption)
                        Spacer()
                    }
                    .padding(Space.s)
                }
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 44) }
                    HStack(spacing: Space.s) {
                        AppIcon(app: m.app)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.app.name).font(Typo.title).lineLimit(1)
                                if m.app.background { Badge(text: "No window", tint: .critical) }
                            }
                            Text("Every key press · seen since \(fmtDay(m.firstSeen))")
                                .font(Typo.mono).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .help(abbreviate(m.app.path))
                }
                if system > 0 {
                    if !apps.isEmpty { Rectangle().fill(Color.hairline).frame(height: 0.5) }
                    Text("Plus \(system) macOS service\(system == 1 ? "" : "s") (Siri, accessibility, text input)")
                        .font(Typo.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                }
            }
        }
    }
}

enum PrivacySettings {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FooterButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xxs + 2) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
                Text(title)
            }
            .font(Typo.caption.weight(.medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, Space.xs)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? Color.surface : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}
