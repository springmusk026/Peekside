import SwiftUI

/// `Peekside --snapshot <folder>` renders the panel in each state, in light and dark, plus the
/// menu bar icon states and Settings, to PNG files, then exits. Uses made-up history (Demo).
enum PanelSnapshot {
    @MainActor
    static func write(to dir: URL) {
        let app = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let states: [(String, () -> Recorder, PanelPreview)] = [
            ("panel", { Demo.recorder() }, PanelPreview(setup: false, mode: .sessions)),
            ("apps", { Demo.recorder() }, PanelPreview(setup: false, mode: .apps)),
            ("setup", { Demo.recorder(active: false) }, PanelPreview(setup: true, mode: .sessions)),
            ("idle", { Demo.recorder(active: false) }, PanelPreview(setup: false, mode: .sessions)),
            ("system", { Demo.recorder(active: false) }, PanelPreview(showSystem: true, setup: false, mode: .sessions)),
            ("empty", { Demo.recorder(empty: true) }, PanelPreview(setup: false, mode: .sessions)),
        ]
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            app.appearance = appearance
            for (state, make, preview) in states {
                let view = PanelView(preview: preview)
                    .environmentObject(make())
                    .environment(\.colorScheme, scheme)
                    .environment(\.isSnapshot, true)
                    .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.955))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                appearance.performAsCurrentDrawingAppearance {
                    save(renderer, to: dir.appendingPathComponent("\(state)-\(name).png"))
                }
            }
            capture(SettingsView().environmentObject(Demo.recorder()), appearance: appearance,
                    to: dir.appendingPathComponent("settings-\(name).png"))
        }
        let renderer = ImageRenderer(content: menuBarStates)
        renderer.scale = 3
        save(renderer, to: dir.appendingPathComponent("menubar.png"))
    }

    @MainActor
    private static func save<V: View>(_ renderer: ImageRenderer<V>, to url: URL) {
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @MainActor
    private static func capture<V: View>(_ view: V, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static var menuBarStates: some View {
        let states: [(String, Bool, Bool)] = [("Nothing listening", false, false), ("Mic or camera in use", true, false),
                                              ("Red flag", true, true)]
        return HStack(spacing: 0) {
            ForEach([true, false], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(states.indices, id: \.self) { i in
                        HStack(spacing: 14) {
                            MenuBarLabel(active: states[i].1, flagged: states[i].2).content
                            Image(systemName: "wifi")
                            Image(systemName: "battery.75percent")
                            Text("Thu 9:30 PM").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(states[i].0).font(.system(size: 10)).opacity(0.6)
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(dark ? .white : .black)
                        .padding(.horizontal, 10)
                        .frame(width: 400, height: 24)
                        .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                    }
                }
                .padding(10)
                .background(dark ? Color(white: 0.08) : Color.white)
            }
        }
    }
}
