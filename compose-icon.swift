#!/usr/bin/swift
// Composites the transparent artwork PNG over a glass-blue gradient background.
// Usage: swift compose-icon.swift <artwork.png> <output.png>
import AppKit

guard CommandLine.arguments.count == 3 else {
    print("Usage: compose-icon <artwork.png> <output.png>"); exit(1)
}
let inputPath  = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let artwork = NSImage(contentsOfFile: inputPath) else {
    print("Cannot load \(inputPath)"); exit(1)
}

let sz = NSSize(width: 1024, height: 1024)
let result = NSImage(size: sz)
result.lockFocus()

// ── Glass-blue gradient: lighter (top) → deeper (bottom) ──────────────────
NSGradient(colors: [
    NSColor(calibratedRed: 0.78, green: 0.89, blue: 0.97, alpha: 1),
    NSColor(calibratedRed: 0.52, green: 0.70, blue: 0.88, alpha: 1),
])!.draw(in: NSRect(origin: .zero, size: sz), angle: 270)

// ── Specular sheen: white glow fading from top ~38% down ──────────────────
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.28),
    NSColor.white.withAlphaComponent(0.00),
])!.draw(in: NSRect(x: 0, y: 635, width: 1024, height: 389), angle: 270)

// ── Artwork composited over the background ────────────────────────────────
artwork.draw(in: NSRect(origin: .zero, size: sz),
             from: .zero, operation: .sourceOver, fraction: 1.0)

result.unlockFocus()

// Write PNG
guard let tiff   = result.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png    = bitmap.representation(using: .png, properties: [:])
else { print("Failed to encode PNG"); exit(1) }

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath)")
} catch {
    print("Write failed: \(error)"); exit(1)
}
