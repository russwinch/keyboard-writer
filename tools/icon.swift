// Draws the app icon and writes Resources/AppIcon.icns.
//   swift tools/icon.swift [preview.png]
// The optional argument also saves the 1024px rendering there.
import AppKit
import Foundation

struct Palette {
    static let backgroundTop = NSColor(srgbRed: 0.33, green: 0.42, blue: 0.98, alpha: 1)
    static let backgroundBottom = NSColor(srgbRed: 0.19, green: 0.17, blue: 0.62, alpha: 1)
    static let capSide = NSColor(srgbRed: 0.73, green: 0.76, blue: 0.84, alpha: 1)
    static let capSideShade = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.69, alpha: 1)
    static let capTopCentre = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let capTopEdge = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1)
    static let glyph = NSColor(srgbRed: 0.24, green: 0.25, blue: 0.80, alpha: 1)
}

struct IconSize {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var fileName: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

/// Everything is laid out on a 1024 canvas, origin at the bottom left.
func drawIcon(in context: CGContext) {
    // Apple's grid: an 824 square with a 185 corner, leaving room for the shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    context.addPath(tilePath)
    context.setFillColor(Palette.backgroundBottom.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    fillLinear([Palette.backgroundTop, Palette.backgroundBottom], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: context)
    context.restoreGState()

    // The cap's skirt; seen from above and in front, so the front side shows most.
    let skirt = CGRect(x: 232, y: 214, width: 560, height: 560)
    let skirtPath = CGPath(roundedRect: skirt, cornerWidth: 110, cornerHeight: 110, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -30), blur: 60, color: NSColor(white: 0, alpha: 0.45).cgColor)
    context.addPath(skirtPath)
    context.setFillColor(Palette.capSide.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(skirtPath)
    context.clip()
    fillLinear([Palette.capSide, Palette.capSideShade], from: CGPoint(x: 512, y: 774), to: CGPoint(x: 512, y: 214), in: context)
    context.restoreGState()

    let top = CGRect(x: 286, y: 330, width: 452, height: 420)
    let topPath = CGPath(roundedRect: top, cornerWidth: 80, cornerHeight: 80, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.18).cgColor)
    context.addPath(topPath)
    context.setFillColor(Palette.capTopEdge.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(topPath)
    context.clip()
    let colours = [Palette.capTopCentre.cgColor, Palette.capTopEdge.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1])!
    context.drawRadialGradient(
        gradient, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 540), endRadius: 260, options: .drawsAfterEndLocation)
    context.restoreGState()

    // A downward arrow onto a bar: firmware going into the key.
    let centreX = top.midX
    context.setFillColor(Palette.glyph.cgColor)
    let shaft = CGRect(x: centreX - 38, y: 510, width: 76, height: 184)
    context.addPath(CGPath(roundedRect: shaft, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.fillPath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: centreX - 120, y: 552))
    head.addLine(to: CGPoint(x: centreX + 120, y: 552))
    head.addLine(to: CGPoint(x: centreX, y: 432))
    head.closeSubpath()
    context.addPath(head)
    context.setLineJoin(.round)
    context.setLineWidth(28)
    context.setStrokeColor(Palette.glyph.cgColor)
    context.drawPath(using: .fillStroke)
    let bar = CGRect(x: centreX - 128, y: 348, width: 256, height: 42)
    context.addPath(CGPath(roundedRect: bar, cornerWidth: 21, cornerHeight: 21, transform: nil))
    context.fillPath()
}

func fillLinear(_ colours: [NSColor], from start: CGPoint, to end: CGPoint, in context: CGContext) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours.map(\.cgColor) as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512].flatMap { points in [1, 2].map { IconSize(points: points, scale: $0) } }
for size in sizes {
    try render(pixels: size.pixels).write(to: iconset.appendingPathComponent(size.fileName))
}
if CommandLine.arguments.count > 1 {
    try render(pixels: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}

let output = repo.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
