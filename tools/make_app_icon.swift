import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: make_app_icon.swift <output.iconset> <emoji>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let emoji = arguments[2]
let fileManager = FileManager.default

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
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

func drawIcon(pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(origin: .zero, size: size)
    NSColor.clear.setFill()
    rect.fill()

    let tileRect = rect.insetBy(dx: CGFloat(pixels) * 0.055, dy: CGFloat(pixels) * 0.055)
    let cornerRadius = CGFloat(pixels) * 0.215
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowBlurRadius = CGFloat(pixels) * 0.040
    tileShadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixels) * 0.018)
    tileShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
    tileShadow.set()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.54, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.76, blue: 0.86, alpha: 1)
    ])
    gradient?.draw(in: tile, angle: -28)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    let faceRect = NSRect(
        x: CGFloat(pixels) * 0.205,
        y: CGFloat(pixels) * 0.185,
        width: CGFloat(pixels) * 0.590,
        height: CGFloat(pixels) * 0.590
    )
    let face = NSBezierPath(ovalIn: faceRect)

    NSGraphicsContext.saveGraphicsState()
    let faceShadow = NSShadow()
    faceShadow.shadowBlurRadius = CGFloat(pixels) * 0.030
    faceShadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixels) * 0.012)
    faceShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
    faceShadow.set()

    let faceGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.26, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.63, blue: 0.10, alpha: 1)
    ])
    faceGradient?.draw(in: face, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedWhite: 1, alpha: 0.24).setStroke()
    face.lineWidth = max(1, CGFloat(pixels) * 0.012)
    face.stroke()

    let featureColor = NSColor(calibratedRed: 0.28, green: 0.17, blue: 0.08, alpha: 0.95)
    featureColor.setFill()

    let eyeWidth = CGFloat(pixels) * 0.062
    let eyeHeight = CGFloat(pixels) * 0.100
    let eyeY = CGFloat(pixels) * 0.535
    NSBezierPath(ovalIn: NSRect(x: CGFloat(pixels) * 0.365, y: eyeY, width: eyeWidth, height: eyeHeight)).fill()
    NSBezierPath(ovalIn: NSRect(x: CGFloat(pixels) * 0.573, y: eyeY, width: eyeWidth, height: eyeHeight)).fill()

    let zipperBase = NSRect(
        x: CGFloat(pixels) * 0.330,
        y: CGFloat(pixels) * 0.405,
        width: CGFloat(pixels) * 0.340,
        height: CGFloat(pixels) * 0.044
    )
    NSColor(calibratedRed: 0.34, green: 0.20, blue: 0.08, alpha: 0.98).setFill()
    NSBezierPath(roundedRect: zipperBase, xRadius: CGFloat(pixels) * 0.020, yRadius: CGFloat(pixels) * 0.020).fill()

    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    let toothCount = 7
    let toothWidth = CGFloat(pixels) * 0.026
    let toothHeight = CGFloat(pixels) * 0.030
    let toothGap = (zipperBase.width - CGFloat(toothCount) * toothWidth) / CGFloat(toothCount + 1)
    for index in 0..<toothCount {
        let x = zipperBase.minX + toothGap + CGFloat(index) * (toothWidth + toothGap)
        let y = zipperBase.midY - toothHeight / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: toothWidth, height: toothHeight), xRadius: toothWidth * 0.18, yRadius: toothWidth * 0.18).fill()
    }

    NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
    let pullRect = NSRect(
        x: zipperBase.maxX - CGFloat(pixels) * 0.018,
        y: zipperBase.minY - CGFloat(pixels) * 0.020,
        width: CGFloat(pixels) * 0.048,
        height: CGFloat(pixels) * 0.078
    )
    NSBezierPath(roundedRect: pullRect, xRadius: CGFloat(pixels) * 0.014, yRadius: CGFloat(pixels) * 0.014).fill()
    NSColor(calibratedRed: 0.42, green: 0.42, blue: 0.44, alpha: 1).setStroke()
    let pullHole = NSBezierPath(ovalIn: pullRect.insetBy(dx: CGFloat(pixels) * 0.012, dy: CGFloat(pixels) * 0.020))
    pullHole.lineWidth = max(1, CGFloat(pixels) * 0.004)
    pullHole.stroke()

    NSGraphicsContext.restoreGraphicsState()

    if emoji != "🤐" {
        let font = NSFont.systemFont(ofSize: CGFloat(pixels) * 0.15, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributed = NSAttributedString(string: emoji, attributes: attributes)
        attributed.draw(at: NSPoint(x: CGFloat(pixels) * 0.74, y: CGFloat(pixels) * 0.14))
    }

    return image
}

for size in sizes {
    let image = drawIcon(pixels: size.pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to render \(size.name)\n", stderr)
        exit(1)
    }

    try png.write(to: outputURL.appendingPathComponent(size.name))
}
