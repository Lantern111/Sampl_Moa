import AppKit

// Draws the disk image's window background as background.png and background@2x.png.
// Usage: swift dmg-background.swift <logo.svg> <output directory>
//
// Finder writes icon labels in black in Light Mode and white in Dark Mode, on top of this picture and out of our
// control. So the background is a mid-tone gray, which both colors stay readable against. The icon positions it draws
// around are set in dmg-settings.py.

let canvas = NSSize(width: 680, height: 560)
let iconRowY: CGFloat = 195
let arrowStartX: CGFloat = 270
let arrowEndX: CGFloat = 410
let textX: CGFloat = 205

func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceIn)
        return true
    }
}

func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, opacity: CGFloat = 1, y: CGFloat, x: CGFloat? = nil) {
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(opacity),
    ])
    let width = string.size().width
    string.draw(at: NSPoint(x: x ?? (canvas.width - width) / 2, y: y))
}

func drawContents(logo: NSImage) {
    NSGradient(
        starting: NSColor(srgbRed: 0x7C / 255, green: 0x7C / 255, blue: 0x80 / 255, alpha: 1),
        ending: NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x72 / 255, alpha: 1)
    )?.draw(in: NSRect(origin: .zero, size: canvas), angle: 90)

    let logoHeight: CGFloat = 26
    let logoWidth = logoHeight * logo.size.width / logo.size.height
    tinted(logo, with: .white).draw(
        in: NSRect(x: (canvas.width - logoWidth) / 2, y: 28, width: logoWidth, height: logoHeight),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
    )
    drawText("Sampl Moa를 Applications 폴더로 끌어다 놓으세요", size: 20, weight: .semibold, y: 64)
    drawText("Drag Sampl Moa onto the Applications folder", size: 13, weight: .regular, opacity: 0.92, y: 94)

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: arrowStartX, y: iconRowY))
    shaft.line(to: NSPoint(x: arrowEndX - 4, y: iconRowY))
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: arrowEndX - 20, y: iconRowY - 16))
    head.line(to: NSPoint(x: arrowEndX, y: iconRowY))
    head.line(to: NSPoint(x: arrowEndX - 20, y: iconRowY + 16))
    head.lineWidth = 6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    NSColor.white.setStroke()
    shaft.stroke()
    head.stroke()

    NSColor.white.withAlphaComponent(0.25).setFill()
    NSRect(x: 40, y: 298, width: canvas.width - 80, height: 1).fill()

    drawText("처음 열 때 경고가 뜨면", size: 14, weight: .semibold, y: 318, x: textX)
    drawText("시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기", size: 14, weight: .regular, y: 339, x: textX)
    drawText("If a warning appears the first time", size: 12.5, weight: .semibold, y: 372, x: textX)
    drawText("System Settings → Privacy & Security → Open Anyway", size: 12.5, weight: .regular, y: 391, x: textX)
    drawText("자세한 방법은 왼쪽 안내문을 열어 보세요 · See the guide on the left for details", size: 12, weight: .regular, opacity: 0.92, y: 424, x: textX)
}

func writeBackground(logo: NSImage, scale: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width) * scale,
        pixelsHigh: Int(canvas.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = canvas

    // Top-left origin, the same way Finder counts icon positions.
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawContents(logo: logo)
    NSGraphicsContext.restoreGraphicsState()

    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let logo = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("Usage: swift dmg-background.swift <logo.svg> <output directory>")
}
let output = URL(fileURLWithPath: arguments[2])
try writeBackground(logo: logo, scale: 1, to: output.appending(path: "background.png"))
try writeBackground(logo: logo, scale: 2, to: output.appending(path: "background@2x.png"))
