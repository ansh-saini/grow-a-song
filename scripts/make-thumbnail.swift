// YouTube thumbnail (1280x720): app rings on the left, post-run selfie on the right.
// Usage: swift scripts/make-thumbnail.swift <face.png> <out.png>
import AppKit

let W = 1280, H = 720
let face = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: 0.06, green: 0.12, blue: 0.09, alpha: 1), CGColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// Selfie on the right, cropped to fill, with a soft left edge.
let faceRect = CGRect(x: 820, y: 0, width: 460, height: 720)
ctx.saveGState()
ctx.clip(to: faceRect)
let fs = face.size, scale = max(faceRect.width / fs.width, faceRect.height / fs.height)
let fw = fs.width * scale, fh = fs.height * scale
face.draw(in: CGRect(x: faceRect.midX - fw / 2 - 30, y: faceRect.midY - fh / 2, width: fw, height: fh))
ctx.restoreGState()
let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 0.04, green: 0.08, blue: 0.06, alpha: 1), CGColor(red: 0.04, green: 0.08, blue: 0.06, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(fade, start: CGPoint(x: 820, y: 0), end: CGPoint(x: 930, y: 0), options: [])

// Rings.
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.40, 0.55, 0.95), (0.55, 0.45, 0.95), (0.95, 0.45, 0.55),
                                             (0.98, 0.65, 0.30), (0.98, 0.88, 0.40), (0.45, 0.85, 0.55)]
let c = CGPoint(x: 205, y: 370)
for (i, col) in colors.enumerated() {
    let r = CGFloat(48 + i * 27)
    let color = CGColor(red: col.0, green: col.1, blue: col.2, alpha: 1)
    ctx.setShadow(offset: .zero, blur: 18, color: color.copy(alpha: 0.7))
    ctx.setStrokeColor(color)
    ctx.setLineWidth(13)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)

func draw(_ s: String, x: CGFloat, yTop: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, serif: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if serif, let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = 10
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .shadow: shadow])
    let h = a.size().height
    a.draw(at: CGPoint(x: x, y: CGFloat(H) - yTop - h))
}
draw("My run", x: 425, yTop: 165, size: 92, weight: .heavy, color: .white)
draw("wrote this", x: 425, yTop: 265, size: 92, weight: .heavy, color: .white)
draw("song", x: 425, yTop: 365, size: 92, weight: .heavy, color: NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1))
draw("Gemma on my iPhone · no server", x: 60, yTop: 650, size: 32, weight: .semibold, color: NSColor(white: 1, alpha: 0.75))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
