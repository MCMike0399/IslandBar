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

/// Latest analyzer output. Written from the analysis/procedural queues, read on the main 30 Hz timer.
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

/// Main-queue 30 Hz publisher that copies atomics into `NowPlayingStore.barLevels`.
final class BarLevelPump: @unchecked Sendable {
    private let shared: SharedBarState
    private var timer: DispatchSourceTimer?
    private var lastSecondLog: CFAbsoluteTime = 0
    private let onLevels: @Sendable (BarLevels, Float, Bool) -> Void

    init(shared: SharedBarState, onLevels: @escaping @Sendable (BarLevels, Float, Bool) -> Void) {
        self.shared = shared
        self.onLevels = onLevels
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snap = self.shared.snapshot()
            self.onLevels(BarLevels(values: snap.bars), snap.rmsDb, snap.fromTap)
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
    }
}
