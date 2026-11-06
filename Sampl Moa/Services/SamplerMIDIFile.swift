import AVFoundation
import Foundation

/// Writes a pattern as a standard MIDI file, which every DAW can open. Pads are on channel 10 from note 36, the same as
/// they come from a pad controller, and the keyboard is on channel 1.
nonisolated enum SamplerMIDIFile {
    private static let ticksPerBeat = 480

    static func data(for pattern: SamplerPattern) -> Data {
        var events: [(tick: Int, bytes: [UInt8])] = []

        for note in pattern.timedNotes {
            let channel: UInt8 = note.note == nil ? 9 : 0
            let pitch = UInt8(min(max(note.note ?? (36 + note.slot), 0), 127))
            let start = Int((note.beat * Double(ticksPerBeat)).rounded())
            let end = start + max(1, Int((note.length * Double(ticksPerBeat)).rounded()))
            events.append((start, [0x90 | channel, pitch, UInt8(max(1, min(note.velocity, 127)))]))
            events.append((end, [0x80 | channel, pitch, 0]))
        }
        // Offs before ons at the same moment, so a repeated note doesn't cut itself short.
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : ($0.bytes[0] & 0xF0) < ($1.bytes[0] & 0xF0) }

        var track = Data()
        let microseconds = Int((pattern.secondsPerBeat * 1_000_000).rounded())
        track.append(contentsOf: [0x00, 0xFF, 0x51, 0x03, UInt8(microseconds >> 16 & 0xFF), UInt8(microseconds >> 8 & 0xFF), UInt8(microseconds & 0xFF)])
        track.append(contentsOf: [0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08])

        var lastTick = 0
        for event in events {
            track.append(contentsOf: variableLength(event.tick - lastTick))
            track.append(contentsOf: event.bytes)
            lastTick = event.tick
        }
        let patternEnd = Int(pattern.beats) * ticksPerBeat
        track.append(contentsOf: variableLength(max(0, patternEnd - lastTick)))
        track.append(contentsOf: [0xFF, 0x2F, 0x00])

        var file = Data("MThd".utf8)
        file.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1, UInt8(ticksPerBeat >> 8), UInt8(ticksPerBeat & 0xFF)])
        file.append(Data("MTrk".utf8))
        withUnsafeBytes(of: UInt32(track.count).bigEndian) { file.append(contentsOf: $0) }
        file.append(track)
        return file
    }

    private static func variableLength(_ value: Int) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }
}

/// Renders a pattern to a file ahead of time, through its own copy of the whole signal path. Timing comes out exact,
/// faster than playing it, and nothing is heard while it happens.
nonisolated enum SamplerBouncer {
    struct Job: @unchecked Sendable {
        var slots: [Int: SamplerMixer.Slot]
        var noteSounds: [Int: SamplerMixer.NoteSound]
        var events: [SamplerMixer.SequenceEvent]
        var seconds: Double
        var secondsPerBeat: Double
        var sampleRate: Double
        var master: SamplerMaster
        /// Must be copies, since a plug-in can only be in one place at a time.
        var plugins: [AVAudioUnit]
        var slotPlugins: [Int: [AVAudioUnit]]
        var url: URL
        /// Keeps the sounds' memory alive until this is done.
        var keepAlive: [AnyObject]
    }

    enum BounceError: Error {
        case couldNotRender
    }

    @concurrent static func render(_ job: Job) async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: job.sampleRate, channels: 2) else {
            throw BounceError.couldNotRender
        }

        let mixer = SamplerMixer()
        mixer.setOutputRate(job.sampleRate)
        for (index, slot) in job.slots { mixer.setSlot(index, to: slot) }
        for (note, sound) in job.noteSounds { mixer.setNoteSound(note, to: sound) }

        let sequence = SamplerMixer.Sequence(events: job.events, length: job.seconds, beatLength: job.secondsPerBeat)
        mixer.setSequence(sequence)
        mixer.startTransport()

        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        _ = SamplerGraph.build(
            in: engine,
            mixer: mixer,
            format: format,
            master: job.master,
            plugins: job.plugins,
            slotPlugins: job.slotPlugins
        )
        try engine.start()
        defer { engine.stop() }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: job.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: job.url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw BounceError.couldNotRender
        }

        var remaining = AVAudioFrameCount((job.seconds * job.sampleRate).rounded())
        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let frames = min(remaining, chunk)
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw BounceError.couldNotRender }
            try file.write(from: buffer)
            remaining -= frames
        }
        withExtendedLifetime(sequence) {}
        withExtendedLifetime(job.keepAlive) {}
    }
}
