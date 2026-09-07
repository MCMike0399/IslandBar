import AppKit
import SwiftUI

struct ArtworkPalette: Equatable {
    var colors: [Color]

    static let fallback = ArtworkPalette(colors: [
        Color(red: 0.92, green: 0.93, blue: 0.96),
        Color(red: 0.78, green: 0.82, blue: 0.90),
        Color(red: 0.88, green: 0.80, blue: 0.74),
        Color(red: 0.70, green: 0.76, blue: 0.86),
    ])

    static func make(from image: NSImage?) -> ArtworkPalette {
        guard let image, let samples = samplePixels(image), !samples.isEmpty else {
            return .fallback
        }
        var buckets: [[NSColor]] = [[], [], [], []]
        for color in samples {
            let hue = color.usingColorSpace(.deviceRGB)?.hueComponent ?? 0
            let idx = min(3, Int(hue * 4.0))
            buckets[idx].append(color)
        }
        var result: [Color] = []
        for i in 0..<4 {
            if let avg = average(buckets[i]) {
                result.append(Color(nsColor: avg))
            } else if let avg = average(samples) {
                let shifted = avg.blended(withFraction: 0.18 * CGFloat(i), of: i % 2 == 0 ? .white : .black) ?? avg
                result.append(Color(nsColor: shifted))
            } else {
                result.append(Self.fallback.colors[i])
            }
        }
        return ArtworkPalette(colors: result)
    }

    private static func samplePixels(_ image: NSImage) -> [NSColor]? {
        let size = NSSize(width: 16, height: 16)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var colors: [NSColor] = []
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let s = c.saturationComponent
                let b = c.brightnessComponent
                if s > 0.12 && b > 0.12 && b < 0.96 {
                    colors.append(c)
                }
            }
        }
        return colors.isEmpty ? nil : colors
    }

    private static func average(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        for c in colors {
            let rgb = c.usingColorSpace(.deviceRGB) ?? c
            r += rgb.redComponent
            g += rgb.greenComponent
            b += rgb.blueComponent
            a += rgb.alphaComponent
        }
        let n = CGFloat(colors.count)
        return NSColor(deviceRed: r / n, green: g / n, blue: b / n, alpha: a / n)
    }
}
