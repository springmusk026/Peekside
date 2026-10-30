// Peekside design system: tokens and the components built from them (shared with Portside
// and Sweepside). Follows the system light/dark appearance. Color carries meaning, and the
// sensor colors match macOS's own privacy indicators:
//   mic      – the microphone (orange, like the menu bar dot)
//   camera   – the camera (green, like the camera light)
//   keys     – apps that can read keystrokes
//   critical – a red flag: used while the screen was locked

import SwiftUI

// MARK: - Tokens

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let control: CGFloat = 6
    static let card: CGFloat = 12
}

private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let mic      = Color(light: rgb(0.93, 0.47, 0.05), dark: rgb(1.00, 0.62, 0.20))
    static let camera   = Color(light: rgb(0.12, 0.62, 0.30), dark: rgb(0.30, 0.84, 0.48))
    static let keys     = Color(light: rgb(0.36, 0.38, 0.90), dark: rgb(0.58, 0.62, 1.00))
    static let live     = Color(light: rgb(0.12, 0.60, 0.34), dark: rgb(0.32, 0.84, 0.52))
    static let caution  = Color(light: rgb(0.84, 0.50, 0.04), dark: rgb(1.00, 0.72, 0.28))
    static let critical = Color(light: rgb(0.85, 0.20, 0.18), dark: rgb(1.00, 0.45, 0.40))

    static let surface   = Color(light: rgb(0, 0, 0, 0.035), dark: rgb(1, 1, 1, 0.05))
    static let selection = Color(light: rgb(1, 1, 1, 1), dark: rgb(1, 1, 1, 0.13))
    static let hairline  = Color(light: rgb(0, 0, 0, 0.08), dark: rgb(1, 1, 1, 0.09))
    static let track     = Color(light: rgb(0, 0, 0, 0.11), dark: rgb(1, 1, 1, 0.13))
}

enum Typo {
    static let hero    = Font.system(size: 34, weight: .semibold).monospacedDigit()
    static let display = Font.system(size: 26, weight: .semibold).monospacedDigit()
    static let metric  = Font.system(size: 15, weight: .semibold).monospacedDigit()
    static let title   = Font.system(size: 13, weight: .semibold)
    static let heading = Font.system(size: 12, weight: .medium)
    static let body    = Font.system(size: 13)
    static let unit    = Font.system(size: 15, weight: .medium)
    static let caption = Font.system(size: 11)
    static let micro   = Font.system(size: 10, weight: .medium)
    static let mono    = Font.system(size: 10.5, design: .monospaced)
}

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let quick  = Animation.snappy(duration: 0.22)
    static let count  = Animation.smooth(duration: 0.8)
    static let draw   = Animation.easeOut(duration: 0.9)
}

// MARK: - Environment

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

private struct FlatGlowKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering to an image: show final states, no entrance animations.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }

    /// Card glows as an even tint: gradients band in GIFs' 256 colors.
    var flatGlow: Bool {
        get { self[FlatGlowKey.self] }
        set { self[FlatGlowKey.self] = newValue }
    }
}

// MARK: - Animation helpers

/// Holds a value that animates from zero when it first appears, then between updates.
struct Animated<Content: View>: View {
    let target: Double
    var animation: Animation = Motion.count
    let content: (Double) -> Content
    @State private var shown: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        content(shown ?? (reduceMotion || isSnapshot ? target : 0))
            .onAppear {
                guard shown == nil else { return }
                if reduceMotion { shown = target } else { withAnimation(animation) { shown = target } }
            }
            .onChange(of: target) { _, new in
                if reduceMotion { shown = new } else { withAnimation(Motion.spring) { shown = new } }
            }
    }
}

/// A number that counts toward its value.
struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(format(value)) }
}

struct AnimatedNumber: View {
    let value: Double
    let format: (Double) -> String

    var body: some View {
        Animated(target: value) { CountingText(value: $0, format: format) }
    }
}

/// Fades and lifts content in when the panel opens, staggered by `order`.
struct Entrance: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion || isSnapshot
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .scaleEffect(visible ? 1 : 0.985, anchor: .top)
            .onAppear {
                withAnimation(Motion.spring.delay(Double(order) * 0.05)) { shown = true }
            }
    }
}

extension View {
    func entrance(_ order: Int) -> some View { modifier(Entrance(order: order)) }
}

/// Precise press feedback for custom buttons.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Surfaces

/// The one card style. `glow` adds a soft light in one corner, in the color of what the card is about.
/// With `padding: 0, spacing: 0` it's a list container whose rows bring their own padding.
struct Card<Content: View>: View {
    var glow: Color? = nil
    var glowAt: UnitPoint = .topLeading
    var outline: Color? = nil
    var padding: CGFloat = Space.s
    var spacing: CGFloat = Space.s
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatGlow) private var flatGlow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Color.surface)
                    if let glow, flatGlow {
                        shape.fill(glow.opacity(scheme == .dark ? 0.08 : 0.05))
                    } else if let glow {
                        shape.fill(RadialGradient(colors: [glow.opacity(scheme == .dark ? 0.20 : 0.11), .clear],
                                                  center: glowAt, startRadius: 0, endRadius: 200))
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(outline ?? Color.hairline, lineWidth: outline == nil ? 0.5 : 1))
            .overlay(  // a faint top edge catching the light, dark mode only
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.07 : 0), .clear],
                                                  startPoint: .top, endPoint: .center), lineWidth: 0.5))
    }
}

// MARK: - Progress

/// Progress as a row of dots, lit up to `value` with a brighter head.
struct DotTrack: View, Animatable {
    var value: Double
    var tint: Color
    var dots = 32
    var size: CGFloat = 4

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { ctx, canvas in
            let gap = max(1, (canvas.width - CGFloat(dots) * size) / CGFloat(dots - 1))
            let lit = min(1, max(0, value)) * Double(dots)
            let y = (canvas.height - size) / 2
            for i in 0..<dots {
                let rect = CGRect(x: CGFloat(i) * (size + gap), y: y, width: size, height: size)
                let fill = Double(i) + 1 <= lit ? 1 : max(0, lit - Double(i))
                ctx.fill(Path(ellipseIn: rect), with: .color(.track))
                if fill > 0 { ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(fill))) }
            }
            // The head: where progress currently stands
            if lit > 0 && lit < Double(dots) {
                let i = min(dots - 1, Int(lit))
                let center = CGPoint(x: CGFloat(i) * (size + gap) + size / 2, y: canvas.height / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - size * 1.6, y: center.y - size * 1.6,
                                                width: size * 3.2, height: size * 3.2)),
                         with: .color(tint.opacity(0.22)))
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - size * 0.75, y: center.y - size * 0.75,
                                                width: size * 1.5, height: size * 1.5)),
                         with: .color(tint))
            }
        }
        .frame(height: size * 3.2)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Controls

/// A floating pill of choices with a sliding selection.
struct Segmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var icon: String? = nil
    }

    let items: [Item]
    @Binding var selection: Value
    var stretch = false
    var small = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let selected = item.value == selection
                Button {
                    withAnimation(Motion.spring) { selection = item.value }
                } label: {
                    HStack(spacing: Space.xxs) {
                        if let icon = item.icon {
                            Image(systemName: icon).font(.system(size: small ? 10 : 11, weight: .medium))
                        }
                        Text(item.title)
                    }
                    .font(.system(size: small ? 11 : 12, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, small ? Space.xs : Space.s)
                    .frame(height: small ? 22 : 26)
                    .frame(maxWidth: stretch ? .infinity : nil)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.selection)
                                .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.surface))
        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}

/// The primary action: a pill with a contrasting circular icon.
struct PrimaryPill: View {
    let title: String
    var detail: String? = nil
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                ZStack {
                    Circle().fill(isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5))
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.background)
                }
                .frame(width: 22, height: 22)
                Text(title).font(Typo.body.weight(.medium))
                if let detail {
                    Text(detail).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, Space.xxs)
            .padding(.trailing, Space.s)
            .frame(height: 30)
            .background(Capsule().fill(Color.surface.opacity(hovering ? 2 : 1)))
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}

/// A round icon button for secondary actions.
struct CircleButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.surface.opacity(hovering ? 2 : 1)))
                .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Small pieces

/// A status light. Breathes only while something is happening.
struct StatusDot: View {
    let color: Color
    var active = false
    var hollow = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(hollow ? Color.clear : color)
            .overlay(Circle().strokeBorder(color, lineWidth: hollow ? 1 : 0))
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(color.opacity(active ? (breathe ? 0 : 0.45) : 0))
                    .scaleEffect(breathe ? 2.6 : 1))
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
            }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .fixedSize()
    }
}
