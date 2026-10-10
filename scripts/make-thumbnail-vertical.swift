// Vertical YouTube Shorts thumbnail (1080x1920): post-run selfie on top, headline and rings below.
// Usage: swift scripts/make-thumbnail-vertical.swift <face.png> <out.png>
import AppKit

let W = 1080, H = 1920
let face = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let dark = CGColor(red: 0.04, green: 0.08, blue: 0.06, alpha: 1)
ctx.setFillColor(dark)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// Selfie fills the top 1200 px (y measured from the bottom in CoreGraphics).
let faceRect = CGRect(x: 0, y: CGFloat(H - 1200), width: CGFloat(W), height: 1200)
ctx.saveGState()
ctx.clip(to: faceRect)
let fs = face.size, scale = max(faceRect.width / fs.width, faceRect.height / fs.height)
let fw = fs.width * scale, fh = fs.height * scale
face.draw(in: CGRect(x: faceRect.midX - fw / 2, y: faceRect.midY - fh / 2, width: fw, height: fh))
ctx.restoreGState()
let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [dark, dark.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: CGFloat(H - 1200)), end: CGPoint(x: 0, y: CGFloat(H - 920)), options: [])

func draw(_ s: String, yTop: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
    shadow.shadowBlurRadius = 14
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .shadow: shadow])
    let sz = a.size()
    a.draw(at: CGPoint(x: (CGFloat(W) - sz.width) / 2, y: CGFloat(H) - yTop - sz.height))
}
let green = NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1)
draw("My run", yTop: 1010, size: 150, weight: .heavy, color: .white)
draw("wrote this song", yTop: 1180, size: 128, weight: .heavy, color: green)

// Rings.
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.40, 0.55, 0.95), (0.55, 0.45, 0.95), (0.95, 0.45, 0.55),
                                             (0.98, 0.65, 0.30), (0.98, 0.88, 0.40), (0.45, 0.85, 0.55)]
let c = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) - 1555)
for (i, col) in colors.enumerated() {
    let r = CGFloat(34 + i * 20)
    let color = CGColor(red: col.0, green: col.1, blue: col.2, alpha: 1)
    ctx.setShadow(offset: .zero, blur: 16, color: color.copy(alpha: 0.7))
    ctx.setStrokeColor(color)
    ctx.setLineWidth(10)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)
draw("Gemma on my iPhone · no server", yTop: 1735, size: 50, weight: .semibold, color: NSColor(white: 1, alpha: 0.8))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
