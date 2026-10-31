import AppKit

let width = 660, height = 420
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocusFlipped(true)
NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: y, width: 600, height: 48), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
    ])
}
text("upd8er", y: 42, size: 24, weight: .semibold, color: NSColor(calibratedWhite: 0.12, alpha: 1))
text("A little persistence. A more up-to-date Mac.", y: 80, size: 13, weight: .regular, color: .secondaryLabelColor)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 302, y: 205)); arrow.line(to: NSPoint(x: 358, y: 205))
arrow.move(to: NSPoint(x: 346, y: 193)); arrow.line(to: NSPoint(x: 358, y: 205)); arrow.line(to: NSPoint(x: 346, y: 217))
arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.65, alpha: 1).setStroke(); arrow.stroke()
text("Drag upd8er to Applications to install.", y: 350, size: 13, weight: .regular, color: .secondaryLabelColor)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
