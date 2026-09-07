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
    private var peak: [Float] = [-20, -20, -20, -20]
    private var floorDb: [Float] = [-70, -70, -70, -70]

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
        let bands: [(Double, Double)] = [(40, 200), (200, 800), (800, 3_000), (3_000, 12_000)]
        var db = [Float](repeating: -120, count: 4)
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

        let peakDecay = powf(0.5, 1.0 / 90.0)
        var normalized = [Float](repeating: 0, count: 4)
        for i in 0..<4 {
            if db[i] > peak[i] {
                peak[i] = db[i]
            } else {
                peak[i] = peak[i] * peakDecay + db[i] * (1 - peakDecay)
            }
            if db[i] < floorDb[i] {
                floorDb[i] = db[i]
            } else {
                floorDb[i] = floorDb[i] * 0.995 + db[i] * 0.005
            }
            let span = max(6, peak[i] - floorDb[i])
            normalized[i] = (db[i] - floorDb[i]) / span
            normalized[i] = min(1, max(0, normalized[i]))
        }

        if rmsDb < -60 {
            normalized = [0.12, 0.12, 0.12, 0.12]
        }

        for i in 0..<4 {
            envelope[i] = envelopeStep(current: envelope[i], target: normalized[i])
        }
        let published = BarLevels(values: envelope).clampedPlaying().values
        shared.publish(bars: published, rmsDb: rmsDb, fromTap: true)
    }
}

func envelopeStep(current: Float, target: Float, attack: Float = 0.55, release: Float = 0.10) -> Float {
    if target > current {
        return current + (target - current) * attack
    }
    return current + (target - current) * release
}
