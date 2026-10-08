// Draws the app icon: six layer rings on dark green. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.40, 0.55, 0.95), (0.55, 0.45, 0.95), (0.95, 0.45, 0.55),
                                             (0.98, 0.65, 0.30), (0.98, 0.88, 0.40), (0.45, 0.85, 0.55)]
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: 0.07, green: 0.14, blue: 0.11, alpha: 1), CGColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])
let c = CGPoint(x: size / 2, y: size / 2)
for (i, col) in colors.enumerated() {
    let r = CGFloat(110 + i * 62)
    ctx.setStrokeColor(CGColor(red: col.0, green: col.1, blue: col.2, alpha: 1))
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    // Each ring is open at the bottom right, more open on the outer (later) rings, like growth.
    let gap = CGFloat(i) * 0.18
    ctx.addArc(center: c, radius: r, startAngle: -.pi / 2 + gap, endAngle: 1.5 * .pi - 0.05, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(CGColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1))
ctx.fillEllipse(in: CGRect(x: c.x - 44, y: c.y - 44, width: 88, height: 88))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
