// Draws the app icon: the widget's water tank behind its menu bar gauge.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's grid: an 824pt rounded square centred on a 1024pt canvas.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1),
                        NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)])!.draw(in: shape, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    for (offset, alpha) in [(0.04, 0.35), (0.0, 0.75)] {
        let water = NSBezierPath()
        let level = tile.minY + tile.height * (0.40 + offset)
        water.move(to: NSPoint(x: tile.minX, y: tile.minY))
        water.line(to: NSPoint(x: tile.minX, y: level))
        let steps = 48
        for step in 0...steps {
            let x = tile.minX + tile.width * CGFloat(step) / CGFloat(steps)
            let phase = CGFloat(step) / CGFloat(steps) * .pi * 2 + offset * 40
            water.line(to: NSPoint(x: x, y: level + sin(phase) * tile.height * 0.025))
        }
        water.line(to: NSPoint(x: tile.maxX, y: tile.minY))
        water.close()
        NSColor(red: 0.30, green: 0.58, blue: 0.95, alpha: alpha).setFill()
        water.fill()
    }
    NSColor.white.withAlphaComponent(0.55).setFill()
    for (x, y, r) in [(0.30, 0.18, 0.025), (0.62, 0.28, 0.018), (0.74, 0.12, 0.03), (0.45, 0.32, 0.014)] {
        NSBezierPath(ovalIn: NSRect(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y,
                                    width: tile.width * r * 2, height: tile.width * r * 2)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let box = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - box.width / 2, y: tile.minY + tile.height * 0.56 - box.height / 2,
                               width: box.width, height: box.height))
    }
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = max(1, size / 512)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(points * scale).write(to: output.appendingPathComponent(name))
    }
}
