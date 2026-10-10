// Draws the demo video's cards in the app's ring style (1080x1920).
// Usage: swift scripts/make-demo-frames.swift <outDir>
import AppKit

let W = 1080, H = 1920
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let colors: [NSColor] = [
    NSColor(red: 0.40, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.55, green: 0.45, blue: 0.95, alpha: 1),
    NSColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1), NSColor(red: 0.98, green: 0.65, blue: 0.30, alpha: 1),
    NSColor(red: 0.98, green: 0.88, blue: 0.40, alpha: 1), NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1),
]
let layerNames = ["Drone", "Pads", "Bass", "Drums", "Melody", "Field recording"]
let unlockAt = ["0 min", "2 min", "5 min", "8 min", "13 min", "20 min"]

func card(_ name: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [CGColor(red: 0.05, green: 0.10, blue: 0.08, alpha: 1), CGColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: .zero, options: [])
    draw(ctx)
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
}

/// y is measured from the top, like a screen.
func text(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
          serif: Bool = false, italic: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if serif, let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    let rect = attr.boundingRect(with: CGSize(width: W - 140, height: 2000), options: [.usesLineFragmentOrigin])
    attr.draw(with: CGRect(x: 70, y: CGFloat(H) - y - rect.height, width: CGFloat(W - 140), height: rect.height),
              options: [.usesLineFragmentOrigin])
}

func rings(_ ctx: CGContext, lit: Int, centerY: CGFloat) {
    let c = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) - centerY)
    for i in 0..<6 {
        let r = CGFloat(150 + i * 58)
        let on = i < lit
        ctx.setStrokeColor(colors[i].withAlphaComponent(on ? 0.95 : 0.13).cgColor)
        ctx.setLineWidth(on ? 26 : 8)
        if on { ctx.setShadow(offset: .zero, blur: 28, color: colors[i].withAlphaComponent(0.6).cgColor) }
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

let dim = NSColor(white: 1, alpha: 0.6)

card("00-title") { ctx in
    rings(ctx, lit: 6, centerY: 880)
    text("Grow a Song", y: 190, size: 104, weight: .semibold, serif: true)
    text("My run wrote its own soundtrack.", y: 1400, size: 50, color: dim, italic: true)
    text("Gemma 3 1B, running on my iPhone", y: 1520, size: 44, weight: .medium, color: colors[5])
}

for stage in 1...6 {
    card(String(format: "%02d-stage", stage)) { ctx in
        rings(ctx, lit: stage, centerY: 860)
        text("EPHEMERAL ECHOES", y: 200, size: 40, weight: .semibold, color: dim)
        text("D dorian · 160 bpm · composed by Gemma", y: 270, size: 36, color: NSColor(white: 1, alpha: 0.4))
        text("\(unlockAt[stage - 1]) outside", y: 1430, size: 64, weight: .semibold)
        text("+ \(layerNames[stage - 1])", y: 1530, size: 58, weight: .medium, color: colors[stage - 1])
    }
}

card("07-stats") { ctx in
    rings(ctx, lit: 6, centerY: 640)
    text("Friday, 7 AM", y: 1120, size: 46, color: dim)
    text("35.1 min outside\n3.4 km\n6 of 6 layers", y: 1200, size: 72, weight: .semibold)
    text("No server. No account. Works offline.", y: 1610, size: 42, color: colors[5])
}

card("075-app-bg") { _ in
    text("The app", y: 70, size: 56, weight: .semibold, serif: true)
    text("every day gets its own song", y: 150, size: 38, color: dim, italic: true)
}

card("08-selfie-bg") { _ in
    text("After the run", y: 110, size: 60, weight: .semibold, serif: true)
    text("listening back to the song I grew", y: 200, size: 42, color: dim, italic: true)
}

card("09-end") { ctx in
    rings(ctx, lit: 6, centerY: 880)
    text("Grow a Song", y: 190, size: 96, weight: .semibold, serif: true)
    text("Open weights. Your data stays on your phone.", y: 1400, size: 44, color: dim)
    text("Go outside. Finish your song.", y: 1520, size: 54, weight: .medium, color: colors[5])
}
print("frames in \(out.path)")
