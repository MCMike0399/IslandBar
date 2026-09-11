import AppKit
import SwiftUI

struct ArtworkPalette: Equatable {
    var colors: [Color]

    /// Shown before any artwork arrives: a quiet lavender-to-mist wash, clearly "no
    /// track yet" next to the colour a real cover produces, and never mistaken for
    /// a white-covered album (the old white/blue/peach sweep was).
    static let fallback: ArtworkPalette = {
        let anchors = [
            Oklab.fromSRGB(r: 0.62, g: 0.60, b: 0.90),
            Oklab.fromSRGB(r: 0.70, g: 0.68, b: 0.92),
            Oklab.fromSRGB(r: 0.78, g: 0.80, b: 0.94),
            Oklab.fromSRGB(r: 0.86, g: 0.90, b: 0.95),
        ]
        return ArtworkPalette(colors: colors(through: anchors))
    }()

    /// Lightness band and chroma clamp for the displayed bars. Pastel on purpose: the
    /// island tint has to sit on a black pill without shouting, and a lower chroma
    /// cap is what keeps a red cover and a blue cover looking like the same product
    /// while still being unmistakably red and blue.
    private static let minL = 0.70
    private static let maxL = 0.93
    private static let chromaScale = 0.9
    private static let minChroma = 0.05
    private static let maxChroma = 0.12
    /// The band the same palette is mapped into when the bars sit on a light menu bar
    /// instead of the black pill. Pastels and the near-white end of the ramp vanish on
    /// white, so lightness drops below the midpoint and the chroma cap is raised a
    /// little: the bars keep the cover's hue but gain enough weight to be read.
    private static let lightMinL = 0.34
    private static let lightMaxL = 0.60
    private static let lightChromaScale = 1.35
    private static let lightMaxChroma = 0.16
    /// How far the secondary picks are pulled towards the dominant colour before
    /// they become gradient anchors. 0 keeps every cluster as-is (rainbow sweep);
    /// 1 collapses the bars to one flat colour.
    private static let blendTowardDominant = 0.5

    /// Extracts up to four distinct dominant colours from the artwork by k-means
    /// clustering in Oklab and spreads them across the bars as a smooth gradient, the
    /// way the iPhone's Dynamic Island tints its Now Playing waveform. The most
    /// dominant colour sets the family; the others are pulled towards it so the
    /// gradient reads as one tint with a soft shift, not four competing hues. Hue is
    /// preserved; lightness is lifted and chroma is clamped so the bars stay legible
    /// and calm on the black pill. Greyscale art yields grey bars instead of an
    /// invented tint.
    static func make(from image: NSImage?) -> ArtworkPalette {
        guard let image, let pixels = samplePixels(image), pixels.count >= 16 else {
            return .fallback
        }
        let picks = pickPalette(clusterize(pixels))
        guard !picks.isEmpty else { return .fallback }
        return ArtworkPalette(colors: colors(through: picks))
    }

    /// Interpolates the anchors in Oklab into one colour per bar and maps them for display.
    static func colors(through anchors: [Oklab]) -> [Color] {
        let n = BarLevels.count
        guard anchors.count > 1 else {
            return (0..<n).map { _ in Color(nsColor: display(anchors[0])) }
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1) * Double(anchors.count - 1)
            let k = min(anchors.count - 2, Int(t))
            let f = t - Double(k)
            return Color(nsColor: display(anchors[k].mixed(toward: anchors[k + 1], f)))
        }
    }

    // MARK: Cluster selection

    /// k-means over the whole image, plus a separate pass over just the colourful pixels.
    /// On a dark cover with a thin red streak the main pass spends every cluster on shades
    /// of black and the red is averaged away; the accent pass keeps it as a candidate.
    static func clusterize(_ pixels: [Oklab]) -> [Cluster] {
        var clusters = kMeans(pixels, k: 10, iterations: 16)
        let accents = pixels.filter { $0.chroma >= 0.08 }
        let accentFraction = Double(accents.count) / Double(pixels.count)
        if accentFraction >= 0.004, accents.count >= 9 {
            // A tiny accent must stay one candidate; splitting it would push every
            // piece under the population floor.
            let k = accentFraction < 0.03 ? 1 : 5
            let scale = accentFraction
            for var c in kMeans(accents, k: k, iterations: 10) {
                c.population *= scale
                clusters.append(c)
            }
        }
        return clusters
    }

    struct Cluster {
        /// Mean of the cluster (used for distances).
        var center: Oklab
        /// Chroma-weighted mean: the colour the vivid pixels of this cluster actually are.
        /// Averaging a red logo with its anti-aliased edge yields brick; this stays red.
        var vivid: Oklab
        var population: Double
        /// RMS distance of members to the centre. A wide cluster is a blend of two
        /// colours (blue + yellow averages to a green nobody painted) and is distrusted.
        var spread: Double
    }

    static func score(_ c: Cluster) -> Double {
        // Population matters most, chroma breaks ties towards the colour you would
        // name the cover by, and near-black clusters are discounted (they are usually
        // background, and they cannot be shown faithfully on a black pill anyway).
        let chroma = c.vivid.chroma
        let lightness = min(1, max(0.12, (c.center.L - 0.06) / 0.22))
        let purity = c.spread < 0.07 ? 1.0 : max(0.2, 1 - (c.spread - 0.07) * 8)
        return c.population * (0.3 + 2.5 * chroma) * lightness * purity
    }

    /// Prefer a real colour over the neutral background: a dark cover with one red
    /// accent reads as "red", so greys only win when nothing chromatic covers at least
    /// a few percent of the image.
    private static func isChromatic(_ c: Cluster) -> Bool {
        c.vivid.chroma >= 0.06 && c.population >= 0.004
    }

    /// Up to four mutually distinct colours, best score first. Colourful clusters are
    /// taken before neutrals (a dark cover with one red accent reads as "red"); the
    /// runners-up are then pulled towards the winner and everything is ordered dark to
    /// light so the gradient stays in one family and sweeps monotonically; when the art
    /// has fewer distinct colours the ramp is padded with lighter variants.
    static func pickPalette(_ clusters: [Cluster]) -> [Oklab] {
        let ranked = clusters.sorted { score($0) > score($1) }
        var chosen: [Cluster] = []
        func take(where accept: (Cluster) -> Bool) {
            for c in ranked where chosen.count < 4 && accept(c) && c.population >= 0.004 {
                if chosen.allSatisfy({ $0.vivid.distance(to: c.vivid) > 0.1 }) {
                    chosen.append(c)
                }
            }
        }
        take(where: isChromatic)
        take { _ in true }
        var colors = chosen.map(\.vivid)
        guard let base = colors.first else { return [] }
        // Pull the runners-up towards the dominant colour, then order everything dark to
        // light. Every anchor now sits in a small ball around the dominant, so a
        // lightness ramp is a monotonic sweep; hue-sorting gave lightness zig-zags.
        colors = [base] + colors.dropFirst().map { base.mixed(toward: $0, 1 - blendTowardDominant) }
        colors.sort { $0.L < $1.L }
        // Too few distinct colours: continue the ramp with lighter nudges of the last one.
        let tail = colors[colors.count - 1]
        var step = 1
        while colors.count < 4 {
            colors.append(variant(of: tail, step: step, monochrome: base.chroma < 0.03))
            step += 1
        }
        return colors
    }

    private static func variant(of c: Oklab, step: Int, monochrome: Bool) -> Oklab {
        if monochrome {
            return Oklab(L: min(0.95, c.L + 0.08 * Double(step)), a: c.a, b: c.b)
        }
        // About 9 degrees of hue and a touch of lightness per step: a solid red cover
        // ends in a lighter coral, not in gold.
        let angle = 0.15 * Double(step)
        return Oklab(
            L: min(0.95, c.L + 0.06 * Double(step)),
            a: (c.a * cos(angle) - c.b * sin(angle)) * 0.9,
            b: (c.a * sin(angle) + c.b * cos(angle)) * 0.9
        )
    }

    // MARK: Display mapping

    /// The same colours re-mapped to sit on a light menu bar, where the pill's black
    /// capsule is dropped. Only the compact pill uses this; the expanded card keeps the
    /// pastel palette on its dark HUD, so the mapping happens here rather than in the
    /// store, which would darken both.
    var onLightBackground: ArtworkPalette {
        ArtworkPalette(colors: colors.map(Self.darkened))
    }

    /// Hue is kept; lightness is moved from the pastel band into the dark one, keeping
    /// each bar's place in the gradient so the sweep keeps its direction. Grey art stays
    /// grey — an invented tint looks wrong there in either appearance.
    private static func darkened(_ color: Color) -> Color {
        let source = NSColor(color).usingColorSpace(.sRGB) ?? .black
        var c = Oklab.fromSRGB(
            r: Double(source.redComponent),
            g: Double(source.greenComponent),
            b: Double(source.blueComponent)
        )
        let chroma = c.chroma
        if chroma < 0.012 {
            c.a = 0
            c.b = 0
        } else {
            let target = min(lightMaxChroma, chroma * lightChromaScale)
            c.a *= target / chroma
            c.b *= target / chroma
        }
        let t = min(1, max(0, (c.L - minL) / (maxL - minL)))
        c.L = lightMinL + t * (lightMaxL - lightMinL)
        let rgb = c.toSRGBClipped()
        return Color(nsColor: NSColor(deviceRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
    }

    private static func display(_ lab: Oklab) -> NSColor {
        var c = lab
        let chroma = c.chroma
        if chroma < 0.012 {
            // Neutral stays neutral; a tint invented for grey art looks wrong.
            c.a = 0
            c.b = 0
        } else {
            // Keep the hue, clamp the strength: a whisper of colour at least, never neon.
            let target = min(maxChroma, max(minChroma, chroma * chromaScale))
            c.a *= target / chroma
            c.b *= target / chroma
        }
        c.L = min(maxL, max(minL, c.L))
        let rgb = c.toSRGBClipped()
        return NSColor(deviceRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    // MARK: k-means in Oklab

    static func kMeans(_ points: [Oklab], k: Int, iterations: Int) -> [Cluster] {
        var rng = LCG(seed: 0x5EED)
        var centers: [Oklab] = [points[Int(rng.next() % UInt64(points.count))]]
        var distances = [Double](repeating: 0, count: points.count)
        while centers.count < k {
            var total = 0.0
            for (i, p) in points.enumerated() {
                let d = centers.map { p.squaredDistance(to: $0) }.min() ?? 0
                distances[i] = d
                total += d
            }
            guard total > 0 else { break }
            var target = Double(rng.next() % 1_000_000) / 1_000_000 * total
            var chosen = points.count - 1
            for (i, d) in distances.enumerated() {
                target -= d
                if target <= 0 { chosen = i; break }
            }
            centers.append(points[chosen])
        }

        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<iterations {
            var moved = false
            for (i, p) in points.enumerated() {
                var best = 0
                var bestD = Double.greatestFiniteMagnitude
                for (j, c) in centers.enumerated() {
                    let d = p.squaredDistance(to: c)
                    if d < bestD { bestD = d; best = j }
                }
                if assignment[i] != best { assignment[i] = best; moved = true }
            }
            var sums = [Oklab](repeating: Oklab(L: 0, a: 0, b: 0), count: centers.count)
            var counts = [Int](repeating: 0, count: centers.count)
            for (i, p) in points.enumerated() {
                let j = assignment[i]
                sums[j].L += p.L; sums[j].a += p.a; sums[j].b += p.b
                counts[j] += 1
            }
            for j in centers.indices where counts[j] > 0 {
                let n = Double(counts[j])
                centers[j] = Oklab(L: sums[j].L / n, a: sums[j].a / n, b: sums[j].b / n)
            }
            if !moved { break }
        }

        var counts = [Int](repeating: 0, count: centers.count)
        var vividSum = [Oklab](repeating: Oklab(L: 0, a: 0, b: 0), count: centers.count)
        var vividWeight = [Double](repeating: 0, count: centers.count)
        var spreadSum = [Double](repeating: 0, count: centers.count)
        for (i, p) in points.enumerated() {
            let j = assignment[i]
            counts[j] += 1
            spreadSum[j] += p.squaredDistance(to: centers[j])
            let w = 0.02 + p.chroma * p.chroma
            vividSum[j].L += p.L * w; vividSum[j].a += p.a * w; vividSum[j].b += p.b * w
            vividWeight[j] += w
        }
        return centers.indices.compactMap { j in
            guard counts[j] > 0 else { return nil }
            let w = vividWeight[j]
            return Cluster(
                center: centers[j],
                vivid: Oklab(L: vividSum[j].L / w, a: vividSum[j].a / w, b: vividSum[j].b / w),
                population: Double(counts[j]) / Double(points.count),
                spread: (spreadSum[j] / Double(counts[j])).squareRoot()
            )
        }
    }

    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    // MARK: Sampling

    static func samplePixels(_ image: NSImage) -> [Oklab]? {
        let side = 48
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
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
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let bytesPerRow = rep.bytesPerRow
        let bpp = rep.bitsPerPixel / 8
        var out: [Oklab] = []
        out.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                let p = data + y * bytesPerRow + x * bpp
                let alpha = Double(p[3]) / 255
                guard alpha > 0.5 else { continue }
                out.append(Oklab.fromSRGB(r: Double(p[0]) / 255, g: Double(p[1]) / 255, b: Double(p[2]) / 255))
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Perceptual colour space (Björn Ottosson, 2020). Distances approximate perceived difference.
struct Oklab: Equatable {
    var L: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }

    func squaredDistance(to o: Oklab) -> Double {
        let dL = L - o.L, da = a - o.a, db = b - o.b
        return dL * dL + da * da + db * db
    }

    func distance(to o: Oklab) -> Double { squaredDistance(to: o).squareRoot() }

    /// Linear interpolation; `t` 0 is `self`, 1 is `o`.
    func mixed(toward o: Oklab, _ t: Double) -> Oklab {
        Oklab(L: L + (o.L - L) * t, a: a + (o.a - a) * t, b: b + (o.b - b) * t)
    }

    static func fromSRGB(r: Double, g: Double, b: Double) -> Oklab {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lr = lin(r), lg = lin(g), lb = lin(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return Oklab(
            L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Linear-light sRGB, possibly out of gamut.
    private func toLinearSRGB() -> (r: Double, g: Double, b: Double) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// Gamma-encoded sRGB. Chroma is reduced (lightness kept) until the colour fits the gamut.
    func toSRGBClipped() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        func inGamut(_ c: (r: Double, g: Double, b: Double)) -> Bool {
            c.r >= -0.001 && c.r <= 1.001 && c.g >= -0.001 && c.g <= 1.001 && c.b >= -0.001 && c.b <= 1.001
        }
        var lo = 0.0, hi = 1.0
        var rgb = toLinearSRGB()
        if !inGamut(rgb) {
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                let test = Oklab(L: L, a: a * mid, b: b * mid).toLinearSRGB()
                if inGamut(test) { lo = mid } else { hi = mid }
            }
            rgb = Oklab(L: L, a: a * lo, b: b * lo).toLinearSRGB()
        }
        func enc(_ c: Double) -> CGFloat {
            let v = min(1, max(0, c))
            return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return (enc(rgb.r), enc(rgb.g), enc(rgb.b))
    }
}
