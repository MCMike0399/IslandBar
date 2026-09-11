import AppKit
import QuartzCore
import SwiftUI

struct BarMetrics: Equatable {
    var barWidth: CGFloat
    var gap: CGFloat
    var minHeight: CGFloat
    /// Ceiling shared by every bar. A tapered row — tall at the edges, low in the
    /// middle — reads as a shape that was drawn once and then filled in, which is the
    /// opposite of what an audio visualiser does: there the outline *is* the signal,
    /// so every bar needs the same headroom for the audio to draw with.
    var maxHeight: CGFloat

    var totalWidth: CGFloat {
        CGFloat(BarLevels.count) * barWidth + CGFloat(BarLevels.count - 1) * gap
    }

    var size: CGSize { CGSize(width: totalWidth, height: maxHeight) }

    func barX(_ i: Int) -> CGFloat { CGFloat(i) * (barWidth + gap) }
}

/// Core Animation bars, one plain `CALayer` per bar. A level frame only changes each
/// layer's bounds height; the render server draws rounded rectangles straight from
/// the layer properties. There is no gradient-through-mask offscreen pass and no
/// path to rasterise, which is what the previous CAShapeLayer/CAGradientLayer pair
/// cost WindowServer sixty times a second. Heights stay on a continuous scale — the
/// caps are round, so a fractional height only softens the very tip, and snapping them
/// to the pixel grid cost more in stair-steps than it bought in crispness — while a
/// frame that moves nothing by `heightEpsilon` is still not committed at all.
/// SwiftUI is involved only for the rare changes (palette, playing/idle).
@MainActor
final class BarsLayerView: NSView {
    let metrics: BarMetrics
    private let barLayers: [CALayer]
    private let glowLayer: CALayer?
    private let flatLayer = CALayer()
    private var heights: [CGFloat]
    private var flat = true
    /// Height change too small to be worth a commit: a tenth of a point sits well
    /// under a device pixel at any scale, and holding still on it is what keeps a
    /// sustained note from re-committing sixty times a second.
    private static let heightEpsilon: CGFloat = 0.1
    /// True when the bars sit on a light menu bar: the idle line darkens with them.
    private(set) var lightBackground = false
    /// False while idle or with Reduce Motion on: incoming levels are ignored and
    /// the bars sit at their rest heights.
    var animating = false {
        didSet { if !animating { apply(.rest) } }
    }

    /// Neutral idle line, independent of the last artwork. The light variant is what the
    /// same line becomes on a light menu bar, where the default would be near-invisible.
    static let idleColor = NSColor(white: 0.58, alpha: 0.85)
    static let lightIdleColor = NSColor(white: 0.32, alpha: 0.85)

    init(metrics: BarMetrics, glow: Bool) {
        self.metrics = metrics
        barLayers = (0..<BarLevels.count).map { _ in CALayer() }
        glowLayer = glow ? CALayer() : nil
        heights = [CGFloat](repeating: -1, count: BarLevels.count)
        super.init(frame: NSRect(origin: .zero, size: metrics.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        let bounds = CGRect(origin: .zero, size: metrics.size)
        let midY = metrics.maxHeight / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let glowLayer {
            glowLayer.frame = bounds
            glowLayer.shadowOpacity = 0.45
            glowLayer.shadowRadius = metrics.barWidth * 0.6
            glowLayer.shadowOffset = .zero
            glowLayer.opacity = 0
            layer?.addSublayer(glowLayer)
        }
        for (i, bar) in barLayers.enumerated() {
            // Fixed centre; only the bounds height changes per frame, so the bar
            // grows symmetrically without touching its position.
            bar.position = CGPoint(x: metrics.barX(i) + metrics.barWidth / 2, y: midY)
            bar.bounds = CGRect(x: 0, y: 0, width: metrics.barWidth, height: metrics.minHeight)
            bar.cornerRadius = metrics.barWidth / 2
            bar.opacity = 0
            layer?.addSublayer(bar)
        }

        flatLayer.frame = CGRect(
            x: 0,
            y: midY - metrics.minHeight / 2,
            width: metrics.totalWidth,
            height: metrics.minHeight
        )
        flatLayer.cornerRadius = metrics.minHeight / 2
        flatLayer.backgroundColor = Self.idleColor.cgColor
        layer?.addSublayer(flatLayer)
        apply(.rest)
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var intrinsicContentSize: NSSize { metrics.size }
    override var wantsUpdateLayer: Bool { true }

    private var levels = BarLevels.rest

    func setPalette(_ palette: ArtworkPalette) {
        guard palette.colors.count == BarLevels.count else { return }
        let colors = palette.colors.map { NSColor($0).cgColor }
        guard zip(barLayers, colors).contains(where: { $0.backgroundColor != $1 }) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        for (bar, color) in zip(barLayers, colors) {
            bar.backgroundColor = color
        }
        glowLayer?.shadowColor = colors[BarLevels.count / 2]
        CATransaction.commit()
    }

    func setFlat(_ flat: Bool) {
        guard flat != self.flat else { return }
        self.flat = flat
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        for bar in barLayers { bar.opacity = flat ? 0 : 1 }
        glowLayer?.opacity = flat ? 0 : 1
        flatLayer.opacity = flat ? 1 : 0
        CATransaction.commit()
    }

    /// Appearance changed under us (light menu bar ⇄ dark one): only the idle line's
    /// colour lives here, the bar colours arrive through `setPalette`.
    func setLightBackground(_ light: Bool) {
        guard light != lightBackground else { return }
        lightBackground = light
        DebugLog.line("bars: menu bar background=\(light ? "light" : "dark")")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        flatLayer.backgroundColor = (light ? Self.lightIdleColor : Self.idleColor).cgColor
        CATransaction.commit()
    }

    func setLevels(_ levels: BarLevels) {
        guard animating else { return }
        apply(levels)
    }

    private func apply(_ levels: BarLevels) {
        self.levels = levels
        var next = heights
        var changed = false
        for i in 0..<BarLevels.count {
            let level = i < levels.values.count ? CGFloat(levels.values[i]) : 0
            let raw = max(metrics.minHeight, level * metrics.maxHeight)
            // Compared against the height currently on screen, not the previous
            // target, so the drawn height can never drift more than the epsilon.
            if abs(raw - next[i]) > Self.heightEpsilon {
                next[i] = raw
                changed = true
            }
        }
        guard changed else { return }
        heights = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            bar.bounds.size.height = next[i]
        }
        if let glowLayer {
            glowLayer.shadowPath = Self.path(heights: next, metrics: metrics)
        }
        CATransaction.commit()
    }

    /// Outline of all bars, used only as the glow's `shadowPath`: a shadow with an
    /// explicit path is blurred geometry, not a rasterised copy of the layer.
    private static func path(heights: [CGFloat], metrics: BarMetrics) -> CGPath {
        let path = CGMutablePath()
        let midY = metrics.maxHeight / 2
        for (i, height) in heights.enumerated() {
            let bar = CGRect(x: metrics.barX(i), y: midY - height / 2, width: metrics.barWidth, height: height)
            path.addRoundedRect(in: bar, cornerWidth: metrics.barWidth / 2, cornerHeight: metrics.barWidth / 2)
        }
        return path
    }
}

/// SwiftUI wrapper. Levels do not flow through SwiftUI at all: the layer view
/// subscribes to the store's level stream directly, so the 60 Hz frames never
/// re-evaluate a view body.
struct IslandBarsView: NSViewRepresentable {
    @Environment(NowPlayingStore.self) private var store
    /// Idle: a single thin gray line instead of bars.
    var flat: Bool
    /// False with Reduce Motion on: bars are shown but do not move.
    var animating: Bool
    var palette: ArtworkPalette
    var metrics: BarMetrics
    /// Soft glow behind the bars. Off in the menu bar, where it is invisible at 18 pt.
    var glow = false
    /// True on a light menu bar, where the bars darken through `palette.onLightBackground`
    /// and the idle line does the same. Always false in the popover's dark HUD.
    var lightBackground = false

    final class Coordinator {
        var token: UUID?
        weak var store: NowPlayingStore?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BarsLayerView {
        let view = BarsLayerView(metrics: metrics, glow: glow)
        let store = store
        context.coordinator.store = store
        context.coordinator.token = store.addLevelObserver { [weak view] levels in
            view?.setLevels(levels)
        }
        return view
    }

    func updateNSView(_ view: BarsLayerView, context: Context) {
        view.setPalette(lightBackground ? palette.onLightBackground : palette)
        view.setLightBackground(lightBackground)
        view.setFlat(flat)
        if view.animating != animating {
            view.animating = animating
            if animating { view.setLevels(store.barLevels) }
        }
    }

    static func dismantleNSView(_ view: BarsLayerView, coordinator: Coordinator) {
        if let token = coordinator.token {
            coordinator.store?.removeLevelObserver(token)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsLayerView, context: Context) -> CGSize? {
        metrics.size
    }
}
