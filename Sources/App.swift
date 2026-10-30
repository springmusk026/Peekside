// Peekside: a menu bar app that keeps a timeline of which apps used your microphone and
// camera, and which can read your keystrokes, with a flag on anything odd (used while the
// screen was locked, a first-time app, a process with no window). Everything stays local.

import SwiftUI

@main
struct PeeksideApp: App {
    @StateObject private var recorder = Recorder()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            PanelSnapshot.write(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--demo-gif"), i + 1 < args.count {
            DemoReel.write(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if CLI.wants(args) { exit(CLI.run(args)) }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(recorder)
        } label: {
            MenuBarLabel(active: !recorder.active.isEmpty,
                         flagged: recorder.active.contains { $0.flags.contains(.locked) || $0.flags.contains(.background) })
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(recorder)
        }
    }
}

/// The status item, drawn as one template image so it follows the menu bar's colors.
/// macOS shows its own orange and green dots; Peekside's eye opens while something listens.
struct MenuBarLabel: View {
    let active: Bool
    var flagged = false

    var body: some View {
        Image(nsImage: rendered)
    }

    var content: some View {
        MenuGlyph(open: active, flagged: flagged).frame(width: 18, height: 16).padding(.vertical, 1)
    }

    private var rendered: NSImage {
        let renderer = ImageRenderer(content: content.foregroundStyle(.black))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = active ? "Peekside, something is using the mic or camera" : "Peekside"
        return image
    }
}

/// An eye: open with a pupil while an app uses the mic or camera, a closed lid otherwise.
/// With a red flag (locked screen, windowless process) the pupil gets an exclamation.
struct MenuGlyph: View {
    let open: Bool
    var flagged = false

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, mid = h / 2
            var upper = Path()
            upper.move(to: CGPoint(x: 1.5, y: mid))
            upper.addQuadCurve(to: CGPoint(x: w - 1.5, y: mid), control: CGPoint(x: w / 2, y: open ? 0.5 : mid + 5))
            var lower = Path()
            lower.move(to: CGPoint(x: 1.5, y: mid))
            lower.addQuadCurve(to: CGPoint(x: w - 1.5, y: mid), control: CGPoint(x: w / 2, y: h - 0.5))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            if open {
                ctx.stroke(upper, with: .foreground, style: style)
                ctx.stroke(lower, with: .foreground, style: style)
                let r: CGFloat = 3.1
                ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - r, y: mid - r, width: 2 * r, height: 2 * r)), with: .foreground)
                if flagged {
                    ctx.blendMode = .clear
                    ctx.fill(Path(CGRect(x: w / 2 - 0.6, y: mid - 2, width: 1.2, height: 2.4)), with: .color(.black))
                    ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - 0.65, y: mid + 1, width: 1.3, height: 1.3)), with: .color(.black))
                }
            } else {
                // Closed: the lid's curve with lashes
                ctx.stroke(upper, with: .foreground, style: style)
                for (dx, len) in [(-4.5, 2.4), (0.0, 2.8), (4.5, 2.4)] {
                    var lash = Path()
                    let x = w / 2 + dx, y = mid + 2.6 - abs(dx) * 0.25
                    lash.move(to: CGPoint(x: x, y: y))
                    lash.addLine(to: CGPoint(x: x + dx * 0.15, y: y + len))
                    ctx.stroke(lash, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }
            }
        }
    }
}
