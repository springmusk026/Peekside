import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Peekside --demo-gif <file.gif>` renders the README animation from the real panel and demo
/// history: a quiet afternoon, then a FaceTime call starting.
/// Frames are drawn like snapshots (final states) and crossfaded.
enum DemoReel {
    private struct Shot {
        let recorder: Recorder
        let preview: PanelPreview
        let hold: Double
    }

    @MainActor
    static func write(to url: URL) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let shots = [
            Shot(recorder: Demo.recorder(active: false), preview: PanelPreview(setup: false), hold: 2.2),
            Shot(recorder: Demo.recorder(active: true), preview: PanelPreview(setup: false), hold: 3.2),
        ]
        let images = shots.map { render($0) }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, images.count * 4, nil) else { return }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        func add(_ image: CGImage, _ delay: Double) {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        for i in images.indices {
            if i > 0 { for step in 1...3 { add(blend(images[i - 1], images[i], Double(step) / 4), 0.04) } }
            add(images[i], shots[i].hold)
        }
        CGImageDestinationFinalize(destination)
    }

    /// The panel hanging under a menu bar, on a plain backdrop, at a fixed canvas size.
    @MainActor
    private static func render(_ shot: Shot) -> CGImage {
        let panel = PanelView(preview: shot.preview)
            .environmentObject(shot.recorder)
            .environment(\.isSnapshot, true)
            .environment(\.flatGlow, true)
            .environment(\.colorScheme, .dark)
            .background(Color(white: 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

        let scene = VStack(spacing: 6) {
            menuBar(active: !shot.recorder.active.isEmpty)
            HStack {
                Spacer()
                panel.padding(.trailing, 28)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 490, height: 640, alignment: .top)
        .clipped()   // a long list runs off the bottom, like a cropped screenshot (a fade would band)
        .background(Color(white: 0.085))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image!
    }

    /// The menu bar, with macOS's own orange and green dots while the call is on.
    private static func menuBar(active: Bool) -> some View {
        HStack(spacing: 16) {
            Spacer()
            if active {
                HStack(spacing: 3) {
                    Circle().fill(Color.mic).frame(width: 6, height: 6)
                    Circle().fill(Color.camera).frame(width: 6, height: 6)
                }
            }
            MenuBarLabel(active: active).content
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Thu 4:40 PM").font(.system(size: 13, weight: .medium))
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.black.opacity(0.35))
    }

    private static func blend(_ a: CGImage, _ b: CGImage, _ t: Double) -> CGImage {
        let ctx = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ctx.draw(a, in: rect)
        ctx.setAlpha(t)
        ctx.draw(b, in: rect)
        return ctx.makeImage()!
    }
}
