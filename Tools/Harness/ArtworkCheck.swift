// Compile with the production ArtworkImage.swift. Writes a high-resolution cover for
// the real player's --artwork option, then checks dimensions, alpha and orientation.
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct ArtworkCheck {
    static func fixture(width: Int, height: Int, type: UTType = .png, orientation: Int = 1) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 0.7))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func pixels(_ image: NSImage) -> (Int, Int) {
        let rep = image.representations[0]
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    static func main() throws {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL")  \(description)")
            if !condition { failures += 1 }
        }
        let large = fixture(width: 4096, height: 4096)
        if CommandLine.arguments.count == 2 {
            try large.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let image = ArtworkImage.decode(large)!
        check(pixels(image) == (256, 256), "4096 px artwork is bounded to 256 px")
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let red = bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        let blue = bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        let original = NSBitmapImageRep(data: large)!
        let originalRed = original.colorAt(x: original.pixelsWide / 4, y: original.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        let originalBlue = original.colorAt(x: original.pixelsWide * 3 / 4, y: original.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        check(abs(red.redComponent - originalRed.redComponent) < 0.03
              && abs(blue.blueComponent - originalBlue.blueComponent) < 0.03,
              "cover colours survive decoding")
        check(abs(blue.alphaComponent - 0.7) < 0.03, "transparent artwork keeps its alpha")
        let portrait = ArtworkImage.decode(fixture(width: 512, height: 1024))!
        check(pixels(portrait) == (128, 256), "portrait artwork stays bounded and keeps its aspect ratio")
        let small = ArtworkImage.decode(fixture(width: 64, height: 32))!
        check(pixels(small) == (64, 32), "small artwork is not enlarged")
        let rotated = ArtworkImage.decode(fixture(width: 64, height: 32, type: .jpeg, orientation: 6))!
        check(pixels(rotated) == (32, 64), "EXIF orientation is applied")
        check(ArtworkImage.decode(Data("invalid image".utf8)) == nil, "invalid artwork is rejected")
        exit(failures == 0 ? 0 : 1)
    }
}
