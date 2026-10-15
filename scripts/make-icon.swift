// Draws the BalanceKeeper app icon: a balance slider with its knob locked in the center, between sound waves for
// the left and right channels, on a dark rounded square.
// Usage: swift scripts/make-icon.swift <project-dir>
// Writes Resources/AppIcon.icns and .build/AppIcon-preview.png.
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map { color($0) } as CFArray, locations: locations)!
}

// Drawn on a 1024 canvas, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                      transform: nil)

    // Background: deep teal night, lighter in the middle.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x1D5560, 0x10343D, 0x081C22], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [color(0x7FE3D6, 0.22), color(0x7FE3D6, 0)] as CFArray,
                                      locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 430, options: [])
    ctx.restoreGState()

    let y: CGFloat = 512

    // Sound waves for the left and right channels, mirrored.
    ctx.setLineCap(.round)
    for (radius, alpha, width) in [(120.0, 0.85, 26.0), (190.0, 0.5, 24.0)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setStrokeColor(color(0xBFF3EC, alpha))
        ctx.setLineWidth(width)
        // Left: arcs opening to the left, centered right of the left edge.
        ctx.addArc(center: CGPoint(x: 400, y: y), radius: radius, startAngle: .pi * 0.78, endAngle: .pi * 1.22, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: 624, y: y), radius: radius, startAngle: -.pi * 0.22, endAngle: .pi * 0.22, clockwise: false)
        ctx.strokePath()
    }

    // Slider track between the waves, with a center tick.
    let track = CGPath(roundedRect: CGRect(x: 300, y: y - 14, width: 424, height: 28), cornerWidth: 14, cornerHeight: 14,
                       transform: nil)
    ctx.addPath(track)
    ctx.setFillColor(color(0xFFFFFF, 0.28))
    ctx.fillPath()
    ctx.setFillColor(color(0xFFFFFF, 0.55))
    ctx.fill(CGRect(x: 507, y: y + 70, width: 10, height: 44))
    ctx.fill(CGRect(x: 507, y: y - 114, width: 10, height: 44))

    // Knob, locked in the center, glowing.
    let knob = CGRect(x: 512 - 74, y: y - 74, width: 148, height: 148)
    ctx.saveGState()
    for (blur, glow) in [(60.0, 0x7FE3D6), (24.0, 0xBFF3EC)] as [(CGFloat, UInt32)] {
        ctx.setShadow(offset: .zero, blur: blur, color: color(glow, 0.9))
        ctx.addEllipse(in: knob)
        ctx.setFillColor(color(0xF4FFFD))
        ctx.fillPath()
    }
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: knob)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0xFFFFFF, 0xD7EFEB], [0, 1]),
                           start: CGPoint(x: 0, y: knob.maxY), end: CGPoint(x: 0, y: knob.minY), options: [])
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let build = "\(root)/.build"
let iconset = "\(build)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), "\(iconset)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
writePNG(render(1024), "\(build)/AppIcon-preview.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(root)/Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
