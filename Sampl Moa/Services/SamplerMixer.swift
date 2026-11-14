import Foundation
import os

/// Plays every sound the sampler is making, keeps time for the recorder, and mixes it all together.
///
/// `render` runs on the audio system's real-time thread, where waiting for anything causes an audible dropout. So it
/// never allocates, and it only picks up changes if it can do so without waiting. If another thread is busy making a
/// change at that instant, the change simply arrives a few milliseconds later.
/// How loud each side of a stereo sound is, from 0 up, where 1 is full scale.
nonisolated struct SamplerLevel: Equatable, Sendable {
    var left: Float = 0
    var right: Float = 0

    static let silent = SamplerLevel()

    var loudest: Float { max(left, right) }
}

nonisolated final class SamplerMixer: @unchecked Sendable {
    /// The pads, the keyboard, and a hidden one for listening to a slice before it goes on a pad.
    static let slotCount = SamplerSlot.count + 1
    static let auditionSlot = SamplerSlot.count

    /// What can change while a sound is playing.
    struct Live: Equatable {
        var volume: Float = 1
        var semitones = 0.0
        /// From -1 to 1: see `SamplerFilterSweep`.
        var filter: Float = 0
        var pan: Float = 0
        var eqLow = 0.0
        var eqMid = 0.0
        var eqHigh = 0.0
    }

    /// A sound ready to play. Its file's memory must stay alive for as long as this is set, and a little longer.
    struct Slot {
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var frameCount: Int
        var startFrame: Int
        var endFrame: Int
        var sampleRate: Double
        var rootNote: Int
        var mode: SamplerPlayMode
        var cutGroup: Int
        var live = Live()
    }

    /// The keyboard's sound, prepared ahead of time at the pitch of one key.
    struct NoteSound {
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var frameCount: Int
        var sampleRate: Double
    }

    /// One moment in a recorded pattern, in seconds from its start.
    struct SequenceEvent {
        var seconds: Double
        var slot: Int32
        /// A key on the keyboard, or -1 for a pad.
        var note: Int32
        var velocity: Int32
        var isNoteOff: Bool
    }

    /// A pattern, sorted by time. Must stay alive for as long as it's in use, and a little longer.
    final class Sequence: @unchecked Sendable {
        fileprivate let events: UnsafeMutablePointer<SequenceEvent>
        fileprivate let count: Int
        fileprivate let length: Double
        fileprivate let beatLength: Double

        init(events: [SequenceEvent], length: Double, beatLength: Double) {
            self.count = events.count
            self.length = length
            self.beatLength = beatLength
            self.events = .allocate(capacity: max(1, events.count))
            events.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { self.events.initialize(from: base, count: events.count) }
            }
        }

        deinit {
            events.deallocate()
        }
    }

    /// Something played while recording, and when.
    struct RecordedNote: Sendable {
        var seconds: Double
        var slot: Int
        var note: Int?
        var velocity: Int
        var isNoteOff: Bool
    }

    private struct Voice {
        var isActive = false
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var lastFrame = 0
        var startFrame = 0
        var endFrame = 0
        var position = 0.0
        /// The speed that plays the file at its own pitch on this output.
        var baseRate = 1.0
        var semitones = 0.0
        /// False for a sound prepared ahead of time, whose pitch is already part of it.
        var followsLiveTuning = true
        var gain: Float = 1
        var level: Float = 1
        /// How much `level` falls with each frame. 0 means the voice isn't fading out.
        var fade: Float = 0
        var isLooping = false
        var softensStart = false
        var followsPitchBend = false
        var slot = 0
        var owner = -1
        var cutGroup = 0
        var age: UInt64 = 0
        /// How far into the first block it starts, so that recorded notes land exactly in time.
        var delay = 0
    }

    private enum Command {
        case noteOn(slot: Int, note: Int?, velocity: Int)
        case release(slot: Int, note: Int?)
        case stopVoices(using: UnsafePointer<Float>)
        case stopAll
        case pitchBend(Double)
    }

    /// Held apart from the commands, because these must survive the audio output being reconnected.
    private enum TransportRequest {
        case none, stop
        case start(countInBeats: Int)
    }

    private struct Biquad {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0
    }

    /// One slot's settings as the real-time thread sees them.
    private struct SlotMix {
        var live = Live()
        var hasEQ = false
        var low = Biquad()
        var mid = Biquad()
        var high = Biquad()
        var hasSweep = false
        var sweep = Biquad()
        var volume: Float = 1
        var pan: Float = 0
        var wasSounding = false
        var isIsolated = false
        var limiterEnvelope: Float = 0
    }

    static let voiceCount = 32
    private static let commandCapacity = 512
    private static let recordingCapacity = 4096
    private static let largestBlock = 8192
    /// Two channels each of three EQ bands and the filter knob, with two numbers each.
    private static let filterMemoryPerSlot = 16
    /// Rounds off both ends of a sound, in frames of the file. Short enough not to dull a drum hit, long enough to
    /// stop the click that comes from cutting a sound off in the middle of a wave.
    private static let softEdge = 64.0
    private static let cutOffSeconds: Float = 0.006
    private static let padReleaseSeconds: Float = 0.015
    private static let keyReleaseSeconds: Float = 0.08
    private static let pitchBendRange = 2.0
    private static let keyboardOwnerBase = 1000
    private static let limiterCeiling: Float = 0.95
    private static let limiterReleaseSeconds = 0.15
    private static let clickSeconds = 0.03
    /// A hit this close before the count-in ends is someone playing the first beat a little early.
    private static let earlyFirstHit = 0.15

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let voices: UnsafeMutablePointer<Voice>
    private let commands: UnsafeMutablePointer<Command>
    private let slots: UnsafeMutablePointer<Slot?>
    private let noteSounds: UnsafeMutablePointer<NoteSound?>
    private let renderSlots: UnsafeMutablePointer<Slot?>
    private let renderNoteSounds: UnsafeMutablePointer<NoteSound?>
    private let waitingMixes: UnsafeMutablePointer<SlotMix>
    private let mixes: UnsafeMutablePointer<SlotMix>
    /// Left and right memory for each of the 3 filters of each slot.
    private let filterMemory: UnsafeMutablePointer<Float>
    /// How far each slot's newest sound has got, as a fraction of its length, or -1 if it's silent.
    private let playheads: UnsafeMutablePointer<Double>
    /// How many times each slot has started, for the pads to flash along with a recording.
    private let triggerCounts: UnsafeMutablePointer<Int>
    /// The loudest point of each slot's last block, after its volume and pan, left then right.
    private let levels: UnsafeMutablePointer<Float>
    /// The loudest point on each side since the screen last asked, so a short hit isn't missed between two looks.
    private let heldLevels: UnsafeMutablePointer<Float>
    private let slotLeft: UnsafeMutablePointer<Float>
    private let slotRight: UnsafeMutablePointer<Float>
    private let dryLeft: UnsafeMutablePointer<Float>
    private let dryRight: UnsafeMutablePointer<Float>
    /// The click, kept out of the music so it goes straight to the speakers, past the master and its plug-ins.
    private let click: UnsafeMutablePointer<Float>
    /// Slots whose sound goes through plug-ins of their own, kept apart from the main mix.
    private let isolatedLeft: UnsafeMutablePointer<Float>
    private let isolatedRight: UnsafeMutablePointer<Float>
    private let recorded: UnsafeMutablePointer<RecordedNote>
    private var recordedCount = 0
    private var commandCount = 0
    private var slotsHaveChanged = false
    private var mixesHaveChanged = false
    private var outputRate = 48_000.0
    private var limiterRelease: Float = 0.999
    private var limiterEnvelope: Float = 0
    private var pitchBend = 1.0
    private var nextAge: UInt64 = 0
    private var mixedFrames = 0

    // The recorder's clock.
    private var waitingEvents: UnsafePointer<SequenceEvent>?
    private var waitingEventCount = 0
    private var waitingLength = 0.0
    private var waitingBeatLength = 0.5
    private var sequenceHasChanged = false
    private var transportRequest = TransportRequest.none
    private var isRecording = false
    private var isMetronomeOn = false
    private var isRunning = false
    private var transportFrame = 0
    private var sequenceEvents: UnsafePointer<SequenceEvent>?
    private var sequenceCount = 0
    private var sequenceLength = 0.0
    private var beatLength = 0.5
    private var nextEvent = 0
    private var clickRemaining = 0
    private var clickPhase = 0.0
    private var clickStep = 0.0
    private var publishedIsRunning = false
    private var publishedFrame = 0
    private var publishedHostTime: UInt64 = 0
    private let timebaseScale: Double

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        voices = .allocate(capacity: Self.voiceCount)
        let silence = UnsafePointer(UnsafeMutablePointer<Float>.allocate(capacity: 1))
        voices.initialize(repeating: Voice(left: silence, right: silence), count: Self.voiceCount)
        commands = .allocate(capacity: Self.commandCapacity)
        commands.initialize(repeating: .stopAll, count: Self.commandCapacity)
        slots = .allocate(capacity: Self.slotCount)
        slots.initialize(repeating: nil, count: Self.slotCount)
        renderSlots = .allocate(capacity: Self.slotCount)
        renderSlots.initialize(repeating: nil, count: Self.slotCount)
        noteSounds = .allocate(capacity: 128)
        noteSounds.initialize(repeating: nil, count: 128)
        renderNoteSounds = .allocate(capacity: 128)
        renderNoteSounds.initialize(repeating: nil, count: 128)
        waitingMixes = .allocate(capacity: Self.slotCount)
        waitingMixes.initialize(repeating: SlotMix(), count: Self.slotCount)
        mixes = .allocate(capacity: Self.slotCount)
        mixes.initialize(repeating: SlotMix(), count: Self.slotCount)
        let memoryCount = Self.slotCount * Self.filterMemoryPerSlot
        filterMemory = .allocate(capacity: memoryCount)
        filterMemory.initialize(repeating: 0, count: memoryCount)
        playheads = .allocate(capacity: Self.slotCount)
        playheads.initialize(repeating: -1, count: Self.slotCount)
        triggerCounts = .allocate(capacity: Self.slotCount)
        triggerCounts.initialize(repeating: 0, count: Self.slotCount)
        levels = .allocate(capacity: Self.slotCount * 2)
        levels.initialize(repeating: 0, count: Self.slotCount * 2)
        heldLevels = .allocate(capacity: Self.slotCount * 2)
        heldLevels.initialize(repeating: 0, count: Self.slotCount * 2)
        recorded = .allocate(capacity: Self.recordingCapacity)
        recorded.initialize(repeating: RecordedNote(seconds: 0, slot: 0, velocity: 0, isNoteOff: false), count: Self.recordingCapacity)

        func buffer(_ count: Int = SamplerMixer.largestBlock) -> UnsafeMutablePointer<Float> {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            buffer.initialize(repeating: 0, count: count)
            return buffer
        }
        slotLeft = buffer()
        slotRight = buffer()
        dryLeft = buffer()
        dryRight = buffer()
        click = buffer()
        isolatedLeft = buffer(Self.largestBlock * Self.slotCount)
        isolatedRight = buffer(Self.largestBlock * Self.slotCount)

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseScale = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    private func send(_ command: Command) {
        guard commandCount < Self.commandCapacity else { return }
        commands[commandCount] = command
        commandCount += 1
    }

    // MARK: - Used from any thread except the real-time one

    /// Only while `render` isn't being called, as when the output is being reconnected.
    func setOutputRate(_ rate: Double) {
        withLock {
            // The recorder's place is counted in frames, so it's carried over to the new rate to stay at the same beat.
            if outputRate > 0, rate != outputRate {
                transportFrame = Int((Double(transportFrame) * rate / outputRate).rounded())
            }
            outputRate = rate
            limiterRelease = Float(exp(-1 / (Self.limiterReleaseSeconds * rate)))
            for index in 0..<Self.slotCount {
                prepareMix(index, live: waitingMixes[index].live)
            }
        }
    }

    /// The live settings take effect at once on anything already sounding, so a knob can be heard as it turns.
    func setSlot(_ index: Int, to slot: Slot?) {
        withLock {
            slots[index] = slot
            slotsHaveChanged = true
            if let slot { prepareMix(index, live: slot.live) }
        }
    }

    func setNoteSound(_ note: Int, to sound: NoteSound?) {
        withLock {
            noteSounds[note] = sound
            slotsHaveChanged = true
        }
    }

    /// A slot with plug-ins of its own is mixed separately, to be picked up with `copy(slot:)`.
    func setIsolatedSlots(_ isolated: Set<Int>) {
        withLock {
            for index in 0..<Self.slotCount {
                waitingMixes[index].isIsolated = isolated.contains(index)
            }
            mixesHaveChanged = true
        }
    }

    /// Returns false if there's no sound to play.
    @discardableResult
    func noteOn(slot index: Int, velocity: Int, note: Int? = nil) -> Bool {
        withLock {
            guard slots[index] != nil else { return false }
            send(.noteOn(slot: index, note: note, velocity: velocity))
            record(slot: index, note: note, velocity: velocity, isNoteOff: false)
            return true
        }
    }

    /// A one-shot plays on regardless, which is how drum pads are expected to behave.
    func noteOff(slot index: Int, note: Int? = nil) {
        withLock {
            send(.release(slot: index, note: note))
            record(slot: index, note: note, velocity: 0, isNoteOff: true)
        }
    }

    /// Notes are timed by the clock at the moment they arrive, not by when the next block happens to be mixed.
    private func record(slot: Int, note: Int?, velocity: Int, isNoteOff: Bool) {
        guard isRecording, publishedIsRunning, sequenceLength > 0, slot < SamplerSlot.count,
              recordedCount < Self.recordingCapacity
        else { return }

        let sinceBlock = Double(mach_absolute_time() &- publishedHostTime) * timebaseScale
        var seconds = Double(publishedFrame) / outputRate + sinceBlock
        if seconds < 0 {
            guard seconds > -Self.earlyFirstHit else { return }
            seconds = 0
        }
        recorded[recordedCount] = RecordedNote(
            seconds: seconds.truncatingRemainder(dividingBy: sequenceLength),
            slot: slot,
            note: note,
            velocity: velocity,
            isNoteOff: isNoteOff
        )
        recordedCount += 1
    }

    /// Everything played since the last time this was asked.
    func takeRecordedNotes() -> [RecordedNote] {
        withLock {
            let notes = Array(UnsafeBufferPointer(start: recorded, count: recordedCount))
            recordedCount = 0
            return notes
        }
    }

    func setRecording(_ isRecording: Bool) {
        withLock { self.isRecording = isRecording }
    }

    func setMetronome(_ isOn: Bool) {
        withLock { isMetronomeOn = isOn }
    }

    func setSequence(_ sequence: Sequence) {
        withLock {
            waitingEvents = UnsafePointer(sequence.events)
            waitingEventCount = sequence.count
            waitingLength = sequence.length
            waitingBeatLength = sequence.beatLength
            sequenceHasChanged = true
            // Recording can begin as soon as this returns, before the next block has been mixed.
            sequenceLength = sequence.length
        }
    }

    func startTransport(countInBeats: Int = 0) {
        withLock { transportRequest = .start(countInBeats: countInBeats) }
    }

    func stopTransport() {
        withLock { transportRequest = .stop }
    }

    /// For when the sampler is closed, since nothing would carry out a request to stop.
    func stopTransportWhileNotRendering() {
        withLock {
            transportRequest = .none
            isRunning = false
            publishedIsRunning = false
            clickRemaining = 0
        }
    }

    /// Seconds into the pattern, negative during a count-in, or nil if nothing's running.
    func transportPosition() -> Double? {
        withLock {
            guard publishedIsRunning else { return nil }
            let sinceBlock = Double(mach_absolute_time() &- publishedHostTime) * timebaseScale
            let seconds = Double(publishedFrame) / outputRate + sinceBlock
            return seconds < 0 || sequenceLength <= 0 ? seconds : seconds.truncatingRemainder(dividingBy: sequenceLength)
        }
    }

    /// `value` is what a pitch wheel sends, from 0 to 16383 with 8192 in the middle.
    func setPitchBend(value: Int) {
        let semitones = Double(value - 8192) / 8192 * Self.pitchBendRange
        withLock { send(.pitchBend(pow(2, semitones / 12))) }
    }

    /// Call this before the memory behind a sound goes away.
    func stopVoices(using left: UnsafePointer<Float>) {
        withLock { send(.stopVoices(using: left)) }
    }

    func stopAll() {
        withLock { send(.stopAll) }
    }

    /// How far a slot's newest sound has got through its chosen part, from 0 to 1. Negative when it's silent.
    func playhead(of slot: Int) -> Double {
        playheads[slot]
    }

    func triggerCount(of slot: Int) -> Int {
        triggerCounts[slot]
    }

    func level(of slot: Int) -> SamplerLevel {
        SamplerLevel(left: levels[slot * 2], right: levels[slot * 2 + 1])
    }

    /// The loudest a slot has been on each side since this was last asked, for its meter.
    func takeLoudest(of slot: Int) -> SamplerLevel {
        let loudest = SamplerLevel(left: heldLevels[slot * 2], right: heldLevels[slot * 2 + 1])
        heldLevels[slot * 2] = 0
        heldLevels[slot * 2 + 1] = 0
        return loudest
    }

    /// Only for when `render` isn't being called, since nothing else would carry out a command. The recorder's clock
    /// keeps its place, so that changing the audio output or adding a plug-in doesn't stop the music for good.
    func resetWhileNotRendering() {
        withLock {
            commandCount = 0
            pitchBend = 1
            limiterEnvelope = 0
            for index in 0..<Self.voiceCount { voices[index].isActive = false }
            for index in 0..<Self.slotCount { playheads[index] = -1 }
            filterMemory.update(repeating: 0, count: Self.slotCount * Self.filterMemoryPerSlot)
        }
    }

    private static func owner(slot: Int, note: Int?) -> Int {
        note.map { keyboardOwnerBase + $0 } ?? slot
    }

    private func prepareMix(_ index: Int, live: Live) {
        waitingMixes[index].live = live
        waitingMixes[index].hasEQ = live.eqLow != 0 || live.eqMid != 0 || live.eqHigh != 0
        waitingMixes[index].low = Self.lowShelf(decibels: live.eqLow, rate: outputRate)
        waitingMixes[index].mid = Self.peak(decibels: live.eqMid, rate: outputRate)
        waitingMixes[index].high = Self.highShelf(decibels: live.eqHigh, rate: outputRate)
        let sweep = Self.sweep(amount: live.filter, rate: outputRate)
        waitingMixes[index].hasSweep = sweep != nil
        waitingMixes[index].sweep = sweep ?? Biquad()
        mixesHaveChanged = true
    }

    // MARK: - Filters

    /// From the widely used Audio EQ Cookbook by Robert Bristow-Johnson.
    private static func lowShelf(decibels: Double, rate: Double) -> Biquad {
        guard decibels != 0 else { return Biquad() }
        let gain = pow(10, decibels / 40)
        let angle = 2 * Double.pi * 150 / rate
        let shape = sin(angle) / 2 * 2.0.squareRoot()
        let root = 2 * gain.squareRoot() * shape
        let a0 = (gain + 1) + (gain - 1) * cos(angle) + root
        return biquad(
            b0: gain * ((gain + 1) - (gain - 1) * cos(angle) + root),
            b1: 2 * gain * ((gain - 1) - (gain + 1) * cos(angle)),
            b2: gain * ((gain + 1) - (gain - 1) * cos(angle) - root),
            a0: a0,
            a1: -2 * ((gain - 1) + (gain + 1) * cos(angle)),
            a2: (gain + 1) + (gain - 1) * cos(angle) - root
        )
    }

    private static func highShelf(decibels: Double, rate: Double) -> Biquad {
        guard decibels != 0 else { return Biquad() }
        let gain = pow(10, decibels / 40)
        let angle = 2 * Double.pi * min(6000, rate * 0.45) / rate
        let shape = sin(angle) / 2 * 2.0.squareRoot()
        let root = 2 * gain.squareRoot() * shape
        let a0 = (gain + 1) - (gain - 1) * cos(angle) + root
        return biquad(
            b0: gain * ((gain + 1) + (gain - 1) * cos(angle) + root),
            b1: -2 * gain * ((gain - 1) + (gain + 1) * cos(angle)),
            b2: gain * ((gain + 1) + (gain - 1) * cos(angle) - root),
            a0: a0,
            a1: 2 * ((gain - 1) - (gain + 1) * cos(angle)),
            a2: (gain + 1) - (gain - 1) * cos(angle) - root
        )
    }

    private static func peak(decibels: Double, rate: Double) -> Biquad {
        guard decibels != 0 else { return Biquad() }
        let gain = pow(10, decibels / 40)
        let angle = 2 * Double.pi * 1000 / rate
        let shape = sin(angle) / (2 * 0.8)
        return biquad(
            b0: 1 + shape * gain,
            b1: -2 * cos(angle),
            b2: 1 - shape * gain,
            a0: 1 + shape / gain,
            a1: -2 * cos(angle),
            a2: 1 - shape / gain
        )
    }

    private static func biquad(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// The one-knob filter, or nil when it's in the middle and leaves the sound alone.
    private static func sweep(amount: Float, rate: Double) -> Biquad? {
        let shape = SamplerFilterSweep.shape(of: Double(amount))
        let frequency: Double
        let isLowPass: Bool
        switch shape {
        case .off: return nil
        case .lowPass(let cutoff): (frequency, isLowPass) = (cutoff, true)
        case .highPass(let cutoff): (frequency, isLowPass) = (cutoff, false)
        }
        let angle = 2 * Double.pi * min(frequency, rate * 0.45) / rate
        let alpha = sin(angle) / (2 * SamplerFilterSweep.resonance)
        let cosine = cos(angle)
        let edge = isLowPass ? (1 - cosine) / 2 : (1 + cosine) / 2
        return biquad(
            b0: edge,
            b1: isLowPass ? 1 - cosine : -(1 + cosine),
            b2: edge,
            a0: 1 + alpha,
            a1: -2 * cosine,
            a2: 1 - alpha
        )
    }

    /// How much the three bands raise or lower each frequency, in decibels, for drawing the EQ's curve.
    static func eqResponse(low: Double, mid: Double, high: Double, at frequencies: [Double], rate: Double = 48000) -> [Double] {
        let filters = [lowShelf(decibels: low, rate: rate), peak(decibels: mid, rate: rate), highShelf(decibels: high, rate: rate)]
        return frequencies.map { frequency in
            let angle = 2 * Double.pi * min(frequency, rate / 2) / rate
            let (cos1, sin1, cos2, sin2) = (cos(angle), sin(angle), cos(2 * angle), sin(2 * angle))
            return filters.reduce(0) { total, filter in
                let (b0, b1, b2) = (Double(filter.b0), Double(filter.b1), Double(filter.b2))
                let (a1, a2) = (Double(filter.a1), Double(filter.a2))
                let numerator = pow(b0 + b1 * cos1 + b2 * cos2, 2) + pow(b1 * sin1 + b2 * sin2, 2)
                let denominator = pow(1 + a1 * cos1 + a2 * cos2, 2) + pow(a1 * sin1 + a2 * sin2, 2)
                return total + 10 * log10(max(numerator, 1e-12) / max(denominator, 1e-12))
            }
        }
    }

    // MARK: - Used only from the real-time thread

    /// Mixes the next block and hands over the part that goes straight to the output. Call this first in each cycle.
    func render(frames requested: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let frames = min(requested, Self.largestBlock)
        mix(frames: frames)
        left.update(from: dryLeft, count: frames)
        right.update(from: dryRight, count: frames)
        mixedFrames = frames
        if requested > frames {
            (left + frames).update(repeating: 0, count: requested - frames)
            (right + frames).update(repeating: 0, count: requested - frames)
        }
    }

    /// Hands over the sound of a slot that goes through plug-ins of its own.
    func copy(slot: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        hand(from: isolatedLeft + slot * Self.largestBlock, isolatedRight + slot * Self.largestBlock, frames: frames, left: left, right: right)
    }

    /// Hands over the click, the same on both sides.
    func copyClick(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        hand(from: click, click, frames: frames, left: left, right: right)
    }

    private func hand(
        from sourceLeft: UnsafePointer<Float>,
        _ sourceRight: UnsafePointer<Float>,
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        let available = min(frames, mixedFrames)
        left.update(from: sourceLeft, count: available)
        right.update(from: sourceRight, count: available)
        if frames > available {
            (left + available).update(repeating: 0, count: frames - available)
            (right + available).update(repeating: 0, count: frames - available)
        }
    }

    private func mix(frames: Int) {
        if os_unfair_lock_trylock(lock) {
            if slotsHaveChanged {
                renderSlots.update(from: slots, count: Self.slotCount)
                renderNoteSounds.update(from: noteSounds, count: 128)
                slotsHaveChanged = false
            }
            if mixesHaveChanged {
                for index in 0..<Self.slotCount {
                    mixes[index].live = waitingMixes[index].live
                    mixes[index].hasEQ = waitingMixes[index].hasEQ
                    mixes[index].low = waitingMixes[index].low
                    mixes[index].mid = waitingMixes[index].mid
                    mixes[index].high = waitingMixes[index].high
                    mixes[index].hasSweep = waitingMixes[index].hasSweep
                    mixes[index].sweep = waitingMixes[index].sweep
                    mixes[index].isIsolated = waitingMixes[index].isIsolated
                }
                mixesHaveChanged = false
            }
            if sequenceHasChanged {
                // A new tempo keeps the music on the same beat, rather than at the same number of seconds in.
                if beatLength > 0, waitingBeatLength > 0, waitingBeatLength != beatLength {
                    transportFrame = Int((Double(transportFrame) * waitingBeatLength / beatLength).rounded())
                }
                sequenceEvents = waitingEvents
                sequenceCount = waitingEventCount
                sequenceLength = waitingLength
                beatLength = waitingBeatLength
                positionNextEvent()
                sequenceHasChanged = false
            }
            for index in 0..<commandCount { carryOut(commands[index]) }
            commandCount = 0
            applyTransportRequest()
            publishedIsRunning = isRunning
            publishedFrame = transportFrame
            publishedHostTime = mach_absolute_time()
            os_unfair_lock_unlock(lock)
        }

        dryLeft.update(repeating: 0, count: frames)
        dryRight.update(repeating: 0, count: frames)
        click.update(repeating: 0, count: frames)

        let blockStart = transportFrame
        if isRunning { runTransport(frames: frames) }

        for slot in 0..<Self.slotCount {
            if mixes[slot].isIsolated {
                (isolatedLeft + slot * Self.largestBlock).update(repeating: 0, count: frames)
                (isolatedRight + slot * Self.largestBlock).update(repeating: 0, count: frames)
            }
            mixVoices(ofSlot: slot, frames: frames)
            if mixes[slot].isIsolated {
                Self.limit(
                    left: isolatedLeft + slot * Self.largestBlock,
                    right: isolatedRight + slot * Self.largestBlock,
                    frames: frames,
                    envelope: &mixes[slot].limiterEnvelope,
                    release: limiterRelease
                )
            }
        }
        Self.limit(left: dryLeft, right: dryRight, frames: frames, envelope: &limiterEnvelope, release: limiterRelease)
        if isRunning { addMetronome(frames: frames, startingAt: blockStart) }
    }

    private func mixVoices(ofSlot slot: Int, frames: Int) {
        var isSounding = false
        var newest: UInt64 = 0
        var playhead = -1.0
        var heldNotes = 0

        for index in 0..<Self.voiceCount where voices[index].isActive && voices[index].slot == slot {
            if !isSounding {
                slotLeft.update(repeating: 0, count: frames)
                slotRight.update(repeating: 0, count: frames)
                isSounding = true
            }
            if voices[index].fade == 0 { heldNotes += 1 }
            mix(voiceAt: index, frames: frames)
            if voices[index].isActive, voices[index].age > newest {
                newest = voices[index].age
                let length = Double(voices[index].endFrame - voices[index].startFrame)
                playhead = length > 0 ? (voices[index].position - Double(voices[index].startFrame)) / length : 0
            }
        }
        playheads[slot] = playhead

        guard isSounding else {
            mixes[slot].wasSounding = false
            levels[slot * 2] = 0
            levels[slot * 2 + 1] = 0
            return
        }

        if mixes[slot].hasEQ { applyEQ(toSlot: slot, frames: frames) }
        if mixes[slot].hasSweep { applySweep(toSlot: slot, frames: frames) }

        // Notes of a chord add up to far more than one note. Turning them down together as more are held leaves room
        // for them, so a chord stays clean and only about as loud as a person would expect.
        let target = mixes[slot].live
        let headroom = slot == SamplerSlot.keyboardIndex ? 1 / Float(max(1, heldNotes)).squareRoot() : 1
        let targetVolume = target.volume * headroom

        // A new sound starts at the current settings. One already playing glides to them, because a jump would click.
        if !mixes[slot].wasSounding {
            mixes[slot].volume = targetVolume
            mixes[slot].pan = target.pan
            mixes[slot].wasSounding = true
        }

        var volume = mixes[slot].volume
        var pan = mixes[slot].pan
        let steps = Float(frames)
        let volumeStep = (targetVolume - volume) / steps
        let panStep = (target.pan - pan) / steps
        let outLeft = mixes[slot].isIsolated ? isolatedLeft + slot * Self.largestBlock : dryLeft
        let outRight = mixes[slot].isIsolated ? isolatedRight + slot * Self.largestBlock : dryRight

        var loudestLeft: Float = 0
        var loudestRight: Float = 0
        for frame in 0..<frames {
            volume += volumeStep
            pan += panStep
            // Panning turns down the far side and leaves the near one, so the middle is as loud as before.
            let left = slotLeft[frame] * volume * min(1, 1 - pan)
            let right = slotRight[frame] * volume * min(1, 1 + pan)
            loudestLeft = max(loudestLeft, abs(left))
            loudestRight = max(loudestRight, abs(right))
            outLeft[frame] += left
            outRight[frame] += right
        }
        mixes[slot].volume = targetVolume
        mixes[slot].pan = target.pan
        levels[slot * 2] = loudestLeft
        levels[slot * 2 + 1] = loudestRight
        heldLevels[slot * 2] = max(heldLevels[slot * 2], loudestLeft)
        heldLevels[slot * 2 + 1] = max(heldLevels[slot * 2 + 1], loudestRight)
    }

    private func applyEQ(toSlot slot: Int, frames: Int) {
        let memory = filterMemory + slot * Self.filterMemoryPerSlot
        Self.filter(slotLeft, frames: frames, with: mixes[slot].low, memory: memory)
        Self.filter(slotRight, frames: frames, with: mixes[slot].low, memory: memory + 2)
        Self.filter(slotLeft, frames: frames, with: mixes[slot].mid, memory: memory + 4)
        Self.filter(slotRight, frames: frames, with: mixes[slot].mid, memory: memory + 6)
        Self.filter(slotLeft, frames: frames, with: mixes[slot].high, memory: memory + 8)
        Self.filter(slotRight, frames: frames, with: mixes[slot].high, memory: memory + 10)
    }

    private func applySweep(toSlot slot: Int, frames: Int) {
        let memory = filterMemory + slot * Self.filterMemoryPerSlot + 12
        Self.filter(slotLeft, frames: frames, with: mixes[slot].sweep, memory: memory)
        Self.filter(slotRight, frames: frames, with: mixes[slot].sweep, memory: memory + 2)
    }

    private static func filter(_ samples: UnsafeMutablePointer<Float>, frames: Int, with biquad: Biquad, memory: UnsafeMutablePointer<Float>) {
        var first = memory[0]
        var second = memory[1]
        for frame in 0..<frames {
            let input = samples[frame]
            let output = biquad.b0 * input + first
            first = biquad.b1 * input - biquad.a1 * output + second
            second = biquad.b2 * input - biquad.a2 * output
            samples[frame] = output
        }
        memory[0] = first
        memory[1] = second
    }

    /// Several loud sounds at once add up to more than the output can take. This turns the whole mix down until they
    /// fit, rather than bending the wave, which is what makes a chord sound harsh. A single sound passes untouched.
    private static func limit(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        envelope: inout Float,
        release: Float
    ) {
        for frame in 0..<frames {
            let peak = max(abs(left[frame]), abs(right[frame]))
            envelope = peak > envelope ? peak : envelope * release
            if envelope > limiterCeiling {
                let gain = limiterCeiling / envelope
                left[frame] *= gain
                right[frame] *= gain
            }
        }
    }

    private func carryOut(_ command: Command) {
        switch command {
        case .noteOn(let slot, let note, let velocity):
            startVoice(slot: slot, note: note, velocity: velocity, delay: 0)
        case .release(let slot, let note):
            releaseVoices(slot: slot, note: note)
        case .stopVoices(let left):
            for index in 0..<Self.voiceCount where voices[index].isActive && voices[index].left == left {
                beginFade(ofVoiceAt: index, seconds: Self.cutOffSeconds)
            }
        case .stopAll:
            fadeEverything()
        case .pitchBend(let bend):
            pitchBend = bend
        }
    }

    private func applyTransportRequest() {
        switch transportRequest {
        case .none:
            break
        case .start(let countInBeats):
            isRunning = true
            transportFrame = -Int((Double(countInBeats) * beatLength * outputRate).rounded())
            nextEvent = 0
        case .stop:
            isRunning = false
            clickRemaining = 0
            fadeEverything()
        }
        transportRequest = .none
    }

    private func fadeEverything() {
        for index in 0..<Self.voiceCount where voices[index].isActive {
            beginFade(ofVoiceAt: index, seconds: Self.cutOffSeconds)
        }
    }

    private func releaseVoices(slot: Int, note: Int?) {
        guard let sound = renderSlots[slot], sound.mode != .oneShot else { return }
        let owner = Self.owner(slot: slot, note: note)
        let seconds = note == nil ? Self.padReleaseSeconds : Self.keyReleaseSeconds
        for index in 0..<Self.voiceCount where voices[index].isActive && voices[index].owner == owner {
            beginFade(ofVoiceAt: index, seconds: seconds)
        }
    }

    private func startVoice(slot index: Int, note: Int?, velocity: Int, delay: Int) {
        guard let slot = renderSlots[index] else { return }

        let velocityLevel = Float(pow(Double(max(1, min(velocity, 127))) / 127, 1.5))
        nextAge += 1

        var voice = Voice(
            isActive: true,
            left: slot.left,
            right: slot.right,
            lastFrame: slot.frameCount - 1,
            startFrame: slot.startFrame,
            endFrame: slot.endFrame,
            position: Double(slot.startFrame),
            baseRate: slot.sampleRate / outputRate,
            gain: velocityLevel,
            isLooping: slot.mode == .loop,
            softensStart: slot.startFrame > 0,
            followsPitchBend: note != nil,
            slot: index,
            owner: Self.owner(slot: index, note: note),
            cutGroup: slot.cutGroup,
            age: nextAge,
            delay: delay
        )

        if let note {
            if let sound = renderNoteSounds[note] {
                voice.left = sound.left
                voice.right = sound.right
                voice.lastFrame = sound.frameCount - 1
                voice.startFrame = 0
                voice.endFrame = sound.frameCount
                voice.position = 0
                voice.baseRate = sound.sampleRate / outputRate
                voice.followsLiveTuning = false
                voice.softensStart = false
            } else {
                voice.semitones = Double(note - slot.rootNote)
            }
        }

        for other in 0..<Self.voiceCount where voices[other].isActive {
            let isSameSound = voices[other].owner == voice.owner
            let isCutOff = voice.cutGroup != 0 && voices[other].cutGroup == voice.cutGroup
            if isSameSound || isCutOff {
                beginFade(ofVoiceAt: other, seconds: Self.cutOffSeconds)
            }
        }
        voices[voiceToReplace()] = voice
        triggerCounts[index] += 1
    }

    /// A free voice if there is one, then whichever is already fading out, then the one that started longest ago.
    private func voiceToReplace() -> Int {
        var fading: Int?
        var oldest = 0
        for index in 0..<Self.voiceCount {
            if !voices[index].isActive { return index }
            if voices[index].fade > 0, fading == nil { fading = index }
            if voices[index].age < voices[oldest].age { oldest = index }
        }
        return fading ?? oldest
    }

    private func beginFade(ofVoiceAt index: Int, seconds: Float) {
        guard voices[index].fade == 0 else { return }
        voices[index].fade = 1 / max(1, seconds * Float(outputRate))
    }

    private func mix(voiceAt index: Int, frames: Int) {
        var voice = voices[index]
        let tuning = voice.semitones + (voice.followsLiveTuning ? mixes[voice.slot].live.semitones : 0)
        let rate = voice.baseRate * (tuning == 0 ? 1 : pow(2, tuning / 12)) * (voice.followsPitchBend ? pitchBend : 1)
        let start = Double(voice.startFrame)
        let end = Double(voice.endFrame)
        // Never before the start of the block, which would write outside it.
        let firstFrame = max(0, min(voice.delay, frames))
        voice.delay -= firstFrame

        for frame in firstFrame..<frames {
            if voice.position >= end - 1 {
                guard voice.isLooping, end - start > 2 else {
                    voice.isActive = false
                    break
                }
                voice.position = start + (voice.position - (end - 1))
                voice.softensStart = true
            }
            if voice.fade > 0 {
                voice.level -= voice.fade
                if voice.level <= 0 {
                    voice.isActive = false
                    break
                }
            }

            var edge = Float(min(1, (end - voice.position) / Self.softEdge))
            if voice.softensStart {
                edge = min(edge, Float(min(1, (voice.position - start) / Self.softEdge)))
            }
            let gain = voice.gain * voice.level * edge

            let whole = Int(voice.position)
            let fraction = Float(voice.position - Double(whole))
            slotLeft[frame] += Self.value(of: voice.left, at: whole, fraction: fraction, last: voice.lastFrame) * gain
            slotRight[frame] += Self.value(of: voice.right, at: whole, fraction: fraction, last: voice.lastFrame) * gain
            voice.position += rate
        }
        voices[index] = voice
    }

    /// Reads between two frames along a smooth curve, which keeps high notes cleaner than a straight line would.
    @inline(__always)
    private static func value(of data: UnsafePointer<Float>, at index: Int, fraction: Float, last: Int) -> Float {
        if fraction == 0 { return data[index] }
        let before = data[max(index - 1, 0)]
        let here = data[index]
        let next = data[min(index + 1, last)]
        let after = data[min(index + 2, last)]
        let a = (3 * (here - next) + after - before) * 0.5
        let b = 2 * next + before - (5 * here + after) * 0.5
        let c = (next - before) * 0.5
        return ((a * fraction + b) * fraction + c) * fraction + here
    }

    // MARK: - The recorder's clock

    private func positionNextEvent() {
        guard sequenceLength > 0, let events = sequenceEvents else {
            nextEvent = 0
            return
        }
        let now = max(0, Double(transportFrame) / outputRate)
        nextEvent = 0
        while nextEvent < sequenceCount, events[nextEvent].seconds < now { nextEvent += 1 }
    }

    /// Starts everything in the pattern that falls within this block, each at its exact frame.
    private func runTransport(frames: Int) {
        let lengthFrames = Int((sequenceLength * outputRate).rounded())
        guard lengthFrames > 0 else { return }

        var done = 0
        while done < frames {
            if transportFrame < 0 {
                let step = min(frames - done, -transportFrame)
                transportFrame += step
                done += step
                continue
            }

            // The loop may have just become shorter, from fewer bars, a faster tempo, or a lower output rate.
            if transportFrame >= lengthFrames {
                transportFrame %= lengthFrames
                positionNextEvent()
            }

            let step = min(frames - done, lengthFrames - transportFrame)
            let end = transportFrame + step
            if let events = sequenceEvents {
                while nextEvent < sequenceCount {
                    let event = events[nextEvent]
                    let eventFrame = Int((event.seconds * outputRate).rounded())
                    guard eventFrame < end else { break }
                    if eventFrame >= transportFrame {
                        let note = event.note >= 0 ? Int(event.note) : nil
                        if event.isNoteOff {
                            releaseVoices(slot: Int(event.slot), note: note)
                        } else {
                            startVoice(slot: Int(event.slot), note: note, velocity: Int(event.velocity), delay: done + eventFrame - transportFrame)
                        }
                    }
                    nextEvent += 1
                }
            }
            transportFrame = end
            done += step
            if transportFrame >= lengthFrames {
                transportFrame = 0
                nextEvent = 0
            }
        }
    }

    /// The click has an output of its own, so the master's volume and plug-ins never touch it, and it isn't part of
    /// what gets exported.
    private func addMetronome(frames: Int, startingAt start: Int) {
        let beatFrames = Int((beatLength * outputRate).rounded())
        guard beatFrames > 0 else { return }
        let lengthFrames = Int((sequenceLength * outputRate).rounded())
        let clickLength = Int(Self.clickSeconds * outputRate)

        var position = start
        for frame in 0..<frames {
            // The count-in always clicks, because that's the only way to know when to come in.
            if (isMetronomeOn || position < 0), position % beatFrames == 0 {
                let isBarStart = position % (beatFrames * 4) == 0
                clickRemaining = clickLength
                clickPhase = 0
                clickStep = 2 * Double.pi * (isBarStart ? 1500 : 1000) / outputRate
            }
            if clickRemaining > 0 {
                let envelope = Float(clickRemaining) / Float(clickLength)
                click[frame] = Float(sin(clickPhase)) * 0.3 * envelope
                clickPhase += clickStep
                clickRemaining -= 1
            }
            position += 1
            if lengthFrames > 0, position >= lengthFrames { position = 0 }
        }
    }
}
