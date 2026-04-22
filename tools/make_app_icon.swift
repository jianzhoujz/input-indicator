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

    let cornerRadius = CGFloat(pixels) * 0.22
    let background = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.30, alpha: 1)
    ])
    gradient?.draw(in: background, angle: -35)

    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    background.lineWidth = max(1, CGFloat(pixels) * 0.012)
    background.stroke()

    let shadow = NSShadow()
    shadow.shadowBlurRadius = CGFloat(pixels) * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixels) * 0.015)
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)

    let font = NSFont.systemFont(ofSize: CGFloat(pixels) * 0.58, weight: .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraph,
        .shadow: shadow
    ]

    let attributed = NSAttributedString(string: emoji, attributes: attributes)
    let textSize = attributed.size()
    let textRect = NSRect(
        x: (size.width - textSize.width) / 2,
        y: (size.height - textSize.height) / 2 + CGFloat(pixels) * 0.012,
        width: textSize.width,
        height: textSize.height
    )
    attributed.draw(in: textRect)

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
