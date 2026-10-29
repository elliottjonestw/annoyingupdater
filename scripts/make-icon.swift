import AppKit

// Draw a code-native icon using system symbols; no external asset dependencies.
let output = CommandLine.arguments[1]
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let rect = NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
        let shape = NSBezierPath(roundedRect: rect, xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.67, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.35, blue: 0.90, alpha: 1))!.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.57, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        symbol.draw(in: NSRect(x: side * 0.205, y: side * 0.205, width: side * 0.59, height: side * 0.59))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: temporary.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", output]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
