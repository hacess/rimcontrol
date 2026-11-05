#!/usr/bin/env swift
// Draws the app icon and writes it as an .icns file. Only needed when the design changes.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Fills a path with a vertical gradient. Y values are in the 1024-unit design space.
func fill(_ path: CGPath, in context: CGContext, from top: (CGFloat, UInt32), to bottom: (CGFloat, UInt32)) {
    let colors = [color(top.1), color(bottom.1)] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])
    else { return }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: top.0),
        end: CGPoint(x: 0, y: bottom.0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A vertical pill centred on `x`, used for the two lit edges.
func levelPill(x: CGFloat, top: CGFloat, bottom: CGFloat) -> CGPath {
    let halfWidth: CGFloat = 23
    let rect = CGRect(x: x - halfWidth, y: top - halfWidth, width: halfWidth * 2, height: bottom - top + halfWidth * 2)
    return roundedRect(rect, radius: halfWidth)
}

func drawIcon(in context: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    // Design space: 1024 units with y pointing down.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    // Tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    fill(roundedRect(tile, radius: 185), in: context, from: (100, 0x2B3040), to: (924, 0x11131A))
    context.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), radius: 183))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.09))
    context.setLineWidth(4)
    context.strokePath()

    // Trackpad
    let trackpad = CGRect(x: 232, y: 272, width: 560, height: 480)
    context.addPath(roundedRect(trackpad.insetBy(dx: 15, dy: 15), radius: 75))
    context.setFillColor(color(0xFFFFFF, alpha: 0.04))
    context.fillPath()
    context.addPath(roundedRect(trackpad, radius: 90))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.2))
    context.setLineWidth(30)
    context.strokePath()

    // Brightness on the left edge, volume on the right
    fill(levelPill(x: 232, top: 520, bottom: 662), in: context, from: (497, 0xFFC94D), to: (685, 0xFF8A1F))
    fill(levelPill(x: 792, top: 400, bottom: 662), in: context, from: (377, 0x5EF2E0), to: (685, 0x1FB6FF))

    // Fingertip on the volume edge
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: 742, y: 350, width: 100, height: 100))
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    drawIcon(in: context, pixels: pixels)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift scripts/make-icon.swift <output.icns>")
    exit(2)
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try writePNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", CommandLine.arguments[1], iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote \(CommandLine.arguments[1])")
