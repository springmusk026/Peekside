// Renders the 1024px app icon PNG: a graphite squircle with a white open eye, its pupil
// lit in the microphone orange. Usage: swift tools/make-icon.swift <output.png>

import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedWhite: 0.10, alpha: 1),
           ending: NSColor(calibratedWhite: 0.27, alpha: 1))!.draw(in: shape, angle: 90)
NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
shape.lineWidth = 4
shape.stroke()

// The eye
let eye = NSBezierPath()
eye.move(to: NSPoint(x: 232, y: 512))
eye.curve(to: NSPoint(x: 792, y: 512), controlPoint1: NSPoint(x: 400, y: 760), controlPoint2: NSPoint(x: 624, y: 760))
eye.curve(to: NSPoint(x: 232, y: 512), controlPoint1: NSPoint(x: 624, y: 264), controlPoint2: NSPoint(x: 400, y: 264))
eye.close()
NSColor.white.setStroke()
eye.lineWidth = 48
eye.lineJoinStyle = .round
eye.stroke()

// The pupil, orange like the microphone indicator
let pupil = NSBezierPath(ovalIn: NSRect(x: 512 - 92, y: 512 - 92, width: 184, height: 184))
NSColor(srgbRed: 1.0, green: 0.62, blue: 0.2, alpha: 1).setFill()
pupil.fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 540, y: 548, width: 44, height: 44)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
