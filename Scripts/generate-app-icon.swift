#!/usr/bin/env swift
import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.dropFirst().first ?? "Resources"
let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
let sourceURL = outputURL.appendingPathComponent("AIQuotaBarIconSource.png")
let iconsetURL = outputURL.appendingPathComponent("AIQuotaBar.iconset", isDirectory: true)
let icnsURL = outputURL.appendingPathComponent("AIQuotaBar.icns")

let fileManager = FileManager.default
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(
        domain: "AIQuotaBarIcon",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法读取图标源图 \(sourceURL.path)"]
    )
}

func drawSourceImage(in rect: NSRect) {
    let sourceSize = sourceImage.size
    let sourceAspect = sourceSize.width / sourceSize.height
    let targetAspect = rect.width / rect.height
    var cropRect = NSRect(origin: .zero, size: sourceSize)

    if sourceAspect > targetAspect {
        let width = sourceSize.height * targetAspect
        cropRect.origin.x = (sourceSize.width - width) / 2
        cropRect.size.width = width
    } else if sourceAspect < targetAspect {
        let height = sourceSize.width / targetAspect
        cropRect.origin.y = (sourceSize.height - height) / 2
        cropRect.size.height = height
    }

    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(in: rect, from: cropRect, operation: .copy, fraction: 1)
}

func writePNG(name: String, pixelSize: Int) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "AIQuotaBarIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 \(name) bitmap"])
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawSourceImage(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AIQuotaBarIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成 \(name)"])
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for output in outputs {
    try writePNG(name: output.0, pixelSize: output.1)
}

if fileManager.fileExists(atPath: icnsURL.path) {
    try fileManager.removeItem(at: icnsURL)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "AIQuotaBarIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil 生成 icns 失败"])
}

print("Generated \(icnsURL.path)")
