import Foundation
import Observation

/// Records what's played on the pads and keys into a short loop, and plays it back.
@Observable
final class SamplerSequencer {
    private static let countInBeats = 4
    static let bpmRange = 30.0...300.0
    /// How long a note counts for if it's still held when it needs to be placed, in beats.
    private static let shortestNote = 0.25

    private(set) var pattern = SamplerPattern()
    private(set) var isPlaying = false
    private(set) var isRecording = false
    /// Where the music is, in beats from the start. Negative during a count-in, nil when stopped.
    private(set) var position: Double?
    var isMetronomeOn = true {
        didSet { mixer.setMetronome(isMetronomeOn) }
    }

    @ObservationIgnored private let mixer: SamplerMixer
    @ObservationIgnored private let onChange: () -> Void
    @ObservationIgnored private var sequence: SamplerMixer.Sequence?
    @ObservationIgnored private var taps: [TimeInterval] = []
    /// Notes just played. They've already been heard, so they wait until the music has passed where they land, to
    /// save them sounding twice when pulled forward onto the beat.
    @ObservationIgnored private var waiting: [Waiting] = []
    @ObservationIgnored private var currentTake = 0

    private struct Waiting {
        var note: SamplerRecordedNote
        var hasEnded = false
    }

    init(mixer: SamplerMixer, onChange: @escaping () -> Void) {
        self.mixer = mixer
        self.onChange = onChange
        mixer.setMetronome(isMetronomeOn)
        sendToMixer()
    }

    var hasNotes: Bool {
        !pattern.notes.isEmpty
    }

    func load(_ pattern: SamplerPattern) {
        self.pattern = pattern
        currentTake = pattern.notes.map(\.take).max() ?? 0
        sendToMixer()
    }

    // MARK: - Transport

    func togglePlayback() {
        if isPlaying {
            stop()
        } else {
            isPlaying = true
            mixer.startTransport()
        }
    }

    /// Records straight away if the music is already playing, and after a count-in if not.
    func toggleRecording() {
        if isRecording {
            finishRecording()
            return
        }
        currentTake += 1
        isRecording = true
        mixer.setRecording(true)
        if !isPlaying {
            isPlaying = true
            mixer.startTransport(countInBeats: Self.countInBeats)
        }
    }

    func stop() {
        if isRecording { finishRecording() }
        isPlaying = false
        position = nil
        mixer.stopTransport()
    }

    private func finishRecording() {
        isRecording = false
        mixer.setRecording(false)
        takeNotes()
        for item in waiting { pattern.notes.append(item.note) }
        waiting = []
        patternChanged()
    }

    /// Called many times a second while the music is playing.
    func tick() {
        guard isPlaying else { return }

        let seconds = mixer.transportPosition()
        let newPosition = seconds.map { $0 / pattern.secondsPerBeat }
        if newPosition != position { position = newPosition }

        guard isRecording, let beat = newPosition else { return }
        takeNotes()
        placeWaitingNotes(at: beat)
    }

    private func takeNotes() {
        for played in mixer.takeRecordedNotes() {
            let beat = played.seconds / pattern.secondsPerBeat
            if played.isNoteOff {
                end(slot: played.slot, note: played.note, at: beat)
            } else {
                waiting.append(Waiting(note: SamplerRecordedNote(
                    slot: played.slot,
                    note: played.note,
                    velocity: played.velocity,
                    beat: beat,
                    length: Self.shortestNote,
                    take: currentTake
                )))
            }
        }
    }

    private func end(slot: Int, note: Int?, at beat: Double) {
        if let index = waiting.lastIndex(where: { $0.note.slot == slot && $0.note.note == note && !$0.hasEnded }) {
            waiting[index].note.length = length(from: waiting[index].note.beat, to: beat)
            waiting[index].hasEnded = true
        } else if let index = pattern.notes.lastIndex(where: { $0.slot == slot && $0.note == note && $0.take == currentTake }) {
            // It was placed while still being held.
            pattern.notes[index].length = length(from: pattern.notes[index].beat, to: beat)
            patternChanged()
        }
    }

    private func length(from start: Double, to end: Double) -> Double {
        var length = end - start
        if length < 0 { length += pattern.beats }
        return max(0.01, length)
    }

    private func placeWaitingNotes(at beat: Double) {
        guard beat >= 0 else { return }
        var placedAny = false
        waiting.removeAll { item in
            let landing = pattern.timedBeat(item.note.beat)
            var passed = beat - landing
            if passed < 0 { passed += pattern.beats }
            guard passed < pattern.beats / 2, item.hasEnded || passed >= Self.shortestNote else { return false }
            pattern.notes.append(item.note)
            placedAny = true
            return true
        }
        if placedAny { patternChanged() }
    }

    // MARK: - Editing

    func setBPM(_ bpm: Double) {
        pattern.bpm = min(max(bpm, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
        patternChanged()
    }

    /// Sets the tempo from the time between taps, the way a drum machine's tap button does. The last few taps count,
    /// and a pause of two seconds starts over.
    func tapTempo(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let last = taps.last, time - last > 2 { taps = [] }
        taps = Array((taps + [time]).suffix(5))
        guard taps.count >= 2, let first = taps.first, let last = taps.last, last > first else { return }
        setBPM((60 / ((last - first) / Double(taps.count - 1))).rounded())
    }

    func setBars(_ bars: Int) {
        pattern.bars = bars
        patternChanged()
    }

    func setQuantize(_ quantize: SamplerQuantize) {
        pattern.quantize = quantize
        patternChanged()
    }

    func setSwing(_ swing: Double) {
        pattern.swing = swing
        patternChanged()
    }

    func undoLastTake() {
        guard let last = pattern.notes.map(\.take).max() else { return }
        pattern.notes.removeAll { $0.take == last }
        patternChanged()
    }

    func clear() {
        pattern.notes = []
        waiting = []
        patternChanged()
    }

    private func patternChanged() {
        sendToMixer()
        onChange()
    }

    private func sendToMixer() {
        let previous = sequence
        let new = SamplerMixer.Sequence(
            events: events(),
            length: pattern.seconds,
            beatLength: pattern.secondsPerBeat
        )
        sequence = new
        mixer.setSequence(new)

        // The real-time thread may still be reading the old one for a moment.
        if let previous {
            Task {
                try? await Task.sleep(for: .seconds(3))
                _ = previous
            }
        }
    }

    /// The pattern as timed starts and stops, for one slot if `slot` is given.
    func events(slot: Int? = nil) -> [SamplerMixer.SequenceEvent] {
        let secondsPerBeat = pattern.secondsPerBeat
        var events: [SamplerMixer.SequenceEvent] = []
        for note in pattern.timedNotes where slot == nil || note.slot == slot {
            let key = Int32(note.note ?? -1)
            events.append(SamplerMixer.SequenceEvent(
                seconds: note.beat * secondsPerBeat,
                slot: Int32(note.slot),
                note: key,
                velocity: Int32(note.velocity),
                isNoteOff: false
            ))
            events.append(SamplerMixer.SequenceEvent(
                seconds: (note.beat + note.length).truncatingRemainder(dividingBy: pattern.beats) * secondsPerBeat,
                slot: Int32(note.slot),
                note: key,
                velocity: 0,
                isNoteOff: true
            ))
        }
        return events.sorted { $0.seconds != $1.seconds ? $0.seconds < $1.seconds : $0.isNoteOff && !$1.isNoteOff }
    }

    /// Which slots have anything recorded.
    var slotsWithNotes: [Int] {
        Array(Set(pattern.timedNotes.map(\.slot))).sorted()
    }
}
