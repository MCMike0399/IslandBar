import AppKit
import ImageIO

/// Artwork is shown at 80 pt (160 px on Retina) and sampled at 48 px for its palette.
/// Decode a little larger than either consumer needs, without caching a full-size cover.
enum ArtworkImage {
    static let maxPixelSize = 256

    static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            // Keep NSImage's support for formats ImageIO cannot thumbnail.
            return NSImage(data: data)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
}
