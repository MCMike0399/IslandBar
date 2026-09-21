import Foundation

/// One tap's gain state. Laid out as a plain struct in raw memory so the IO proc can reach
/// it through a pointer captured at block-creation time, with no ARC traffic on the audio
/// thread.
struct MixerSlot {
    /// Where the gain is heading. Written only by the mixer queue.
    var target: Float
    /// Where the ramp has reached. Written only by the IO proc, which carries it across
    /// callbacks so an 8 ms ramp survives being split over several buffers.
    var current: Float
    /// Which table generation this slot belongs to. The IO proc renders a slot only when
    /// this matches the published epoch, so a slot whose buffer index is in doubt goes
    /// silent instead of playing someone else's audio at the wrong level.
    var epoch: UInt32
    /// Incremented by the IO proc whenever this slot actually contributed samples. Read by
    /// the zero-energy watchdog to tell "muted" apart from "delivering nothing".
    var rendered: UInt32
}

/// Gain state shared between the mixer queue and the Core Audio IO thread.
///
/// The split is strict and is the whole reason this is safe without locks:
/// **the mixer queue owns `target` and `epoch`; the IO thread owns `current`, `rendered`,
/// `callbacks` and `clipped`.** No field is ever read-modify-written from both sides, and
/// every field is a naturally aligned 32-bit value, so a torn read is not possible on the
/// architectures this app supports.
///
/// The storage is allocated once and never resized, because growing it would mean freeing
/// memory the IO proc may be reading.
final class MixerGainTable: @unchecked Sendable {
    /// Slots are append-only within an engine's life and are reclaimed only by tearing the
    /// engine down, so this is a ceiling on *simultaneously adjusted* apps, not on apps.
    static let capacity = 8

    private let slots: UnsafeMutablePointer<MixerSlot>
    private let meta: UnsafeMutablePointer<UInt32>
    private let rampFramesStorage: UnsafeMutablePointer<Int32>

    private static let publishedEpochIndex = 0
    private static let callbacksIndex = 1
    private static let clippedIndex = 2

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: MixerSlot(target: 0, current: 0, epoch: .max, rendered: 0), count: Self.capacity)
        meta = .allocate(capacity: 3)
        meta.initialize(repeating: 0, count: 3)
        rampFramesStorage = .allocate(capacity: 1)
        rampFramesStorage.initialize(to: 384)
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
        meta.deinitialize(count: 3)
        meta.deallocate()
        rampFramesStorage.deinitialize(count: 1)
        rampFramesStorage.deallocate()
    }

    /// Pointers handed to the IO block at creation time. The block captures these rather
    /// than `self`, so the audio thread never touches a Swift object.
    var slotPointer: UnsafeMutablePointer<MixerSlot> { slots }
    var metaPointer: UnsafeMutablePointer<UInt32> { meta }
    var rampFramesPointer: UnsafeMutablePointer<Int32> { rampFramesStorage }

    var callbacks: UInt32 { meta[Self.callbacksIndex] }
    var clipped: UInt32 { meta[Self.clippedIndex] }

    func rendered(slot: Int) -> UInt32 {
        guard slot >= 0, slot < Self.capacity else { return 0 }
        return slots[slot].rendered
    }

    /// An 8 ms ramp. Short enough to feel instant, long enough that a mute is a fade rather
    /// than the click a step change in gain produces.
    func setSampleRate(_ rate: Double) {
        rampFramesStorage.pointee = Int32(max(rate * 0.008, 1))
    }

    /// Stages a slot for the *next* epoch. It stays unrendered until `publish` runs.
    func stage(slot: Int, target: Float, current: Float, epoch: UInt32) {
        guard slot >= 0, slot < Self.capacity else { return }
        slots[slot].target = target
        slots[slot].current = current
        slots[slot].rendered = 0
        slots[slot].epoch = epoch
    }

    /// Re-stamps a live slot into the next epoch without disturbing its ramp, so an append
    /// does not make every other app re-fade in.
    func restamp(slot: Int, epoch: UInt32) {
        guard slot >= 0, slot < Self.capacity else { return }
        slots[slot].epoch = epoch
    }

    /// Moving a fader is exactly this: one `Float` store. No Core Audio call, which is what
    /// keeps a drag from becoming tap churn.
    func setTarget(slot: Int, _ gain: Float) {
        guard slot >= 0, slot < Self.capacity else { return }
        slots[slot].target = min(max(gain, 0), 1)
    }

    func target(slot: Int) -> Float {
        guard slot >= 0, slot < Self.capacity else { return 0 }
        return slots[slot].target
    }

    /// Permanently excludes a slot. `UInt32.max` can never equal a published epoch, so the
    /// IO proc skips it for good without the index ever being reused.
    func retire(slot: Int) {
        guard slot >= 0, slot < Self.capacity else { return }
        slots[slot].target = 0
        slots[slot].epoch = .max
    }

    /// Makes the staged generation live. Everything staged with this epoch starts rendering
    /// on the next callback; everything else falls silent.
    func publish(epoch: UInt32) {
        meta[Self.publishedEpochIndex] = epoch
    }

    func resetCounters() {
        meta[Self.callbacksIndex] = 0
        meta[Self.clippedIndex] = 0
    }
}
