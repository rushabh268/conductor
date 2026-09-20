#!/usr/bin/env swift

import AppKit
import CoreGraphics

func generateIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let context = NSGraphicsContext.current!.cgContext

    // Background - dark gradient
    let bgColors = [
        CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0),
        CGColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1.0)
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors as CFArray, locations: [0.0, 1.0])!

    // Rounded rect background
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

    // Draw conductor baton (diagonal line)
    let s = CGFloat(size)
    context.setStrokeColor(CGColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1.0))
    context.setLineWidth(s * 0.03)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: s * 0.35, y: s * 0.65))
    context.addLine(to: CGPoint(x: s * 0.7, y: s * 0.3))
    context.strokePath()

    // Draw music waves (three arcs)
    let waveColors: [(CGFloat, CGFloat, CGFloat)] = [
        (1.0, 0.6, 0.2),   // orange
        (0.3, 0.7, 1.0),   // blue
        (0.5, 1.0, 0.5),   // green
    ]
    for (i, color) in waveColors.enumerated() {
        context.setStrokeColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 0.8))
        context.setLineWidth(s * 0.025)

        let yOffset = s * (0.45 + CGFloat(i) * 0.1)
        let wave = CGMutablePath()
        wave.move(to: CGPoint(x: s * 0.15, y: yOffset))
        wave.addCurve(
            to: CGPoint(x: s * 0.85, y: yOffset),
            control1: CGPoint(x: s * 0.35, y: yOffset - s * 0.12),
            control2: CGPoint(x: s * 0.65, y: yOffset + s * 0.12)
        )
        context.addPath(wave)
        context.strokePath()
    }

    // Draw small circle at baton tip
    context.setFillColor(CGColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1.0))
    let tipSize = s * 0.04
    context.fillEllipse(in: CGRect(x: s * 0.7 - tipSize, y: s * 0.3 - tipSize, width: tipSize * 2, height: tipSize * 2))

    image.unlockFocus()
    return image
}

// Generate all required sizes
let sizes = [16, 32, 128, 256, 512]
let outputDir = "Conductor/Conductor/Assets.xcassets/AppIcon.appiconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for size in sizes {
    let image = generateIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(size)x\(size).png"))
    print("Generated \(size)x\(size)")
}

// Also generate @2x versions
for size in [16, 32, 128, 256, 512] {
    let actualSize = size * 2
    let image = generateIcon(size: actualSize)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(size)x\(size)@2x.png"))
    print("Generated \(size)x\(size)@2x")
}

// Create Contents.json
let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("Generated Contents.json")
