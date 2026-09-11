import Foundation

struct BarLevels: Equatable, Sendable {
    var values: [Float]

    /// Number of bars everywhere: analyzer bands, procedural motion, palette entries, views.
    static let count = 12
    static let rest = BarLevels(values: (0..<count).map { $0 % 2 == 0 ? 0.30 : 0.45 })

    init(values: [Float]) {
        if values.count == Self.count {
            self.values = values
        } else {
            var padded = Array(values.prefix(Self.count))
            while padded.count < Self.count { padded.append(0.30) }
            self.values = padded
        }
    }

    static func clampPlaying(_ v: Float) -> Float { min(1.0, max(0.12, v)) }

    func clampedPlaying() -> BarLevels {
        BarLevels(values: values.map(Self.clampPlaying))
    }
}

/// Latest analyzer output. Written from the analysis/procedural queues, read by the main-queue pump every frame.
final class SharedBarState: @unchecked Sendable {
    private let lock = NSLock()
    private var bars: [Float] = BarLevels.rest.values
    private var rmsDb: Float = -120
    private var fromTap = false

    func publish(bars: [Float], rmsDb: Float, fromTap: Bool) {
        lock.lock()
        self.bars = bars
        self.rmsDb = rmsDb
        self.fromTap = fromTap
        lock.unlock()
    }

    func snapshot() -> (bars: [Float], rmsDb: Float, fromTap: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bars, rmsDb, fromTap)
    }
}

/// Main-queue publisher that eases the analyzer's latest bars into
/// `NowPlayingStore.barLevels` at a fixed frame rate.
///
/// Smoothing lives here rather than in a SwiftUI animation: an implicit spring
/// redraws the menu bar at the display's full refresh rate (120 Hz on ProMotion)
/// for as long as levels keep changing, which is always while music plays.
/// Easing in the pump caps redraws at `frameRate` and skips frames that would not
/// visibly move.
///
/// Two shapings happen on the way out, and this is the one place the analyzer and the
/// procedural fallback both publish through, so both get them: a cross-band blend that
/// makes the bars read as one contour, and an asymmetric ease so peaks land quickly
/// and decay gently.
final class BarLevelPump: @unchecked Sendable {
    static let frameRate = 60.0
    /// Fraction of the remaining distance covered per frame, going up and coming down.
    /// Attack is quick enough to catch a kick, release slow enough that a bar glides
    /// back instead of dropping. One symmetric rate rounded every peak off into a mush
    /// and fought the analyzer's envelope, which already supplies the long tail.
    private static let attack: Float = 0.62
    private static let release: Float = 0.32
    private static let settleThreshold: Float = 0.003
    /// How far each bar is pulled towards the mean of its two neighbours, per frame.
    /// At 0.45 a band that jumps on its own keeps a little over half its height and
    /// lifts the bars beside it, so the row reads as a moving contour rather than a bar
    /// chart. Raising it broadens the hump; at 0 it is the raw spectrum again, where
    /// neighbouring bars sit at opposite heights.
    private static let neighborPull: Float = 0.45

    private let shared: SharedBarState
    private var timer: DispatchSourceTimer?
    private var lastSecondLog: CFAbsoluteTime = 0
    private var display: [Float] = BarLevels.rest.values
    /// The shaped copy of `display` that actually gets published, plus one scratch
    /// buffer to blur into. Kept apart from `display` deliberately: blending back into
    /// the easing state would re-blur the row every frame and flatten it to its own
    /// mean, which is a much stronger effect than a single pass.
    private var shaped: [Float] = BarLevels.rest.values
    private var scratch: [Float] = [Float](repeating: 0, count: BarLevels.count)
    private let onLevels: @Sendable (BarLevels, Float, Bool) -> Void
    private(set) var isRunning = false

    init(shared: SharedBarState, onLevels: @escaping @Sendable (BarLevels, Float, Bool) -> Void) {
        self.shared = shared
        self.onLevels = onLevels
    }

    func start() {
        stop()
        isRunning = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / Self.frameRate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snap = self.shared.snapshot()
            var moved = false
            for i in 0..<min(self.display.count, snap.bars.count) {
                let delta = snap.bars[i] - self.display[i]
                if abs(delta) < Self.settleThreshold {
                    if self.display[i] != snap.bars[i] {
                        self.display[i] = snap.bars[i]
                        moved = true
                    }
                } else {
                    self.display[i] += delta * (delta > 0 ? Self.attack : Self.release)
                    moved = true
                }
            }
            if moved {
                self.shape()
                self.onLevels(BarLevels(values: self.shaped), snap.rmsDb, snap.fromTap)
            }
            if DebugLog.enabled {
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastSecondLog >= 1.0 {
                    self.lastSecondLog = now
                    let formatted = snap.bars.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                    DebugLog.line("bandLevels=[\(formatted)] rms=\(String(format: "%.1f", snap.rmsDb)) fromTap=\(snap.fromTap)")
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// One pass of the neighbour blend. Bands from the analyzer are already
    /// correlated — log-spaced slices of the same spectrum — but it reports each one
    /// as a deviation from *that band's* running mean, and that is what decorrelates
    /// them and makes the raw output jump around as twelve separate columns. Ends clamp
    /// rather than pad with silence, so the outermost bars keep their own level instead
    /// of being dragged towards zero. The blend is a convex combination, so it cannot
    /// push a level outside the 0.12…1.0 the publishers have already clamped to.
    private func shape() {
        for i in 0..<display.count { shaped[i] = display[i] }
        for i in 0..<display.count {
            let left = shaped[max(0, i - 1)]
            let right = shaped[min(shaped.count - 1, i + 1)]
            scratch[i] = shaped[i] + ((left + right) * 0.5 - shaped[i]) * Self.neighborPull
        }
        for i in 0..<display.count { shaped[i] = scratch[i] }
    }

    /// Drops the eased display back to the rest line and stops the timer. Called when
    /// playback stops: a 60 Hz main-queue timer easing a static line was pure overhead,
    /// and the next `start()` must not ease in from stale heights.
    func rest() {
        display = BarLevels.rest.values
        if isRunning {
            shape()
            onLevels(BarLevels(values: shaped), -120, false)
        }
        stop()
    }
}
