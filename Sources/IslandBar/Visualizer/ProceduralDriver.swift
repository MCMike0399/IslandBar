import Foundation

final class ProceduralDriver: @unchecked Sendable {
    private let shared: SharedBarState
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.procedural")
    private var t: Double = 0
    private var envelope: [Float] = BarLevels.rest.values
    private let phases: [(f1: Double, f2: Double, p: Double)] = [
        (0.90, 1.70, 0.0),
        (1.10, 1.90, 0.7),
        (1.40, 2.10, 1.4),
        (1.60, 2.40, 2.1),
    ]

    init(shared: SharedBarState) {
        self.shared = shared
    }

    func start() {
        stop()
        t = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        var target = [Float](repeating: 0, count: 4)
        for i in 0..<4 {
            let p = phases[i]
            let raw = 0.52
                + 0.28 * sin(2 * Double.pi * p.f1 * t + p.p)
                + 0.14 * sin(2 * Double.pi * p.f2 * t)
                + Double.random(in: -0.03...0.03)
            target[i] = Float(min(1, max(0, raw)))
            envelope[i] = envelopeStep(current: envelope[i], target: target[i])
        }
        t += 1.0 / 30.0
        shared.publish(bars: BarLevels(values: envelope).clampedPlaying().values, rmsDb: -12, fromTap: false)
    }
}
