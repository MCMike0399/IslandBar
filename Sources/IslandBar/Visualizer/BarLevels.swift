import Foundation

struct BarLevels: Equatable, Sendable {
    var values: [Float]

    /// Number of bars everywhere: analyzer bands, procedural motion, palette entries, views.
    static let count = 8
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

    func clampedPlaying() -> BarLevels {
        BarLevels(values: values.map { min(1.0, max(0.12, $0)) })
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
final class BarLevelPump: @unchecked Sendable {
    static let frameRate = 60.0
    /// Fraction of the remaining distance covered per frame. 0.45 at 60 Hz settles
    /// in roughly 80 ms, fast enough for beats yet free of 30 Hz stair-steps.
    private static let easing: Float = 0.45
    private static let settleThreshold: Float = 0.003

    private let shared: SharedBarState
    private var timer: DispatchSourceTimer?
    private var lastSecondLog: CFAbsoluteTime = 0
    private var display: [Float] = BarLevels.rest.values
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
                    self.display[i] += delta * Self.easing
                    moved = true
                }
            }
            if moved {
                self.onLevels(BarLevels(values: self.display), snap.rmsDb, snap.fromTap)
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
}
