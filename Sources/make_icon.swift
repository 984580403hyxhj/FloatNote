import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
NSGraphicsContext.current?.shouldAntialias = true

let canvas = NSRect(origin: .zero, size: size)
NSColor.clear.setFill()
canvas.fill()

let baseRect = canvas.insetBy(dx: 80, dy: 80)
let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 210, yRadius: 210)

let baseShadow = NSShadow()
baseShadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
baseShadow.shadowOffset = NSSize(width: 0, height: -18)
baseShadow.shadowBlurRadius = 44
baseShadow.set()

NSGradient(
    starting: NSColor(calibratedRed: 0.90, green: 0.96, blue: 1.00, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.73, green: 0.84, blue: 0.98, alpha: 1.0)
)?.draw(in: basePath, angle: 90)

NSShadow().set()

let noteRect = NSRect(x: 246, y: 250, width: 532, height: 536)
let notePath = NSBezierPath(roundedRect: noteRect, xRadius: 78, yRadius: 78)

let noteShadow = NSShadow()
noteShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
noteShadow.shadowOffset = NSSize(width: 0, height: -14)
noteShadow.shadowBlurRadius = 30
noteShadow.set()

NSGradient(
    starting: NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.36, alpha: 1.0),
    ending: NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.18, alpha: 1.0)
)?.draw(in: notePath, angle: 90)

NSShadow().set()

NSColor(calibratedRed: 0.62, green: 0.46, blue: 0.08, alpha: 0.20).setStroke()
notePath.lineWidth = 8
notePath.stroke()

let foldPath = NSBezierPath()
foldPath.move(to: NSPoint(x: noteRect.maxX - 142, y: noteRect.maxY))
foldPath.line(to: NSPoint(x: noteRect.maxX, y: noteRect.maxY - 142))
foldPath.line(to: NSPoint(x: noteRect.maxX, y: noteRect.maxY - 34))
foldPath.curve(
    to: NSPoint(x: noteRect.maxX - 34, y: noteRect.maxY),
    controlPoint1: NSPoint(x: noteRect.maxX, y: noteRect.maxY - 16),
    controlPoint2: NSPoint(x: noteRect.maxX - 16, y: noteRect.maxY)
)
foldPath.close()

NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.66, alpha: 0.72).setFill()
foldPath.fill()

NSColor.white.withAlphaComponent(0.45).setFill()
NSBezierPath(roundedRect: NSRect(x: 330, y: 650, width: 240, height: 26), xRadius: 13, yRadius: 13).fill()
NSColor(calibratedRed: 0.47, green: 0.36, blue: 0.08, alpha: 0.24).setFill()
NSBezierPath(roundedRect: NSRect(x: 328, y: 558, width: 340, height: 24), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: 328, y: 486, width: 288, height: 24), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: 328, y: 414, width: 224, height: 24), xRadius: 12, yRadius: 12).fill()

let orbRect = NSRect(x: 618, y: 610, width: 232, height: 232)
let orbPath = NSBezierPath(ovalIn: orbRect)

let orbShadow = NSShadow()
orbShadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
orbShadow.shadowOffset = NSSize(width: 0, height: -8)
orbShadow.shadowBlurRadius = 22
orbShadow.set()

NSGradient(
    starting: NSColor(calibratedRed: 0.20, green: 0.57, blue: 1.00, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.82, alpha: 1.0)
)?.draw(in: orbPath, angle: 90)

NSShadow().set()

NSColor.white.setStroke()
let plus = NSBezierPath()
plus.lineWidth = 26
plus.lineCapStyle = .round
plus.move(to: NSPoint(x: orbRect.midX, y: orbRect.midY - 56))
plus.line(to: NSPoint(x: orbRect.midX, y: orbRect.midY + 56))
plus.move(to: NSPoint(x: orbRect.midX - 56, y: orbRect.midY))
plus.line(to: NSPoint(x: orbRect.midX + 56, y: orbRect.midY))
plus.stroke()

NSColor.white.withAlphaComponent(0.38).setFill()
NSBezierPath(ovalIn: NSRect(x: 672, y: 750, width: 72, height: 34)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render icon PNG\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
