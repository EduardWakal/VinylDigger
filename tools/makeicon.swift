import AppKit
import CoreGraphics
import Foundation

// Renders the VinylDigger app icon: a record on a dark tile, amber label in the
// middle. At 16 px the grooves vanish and what is left is a dark square with a
// warm dot — still tellable apart in the Dock.
func drawIcon(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.saveGState()

    // macOS rounds icons itself on recent systems, but the squircle is baked in
    // so the tile also looks right wherever it is shown unmasked.
    let inset = size * 0.055
    let tile = rect.insetBy(dx: inset, dy: inset)
    let corner = tile.width * 0.2237
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil
    )
    context.addPath(tilePath)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let backdrop = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.13, green: 0.16, blue: 0.19, alpha: 1),
            CGColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: []
    )

    let center = CGPoint(x: rect.midX, y: rect.midY)
    let recordRadius = size * 0.335

    // Record body, slightly lighter at the top left so it reads as a disc.
    let discGradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1),
            CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.addArc(
        center: center, radius: recordRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.clip()
    context.drawRadialGradient(
        discGradient,
        startCenter: CGPoint(x: center.x - recordRadius * 0.4, y: center.y + recordRadius * 0.4),
        startRadius: 0,
        endCenter: center,
        endRadius: recordRadius * 1.3,
        options: []
    )
    context.restoreGState()

    // Grooves. Thin enough to disappear below ~64 px instead of turning to mush.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    context.setLineWidth(max(size * 0.004, 0.5))
    var groove = recordRadius * 0.95
    while groove > recordRadius * 0.42 {
        context.addArc(
            center: center, radius: groove, startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        context.strokePath()
        groove -= recordRadius * 0.075
    }

    // Amber centre label — the part that survives at small sizes.
    let labelRadius = recordRadius * 0.375
    let labelGradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.98, green: 0.76, blue: 0.29, alpha: 1),
            CGColor(red: 0.86, green: 0.45, blue: 0.13, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.addArc(
        center: center, radius: labelRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.clip()
    context.drawLinearGradient(
        labelGradient,
        start: CGPoint(x: center.x - labelRadius, y: center.y + labelRadius),
        end: CGPoint(x: center.x + labelRadius, y: center.y - labelRadius),
        options: []
    )
    context.restoreGState()

    // Spindle hole.
    context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1))
    context.addArc(
        center: center, radius: labelRadius * 0.17,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.fillPath()

    // Sheen across the top left, keeps the disc from looking flat.
    context.saveGState()
    context.addArc(
        center: center, radius: recordRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.clip()
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: center.x - recordRadius, y: center.y + recordRadius),
        end: CGPoint(x: center.x + recordRadius * 0.2, y: center.y - recordRadius * 0.2),
        options: []
    )
    context.restoreGState()

    context.restoreGState()
}

func writePNG(size: Int, to url: URL) throws {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "icon", code: 1) }

    context.setAllowsAntialiasing(true)
    drawIcon(size: side, into: context)

    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true
)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try writePNG(size: size, to: outputDirectory.appendingPathComponent("icon_\(size).png"))
    print("wrote icon_\(size).png")
}
