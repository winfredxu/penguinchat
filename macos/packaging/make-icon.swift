#!/usr/bin/env swift
// Renders AppIcon.icns from code so the repository carries no opaque binary
// asset that nobody can regenerate. Run: swift packaging/make-icon.swift
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "packaging/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("could not allocate \(size)pt bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Rounded-rect gradient plate, matching the macOS icon grid inset.
    let inset = side * 0.06
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let plate = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
    NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.94, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.58, alpha: 1)
    )?.draw(in: plate, angle: -90)

    let glyph = "🐧" as NSString
    let font = NSFont.systemFont(ofSize: side * 0.56)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let bounds = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: NSPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2 + side * 0.01),
        withAttributes: attributes
    )

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not rasterize \(size)pt icon")
    }
    return data
}

for size in sizes {
    let data = render(size: size)
    try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    // @2x slots reuse the next size up, which is what iconutil expects.
    if size >= 32, sizes.contains(size) {
        let half = size / 2
        try data.write(to: iconset.appendingPathComponent("icon_\(half)x\(half)@2x.png"))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "packaging/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote packaging/AppIcon.icns")
