import Accelerate
import Foundation

final class SpectrumAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let hop = 512
    private let ring: FloatRingBuffer
    private let shared: SharedBarState
    private let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.fft")
    private var timer: DispatchSourceTimer?

    private var window: [Float]
    private var frame: [Float]
    private var filled = 0
    private var realp: [Float]
    private var imagp: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var hopScratch: [Float]
    private var setup: OpaquePointer?
    private var envelope: [Float] = BarLevels.rest.values
    /// Per-band running mean (dB) and mean absolute deviation (dB). Bars are
    /// drawn relative to these, so steady loud content sits mid-height and only
    /// transients (beats, hits) reach the top. The old floor/peak AGC pinned
    /// everything near 1.0 because music rarely returns to its quietest frame.
    private let bandCount = BarLevels.count
    private var meanDb: [Float] = [Float](repeating: 0, count: BarLevels.count)
    private var devDb: [Float] = [Float](repeating: 6, count: BarLevels.count)
    private var primed = false
    /// Frames left in the fast-adapting phase after (re)start. Resuming after a pause
    /// used to pin every bar at 1.0 for seconds: the statistics primed on the fade-in
    /// or on silence and then crawled up to the real level at the slow rate.
    private var warmupFrames = 0
    private static let warmupLength = 90

    var sampleRate: Double = 48_000

    init(ring: FloatRingBuffer, shared: SharedBarState) {
        self.ring = ring
        self.shared = shared
        window = [Float](repeating: 0, count: n)
        frame = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        outReal = [Float](repeating: 0, count: n / 2)
        outImag = [Float](repeating: 0, count: n / 2)
        hopScratch = [Float](repeating: 0, count: hop)
        window.withUnsafeMutableBufferPointer { buf in
            vDSP_hann_window(buf.baseAddress!, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        }
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
    }

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func start() {
        stop()
        filled = 0
        envelope = BarLevels.rest.values
        // Statistics deliberately survive stop/start: a resumed track has the same
        // loudness it had before the pause, so there is nothing to relearn.
        warmupFrames = Self.warmupLength
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
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
        let got = hopScratch.withUnsafeMutableBufferPointer { buf -> Int in
            ring.read(buf.baseAddress!, maxCount: hop)
        }
        guard got > 0 else { return }
        for i in 0..<got {
            if filled < n {
                frame[filled] = hopScratch[i]
                filled += 1
            }
        }
        guard filled >= n else { return }
        analyzeFrame()
        let keep = n - hop
        for i in 0..<keep {
            frame[i] = frame[i + hop]
        }
        filled = keep
    }

    private var windowed = [Float](repeating: 0, count: 1024)

    private func analyzeFrame() {
        guard let setup else { return }
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(n))
        let rmsDb = 20 * log10(max(rms, 1e-12))

        windowed.withUnsafeMutableBufferPointer { src in
            src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                realp.withUnsafeMutableBufferPointer { realBuf in
                    imagp.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        realp.withUnsafeBufferPointer { ir in
            imagp.withUnsafeBufferPointer { ii in
                outReal.withUnsafeMutableBufferPointer { or in
                    outImag.withUnsafeMutableBufferPointer { oi in
                        vDSP_DFT_Execute(setup, ir.baseAddress!, ii.baseAddress!, or.baseAddress!, oi.baseAddress!)
                    }
                }
            }
        }

        let nyquist = sampleRate / 2
        // Roughly log-spaced edges; sub-bass to air across the eight bars.
        let edges: [Double] = [40, 90, 200, 450, 1_000, 2_200, 5_000, 9_000, 14_000]
        let bands = (0..<bandCount).map { (edges[$0], edges[$0 + 1]) }
        var db = [Float](repeating: -120, count: bandCount)
        for (band, range) in bands.enumerated() {
            let lo = range.0
            let hi = min(range.1, nyquist)
            var sum: Float = 0
            var count: Float = 0
            for k in 1..<(n / 2) {
                let freq = Double(k) * sampleRate / Double(n)
                if freq >= lo && freq < hi {
                    let mag = hypot(outReal[k], outImag[k])
                    sum += mag
                    count += 1
                }
            }
            let mean = count > 0 ? sum / count : 0
            db[band] = 20 * log10(max(mean, 1e-12))
        }

        // ~94 analysis frames/s at 48 kHz (hop 512). Mean follows over ~1 s,
        // deviation over ~2 s, so a 4-on-the-floor kick stays a transient.
        // Silence and fade-ins carry no loudness information: never prime on them,
        // and do not let them drag the mean down while we wait for real signal.
        let informative = rmsDb > -50
        if !primed {
            guard informative else {
                publishQuiet(rmsDb: rmsDb)
                return
            }
            primed = true
            for i in 0..<bandCount {
                meanDb[i] = db[i]
                devDb[i] = 6
            }
        }
        let warm = warmupFrames > 0
        if warm && informative { warmupFrames -= 1 }
        let meanAlpha: Float = warm ? 0.06 : 0.012
        let devAlpha: Float = warm ? 0.03 : 0.006
        var normalized = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let delta = db[i] - meanDb[i]
            if informative {
                meanDb[i] += delta * meanAlpha
                devDb[i] += (abs(delta) - devDb[i]) * devAlpha
            }
            // Map ±2.2 deviations onto 0…1 around 0.5. Clamp the scale so a
            // near-constant tone still has a little life and a chaotic band
            // does not become a strobe.
            let scale = min(14, max(3.5, devDb[i] * 2.2))
            var x = 0.5 + delta / (2 * scale)
            // Gentle curve: keeps the mid-range around 0.45 and lets peaks pop.
            x = min(1, max(0, x))
            normalized[i] = powf(x, 1.15)
        }

        // Very quiet material should not dance at half height.
        if rmsDb < -60 {
            normalized = [Float](repeating: 0.12, count: bandCount)
        } else if rmsDb < -40 {
            let k = (rmsDb + 60) / 20
            for i in 0..<bandCount { normalized[i] = 0.12 + (normalized[i] - 0.12) * k }
        }

        for i in 0..<bandCount {
            envelope[i] = envelopeStep(current: envelope[i], target: normalized[i])
        }
        let published = BarLevels(values: envelope).clampedPlaying().values
        shared.publish(bars: published, rmsDb: rmsDb, fromTap: true)
    }

    private func publishQuiet(rmsDb: Float) {
        for i in 0..<bandCount {
            envelope[i] = envelopeStep(current: envelope[i], target: 0.12)
        }
        let published = BarLevels(values: envelope).clampedPlaying().values
        shared.publish(bars: published, rmsDb: rmsDb, fromTap: true)
    }
}

func envelopeStep(current: Float, target: Float, attack: Float = 0.42, release: Float = 0.085) -> Float {
    if target > current {
        return current + (target - current) * attack
    }
    return current + (target - current) * release
}
