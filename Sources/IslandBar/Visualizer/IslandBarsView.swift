import AppKit
import QuartzCore
import SwiftUI

struct BarMetrics: Equatable {
    var barWidth: CGFloat
    var gap: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat

    var totalWidth: CGFloat {
        CGFloat(BarLevels.count) * barWidth + CGFloat(BarLevels.count - 1) * gap
    }

    var size: CGSize { CGSize(width: totalWidth, height: maxHeight) }
}

/// Core Animation bars. Each level frame only swaps one `CAShapeLayer` path, which
/// the render server rasterises on the GPU; nothing on our side lays out or draws.
/// SwiftUI is involved only for the rare changes (palette, playing/idle).
@MainActor
final class BarsLayerView: NSView {
    let metrics: BarMetrics
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private let glowLayer: CAShapeLayer?
    private let flatLayer = CAShapeLayer()
    private var levels = BarLevels.rest
    private var flat = true
    /// False while idle or with Reduce Motion on: incoming levels are ignored and
    /// the bars sit at their rest heights.
    var animating = false {
        didSet { if !animating { applyPath(for: .rest) } }
    }

    /// Neutral idle line, independent of the last artwork.
    static let idleColor = NSColor(white: 0.58, alpha: 0.85)

    init(metrics: BarMetrics, glow: Bool) {
        self.metrics = metrics
        glowLayer = glow ? CAShapeLayer() : nil
        super.init(frame: NSRect(origin: .zero, size: metrics.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        let bounds = CGRect(origin: .zero, size: metrics.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        // The palette is already a gradient across the eight bars; a stop at each
        // bar centre reproduces the per-bar colours.
        gradientLayer.locations = (0..<BarLevels.count).map { i in
            let center = CGFloat(i) * (metrics.barWidth + metrics.gap) + metrics.barWidth / 2
            return NSNumber(value: Double(center / metrics.totalWidth))
        }
        gradientLayer.opacity = 0
        maskLayer.frame = bounds
        maskLayer.fillColor = NSColor.black.cgColor
        gradientLayer.mask = maskLayer

        flatLayer.frame = bounds
        flatLayer.fillColor = Self.idleColor.cgColor
        let line = CGRect(
            x: 0,
            y: (metrics.maxHeight - metrics.minHeight) / 2,
            width: metrics.totalWidth,
            height: metrics.minHeight
        )
        flatLayer.path = CGPath(
            roundedRect: line,
            cornerWidth: metrics.minHeight / 2,
            cornerHeight: metrics.minHeight / 2,
            transform: nil
        )

        if let glowLayer {
            glowLayer.frame = bounds
            glowLayer.shadowOpacity = 0.45
            glowLayer.shadowRadius = metrics.barWidth * 0.6
            glowLayer.shadowOffset = .zero
            glowLayer.opacity = 0
            layer?.addSublayer(glowLayer)
        }
        layer?.addSublayer(gradientLayer)
        layer?.addSublayer(flatLayer)
        applyPath(for: .rest)
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var intrinsicContentSize: NSSize { metrics.size }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [gradientLayer, maskLayer, flatLayer] + (glowLayer.map { [$0] } ?? []) {
            sublayer.contentsScale = scale
        }
    }

    func setPalette(_ palette: ArtworkPalette) {
        let colors = palette.colors.map { NSColor($0).cgColor }
        guard colors.count == BarLevels.count, colors != (gradientLayer.colors as? [CGColor]) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        gradientLayer.colors = colors
        glowLayer?.fillColor = colors[BarLevels.count / 2]
        glowLayer?.shadowColor = colors[BarLevels.count / 2]
        CATransaction.commit()
    }

    func setFlat(_ flat: Bool) {
        guard flat != self.flat else { return }
        self.flat = flat
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        gradientLayer.opacity = flat ? 0 : 1
        glowLayer?.opacity = flat ? 0 : 1
        flatLayer.opacity = flat ? 1 : 0
        CATransaction.commit()
    }

    func setLevels(_ levels: BarLevels) {
        guard animating else { return }
        applyPath(for: levels)
    }

    private func applyPath(for levels: BarLevels) {
        guard levels != self.levels || maskLayer.path == nil else { return }
        self.levels = levels
        let path = Self.path(for: levels, metrics: metrics)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        glowLayer?.path = path
        CATransaction.commit()
    }

    private static func path(for levels: BarLevels, metrics: BarMetrics) -> CGPath {
        let path = CGMutablePath()
        let midY = metrics.maxHeight / 2
        for i in 0..<BarLevels.count {
            let level = i < levels.values.count ? CGFloat(levels.values[i]) : 0
            let height = max(metrics.minHeight, level * metrics.maxHeight)
            let x = CGFloat(i) * (metrics.barWidth + metrics.gap)
            let bar = CGRect(x: x, y: midY - height / 2, width: metrics.barWidth, height: height)
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
        view.setPalette(palette)
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
